using ArtisanLogbook.Runtime;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class MonitoringMaintenanceTests
{
    [Test]
    public async Task DirtyActiveImportRetriesPersistenceWithoutRediscoveringOrInspectingSources()
    {
        await using MonitoringTestHost host = new();
        string retail = host.Ledger();
        host.Ledger("_forever_", "B");
        MonitoringCheckpointTests.MemoryStore store = new() { Fail = true };
        await host.StartAsync(checkpointStore: store);
        var import = host.Imports.BlockNext();
        host.Preferences(true);
        await import.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await Fence(host);
        int passes = Passes(host);
        int inspections = host.Reader.Reads.Values.Sum();
        Assert.That(host.Operations.IsSourceActive(SourceCatalog.IdFor(retail)), Is.True);
        Assert.That(host.Checkpoints.Read().IsDirty, Is.True);

        for (int tick = 0; tick < 8; tick++)
        {
            int failures = SaveFailures(host);
            host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(1).Ticks);
            await MonitoringTestHost.Eventually(() => SaveFailures(host) > failures);
        }
        TestContext.Out.WriteLine($"Eight active-import maintenance ticks: {Passes(host) - passes} full passes, " +
            $"{host.Reader.Reads.Values.Sum() - inspections} snapshot inspections.");
        Assert.That(Passes(host) - passes, Is.Zero, "dirty state needs persistence, not full reconciliation");
        Assert.That(host.Reader.Reads.Values.Sum(), Is.EqualTo(inspections));

        store.Fail = false;
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(1).Ticks);
        await MonitoringTestHost.Eventually(() => !host.Checkpoints.Read().IsDirty);
        Assert.That(store.Durable.Sources[SourceCatalog.IdFor(retail)].LastAttempt!.Outcome,
            Is.EqualTo(CheckpointAttemptOutcome.Pending));
        Assert.That(Passes(host), Is.EqualTo(passes));
        import.Release.SetResult();
        await host.Settled();
        await MonitoringTestHost.Eventually(() => !host.Operations.IsSourceActive(SourceCatalog.IdFor(retail)));
        Assert.That(store.Durable.Sources.Values.All(source => source.Successful is not null), Is.True);
        Assert.That(Passes(host), Is.EqualTo(passes), "matching completion requires acknowledgement, not inspection");

        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(20).Ticks);
        await Fence(host);
        Assert.That(Passes(host), Is.EqualTo(passes + 1), "idle ticks add no passes; only the explicit fence reconciles");
        Assert.That(host.Monitor.Read().PendingSources, Is.Zero);
        Assert.That(host.Monitor.Read().Diagnostics, Is.Empty);
    }

    [Test]
    public async Task ChangedBytesDuringActiveImportAreReconciledOnceAfterCompletion()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        await host.StartAsync();
        var import = host.Imports.BlockNext();
        host.Preferences(true);
        await import.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await Fence(host);
        File.AppendAllText(source, "\n-- bytes saved while the previous import is active");
        host.Feed.Events.OnNext(new(SourceChangeReason.FileSystem, SourceCatalog.IdFor(source)));
        host.Scheduler.AdvanceBy(SourceChangeFeed.Debounce.Ticks);
        await MonitoringTestHost.Eventually(() => host.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(source)].Observed !=
            import.Entered.Task.Result.SourceFingerprint);
        await Fence(host);
        int passes = Passes(host);
        int inspections = host.Reader.Reads[source];
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(8).Ticks);
        await Fence(host);
        Assert.That(Passes(host), Is.EqualTo(passes + 1));
        Assert.That(host.Reader.Reads[source], Is.EqualTo(inspections + 1));
        Assert.That(host.Imports.Calls, Is.EqualTo(1));

        passes = Passes(host);
        import.Release.SetResult();
        await MonitoringTestHost.Eventually(() => host.Imports.Calls == 2 &&
            host.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(source)].Successful?.Fingerprint ==
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(source))));
        await host.Settled();
        Assert.That(Passes(host), Is.EqualTo(passes + 1), "one completion-triggered pass observes the newer bytes");
        Assert.That(host.Imports.MaximumActive, Is.EqualTo(1));
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(20).Ticks);
        await Fence(host);
        Assert.That(Passes(host), Is.EqualTo(passes + 2));
    }

    [Test]
    public async Task ExpiredDeadlineOnUnchangedSourceDoesNotScheduleMaintenance()
    {
        using MonitoringCheckpoints checkpoints = new(new MonitoringCheckpointTests.MemoryStore());
        string id = SourceCatalog.IdFor("/source");
        string fingerprint = new('A', 64);
        DateTimeOffset now = DateTimeOffset.UnixEpoch;
        checkpoints.Observe(id, fingerprint);
        Assert.That(checkpoints.TryReserve([id], now, out var first), Is.True);
        checkpoints.Complete(id, first[id], CheckpointAttemptOutcome.Successful, fingerprint, now);
        Assert.That(checkpoints.TryReserve([id], now, out var second), Is.True);
        checkpoints.Complete(id, second[id], CheckpointAttemptOutcome.Failed, fingerprint, now);
        await checkpoints.FlushAsync();
        Assert.That(checkpoints.Read().Document.Sources[id].NeedsReconciliation, Is.False);
        Assert.That(checkpoints.Read().Document.Sources[id].RetryAfter, Is.Not.Null);
        Assert.That(checkpoints.NeedsMaintenance(now + TimeSpan.FromMinutes(1), true), Is.False);
    }

    [Test]
    public async Task CleanPendingReceiptWithExpiredDeferralIsNotAnActionableRetry()
    {
        using MonitoringCheckpoints checkpoints = new(new MonitoringCheckpointTests.MemoryStore());
        string id = SourceCatalog.IdFor("/active");
        DateTimeOffset now = DateTimeOffset.UnixEpoch;
        checkpoints.Observe(id, new string('B', 64));
        Assert.That(checkpoints.TryReserve([id], now, out _), Is.True);
        checkpoints.Defer(id, now);
        Assert.That(checkpoints.NeedsMaintenance(now, true), Is.True, "dirty reservation still needs persistence");
        await checkpoints.FlushAsync();
        Assert.That(checkpoints.Read().Document.Sources[id].NeedsReconciliation, Is.True,
            "the API's outstanding source count legitimately includes active imports");
        Assert.That(checkpoints.NeedsMaintenance(now + TimeSpan.FromMinutes(1), true), Is.False,
            "an active C11 attempt cannot admit more work just because its deferral elapsed");
    }

    [Test]
    public async Task ExpiredUnchangedDeadlineAndCleanActiveImportAddNoFullPassesButPeriodicDiscoveryStillRuns()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        await host.StartAsync(enabled: true, interval: 60);
        await MonitoringTestHost.Eventually(() => host.Checkpoints.Read().Document.Sources
            .GetValueOrDefault(SourceCatalog.IdFor(source))?.Successful is not null);
        await host.Settled();
        host.Checkpoints.Defer(SourceCatalog.IdFor(source), host.Scheduler.Now);
        await host.Checkpoints.FlushAsync();
        int passes = Passes(host);
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(8).Ticks);
        await Fence(host);
        Assert.That(Passes(host), Is.EqualTo(passes + 1), "expired backoff for successful unchanged bytes is not source work");

        var import = host.Imports.BlockNext();
        File.AppendAllText(source, "\n-- changed bytes");
        await Fence(host);
        await import.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await host.Settled();
        passes = Passes(host);
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(8).Ticks);
        await Fence(host);
        Assert.That(Passes(host), Is.EqualTo(passes + 1), "a pending receipt cannot admit another import");
        int importing = (int)host.Logs.Entries.Last(log => log.Event == MonitoringEvents.ReconciliationCompleted)
            .Properties["ImportingSources"]!;
        Assert.That(importing, Is.EqualTo(1));
        passes = Passes(host);
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(44).Ticks);
        await MonitoringTestHost.Eventually(() => Passes(host) > passes);
        Assert.That(host.Logs.Entries.Last(log => log.Event == MonitoringEvents.ReconciliationCompleted)
            .Properties["TriggerReasons"]!.ToString(), Does.Contain("Periodic"));
        Assert.That(host.Reader.Reads[source], Is.GreaterThan(passes), "periodic checks remain real inspections during imports");
        import.Release.SetResult();
        await host.Settled();
    }

    private static int Passes(MonitoringTestHost host) =>
        host.Logs.Entries.Count(log => log.Event == MonitoringEvents.ReconciliationCompleted);

    private static int SaveFailures(MonitoringTestHost host) =>
        host.Logs.Entries.Count(log => log.Message == "Monitoring checkpoint persistence failure detail.");

    private static async Task Fence(MonitoringTestHost host)
    {
        int requested = host.Logs.Entries.Count(IsRequested);
        host.Monitor.RequestReconciliation();
        await MonitoringTestHost.Eventually(() => host.Logs.Entries.Count(IsRequested) > requested);
    }

    private static bool IsRequested(CapturedLog log) =>
        log.Event == MonitoringEvents.ReconciliationCompleted &&
        ((string)log.Properties["TriggerReasons"]!).Contains("Requested", StringComparison.Ordinal);
}
