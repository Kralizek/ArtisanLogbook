using ArtisanLogbook.ImportService;
using ArtisanLogbook.Runtime;

using Microsoft.Extensions.Logging;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class MonitoringLoggingTests
{
    [Test]
    public async Task PartialMultiSourceImportHasAnExplicitAggregateEvent()
    {
        await using MonitoringTestHost host = new();
        host.Ledger("_retail_", "VALID");
        host.Ledger("_forever_", "INCOMPLETE", content: "ArtisanLogbookDB = {");
        await host.StartAsync();
        ImportSubmission submission = host.Operations.Submit(null);
        Assert.That(submission.Rejection, Is.Null);
        await Logged(host, MonitoringEvents.ImportPartiallyCompleted);
        CapturedLog partial = Events(host, MonitoringEvents.ImportPartiallyCompleted).Single();
        Assert.That(partial.Properties["SuccessfulSources"], Is.EqualTo(1));
        Assert.That(partial.Properties["SourceCount"], Is.EqualTo(2));
        Assert.That(partial.Properties["OperationId"], Is.EqualTo(submission.Operation!.Id));
        Assert.That(host.Operations.Get(submission.Operation.Id)!.Outcome, Is.EqualTo(ImportOperationOutcome.Partial));
        Assert.That(Events(host, MonitoringEvents.ImportCompleted).Select(log => log.Properties["SourceLabel"]),
            Is.EquivalentTo(new[] { "_retail_", "_forever_" }));
    }

    [Test]
    public async Task LifecycleDescribesEffectiveOptionsAndLiveDisable()
    {
        await using MonitoringTestHost host = new();
        await host.StartAsync(enabled: true, interval: 17);
        await Logged(host, MonitoringEvents.Enabled);
        CapturedLog enabled = Events(host, MonitoringEvents.Enabled).Single();
        Assert.That(enabled.Level, Is.EqualTo(LogLevel.Information));
        Assert.That(enabled.Properties["RootCount"], Is.EqualTo(1));
        Assert.That(enabled.Properties["IntervalSeconds"], Is.EqualTo(17));
        host.Preferences(false);
        await Logged(host, MonitoringEvents.Disabled);
        Assert.That(Events(host, MonitoringEvents.Disabled).Single().Level, Is.EqualTo(LogLevel.Information));
        await host.App.StopAsync();
        Assert.That(Events(host, MonitoringEvents.Stopping).Single().Level, Is.EqualTo(LogLevel.Information));
        Assert.That(Events(host, MonitoringEvents.Stopped).Single().Level, Is.EqualTo(LogLevel.Information));
    }

    [Test]
    public async Task DisabledInvocationIsVisibleEvenWhenSavedPreferenceIsEnabled()
    {
        await using MonitoringTestHost host = new();
        await host.StartAsync(enabled: true, enabledOverride: false);
        await Logged(host, MonitoringEvents.Disabled);
        Assert.That(Events(host, MonitoringEvents.Enabled), Is.Empty);
        host.Preferences(true, 23);
        Assert.That(host.Monitor.Read().Configuration.EffectiveSettings.Monitoring.Enabled, Is.False);
        Assert.That(Events(host, MonitoringEvents.Enabled), Is.Empty);
    }

    [Test]
    public async Task PeriodicSummaryUsesReportCountsAndMaintenanceTicksAreNotInformationHeartbeats()
    {
        await using MonitoringTestHost host = new();
        await host.StartAsync(enabled: true, interval: 10);
        await Logged(host, MonitoringEvents.ReconciliationCompleted);
        await host.Settled();
        host.Monitor.RequestReconciliation();
        await MonitoringTestHost.Eventually(() => Events(host, MonitoringEvents.ReconciliationCompleted)
            .Any(log => ((string)log.Properties["TriggerReasons"]!).Contains("Requested")));
        int summaries = Events(host, MonitoringEvents.ReconciliationCompleted).Count(log => log.Level == LogLevel.Information);
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(9).Ticks);
        await host.Settled();
        Assert.That(Events(host, MonitoringEvents.ReconciliationCompleted).Count(log => log.Level == LogLevel.Information),
            Is.EqualTo(summaries));
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(1).Ticks);
        await MonitoringTestHost.Eventually(() => Events(host, MonitoringEvents.ReconciliationCompleted)
            .Any(log => log.Level == LogLevel.Information && log.Properties["TriggerReasons"]!.ToString()!.Contains("Periodic")));
        CapturedLog periodic = Events(host, MonitoringEvents.ReconciliationCompleted).Last();
        ReconciliationReport report = host.Monitor.Read().LastReconciliation!;
        Assert.That(periodic.Properties["DiscoveredSources"], Is.EqualTo(report.DiscoveredSources));
        Assert.That(periodic.Properties["SubmittedImports"], Is.EqualTo(report.SubmittedImports));
        Assert.That(periodic.Properties["DurationMs"], Is.TypeOf<long>());
        Assert.That(periodic.Properties["DiagnosticCount"], Is.EqualTo(report.Diagnostics.Count));
    }

    [Test]
    public async Task AutomaticAdmissionCompletionUnchangedAndSupersededBytesHaveStructuredEvents()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        await host.StartAsync(enabled: true);
        await Logged(host, MonitoringEvents.AutomaticImportAdmitted);
        await Logged(host, MonitoringEvents.ImportCompleted);
        await host.Settled();
        CapturedLog admitted = Events(host, MonitoringEvents.AutomaticImportAdmitted).Single();
        CapturedLog completed = Events(host, MonitoringEvents.ImportCompleted).Single();
        Assert.That(admitted.Level, Is.EqualTo(LogLevel.Information));
        Assert.That(admitted.Properties["SourceId"], Is.EqualTo(SourceCatalog.IdFor(source)));
        Assert.That(completed.Properties["OperationId"], Is.EqualTo(admitted.Properties["OperationId"]));
        Assert.That(completed.Properties["Origin"], Is.EqualTo(ImportOrigin.Automatic));
        Assert.That(completed.Properties["Outcome"], Is.EqualTo(CompanionImportOutcome.Successful));
        Assert.That(completed.Properties["Observations"], Is.EqualTo(1));
        Assert.That(completed.Properties["Inserted"], Is.EqualTo(1));
        host.Monitor.RequestReconciliation();
        await Logged(host, MonitoringEvents.SourceUnchanged);
        Assert.That(Events(host, MonitoringEvents.SourceUnchanged).Last().Level, Is.EqualTo(LogLevel.Debug));
        File.AppendAllText(source, "\n-- later stable bytes");
        host.Monitor.RequestReconciliation();
        await Logged(host, MonitoringEvents.FingerprintSuperseded);
        Assert.That(Events(host, MonitoringEvents.FingerprintSuperseded).Single().Level, Is.EqualTo(LogLevel.Debug));
        await MonitoringTestHost.Eventually(() => Events(host, MonitoringEvents.ImportCompleted).Length == 2);
        Assert.That(Events(host, MonitoringEvents.ImportCompleted).Last().Properties["AlreadyPresent"], Is.EqualTo(1));
    }

    [TestCase("source-changed-during-read")]
    [TestCase("source-read-failed")]
    [TestCase("invalid-source-encoding")]
    public async Task SnapshotFailureIsDebugWithCodeAndExceptionAndCompletedWriteEventuallyImports(string code)
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        SourceSnapshotException failure = new(code, "controlled snapshot failure");
        host.Reader.Failures[source] = failure;
        await host.StartAsync(enabled: true);
        await Logged(host, MonitoringEvents.SourceInspectionFailed);
        CapturedLog log = Events(host, MonitoringEvents.SourceInspectionFailed).First();
        Assert.That(log.Level, Is.EqualTo(LogLevel.Debug));
        Assert.That(log.Properties["DiagnosticCode"], Is.EqualTo(code));
        Assert.That(log.Exception, Is.SameAs(failure));
        Assert.That(host.Logs.Entries.Any(entry => entry.Level >= LogLevel.Error), Is.False);
        host.Reader.Failures.Clear();
        host.Scheduler.AdvanceBy(MonitoringCheckpoints.RetryDelay.Ticks);
        await Logged(host, MonitoringEvents.ImportCompleted);
        Assert.That(host.Checkpoints.Read().Document.Sources[SourceCatalog.IdFor(source)].Successful, Is.Not.Null);
    }

    [Test]
    public async Task WatcherFailureIsOneWarningPerOutageAndRecoveryIsInformation()
    {
        await using MonitoringTestHost host = new();
        host.Feed.Failure = new IOException("controlled watcher failure");
        await host.StartAsync(enabled: true);
        await Logged(host, MonitoringEvents.WatcherUnavailable);
        Assert.That(Events(host, MonitoringEvents.WatcherUnavailable).Single().Level, Is.EqualTo(LogLevel.Warning));
        host.Scheduler.AdvanceBy(SourceChangeFeed.WatcherRetry.Ticks * 3);
        Assert.That(Events(host, MonitoringEvents.WatcherUnavailable), Has.Length.EqualTo(1));
        host.Feed.Failure = null;
        host.Scheduler.AdvanceBy(SourceChangeFeed.WatcherRetry.Ticks);
        await Logged(host, MonitoringEvents.WatcherReady);
        CapturedLog recovery = Events(host, MonitoringEvents.WatcherReady).Single();
        Assert.That(recovery.Level, Is.EqualTo(LogLevel.Information));
        Assert.That(recovery.Properties["WatcherState"], Is.EqualTo("recovered"));
    }

    [Test]
    public async Task CheckpointPersistenceLogsFailureAndRecoveryWithoutDuplicateErrors()
    {
        await using MonitoringTestHost host = new();
        host.Ledger();
        MonitoringCheckpointTests.MemoryStore store = new() { Fail = true };
        await host.StartAsync(enabled: true, checkpointStore: store);
        await Logged(host, MonitoringEvents.CheckpointSaveFailed);
        await MonitoringTestHost.Eventually(() => host.Checkpoints.Read().PersistenceFailure is not null &&
            host.Checkpoints.Read().Document.Sources.Values.All(source => source.Successful is not null));
        host.Monitor.RequestReconciliation();
        await MonitoringTestHost.Eventually(() => Events(host, MonitoringEvents.ReconciliationCompleted)
            .Any(log => ((string)log.Properties["TriggerReasons"]!).Contains("Requested")));
        int summaries = Events(host, MonitoringEvents.ReconciliationCompleted).Count(log => log.Level == LogLevel.Information);
        int failures = host.Logs.Entries.Count(log => log.Message == "Monitoring checkpoint persistence failure detail.");
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(3).Ticks);
        await MonitoringTestHost.Eventually(() => host.Logs.Entries.Count(log =>
            log.Message == "Monitoring checkpoint persistence failure detail.") > failures);
        Assert.That(Events(host, MonitoringEvents.CheckpointSaveFailed), Has.Length.EqualTo(1));
        Assert.That(Events(host, MonitoringEvents.ReconciliationFailed), Is.Empty);
        Assert.That(Events(host, MonitoringEvents.ReconciliationCompleted).Count(log => log.Level == LogLevel.Information),
            Is.EqualTo(summaries), "dirty checkpoint maintenance must not become an Information heartbeat");
        IOException unrelatedFailure = new("controlled unexpected inspection failure");
        host.Reader.UnexpectedFailure = unrelatedFailure;
        host.Monitor.RequestReconciliation();
        await Logged(host, MonitoringEvents.ReconciliationFailed);
        Assert.That(Events(host, MonitoringEvents.ReconciliationFailed).Last().Exception, Is.SameAs(unrelatedFailure),
            "an outstanding persistence outage must not hide an unrelated monitoring error");
        host.Reader.UnexpectedFailure = null;
        store.Fail = false;
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(1).Ticks);
        await Logged(host, MonitoringEvents.CheckpointSaveRecovered);
        await host.Settled();
    }

    [Test]
    public async Task BoundedTrailingPassRetainsCombinedCausesRatherThanOnlyTheLatestInvalidation()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        await host.StartAsync(interval: 10);
        var gate = host.Reader.BlockNext();
        host.Preferences(true, 10);
        await gate.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        host.Monitor.RequestReconciliation();
        host.Feed.Events.OnNext(new(SourceChangeReason.FileSystem, SourceCatalog.IdFor(source)));
        host.Scheduler.AdvanceBy(TimeSpan.FromSeconds(10).Ticks);
        gate.Release.SetResult();
        await MonitoringTestHost.Eventually(() => Events(host, MonitoringEvents.ReconciliationCompleted).Any(log =>
        {
            string reasons = (string)log.Properties["TriggerReasons"]!;
            return reasons.Contains("Requested") && reasons.Contains("FileSystem") && reasons.Contains("Periodic");
        }));
        Assert.That(Events(host, MonitoringEvents.FileChanged).Single().Level, Is.EqualTo(LogLevel.Debug));
    }

    private static CapturedLog[] Events(MonitoringTestHost host, EventId eventId) =>
        host.Logs.Entries.Where(log => log.Event == eventId).ToArray();

    private static Task Logged(MonitoringTestHost host, EventId eventId) =>
        MonitoringTestHost.Eventually(() => Events(host, eventId).Length > 0, $"event {eventId.Name} was not logged");
}
