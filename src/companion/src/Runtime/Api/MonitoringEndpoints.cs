using ArtisanLogbook.CompanionApi.Contracts;
using ArtisanLogbook.CompanionApi.Endpoints;

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.Extensions.Logging;

using ApiMonitoringStatus = ArtisanLogbook.CompanionApi.Contracts.MonitoringStatus;

namespace ArtisanLogbook.Runtime;

internal static class MonitoringApiMapping
{
    public static ApiMonitoringStatus Map(MonitoringStatus status) => new()
    {
        State = status.Phase switch
        {
            MonitoringPhase.Disabled => MonitoringStatusState.Disabled,
            MonitoringPhase.Starting => MonitoringStatusState.Starting,
            MonitoringPhase.Reconciling => MonitoringStatusState.Reconciling,
            MonitoringPhase.Active => MonitoringStatusState.Active,
            MonitoringPhase.Degraded => MonitoringStatusState.Degraded,
            MonitoringPhase.Stopping => MonitoringStatusState.Stopping,
            MonitoringPhase.Stopped => MonitoringStatusState.Stopped,
            _ => throw new InvalidOperationException("Unknown monitoring phase.")
        },
        Preferences = Map(status.Configuration.PersistedPreferences?.Monitoring ?? new()),
        Effective = Map(status.Configuration.EffectiveSettings.Monitoring),
        Overrides = new()
        {
            Enabled = status.Configuration.InvocationOverrides.Monitoring.HasValue,
            ReconciliationIntervalSeconds = status.Configuration.InvocationOverrides.ReconciliationIntervalSeconds.HasValue
        },
        LastReconciledAt = status.LastReconciliation?.At,
        DiscoveredSources = status.LastReconciliation?.DiscoveredSources,
        LastSubmittedImports = status.LastReconciliation?.SubmittedImports,
        PendingSources = status.PendingSources,
        CheckpointSavePending = status.CheckpointSavePending,
        Diagnostics = status.Diagnostics.Take(50).Select(diagnostic => new MonitoringStatusDiagnosticsItem
        {
            Code = diagnostic.Code,
            Message = diagnostic.Message,
            SourceId = diagnostic.SourceId
        }).ToArray(),
        DiagnosticsTruncated = status.Diagnostics.Count > 50
    };

    private static MonitoringPreferences Map(MonitoringSettings settings) => new()
    {
        Enabled = settings.Enabled,
        ReconciliationIntervalSeconds = settings.ReconciliationIntervalSeconds
    };
}

internal sealed class GetMonitoringEndpoint(SourceMonitor monitor) : GetMonitoringEndpointBase
{
    public override Task<Ok<ApiMonitoringStatus>> HandleAsync(CancellationToken cancellationToken) =>
        Task.FromResult(TypedResults.Ok(MonitoringApiMapping.Map(monitor.Read())));
}

internal sealed class UpdateMonitoringEndpoint(SourceMonitor monitor, ILogger<UpdateMonitoringEndpoint> logger) : UpdateMonitoringEndpointBase
{
    public override Task<Results<Ok<ApiMonitoringStatus>, BadRequestProblem, ConflictProblem, Status503Problem>> HandleAsync(
        Request request, CancellationToken cancellationToken)
    {
        if (request.ReconciliationIntervalSeconds is < 1 or > 86400)
            return Task.FromResult<Results<Ok<ApiMonitoringStatus>, BadRequestProblem, ConflictProblem, Status503Problem>>(
                new BadRequestProblem(ApiMapping.Problem(400, "invalid-monitoring-preferences",
                    "reconciliationIntervalSeconds must be between 1 and 86400.")));
        try
        {
            monitor.UpdatePreferences(new()
            {
                Enabled = request.Enabled,
                ReconciliationIntervalSeconds = request.ReconciliationIntervalSeconds
            }, cancellationToken);
            return Result(TypedResults.Ok(MonitoringApiMapping.Map(monitor.Read())));
        }
        catch (CompanionSettingsException exception)
        {
            logger.LogWarning("Monitoring preferences were not saved ({ExceptionType}).", exception.GetType().Name);
            return Result(new ConflictProblem(ApiMapping.Problem(409, "settings-conflict",
                "Persisted settings cannot be updated. Retry, or back up and repair the settings file.")));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            logger.LogWarning("Monitoring preferences could not be persisted ({ExceptionType}).", exception.GetType().Name);
            return Result(new Status503Problem(ApiMapping.Problem(503, "settings-save-failed",
                "Monitoring preferences could not be persisted; the running configuration was not changed.")));
        }
        catch (InvalidOperationException) when (monitor.Read().Phase is MonitoringPhase.Stopping or MonitoringPhase.Stopped)
        {
            return Result(new Status503Problem(ApiMapping.Problem(503, "application-stopping",
                "The Companion is stopping and is not accepting preference changes.")));
        }
    }

    private static Task<Results<Ok<ApiMonitoringStatus>, BadRequestProblem, ConflictProblem, Status503Problem>> Result(
        Results<Ok<ApiMonitoringStatus>, BadRequestProblem, ConflictProblem, Status503Problem> result) => Task.FromResult(result);
}

internal sealed class ReconcileMonitoringEndpoint(SourceMonitor monitor) : ReconcileMonitoringEndpointBase
{
    public override Task<Results<Accepted<ApiMonitoringStatus>, BadRequestProblem, ConflictProblem, Status503Problem>> HandleAsync(
        Request request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<Results<Accepted<ApiMonitoringStatus>, BadRequestProblem, ConflictProblem, Status503Problem>>(
            monitor.RequestReconciliation() switch
            {
                ReconciliationRequestOutcome.Accepted => TypedResults.Accepted("/api/v1/monitoring", MonitoringApiMapping.Map(monitor.Read())),
                ReconciliationRequestOutcome.Disabled => new ConflictProblem(ApiMapping.Problem(409, "monitoring-disabled",
                    "Effective monitoring is disabled. Enable it or submit a manual import.")),
                _ => new Status503Problem(ApiMapping.Problem(503, "application-stopping",
                    "The Companion is stopping and is not accepting reconciliation requests."))
            });
    }
}
