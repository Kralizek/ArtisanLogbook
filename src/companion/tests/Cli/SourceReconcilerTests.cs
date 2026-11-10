using System.Reactive.Concurrency;
using System.Security.Cryptography;

using ArtisanLogbook.ImportService;
using ArtisanLogbook.Runtime;

using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging.Abstractions;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.Cli;

[TestFixture]
public sealed class SourceReconcilerTests
{
    [Test]
    public async Task DiscoveryFingerprintChangesRemovalAndReappearanceWorkWithoutAnEventStream()
    {
        await using ReconciliationHarness harness = new();
        string retail = harness.Files.Ledger("_retail_", "R", project: 2);
        string classic = harness.Files.Ledger("_classic_", "C", project: 1);
        await harness.StartAsync();
        Assert.That((await harness.Reconcile()).SubmittedImports, Is.EqualTo(2));
        await harness.WaitForImports(2);
        await harness.Checkpoints.FlushAsync();
        Assert.That((await harness.Reconcile()).SubmittedImports, Is.Zero);
        Assert.That(harness.History.ReadStatus().Contexts.Select(context => (int)context.Game.Project),
            Is.EquivalentTo(new[] { 1, 2 }), "directory labels do not establish GameContext");

        DateTime timestamp = File.GetLastWriteTimeUtc(retail);
        string changed = File.ReadAllText(retail) + "\n--new";
        File.WriteAllText(retail + ".new", changed);
        File.SetLastWriteTimeUtc(retail + ".new", timestamp);
        File.Move(retail + ".new", retail, overwrite: true);
        Assert.That((await harness.Reconcile()).SubmittedImports, Is.EqualTo(1));
        await harness.WaitForImports(3);
        Assert.That(harness.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(retail)].Successful!.Fingerprint,
            Is.EqualTo(Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(retail)))));

        File.Delete(classic);
        await harness.Checkpoints.FlushAsync();
        Assert.That((await harness.Reconcile()).DiscoveredSources, Is.EqualTo(1));
        Assert.That(harness.History.ReadStatus().TotalCraftCount, Is.EqualTo(2));
        harness.Files.Ledger("_classic_", "C", project: 1);
        harness.Files.Ledger("_other_client_", "NEW", project: 3);
        Assert.That((await harness.Reconcile()).SubmittedImports, Is.EqualTo(2));
        await harness.WaitForImports(5);
        Assert.That(harness.History.ReadStatus().TotalCraftCount, Is.EqualTo(3));
    }

    [Test]
    public async Task UnstableSourceDoesNotPreventOtherFlavorAndIncompleteContentRetries()
    {
        await using ReconciliationHarness harness = new();
        string unstable = harness.Files.Ledger("_retail_");
        harness.Files.Ledger("_classic_", "C", project: 2);
        harness.Files.Reader.Failures[unstable] = new("source-changed-during-read", "controlled unstable write");
        await harness.StartAsync();
        ReconciliationReport initial = await harness.Reconcile();
        Assert.That(initial.SubmittedImports, Is.EqualTo(1));
        Assert.That(initial.Diagnostics.Single().Code, Is.EqualTo("source-changed-during-read"));
        await harness.WaitForImports(1);

        harness.Files.Reader.Failures.Clear();
        File.WriteAllText(unstable, "ArtisanLogbookDB = {");
        await harness.Reconcile();
        await harness.WaitForImports(2);
        SourceCheckpoint rejected = harness.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(unstable)];
        Assert.That(rejected.Successful, Is.Null);
        Assert.That(rejected.LastAttempt!.Outcome, Is.EqualTo(CheckpointAttemptOutcome.Failed));
        Assert.That((await harness.Reconcile()).SubmittedImports, Is.Zero, "failed unchanged bytes are in backoff");
        harness.Files.Ledger();
        Assert.That((await harness.Reconcile()).SubmittedImports, Is.EqualTo(1), "different bytes are immediately eligible");
        await harness.WaitForImports(3);
        Assert.That(harness.History.ReadStatus().TotalCraftCount, Is.EqualTo(2));
    }

    [Test]
    public async Task ObservationsDuringManualImportRemainPendingAndAutomaticImportsUseTheSameWorker()
    {
        await using ReconciliationHarness harness = new();
        string source = harness.Files.Ledger();
        await harness.StartAsync();
        TestGate<CompanionImportResult> gate = harness.Imports.BlockNext();
        ImportSubmission manual = harness.Operations.Submit(SourceCatalog.IdFor(source));
        CompanionImportResult ingested = await gate.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.That(manual.Rejection, Is.Null);
        Assert.That(harness.Operations.Submit(SourceCatalog.IdFor(source)).Rejection, Is.EqualTo(ImportRejection.SourceBusy));
        File.AppendAllText(source, "\n--later bytes");
        Assert.That((await harness.Reconcile()).SubmittedImports, Is.Zero);
        string observed = harness.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(source)].Observed!;
        Assert.That(observed, Is.Not.EqualTo(ingested.SourceFingerprint));
        gate.Release.SetResult();
        await harness.WaitForImports(1);
        SourceCheckpoint pending = harness.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(source)];
        Assert.That(pending.Successful!.Fingerprint, Is.EqualTo(ingested.SourceFingerprint));
        Assert.That(pending.RequiresImport, Is.True);
        Assert.That((await harness.Reconcile()).SubmittedImports, Is.EqualTo(1));
        await harness.WaitForImports(2);
        Assert.That(harness.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(source)].Successful!.Fingerprint, Is.EqualTo(observed));
        Assert.That(harness.Imports.MaximumActive, Is.EqualTo(1));
    }

    [Test]
    public async Task EvictedOperationsDoNotLoseManualReceiptsWhilePersistenceFails()
    {
        await using ReconciliationHarness harness = new(new(MaxRetainedOperations: 1));
        string source = harness.Files.Ledger();
        await harness.StartAsync();
        harness.Metadata.Fail = true;
        for (int i = 1; i <= 3; i++)
        {
            File.AppendAllText(source, $"\n--snapshot {i}");
            Assert.That(harness.Operations.Submit(SourceCatalog.IdFor(source)).Rejection, Is.Null);
            await harness.WaitForImports(i);
        }
        Assert.That(harness.Operations.List(100), Has.Count.EqualTo(1));
        Assert.ThrowsAsync<IOException>(() => harness.Checkpoints.FlushAsync());
        Assert.That((await harness.Reconcile()).SubmittedImports, Is.Zero, "an unacknowledged success still suppresses duplicate ingestion");
        harness.Metadata.Fail = false;
        await harness.Checkpoints.FlushAsync();
        Assert.That(harness.Metadata.Durable.Sources[SourceCatalog.IdFor(source)].Successful!.Sequence, Is.EqualTo(3));
        Assert.That(harness.Imports.Calls, Is.EqualTo(3));
    }

    [Test]
    public async Task AdmissionRechecksSuccessWhenInspectionBecameStale()
    {
        await using ReconciliationHarness harness = new();
        string path = harness.Files.Ledger();
        string id = SourceCatalog.IdFor(path);
        await harness.StartAsync();
        SavedVariablesSnapshot inspected = await harness.Files.Reader.ReadAsync(path);
        SourceCheckpoint decision = harness.Checkpoints.Observe(id, inspected.Fingerprint);
        Assert.That(decision.IsEligible(harness.Files.Scheduler.Now), Is.True);
        harness.Operations.Submit(id);
        await harness.WaitForImports(1);
        ImportSubmission automatic = harness.Operations.Submit(
            new(id, path, "_retail_", "ArtisanLogbook_Core.lua", null, null), inspected.Fingerprint, CancellationToken.None);
        Assert.That(automatic.Rejection, Is.EqualTo(ImportRejection.Unchanged));
        Assert.That(harness.Imports.Calls, Is.EqualTo(1));
    }

    [Test]
    public async Task BusySourceDoesNotStarveOtherSourcesWhenQueueCapacityIsOne()
    {
        await using ReconciliationHarness harness = new(new(MaxActiveOperations: 1));
        string busy = harness.Files.Ledger("_a_", "BUSY");
        for (int i = 0; i < 8; i++) harness.Files.Ledger("_z_", $"ACCOUNT{i}");
        await harness.StartAsync();
        for (int round = 0; round < 12; round++)
        {
            File.AppendAllText(busy, $"\n--busy {round}");
            await harness.Reconcile();
            await MonitoringTestHost.Eventually(() => harness.Operations.List(100).All(operation => operation.CompletedAt is not null));
            harness.Files.Scheduler.AdvanceBy(MonitoringCheckpoints.RetryDelay.Ticks);
            if (harness.Checkpoints.Read().Document.Sources.Values.Count(source => source.Successful is not null) == 9) break;
        }
        Assert.That(harness.Checkpoints.Read().Document.Sources.Values.Count(source => source.Successful is not null), Is.EqualTo(9));
        Assert.That(harness.Imports.MaximumActive, Is.EqualTo(1));
    }

    private sealed class ReconciliationHarness(ImportOperationLimits? limits = null) : IAsyncDisposable
    {
        private readonly Lifetime _lifetime = new();
        private ServiceProvider _services = null!;
        public MonitoringTestHost Files { get; } = new();
        public MonitoringCheckpointTests.MemoryStore Metadata { get; } = new();
        public MonitoringCheckpoints Checkpoints { get; private set; } = null!;
        public Store History { get; private set; } = null!;
        public ImportOperations Operations { get; private set; } = null!;
        public ControlledRuntimeImports Imports { get; private set; } = null!;
        public SourceReconciler Reconciler { get; private set; } = null!;

        public Task StartAsync()
        {
            Files.Settings.Save(CompanionSettings.ForRoots(Files.Root));
            var configuration = CompanionRuntimeConfiguration.Resolve(Files.Paths, Files.Settings);
            SourceCatalog catalog = new(configuration, new InstallationDiscovery());
            Checkpoints = new(Metadata);
            History = new(configuration.DatabasePath);
            CompanionWorkAdmission admission = new(NullLogger<CompanionWorkAdmission>.Instance);
            admission.Open();
            Imports = new(admission, new CompanionImportService(History, Files.Reader));
            _services = new ServiceCollection().AddSingleton(Checkpoints).AddSingleton<IScheduler>(Files.Scheduler)
                .AddSingleton<CompanionRuntimeImports>(Imports).BuildServiceProvider();
            Operations = new(_services, catalog, _lifetime, limits ?? new(), NullLogger<ImportOperations>.Instance);
            Reconciler = new(catalog, Files.Reader, Checkpoints, Operations);
            return Operations.StartAsync(CancellationToken.None);
        }

        public Task<ReconciliationReport> Reconcile() => Reconciler.ReconcileAsync(Files.Scheduler.Now, CancellationToken.None);

        public Task WaitForImports(int expected) => MonitoringTestHost.Eventually(() =>
            Imports.Calls == expected && Operations.List(100).All(operation => operation.CompletedAt is not null));

        public async ValueTask DisposeAsync()
        {
            Files.Reader.ReleaseAll();
            if (Operations is not null)
            {
                Imports.ReleaseAll();
                await Operations.StopAsync(CancellationToken.None);
                Operations.Dispose();
                Checkpoints.Dispose();
                History.Dispose();
                await _services.DisposeAsync();
            }
            _lifetime.Dispose();
            await Files.DisposeAsync();
        }
    }

    private sealed class Lifetime : IHostApplicationLifetime, IDisposable
    {
        private readonly CancellationTokenSource _stopping = new();
        public CancellationToken ApplicationStarted => CancellationToken.None;
        public CancellationToken ApplicationStopping => _stopping.Token;
        public CancellationToken ApplicationStopped => CancellationToken.None;
        public void StopApplication() => _stopping.Cancel();
        public void Dispose() => _stopping.Dispose();
    }
}
