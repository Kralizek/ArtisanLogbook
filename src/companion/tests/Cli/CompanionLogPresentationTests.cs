using System.Text;
using System.Text.RegularExpressions;

using ArtisanLogbook.Cli.Logging;
using ArtisanLogbook.Runtime;

using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

using NUnit.Framework;

using Spectre.Console;
using Spectre.Console.Testing;

namespace Tests.Cli;

[TestFixture]
public sealed class CompanionLogPresentationTests
{
    private const string Monitor = "ArtisanLogbook.Runtime.SourceMonitor";
    private const string Imports = "ArtisanLogbook.Runtime.ImportOperations";
    private const string Reconciler = "ArtisanLogbook.Runtime.SourceReconciler";
    private const string Lifecycle = "ArtisanLogbook.Runtime.CompanionRuntimeLifecycle";
    private const string Watchers = "ArtisanLogbook.Runtime.SourceChangeFeed";
    private const string SourceId = "src_0123456789abcdef01234567";

    [TestCase(false)]
    [TestCase(true)]
    public void NormalUsesPropertiesForPresentationWhileVerboseRetainsAllDiagnosticFields(bool verbose)
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console, verbose);
        Log(services, Reconciler, MonitoringEvents.AutomaticImportAdmitted,
            new() { ["SourceLabel"] = "_retail_", ["SourceId"] = SourceId, ["OperationId"] = "operation-guid" });
        if (verbose)
        {
            Assert.That(console.Output, Does.Contain("diagnostic message")
                .And.Contain("category=" + Reconciler).And.Contain("event=6050/AutomaticImportAdmitted")
                .And.Contain("SourceId=" + SourceId).And.Contain("OperationId=operation-guid"));
        }
        else
        {
            Assert.That(console.Output, Does.Contain("Import queued · Retail")
                .And.Not.Contain("diagnostic message").And.Not.Contain(SourceId).And.Not.Contain("operation-guid")
                .And.Not.Contain("category=").And.Not.Contain("event=").And.Not.Contain("SourceLabel="));
            Assert.That(console.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries), Has.Length.EqualTo(1));
        }
    }

    [Test]
    public void StartupSelectionIsConciseAndOnlyReportsReadinessFromTheListeningEvent()
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        foreach (EventId id in new[] { CompanionEvents.Started, CompanionEvents.MonitoringPreference,
            CompanionEvents.ReconciliationInterval, CompanionEvents.Installation, CompanionEvents.InstalledFlavors })
            Log(services, Lifecycle, id, []);
        Log(services, Watchers, MonitoringEvents.WatcherReady, new() { ["WatcherState"] = "ready" });
        Assert.That(console.Output, Is.Empty, "Routine startup metadata must not become multiple independent entries");
        Log(services, Monitor, MonitoringEvents.Enabled, new() { ["IntervalSeconds"] = 60, ["RootCount"] = 2 });
        Assert.That(console.Output, Does.Contain("Monitoring active").And.Contain("Every 60s · 2 installations")
            .And.Not.Contain("Server ready"));
        Log(services, Lifecycle, CompanionEvents.Listening,
            new() { ["ListeningUrl"] = "http://127.0.0.1:48721" });
        Assert.That(console.Output, Does.Contain("Server ready").And.Contain("http://127.0.0.1:48721"));
        Assert.That(Regex.Matches(console.Output, "Monitoring active"), Has.Count.EqualTo(1));
    }

    [TestCase(0, "Up to date")]
    [TestCase(1, "1 import queued")]
    [TestCase(3, "3 imports queued")]
    public void PeriodicHeartbeatIsCompactAndDoesNotDumpEmptyDiagnosticsOrPendingState(int imports, string expected)
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Log(services, Monitor, MonitoringEvents.ReconciliationCompleted, Reconciliation(imports));
        Assert.That(console.Output, Does.Contain("Reconciliation complete")
            .And.Contain($"2 sources · {expected} · 550ms")
            .And.Not.Contain("diagnostic").And.Not.Contain("pending").And.Not.Contain("Periodic")
            .And.Not.Contain("category="));
        string[] lines = console.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.That(lines, Has.Length.EqualTo(2));
        Assert.That(lines[0], Does.Match(@"^\d{2}:\d{2}:\d{2}  -> Reconciliation complete$"));
        Assert.That(lines[1], Does.StartWith(new string(' ', 13)));
    }

    [Test]
    public void InitialDiscoveryUsesOnlyReportedSourceMetadata()
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Dictionary<string, object?> state = Reconciliation();
        state["TriggerReasons"] = "Activated, WatcherReady";
        state["SourceLabels"] = new[] { "_retail_", "_forever_" };
        Log(services, Monitor, MonitoringEvents.ReconciliationCompleted, state);
        Assert.That(console.Output, Does.Contain("Sources discovered")
            .And.Contain("2 sources · Retail · Forever · Up to date"));
    }

    [Test]
    public void PendingWorkDoesNotClaimThatSourcesAreUpToDate()
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Dictionary<string, object?> state = Reconciliation();
        state["PendingSources"] = 1;
        Log(services, Monitor, MonitoringEvents.ReconciliationCompleted, state);
        Assert.That(console.Output, Does.Contain("Awaiting import or retry").And.Not.Contain("Up to date"));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void OutstandingSourceWorkDistinguishesImportingRetryAndReadyWithoutChangingPendingCount(bool verbose)
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console, verbose);
        Dictionary<string, object?> state = Reconciliation();
        state["PendingSources"] = 4;
        state["ImportingSources"] = 1;
        state["RetryingSources"] = 2;
        state["ReadySources"] = 1;
        Log(services, Monitor, MonitoringEvents.ReconciliationCompleted, state);
        Assert.That(console.Output, Does.Contain("1 importing · 2 waiting for retry · 1 awaiting reconciliation")
            .And.Not.Contain("Up to date"));
        Assert.That(state["PendingSources"], Is.EqualTo(4));
    }

    [Test]
    public void DiagnosticReconciliationUsesOriginalPropertiesAndOmitsEmptyOptionalSections()
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console, verbose: true);
        Dictionary<string, object?> state = Reconciliation();
        state["SourceLabels"] = new[] { "_forever_", "_retail_" };
        state["AffectedSourceLabels"] = Array.Empty<string>();
        Log(services, Monitor, MonitoringEvents.ReconciliationCompleted, state,
            message: "0 diagnostics (). Sources: stale; affected:");
        Assert.That(console.Output, Does.Contain("Reconciliation completed: 2 sources · 0 imports queued · 550ms (Periodic)")
            .And.Contain("SourceLabels=[_forever_, _retail_]").And.Contain("event=6011/ReconciliationCompleted")
            .And.Not.Contain("AffectedSourceLabels=").And.Not.Contain("DiagnosticCodes=")
            .And.Not.Contain("diagnostics ()").And.Not.Contain("affected:").And.Not.Contain("stale"));
    }

    [TestCase(3, 2739, 0, "+3 new observations · 2,739 existing")]
    [TestCase(1, 0, 0, "+1 new observation")]
    [TestCase(0, 1, 0, "No changes · 1 observation already present")]
    [TestCase(0, 2739, 0, "No changes · 2,739 observations already present")]
    [TestCase(0, 10, 2, "2 enriched · 10 existing")]
    public void SuccessfulImportEmphasizesActualChanges(int inserted, int existing, int enriched, string expected)
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Dictionary<string, object?> state = Import();
        state["Inserted"] = inserted;
        state["AlreadyPresent"] = existing;
        state["Enriched"] = enriched;
        Log(services, Imports, MonitoringEvents.ImportCompleted, state);
        Assert.That(console.Output, Does.Contain("OK Import completed · Retail").And.Contain(expected)
            .And.Not.Contain("OperationId").And.Not.Contain(SourceId).And.Not.Contain("Outcome="));
    }

    [TestCase("Failed", "Import failed")]
    [TestCase("Rejected", "Import rejected")]
    public void FailedImportsExplainAutomaticRetryWithoutClaimingIngestion(string outcome, string title)
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Dictionary<string, object?> state = Import();
        state["Outcome"] = outcome;
        state["DiagnosticCodes"] = "invalid-lua";
        Log(services, Imports, MonitoringEvents.ImportCompleted, state);
        Assert.That(console.Output, Does.Contain("X  " + title + " · Retail")
            .And.Contain("Retrying automatically · invalid-lua")
            .And.Not.Contain("new observations").And.Not.Contain("No changes"));
    }

    [Test]
    public void PartialOperationDoesNotPretendThatAllSourcesSucceeded()
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Log(services, Imports, MonitoringEvents.ImportPartiallyCompleted,
            new() { ["SuccessfulSources"] = 1, ["SourceCount"] = 2 });
        Assert.That(console.Output, Does.Contain("!  Import partially completed")
            .And.Contain("1 of 2 sources imported; check failed sources above"));
    }

    [TestCase(null, "Source 01234567")]
    [TestCase("", "Source 01234567")]
    [TestCase("_forever_", "Forever")]
    [TestCase("_retail_ / WoW / SECOND_ACCOUNT", "Retail / WoW / SECOND_ACCOUNT")]
    [TestCase("custom_client", "custom_client")]
    public void SourceLabelsAreGroundedWithAbbreviatedIdentifierFallback(string? label, string expected)
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Log(services, Reconciler, MonitoringEvents.AutomaticImportAdmitted,
            new() { ["SourceLabel"] = label, ["SourceId"] = SourceId });
        Assert.That(console.Output, Does.Contain("Import queued · " + expected).And.Not.Contain(SourceId));
    }

    [Test]
    public void DisabledMonitoringAndShutdownStayVisibleWithoutDuplicateStoppedLines()
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Log(services, Monitor, MonitoringEvents.Disabled, []);
        Log(services, Monitor, MonitoringEvents.Stopping, []);
        Log(services, Monitor, MonitoringEvents.Stopped, []);
        Log(services, Lifecycle, CompanionEvents.Stopped, []);
        Assert.That(console.Output, Does.Contain("Monitoring disabled").And.Contain("Automatic imports are off")
            .And.Contain("Stopping Companion").And.Contain("Finishing accepted imports").And.Contain("Companion stopped"));
        Assert.That(Regex.Matches(console.Output, "Companion stopped"), Has.Count.EqualTo(1));
    }

    [Test]
    public void OutageAndRecoveryHaveConciseOperationalExplanations()
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Log(services, Watchers, MonitoringEvents.WatcherUnavailable, new() { ["RootId"] = SourceId }, LogLevel.Warning);
        Log(services, Watchers, MonitoringEvents.WatcherReady, new() { ["WatcherState"] = "recovered" });
        Assert.That(console.Output, Does.Contain("!  Filesystem watching unavailable")
            .And.Contain("Retrying automatically; periodic source checks remain active")
            .And.Contain("OK Filesystem watching restored").And.Not.Contain(SourceId));
    }

    [TestCase("source-changed-during-read", "Save still changing; retrying automatically")]
    [TestCase("source-read-failed", "SavedVariables unavailable; retrying automatically")]
    [TestCase("invalid-source-encoding", "Invalid UTF-8; check source encoding")]
    [TestCase("no-installation-roots", "Run artisanlogbook init")]
    public void DegradedReconciliationDoesNotClaimEverythingIsUpToDate(string code, string expected)
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Dictionary<string, object?> state = Reconciliation();
        state["DiagnosticCodes"] = code;
        state["DiagnosticCount"] = 1;
        state["AffectedSourceLabels"] = new[] { "_retail_" };
        Log(services, Monitor, MonitoringEvents.ReconciliationCompleted, state);
        Assert.That(console.Output, Does.Contain("!  Reconciliation complete · Retail").And.Contain(expected)
            .And.Not.Contain("Up to date").And.Not.Contain("0 diagnostics"));
    }

    [TestCase("Other.Worker", 6100, LogLevel.Information)]
    [TestCase(Lifecycle, 6100, LogLevel.Error)]
    [TestCase(Lifecycle, 6100, LogLevel.Critical)]
    [TestCase(Monitor, 9999, LogLevel.Warning)]
    [TestCase("Microsoft.AspNetCore.OtherWorker", 99, LogLevel.Information)]
    public void UnknownEventsAndUnexpectedSeveritiesAlwaysHaveAFallback(string category, int id, LogLevel level)
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Log(services, category, new(id), [], level, message: "[red]Unexpected[/] detail");
        Assert.That(console.Output, Does.Contain("[red]Unexpected[/] detail").And.Not.Contain("category="));
        if (level >= LogLevel.Warning) Assert.That(console.Output, Does.Contain(level.ToString()));
    }

    [Test]
    public void MissingKnownEventPropertiesFallBackRatherThanFabricatingResults()
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Log(services, Monitor, MonitoringEvents.ReconciliationCompleted, [], message: "incomplete event");
        Log(services, Imports, MonitoringEvents.ImportCompleted, new() { ["Outcome"] = "FutureOutcome" }, message: "future result");
        Assert.That(console.Output, Does.Contain("incomplete event").And.Contain("future result"));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void ExceptionsAreConciseNormallyAndDetailedInVerboseMode(bool verbose)
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console, verbose);
        Exception exception;
        try { throw new IOException("[red]disk[/] unavailable", new InvalidOperationException("inner")); }
        catch (IOException caught) { exception = caught; }
        Log(services, "Other", default, [], LogLevel.Error, exception, "Save failed");
        Assert.That(console.Output, Does.Contain("IOException: [red]disk[/] unavailable")
            .And.Contain("InvalidOperationException: inner"));
        Assert.That(console.Output.Contains(nameof(ExceptionsAreConciseNormallyAndDetailedInVerboseMode)), Is.EqualTo(verbose));
        Assert.That(console.Output.Contains("category="), Is.EqualTo(verbose));
    }

    [Test]
    public void EvenAnUnexpectedInformationExceptionIsNotSuppressedWithStartupMetadata()
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Log(services, Lifecycle, CompanionEvents.Started, [], exception: new IOException("unexpected startup failure"));
        Assert.That(console.Output, Does.Contain("unexpected startup failure"));
    }

    [Test]
    public void PresentationPolicyDoesNotDiscardEventsFromOtherProvidersOrAlterFiltering()
    {
        using TestConsole console = new();
        using CapturingLoggerProvider capture = new();
        using ServiceProvider services = Services(console, configure: logging =>
        {
            logging.AddProvider(capture);
            logging.SetMinimumLevel(LogLevel.Warning);
        });
        Log(services, Lifecycle, CompanionEvents.Started, []);
        Assert.That(capture.Entries, Is.Empty);
        Log(services, "Microsoft.AspNetCore.Hosting", default, [], LogLevel.Warning, message: "important framework warning");
        Assert.That(console.Output, Does.Contain("important framework warning"));
        Assert.That(capture.Entries, Has.Count.EqualTo(1));
    }

    [Test]
    public void SuppressedNormalEntriesStillReachOtherProviders()
    {
        using TestConsole console = new();
        using CapturingLoggerProvider capture = new();
        using ServiceProvider services = Services(console, configure: logging => logging.AddProvider(capture));
        Log(services, Lifecycle, CompanionEvents.Started, new() { ["Extra"] = 42 });
        Assert.That(console.Output, Is.Empty);
        Assert.That(capture.Entries.Single().Properties["Extra"], Is.EqualTo(42));
    }

    [Test]
    public void VerboseCanBeConfiguredWithoutChangingStandardLevelFilters()
    {
        using TestConsole console = new();
        IConfiguration configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Logging:SpectreConsole:Verbose"] = "true",
            ["Logging:LogLevel:Default"] = "Error"
        }).Build();
        ServiceCollection collection = new();
        collection.AddLogging(logging => logging.AddConfiguration(configuration.GetSection("Logging")).AddSpectreConsole(console));
        using ServiceProvider services = collection.BuildServiceProvider();
        Log(services, "Other", default, [], message: "filtered info");
        Log(services, "Other", new(15), new() { ["Detail"] = "retained" }, LogLevel.Error);
        Assert.That(console.Output, Does.Not.Contain("filtered info").And.Contain("event=15")
            .And.Contain("Detail=retained"));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void ConcurrentNormalEntriesRemainCompleteLiteralAndMultiline(bool crlf)
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Parallel.For(0, 100, id => Log(services, "Other", default, [], message:
            $"[red]begin-{id}[/]" + (crlf ? "\r\n" : "\n") + $"end-{id}\x1b[2J"));
        MatchCollection entries = Regex.Matches(console.Output,
            @"(?m)^\d{2}:\d{2}:\d{2}  i  \[red\]begin-(\d+)\[/\]\n             end-\1\n");
        Assert.That(entries, Has.Count.EqualTo(100), console.Output);
        Assert.That(entries.Sum(entry => entry.Length), Is.EqualTo(console.Output.Length));
        Assert.That(entries.Select(entry => entry.Groups[1].Value).Distinct().Count(), Is.EqualTo(100));
        Assert.That(console.Output.Contains('\r') || console.Output.Contains('\x1b'), Is.False);
    }

    [Test]
    public void KnownEventValuesCannotInjectMarkupOrTerminalControls()
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Log(services, Reconciler, MonitoringEvents.AutomaticImportAdmitted,
            new() { ["SourceLabel"] = "[red]Retail[/]\x1b[2J\rSpoof" });
        Assert.That(console.Output, Does.Contain("[red]Retail[/]").And.Contain("\n             Spoof"));
        Assert.That(console.Output.Contains('\r') || console.Output.Contains('\x1b'), Is.False);
    }

    [Test]
    public void ConcurrentKnownEventHeadingsAndContextLinesRemainPaired()
    {
        using TestConsole console = new();
        using ServiceProvider services = Services(console);
        Parallel.For(1, 101, id =>
        {
            Dictionary<string, object?> state = Import();
            state["SourceLabel"] = "_retail_ / " + id;
            state["Inserted"] = id;
            state["AlreadyPresent"] = id;
            Log(services, Imports, MonitoringEvents.ImportCompleted, state);
        });
        MatchCollection entries = Regex.Matches(console.Output,
            @"(?m)^\d{2}:\d{2}:\d{2}  OK Import completed · Retail / (\d+)\n             \+\1 new observations? · \1 existing\n");
        Assert.That(entries, Has.Count.EqualTo(100), console.Output);
        Assert.That(entries.Sum(entry => entry.Length), Is.EqualTo(console.Output.Length));
        Assert.That(entries.Select(entry => entry.Groups[1].Value).Distinct().Count(), Is.EqualTo(100));
    }

    [Test]
    public void NormalModeSupportsExplicitScopesWithoutDumpingEventProperties()
    {
        using TestConsole console = new();
        ServiceCollection collection = new();
        collection.AddLogging(logging => logging.AddSpectreConsole(console, options => options.IncludeScopes = true));
        using ServiceProvider services = collection.BuildServiceProvider();
        ILogger logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("Other");
        using (logger.BeginScope("explicit scope"))
            logger.LogInformation("visible");
        Assert.That(console.Output, Does.Contain("visible").And.Contain("scope: explicit scope")
            .And.Not.Contain("category=").And.Not.Contain("event="));
    }

    [Test]
    [NonParallelizable]
    public void BrokenConsoleReportsAnEmergencyFallbackWithoutThrowingIntoApplicationServices()
    {
        using StringWriter errors = new();
        TextWriter original = System.Console.Error;
        System.Console.SetError(errors);
        try
        {
            IAnsiConsole console = AnsiConsole.Create(new AnsiConsoleSettings
            {
                Ansi = AnsiSupport.No,
                Out = new FailingOutput()
            });
            using ServiceProvider services = Services(console);
            Assert.DoesNotThrow(() => Log(services, "Other", default, [], LogLevel.Error, message: "important failure"));
            Assert.That(errors.ToString(), Does.Contain("console output failed (IOException)")
                .And.Contain("important failure"));
            Assert.That(errors.ToString().Contains('\x1b'), Is.False);
        }
        finally { System.Console.SetError(original); }
    }

    private static Dictionary<string, object?> Reconciliation(int imports = 0) => new()
    {
        ["DiscoveredSources"] = 2,
        ["SubmittedImports"] = imports,
        ["DurationMs"] = 550L,
        ["DiagnosticCount"] = 0,
        ["DiagnosticCodes"] = "",
        ["PendingSources"] = 0,
        ["TriggerReasons"] = "Periodic"
    };

    private static Dictionary<string, object?> Import() => new()
    {
        ["Outcome"] = "Successful",
        ["SourceLabel"] = "_retail_",
        ["SourceId"] = SourceId,
        ["Origin"] = "Automatic",
        ["Inserted"] = 0,
        ["AlreadyPresent"] = 0,
        ["Enriched"] = 0,
        ["RejectedOrConflicting"] = 0,
        ["OperationId"] = Guid.NewGuid()
    };

    private static void Log(ServiceProvider services, string category, EventId eventId, Dictionary<string, object?> state,
        LogLevel level = LogLevel.Information, Exception? exception = null, string message = "diagnostic message") =>
        services.GetRequiredService<ILoggerFactory>().CreateLogger(category)
            .Log(level, eventId, state, exception, (_, _) => message);

    private static ServiceProvider Services(IAnsiConsole console, bool verbose = false, Action<ILoggingBuilder>? configure = null)
    {
        ServiceCollection collection = new();
        collection.AddLogging(logging =>
        {
            logging.AddSpectreConsole(console, options => options.Verbose = verbose);
            configure?.Invoke(logging);
        });
        return collection.BuildServiceProvider();
    }

    private sealed class FailingOutput : IAnsiConsoleOutput
    {
        public TextWriter Writer { get; } = new FailingWriter();
        public bool IsTerminal => false;
        public int Width => 80;
        public int Height => 30;
        public void SetEncoding(Encoding encoding) { }
    }

    private sealed class FailingWriter : StringWriter
    {
        public override void Write(string? value) => throw new IOException("controlled console failure");
    }
}
