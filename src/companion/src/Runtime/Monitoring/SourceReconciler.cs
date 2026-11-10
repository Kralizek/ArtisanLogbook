using ArtisanLogbook.ImportService;

using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace ArtisanLogbook.Runtime;

internal sealed record MonitoringDiagnostic(string Code, string Message, string? SourceId = null);
internal sealed record ReconciliationReport(
    DateTimeOffset At, int DiscoveredSources, int SubmittedImports, IReadOnlyList<MonitoringDiagnostic> Diagnostics);

/// <summary>One explicit operation, independent of watchers, Rx subscriptions and HTTP.</summary>
internal class SourceReconciler(
    SourceCatalog catalog, SavedVariablesSnapshotReader snapshots, MonitoringCheckpoints checkpoints, ImportOperations imports,
    ILogger<SourceReconciler>? logger = null)
{
    private readonly ILogger<SourceReconciler> _logger = logger ?? NullLogger<SourceReconciler>.Instance;

    public virtual async Task<ReconciliationReport> ReconcileAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        SourceCatalogSnapshot discovered = catalog.Discover();
        List<MonitoringDiagnostic> diagnostics = discovered.Diagnostics
            .Select(diagnostic => new MonitoringDiagnostic(diagnostic.Code, diagnostic.Message)).ToList();
        if (!discovered.Diagnostics.Any(diagnostic => diagnostic.Severity == DiscoverySeverity.Error))
            checkpoints.Prune(discovered.Sources.Select(source => source.Id).ToHashSet());
        var known = checkpoints.Read().Document.Sources;
        int submitted = 0;
        foreach (DiscoveredSource source in discovered.Sources.OrderBy(source =>
            known.GetValueOrDefault(source.Id)?.LastAttempt?.Sequence ?? 0))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                SavedVariablesSnapshot snapshot;
                try { snapshot = await snapshots.ReadAsync(source.Path, cancellationToken).ConfigureAwait(false); }
                catch (SourceSnapshotException exception)
                {
                    _logger.LogDebug(MonitoringEvents.SourceInspectionFailed, exception,
                        "Source {SourceId} cannot yet provide a snapshot ({DiagnosticCode}); inspection will retry.",
                        source.Id, exception.Code);
                    checkpoints.InspectionFailed(source.Id, exception.Code, now);
                    diagnostics.Add(new(exception.Code, "The source could not be inspected; it will be retried.", source.Id));
                    continue;
                }
                SourceCheckpoint checkpoint = checkpoints.Observe(source.Id, snapshot.Fingerprint);
                if (checkpoint.Successful is { } success && success.Fingerprint != snapshot.Fingerprint &&
                    known.GetValueOrDefault(source.Id)?.Observed != snapshot.Fingerprint)
                    _logger.LogDebug(MonitoringEvents.FingerprintSuperseded,
                        "Previously ingested fingerprint for {SourceId} was superseded: {PreviousFingerprint} -> {ObservedFingerprint}.",
                        source.Id, success.Fingerprint, snapshot.Fingerprint);
                if (!checkpoint.IsEligible(now))
                {
                    if (!checkpoint.RequiresImport)
                        _logger.LogDebug(MonitoringEvents.SourceUnchanged,
                            "Source {SourceId} remains unchanged after inspection; import skipped.", source.Id);
                    continue;
                }
                if (imports.IsSourceActive(source.Id))
                {
                    checkpoints.Defer(source.Id, now);
                    continue;
                }
                cancellationToken.ThrowIfCancellationRequested();
                ImportSubmission submission = imports.Submit(source, snapshot.Fingerprint, cancellationToken);
                if (submission.Rejection is null)
                {
                    submitted++;
                    _logger.LogInformation(MonitoringEvents.AutomaticImportAdmitted,
                        "Automatic import admitted for {SourceId} ({OperationId}).", source.Id, submission.Operation!.Id);
                }
                else if (submission.Rejection != ImportRejection.Unchanged)
                {
                    checkpoints.Defer(source.Id, now);
                    if (submission.Rejection != ImportRejection.SourceBusy)
                        diagnostics.Add(new("import-admission-deferred",
                            "Import admission is unavailable; reconciliation will retry.", source.Id));
                }
            }
            catch (CheckpointCapacityException)
            {
                diagnostics.Add(new("checkpoint-capacity-exceeded",
                    "Monitoring metadata capacity is exhausted; this source was not admitted.", source.Id));
            }
        }
        return new(now, discovered.Sources.Count, submitted, diagnostics.ToArray());
    }
}
