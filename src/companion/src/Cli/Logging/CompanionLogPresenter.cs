using System.Globalization;

using ArtisanLogbook.Runtime;

using Microsoft.Extensions.Logging;

namespace ArtisanLogbook.Cli.Logging;

internal enum ConsoleTone { Neutral, Activity, Queued, Success, Warning, Error, Idle }
internal sealed record ConsoleEntry(string Message, string? Detail = null, ConsoleTone Tone = ConsoleTone.Neutral);

/// <summary>A stateless console policy over stable event identities and original structured state.</summary>
internal static class CompanionLogPresenter
{
    private const string Monitor = "ArtisanLogbook.Runtime.SourceMonitor";
    private const string Reconciler = "ArtisanLogbook.Runtime.SourceReconciler";
    private const string Imports = "ArtisanLogbook.Runtime.ImportOperations";
    private const string Watchers = "ArtisanLogbook.Runtime.SourceChangeFeed";
    private const string Checkpoints = "ArtisanLogbook.Runtime.MonitoringCheckpoints";
    private const string Lifecycle = "ArtisanLogbook.Runtime.CompanionRuntimeLifecycle";

    public static ConsoleEntry? Present(string category, LogLevel level, EventId eventId,
        IEnumerable<KeyValuePair<string, object?>>? state, Func<string> message)
    {
        Properties properties = new(state);
        // A familiar event number from another category (or at an unexpected severity) is not safe to suppress.
        if (level == LogLevel.Information)
        {
            if (category == Lifecycle)
            {
                if (eventId == CompanionEvents.Started || eventId == CompanionEvents.MonitoringPreference ||
                    eventId == CompanionEvents.ReconciliationInterval || eventId == CompanionEvents.Installation ||
                    eventId == CompanionEvents.InstalledFlavors || eventId == CompanionEvents.NoInstallations)
                    return null;
                if (eventId == CompanionEvents.Listening && properties.Text("ListeningUrl") is { } url)
                    return new("Server ready", url, ConsoleTone.Success);
                if (eventId == CompanionEvents.Stopped)
                    return new("Companion stopped", Tone: ConsoleTone.Idle);
            }
            if (category == Monitor)
            {
                if (eventId == MonitoringEvents.Enabled && properties.Number("IntervalSeconds") is { } interval &&
                    properties.Number("RootCount") is { } roots)
                    return new("Monitoring active", $"Every {interval}s" +
                        (roots == 0 ? " · No installations configured; run artisanlogbook init" :
                        roots > 1 ? $" · {roots} installations" : ""), ConsoleTone.Success);
                if (eventId == MonitoringEvents.Disabled)
                    return new("Monitoring disabled", "Automatic imports are off", ConsoleTone.Idle);
                if (eventId == MonitoringEvents.Stopping)
                    return new("Stopping Companion", "Finishing accepted imports", ConsoleTone.Idle);
                if (eventId == MonitoringEvents.Stopped)
                    return null;
                if (eventId == MonitoringEvents.ReconciliationCompleted &&
                    properties.Number("DiscoveredSources") is { } sources &&
                    properties.Number("SubmittedImports") is { } imports &&
                    properties.Number("DurationMs") is { } duration && properties.Number("DiagnosticCount") is { } diagnostics)
                    return Reconciliation(properties, sources, imports, duration, diagnostics);
            }
            if (category == Watchers && eventId == MonitoringEvents.WatcherReady)
            {
                if (properties.Text("WatcherState") == "ready") return null;
                if (properties.Text("WatcherState") == "recovered")
                    return new("Filesystem watching restored" + Installation(properties),
                        "Automatic change detection is active", ConsoleTone.Success);
            }
            if (category == Reconciler && eventId == MonitoringEvents.AutomaticImportAdmitted)
                return new("Import queued · " + Source(properties), Tone: ConsoleTone.Queued);
            if (category == Imports)
            {
                if (eventId == MonitoringEvents.ImportCompleted && properties.Text("Outcome") is { } outcome)
                {
                    if (Import(properties, outcome) is { } imported) return imported;
                }
                if (eventId == MonitoringEvents.ImportPartiallyCompleted &&
                    properties.Number("SuccessfulSources") is { } successful && properties.Number("SourceCount") is { } count)
                    return new("Import partially completed", $"{successful} of {count} sources imported; check failed sources above",
                        ConsoleTone.Warning);
            }
            if (category == Checkpoints && eventId == MonitoringEvents.CheckpointSaveRecovered)
                return new("Monitoring state saved", "Persistence recovered", ConsoleTone.Success);
        }
        if (level == LogLevel.Warning)
        {
            if (category == Watchers && eventId == MonitoringEvents.WatcherUnavailable)
                return new("Filesystem watching unavailable" + Installation(properties),
                    "Retrying automatically; periodic source checks remain active",
                    ConsoleTone.Warning);
            if (category == Checkpoints && eventId == MonitoringEvents.CheckpointSaveFailed)
                return new("Monitoring state could not be saved", "Results retained in memory; retrying automatically",
                    ConsoleTone.Warning);
        }
        if (category == Reconciler && eventId == MonitoringEvents.SourceInspectionFailed && level == LogLevel.Debug)
            return new("SavedVariables temporarily unavailable · " + Source(properties),
                InspectionAdvice(properties.Text("DiagnosticCode")), ConsoleTone.Warning);
        // Framework request chatter is diagnostic, but warnings/errors and explicitly enabled Debug remain visible.
        if (level == LogLevel.Information &&
            (category is "Microsoft.AspNetCore.Hosting.Diagnostics" or "Microsoft.AspNetCore.Routing.EndpointMiddleware" ||
                category.StartsWith("Microsoft.AspNetCore.Http.Result.", StringComparison.Ordinal)))
            return null;
        return new((level >= LogLevel.Warning ? level + ": " : "") + message(),
            Tone: level >= LogLevel.Error ? ConsoleTone.Error : level == LogLevel.Warning ? ConsoleTone.Warning : ConsoleTone.Neutral);
    }

    private static ConsoleEntry Reconciliation(Properties properties, long sources, long imports, long duration, long diagnostics)
    {
        string status = imports == 0 ? "Up to date" : $"{imports} {(imports == 1 ? "import" : "imports")} queued";
        if (imports == 0 && properties.Number("PendingSources") is > 0)
            status = "Awaiting import or retry";
        string? advice = diagnostics > 0 ? ReconciliationAdvice(properties.Text("DiagnosticCodes")) : null;
        if (advice is not null) status = imports > 0 ? status + " · " + advice : advice;
        string message = "Reconciliation complete";
        string? labels = null;
        if (properties.Text("TriggerReasons")?.Split(", ").Contains("Activated") == true)
        {
            message = "Sources discovered";
            if (properties.Get("SourceLabels") is IEnumerable<string> values)
                labels = string.Join(" · ", values.Select(ClientLabel).Distinct());
        }
        if (diagnostics > 0 && properties.Get("AffectedSourceLabels") is IEnumerable<string> affected)
        {
            string names = string.Join(" · ", affected.Select(ClientLabel).Distinct());
            if (names.Length > 0) message += " · " + names;
        }
        return new(message, $"{sources} {(sources == 1 ? "source" : "sources")} · " +
            (string.IsNullOrEmpty(labels) ? "" : labels + " · ") + $"{status} · {duration}ms",
            diagnostics > 0 ? ConsoleTone.Warning : ConsoleTone.Activity);
    }

    private static ConsoleEntry? Import(Properties properties, string outcome)
    {
        if (outcome is not ("Successful" or "Failed" or "Rejected" or "Partial"))
            return null;
        string source = Source(properties);
        if (outcome is "Failed" or "Rejected")
            return new($"Import {outcome.ToLowerInvariant()} · {source}",
                (properties.Text("Origin") == "Automatic" ? "Retrying automatically" : "Check the source and retry") +
                DiagnosticDetail(properties.Text("DiagnosticCodes")), ConsoleTone.Error);
        if (properties.Number("Inserted") is not { } inserted || properties.Number("AlreadyPresent") is not { } existing ||
            properties.Number("Enriched") is not { } enriched || properties.Number("RejectedOrConflicting") is not { } rejected)
            return null;
        List<string> changes = [];
        if (inserted > 0) changes.Add($"+{Count(inserted)} new {(inserted == 1 ? "observation" : "observations")}");
        if (enriched > 0) changes.Add($"{Count(enriched)} enriched");
        if (rejected > 0) changes.Add($"{Count(rejected)} rejected or conflicting");
        if (inserted == 0 && enriched == 0 && rejected == 0)
            changes.Add($"No changes · {Count(existing)} {(existing == 1 ? "observation" : "observations")} already present");
        else if (existing > 0)
            changes.Add($"{Count(existing)} existing");
        bool partial = outcome == "Partial" || rejected > 0;
        return new($"Import {(partial ? "partially completed" : "completed")} · {source}",
            string.Join(" · ", changes), partial ? ConsoleTone.Warning : ConsoleTone.Success);
    }

    private static string Source(Properties properties)
    {
        if (properties.Text("SourceLabel") is { Length: > 0 } label) return ClientLabel(label);
        string? id = properties.Text("SourceId");
        return string.IsNullOrWhiteSpace(id) || id == "src_" ? "Unknown source" :
            "Source " + (id.StartsWith("src_", StringComparison.Ordinal) ? id[4..Math.Min(id.Length, 12)] :
                id[..Math.Min(id.Length, 8)]);
    }

    private static string Installation(Properties properties) =>
        properties.Text("RootLabel") is { Length: > 0 } label ? " · " + label : "";

    private static string ClientLabel(string label)
    {
        int separator = label.IndexOf(" / ", StringComparison.Ordinal);
        string client = separator < 0 ? label : label[..separator];
        string name = client.ToLowerInvariant() switch
        {
            "_retail_" => "Retail",
            "_forever_" => "Forever",
            "_classic_" => "Classic",
            "_classic_era_" => "Classic Era",
            _ => client
        };
        return name + (separator < 0 ? "" : label[separator..]);
    }

    private static string InspectionAdvice(string? code) => code switch
    {
        "source-changed-during-read" => "Save still changing; retrying automatically",
        "invalid-source-encoding" => "Invalid UTF-8; check the source encoding",
        _ => "Retrying automatically" + DiagnosticDetail(code)
    };

    private static string ReconciliationAdvice(string? codes)
    {
        if (codes?.Contains("no-installation-roots", StringComparison.Ordinal) == true)
            return "Run artisanlogbook init to configure an installation";
        if (codes?.Contains("source-changed-during-read", StringComparison.Ordinal) == true)
            return "Save still changing; retrying automatically";
        if (codes?.Contains("source-read-failed", StringComparison.Ordinal) == true)
            return "SavedVariables unavailable; retrying automatically";
        if (codes?.Contains("invalid-source-encoding", StringComparison.Ordinal) == true)
            return "Invalid UTF-8; check source encoding";
        return "Needs attention" + DiagnosticDetail(codes);
    }

    private static string DiagnosticDetail(string? codes) => string.IsNullOrWhiteSpace(codes) ? "" : " · " + codes;
    private static string Count(long value) => value.ToString("N0", CultureInfo.InvariantCulture);

    private readonly struct Properties(IEnumerable<KeyValuePair<string, object?>>? state)
    {
        public object? Get(string name) => state?.FirstOrDefault(pair => pair.Key == name).Value;
        public string? Text(string name) => Get(name) is { } value ? Convert.ToString(value, CultureInfo.InvariantCulture) : null;
        public long? Number(string name) => Get(name) switch
        {
            int value => value,
            long value => value,
            _ => null
        };
    }
}
