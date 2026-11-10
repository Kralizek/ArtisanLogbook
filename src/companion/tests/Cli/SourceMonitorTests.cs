using System.Security.Cryptography;

using ArtisanLogbook.Runtime;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class SourceMonitorTests
{
    [Test]
    public async Task ActivationDiscoversFlavorsAndPeriodicTicksRecoverMissedNotifications()
    {
        await using MonitoringTestHost host = new();
        string retail = host.Ledger("_retail_", "R", project: 2);
        host.Ledger("_classic_", "C", project: 1);
        await host.StartAsync(enabled: true, interval: 10);
        await MonitoringTestHost.Eventually(() => host.Checkpoints.Read().Document.Sources.Values.Count(s => s.Successful is not null) == 2);
        await host.Settled();
        Assert.That(host.Imports.Calls, Is.EqualTo(2));
        Assert.That(host.Imports.MaximumActive, Is.EqualTo(1));
        File.AppendAllText(retail, "\n--missed notification");
        host.Ledger("_new_client_", "NEW", project: 3);
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(10).Ticks);
        await MonitoringTestHost.Eventually(() => host.History.ReadStatus().TotalCraftCount == 3 &&
            host.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(retail)].Successful?.Fingerprint == Hash(retail));
        await host.Settled();
        Assert.That(host.Imports.Calls, Is.EqualTo(4));
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(10).Ticks);
        await MonitoringTestHost.Eventually(() => host.Monitor.Read().LastReconciliation?.At == host.Scheduler.Now);
        await host.Settled();
        Assert.That(host.Imports.Calls, Is.EqualTo(4), "periodic inspection must not import unchanged content");
    }

    [Test]
    public async Task UnavailableRootReappearsThroughPeriodicDiscoveryAlone()
    {
        await using MonitoringTestHost host = new();
        Directory.Delete(host.Root);
        await host.StartAsync(enabled: true, interval: 10);
        await MonitoringTestHost.Eventually(() => host.Monitor.Read().LastReconciliation is not null);
        Assert.That(host.Monitor.Read().Diagnostics.Select(d => d.Code), Does.Contain("discovery-failed"));
        string source = host.Ledger("_classic_", "LATE");
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(10).Ticks);
        await MonitoringTestHost.Eventually(() =>
            host.Checkpoints.Read().Document.Sources.GetValueOrDefault(SourceCatalog.IdFor(source))?.Successful is not null);
        await host.Settled();
        Assert.That(host.Monitor.Read().Phase, Is.EqualTo(MonitoringPhase.Active));
    }

    [Test]
    public async Task RealWatchersDiscoverAtomicReplacementRemovalAndReappearance()
    {
        await using MonitoringTestHost host = new();
        string retail = host.Ledger();
        await host.StartAsync(enabled: true, interval: 86400, realWatchers: true);
        await MonitoringTestHost.Eventually(() => host.Checkpoints.Read().Document.Sources.GetValueOrDefault(SourceCatalog.IdFor(retail))?.Successful is not null);
        await host.Settled();
        string classic = host.Ledger("_classic_", "C", project: 2);
        await MonitoringTestHost.Eventually(() => host.History.ReadStatus().TotalCraftCount == 2);
        await host.Settled();
        File.WriteAllText(retail + ".new", File.ReadAllText(retail) + "\n--atomic replacement");
        File.Move(retail + ".new", retail, overwrite: true);
        await MonitoringTestHost.Eventually(() =>
            host.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(retail)].Successful?.Fingerprint == Hash(retail));
        File.Delete(classic);
        await MonitoringTestHost.Eventually(() => host.Monitor.Read().LastReconciliation?.DiscoveredSources == 1);
        Assert.That(host.History.ReadStatus().TotalCraftCount, Is.EqualTo(2));
        host.Ledger("_classic_", "C", project: 2);
        await MonitoringTestHost.Eventually(() => host.Monitor.Read().LastReconciliation?.DiscoveredSources == 2 &&
            host.Checkpoints.Read().Document.Sources.GetValueOrDefault(SourceCatalog.IdFor(classic))?.Successful is not null);
        Assert.That(host.History.ReadStatus().TotalCraftCount, Is.EqualTo(2));
    }

    [Test]
    public async Task IncompleteSnapshotRetriesAndRecoveredContentStopsReimporting()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger(content: "ArtisanLogbookDB = {");
        string id = SourceCatalog.IdFor(source);
        await host.StartAsync(enabled: true);
        await MonitoringTestHost.Eventually(() =>
            host.Checkpoints.Read().Document.Sources.GetValueOrDefault(id)?.LastAttempt?.Outcome == CheckpointAttemptOutcome.Failed);
        long first = host.Checkpoints.Read().Document.Sources[id].LastAttempt!.Sequence;
        Assert.That(host.Monitor.Read().Diagnostics.Select(d => d.Code), Does.Contain("source-import-failed"));
        host.Scheduler.AdvanceBy(MonitoringCheckpoints.RetryDelay.Ticks);
        await MonitoringTestHost.Eventually(() =>
            host.Checkpoints.Read().Document.Sources[id].LastAttempt is { Outcome: CheckpointAttemptOutcome.Failed } attempt &&
            attempt.Sequence > first);
        host.Ledger();
        host.Scheduler.AdvanceBy(MonitoringCheckpoints.RetryDelay.Ticks);
        await MonitoringTestHost.Eventually(() => host.Checkpoints.Read().Document.Sources[id].Successful is not null);
        await host.Settled();
        int calls = host.Imports.Calls;
        int reads = host.Reader.Reads[source];
        File.SetLastWriteTimeUtc(source, DateTime.UtcNow.AddSeconds(1));
        host.Feed.Events.OnNext(new(SourceChangeReason.FileSystem, id));
        host.Scheduler.AdvanceBy(SourceChangeFeed.Debounce.Ticks);
        await MonitoringTestHost.Eventually(() => host.Reader.Reads[source] > reads);
        await host.Settled();
        Assert.That(host.Imports.Calls, Is.EqualTo(calls));
    }

    [Test]
    public async Task CheckpointRetryDoesNotRequireAnotherImport()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        MonitoringCheckpointTests.MemoryStore metadata = new() { Fail = true };
        await host.StartAsync(enabled: true, checkpointStore: metadata);
        await MonitoringTestHost.Eventually(() =>
            host.Checkpoints.Read().Document.Sources.GetValueOrDefault(SourceCatalog.IdFor(source))?.Successful is not null &&
            host.Checkpoints.Read().PersistenceFailure is not null);
        Assert.That(host.Checkpoints.Read().IsDirty, Is.True);
        int passes = host.Logs.Entries.Count(log => log.Event == MonitoringEvents.ReconciliationCompleted);
        int inspections = host.Reader.Reads[source];
        metadata.Fail = false;
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(1).Ticks);
        await host.Settled();
        Assert.That(metadata.Durable.Sources[SourceCatalog.IdFor(source)].Successful, Is.Not.Null);
        Assert.That(host.Imports.Calls, Is.EqualTo(1));
        Assert.That(host.Logs.Entries.Count(log => log.Event == MonitoringEvents.ReconciliationCompleted), Is.EqualTo(passes));
        Assert.That(host.Reader.Reads[source], Is.EqualTo(inspections), "terminal receipt persistence must not inspect the source again");
    }

    [Test]
    public async Task RestartUsesDurableExactFingerprintsWithoutReimportingUnchangedContent()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        await host.StartAsync(enabled: true);
        await MonitoringTestHost.Eventually(() => host.Checkpoints.Read().Document.Sources.GetValueOrDefault(SourceCatalog.IdFor(source))?.Successful is not null);
        await host.Settled();
        await host.App.StopAsync();
        host.Http.Dispose();
        await host.App.DisposeAsync();

        await host.StartAsync(enabled: true);
        await MonitoringTestHost.Eventually(() => host.Monitor.Read().LastReconciliation?.DiscoveredSources == 1);
        await host.Settled();
        Assert.That(host.Imports.Calls, Is.Zero);
        Assert.That(host.History.ReadStatus().TotalCraftCount, Is.EqualTo(1));
        Assert.That(host.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(source)].Successful!.Fingerprint, Is.EqualTo(Hash(source)));
    }

    [Test]
    public async Task DisabledActivationCannotPublishActiveEvenWhenInspectionIgnoresCancellation()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        await host.StartAsync();
        host.Operations.Submit(SourceCatalog.IdFor(source));
        await MonitoringTestHost.Eventually(() => host.Operations.List(10).All(operation => operation.CompletedAt is not null));
        await host.Settled();
        TestGate<ArtisanLogbook.ImportService.SavedVariablesSnapshot> gate = host.Reader.BlockNext();
        host.Preferences(true);
        await gate.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        host.Preferences(false);
        Assert.That(host.Feed.Subscriptions, Is.Zero);
        Assert.That(host.Monitor.Read().Phase, Is.EqualTo(MonitoringPhase.Disabled));
        host.Checkpoints.Defer(SourceCatalog.IdFor(source), host.Scheduler.Now);
        gate.Release.SetResult();
        await host.Settled();
        Assert.That(host.Monitor.Read().Phase, Is.EqualTo(MonitoringPhase.Disabled));
        Assert.That(host.Imports.Calls, Is.EqualTo(1));
    }

    [Test]
    public async Task ReenableWaitsForPreviousInspectionWhileNewEventsRemainObservable()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        await host.StartAsync();
        TestGate<ArtisanLogbook.ImportService.SavedVariablesSnapshot> gate = host.Reader.BlockNext();
        host.Preferences(true);
        await gate.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        host.Preferences(false);
        host.Preferences(true);
        Assert.That(host.Feed.Subscriptions, Is.EqualTo(1));
        Assert.That(host.Monitor.Read().Phase, Is.EqualTo(MonitoringPhase.Starting));
        for (int i = 0; i < 10_000; i++) host.Monitor.RequestReconciliation();
        host.Feed.Events.OnNext(new(SourceChangeReason.FileSystem, SourceCatalog.IdFor(source)));
        host.Scheduler.AdvanceBy(SourceChangeFeed.Debounce.Ticks);
        Assert.That(host.Reader.Reads[source], Is.EqualTo(1), "replacement cannot overlap the still-running pass");
        gate.Release.SetResult();
        await MonitoringTestHost.Eventually(() => host.Checkpoints.Read().Document.Sources.GetValueOrDefault(SourceCatalog.IdFor(source))?.Successful is not null);
        await host.Settled();
        Assert.That(host.Imports.Calls, Is.EqualTo(1));
        Assert.That(host.Reader.Reads[source], Is.LessThanOrEqualTo(6), "bursts must not leave a reconciliation backlog");
    }

    [Test]
    public async Task EnableDisableDuringWatcherBackoffRespondsWithoutWaitingForRetry()
    {
        await using MonitoringTestHost host = new();
        host.Feed.Failure = new IOException("unavailable root");
        await host.StartAsync(enabled: true);
        Assert.That(host.Monitor.Read().Diagnostics.Select(d => d.Code), Does.Contain("watcher-unavailable"));
        int attempts = host.Feed.Attempts;
        host.Preferences(false);
        host.Scheduler.AdvanceBy(TimeSpan.FromHours(1).Ticks);
        Assert.That(host.Feed.Attempts, Is.EqualTo(attempts));
        host.Feed.Failure = null;
        host.Preferences(true);
        Assert.That(host.Feed.Attempts, Is.EqualTo(attempts + 1));
        Assert.That(host.Feed.Subscriptions, Is.EqualTo(1));
        await host.Settled();
        Assert.That(host.Monitor.Read().Diagnostics.Select(d => d.Code), Does.Not.Contain("watcher-unavailable"));
    }

    [Test]
    public async Task UnexpectedReconciliationFailureDoesNotTerminateThePipeline()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        host.Reader.UnexpectedFailure = new IOException("controlled unexpected failure");
        await host.StartAsync(enabled: true, interval: 1);
        await MonitoringTestHost.Eventually(() => host.Monitor.Read().Diagnostics.Any(d => d.Code == "reconciliation-failed"));
        host.Reader.UnexpectedFailure = null;
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(1).Ticks);
        await MonitoringTestHost.Eventually(() => host.Checkpoints.Read().Document.Sources.GetValueOrDefault(SourceCatalog.IdFor(source))?.Successful is not null);
        await host.Settled();
        Assert.That(host.Monitor.Read().Phase, Is.EqualTo(MonitoringPhase.Active));
    }

    [Test]
    public async Task ShutdownDrainsAcceptedManualImportBeforeFinalCheckpointAcknowledgement()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        await host.StartAsync();
        var gate = host.Imports.BlockNext();
        host.Operations.Submit(SourceCatalog.IdFor(source));
        var result = await gate.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Task stopping = host.App.StopAsync();
        Assert.That(stopping.IsCompleted, Is.False);
        Assert.That(host.Operations.Submit(null).Rejection, Is.EqualTo(ImportRejection.Stopping));
        gate.Release.SetResult();
        await stopping.WaitAsync(TimeSpan.FromSeconds(10));
        CheckpointDocument saved = new MonitoringCheckpointStore(host.Paths.ResolveDatabase(null) + ".monitoring.json").Load();
        Assert.That(saved.Sources[SourceCatalog.IdFor(source)].Successful!.Fingerprint, Is.EqualTo(result.SourceFingerprint));
        Assert.That(host.Checkpoints.Read().IsDirty, Is.False);
        Assert.That(host.Monitor.Read().Phase, Is.EqualTo(MonitoringPhase.Stopped));
        Assert.That(host.Feed.Subscriptions, Is.Zero);
        Assert.That(() => host.History.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
    }

    [Test]
    public async Task ApplicationStoppingImmediatelyDisposesSourcesWithoutWaitingForStopAsync()
    {
        await using MonitoringTestHost host = new();
        await host.StartAsync(enabled: true);
        Assert.That(host.Feed.Subscriptions, Is.EqualTo(1));
        host.App.Lifetime.StopApplication();
        Assert.That(host.Feed.Subscriptions, Is.Zero);
        Assert.That(host.Monitor.Read().Phase, Is.EqualTo(MonitoringPhase.Stopping));
        Assert.That(host.Monitor.RequestReconciliation(), Is.EqualTo(ReconciliationRequestOutcome.Stopping));
    }

    [Test]
    public async Task ShutdownPersistenceFailureRemainsUnacknowledgedAndReleasesHistoryWriter()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        MonitoringCheckpointTests.MemoryStore metadata = new() { Fail = true };
        await host.StartAsync(checkpointStore: metadata);
        host.Operations.Submit(SourceCatalog.IdFor(source));
        await MonitoringTestHost.Eventually(() => host.Operations.List(10).All(operation => operation.CompletedAt is not null));
        Assert.CatchAsync<IOException>(() => host.App.StopAsync());
        Assert.That(host.Checkpoints.Read().IsDirty, Is.True);
        Assert.That(host.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(source)].Successful, Is.Not.Null);
        Assert.That(metadata.Durable.Sources, Is.Empty);
        Assert.That(() => host.History.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        metadata.Fail = false;
        await host.Checkpoints.FlushAsync();
        Assert.That(metadata.Durable.Sources[SourceCatalog.IdFor(source)].Successful, Is.Not.Null);
    }

    [Test]
    public async Task ShutdownDisposesSubscriptionsButWaitsForInspectionToUnwind()
    {
        await using MonitoringTestHost host = new();
        host.Ledger();
        await host.StartAsync();
        var gate = host.Reader.BlockNext();
        host.Preferences(true);
        await gate.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Task stopping = host.App.StopAsync();
        Assert.That(host.Feed.Subscriptions, Is.Zero);
        Assert.That(stopping.IsCompleted, Is.False);
        gate.Release.SetResult();
        await stopping.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.That(host.Imports.Calls, Is.Zero);
        Assert.That(host.Checkpoints.Read().Document.Sources.Values.All(source => source.Successful is null), Is.True);
        Assert.That(host.Monitor.Read().Phase, Is.EqualTo(MonitoringPhase.Stopped));
    }

    [Test]
    public async Task ConcurrentWatcherDiagnosticsAndRequestsDoNotInvertStatusAndRxLocks()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        await host.StartAsync(enabled: true);
        await MonitoringTestHost.Eventually(() => host.Checkpoints.Read().Document.Sources.GetValueOrDefault(SourceCatalog.IdFor(source))?.Successful is not null);
        await host.Settled();
        using ManualResetEventSlim start = new();
        Task requests = Task.Run(() =>
        {
            start.Wait();
            for (int i = 0; i < 1_000; i++) host.Monitor.RequestReconciliation();
        });
        Task watcher = Task.Run(() =>
        {
            start.Wait();
            for (int i = 0; i < 1_000; i++)
                host.Feed.Events.OnNext(new(i % 2 == 0 ? SourceChangeReason.WatcherUnavailable : SourceChangeReason.WatcherReady,
                    SourceCatalog.IdFor(host.Root)));
        });
        start.Set();
        await Task.WhenAll(requests, watcher).WaitAsync(TimeSpan.FromSeconds(10));
        await host.Settled();
        Assert.That(host.Imports.Calls, Is.EqualTo(1));
        Assert.That(host.Monitor.Read().Diagnostics.Select(d => d.Code), Does.Not.Contain("watcher-unavailable"));
    }

    private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
}
