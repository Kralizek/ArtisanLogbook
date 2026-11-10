using ArtisanLogbook.CompanionApi.Contracts;
using ArtisanLogbook.CompanionApi.Endpoints;
using ArtisanLogbook.HistoryStore;

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;

namespace ArtisanLogbook.Runtime;

internal static class ApiMapping
{
    public static Problem Problem(int status, string code, string detail) => new()
    {
        Type = FormattableString.Invariant($"https://httpstatuses.io/{status}"),
        Title = ProblemResponses.Title(status),
        Status = status,
        Detail = detail,
        Code = code
    };

    public static LifecycleState Map(CompanionLifecycleState state) => state switch
    {
        CompanionLifecycleState.Created => LifecycleState.Created,
        CompanionLifecycleState.Starting => LifecycleState.Starting,
        CompanionLifecycleState.Running => LifecycleState.Running,
        CompanionLifecycleState.Stopping => LifecycleState.Stopping,
        CompanionLifecycleState.Stopped => LifecycleState.Stopped,
        _ => LifecycleState.Failed
    };

    public static ImportOperation Map(ImportOperationSnapshot operation) => new()
    {
        Id = operation.Id,
        Origin = (CompanionApi.Contracts.ImportOperationOrigin)Enum.Parse(
            typeof(CompanionApi.Contracts.ImportOperationOrigin), operation.Origin.ToString()),
        Status = Map(operation.Status),
        Outcome = operation.Outcome switch
        {
            ImportOperationOutcome.Successful => CompanionApi.Contracts.ImportOperationOutcome.Successful,
            ImportOperationOutcome.Partial => CompanionApi.Contracts.ImportOperationOutcome.Partial,
            ImportOperationOutcome.Failed => CompanionApi.Contracts.ImportOperationOutcome.Failed,
            _ => null
        },
        RequestedSourceId = operation.RequestedSourceId,
        CreatedAt = operation.CreatedAt,
        StartedAt = operation.StartedAt,
        CompletedAt = operation.CompletedAt,
        Sources = operation.Sources.Select(Map).ToArray(),
        Diagnostics = operation.Diagnostics.Select(Map).ToArray()
    };

    private static CompanionApi.Contracts.ImportOperationStatus Map(ImportOperationStatus status) => status switch
    {
        ImportOperationStatus.Queued => CompanionApi.Contracts.ImportOperationStatus.Queued,
        ImportOperationStatus.Running => CompanionApi.Contracts.ImportOperationStatus.Running,
        ImportOperationStatus.Completed => CompanionApi.Contracts.ImportOperationStatus.Completed,
        ImportOperationStatus.Failed => CompanionApi.Contracts.ImportOperationStatus.Failed,
        _ => CompanionApi.Contracts.ImportOperationStatus.Cancelled
    };

    private static ImportSourceResult Map(ImportSourceSnapshot source) => new()
    {
        SourceId = source.SourceId,
        Status = (ImportSourceResultStatus)Enum.Parse(typeof(ImportSourceResultStatus), source.Status.ToString()),
        Outcome = source.Outcome switch
        {
            ImportService.CompanionImportOutcome.Successful => ImportSourceResultOutcome.Successful,
            ImportService.CompanionImportOutcome.Rejected => ImportSourceResultOutcome.Rejected,
            ImportService.CompanionImportOutcome.Failed => ImportSourceResultOutcome.Failed,
            _ => null
        },
        Counts = source.Counts is null ? null : new()
        {
            Observations = source.Counts.Observations,
            Inserted = source.Counts.Inserted,
            AlreadyPresent = source.Counts.AlreadyPresent,
            Enriched = source.Counts.Enriched,
            RejectedOrConflicting = source.Counts.RejectedOrConflicting,
            DimensionsInserted = source.Counts.DimensionsInserted,
            DimensionsEnriched = source.Counts.DimensionsEnriched
        },
        Diagnostics = source.Diagnostics.Select(Map).ToArray(),
        DiagnosticsTruncated = source.DiagnosticsTruncated
    };

    private static ImportDiagnostic Map(ImportDiagnosticInfo diagnostic) =>
        new() { Category = diagnostic.Category, Code = diagnostic.Code, Message = diagnostic.Message };
}

internal sealed class GetHealthEndpoint(CompanionApplicationStatus status) : GetHealthEndpointBase
{
    public override Task<Results<Ok<Health>, IResult>> HandleAsync(CancellationToken cancellationToken)
    {
        CompanionStatus current = status.Read();
        bool healthy = current.LifecycleState == CompanionLifecycleState.Running && current.DatabaseAvailable;
        Health body = new() { Status = healthy ? HealthStatus.Healthy : HealthStatus.Unhealthy, State = ApiMapping.Map(current.LifecycleState) };
        return Task.FromResult<Results<Ok<Health>, IResult>>(healthy
            ? TypedResults.Ok(body)
            : TypedResults.Json(body, statusCode: StatusCodes.Status503ServiceUnavailable));
    }
}

internal sealed class GetStatusEndpoint(CompanionApplicationStatus status) : GetStatusEndpointBase
{
    public override Task<Ok<OkResponse>> HandleAsync(CancellationToken cancellationToken)
    {
        CompanionStatus current = status.Read();
        OkResponse body = new()
        {
            ApplicationVersion = current.ApplicationVersion,
            State = ApiMapping.Map(current.LifecycleState),
            StartedAt = current.StartupTime,
            Database = new() { Available = current.DatabaseAvailable, SchemaVersion = current.DatabaseSchemaVersion },
            History = current.CanonicalCraftCount is long count && current.CanonicalContexts is { } contexts
                ? new()
                {
                    CraftCount = count,
                    GameContexts = contexts.Select(context => new OkResponseHistoryGameContextsItem
                    {
                        Project = (int)context.Game.Project,
                        ProjectName = Enum.IsDefined(context.Game.Project) ? context.Game.Project.ToString() : null,
                        ProgressionTrack = context.Game.ProgressionTrack,
                        CraftCount = context.CraftCount
                    }).ToArray()
                }
                : null,
            Failure = current.CriticalFailure is null ? null! : new() { Code = current.CriticalFailure.Code, Message = current.CriticalFailure.Message }
        };
        return Task.FromResult(TypedResults.Ok(body));
    }
}

internal sealed class ListSourcesEndpoint(SourceCatalog catalog) : ListSourcesEndpointBase
{
    public override Task<Ok<OkResponse>> HandleAsync(CancellationToken cancellationToken)
    {
        SourceCatalogSnapshot snapshot = catalog.Discover();
        return Task.FromResult(TypedResults.Ok(new OkResponse
        {
            Sources = snapshot.Sources.Select(source => new Source
            {
                Id = source.Id,
                Client = source.Client,
                FileName = source.FileName,
                SizeBytes = source.SizeBytes,
                ModifiedAt = source.ModifiedAt
            }).ToArray(),
            Diagnostics = snapshot.Diagnostics.Select(diagnostic => new SourceDiagnostic
            {
                Severity = diagnostic.Severity == DiscoverySeverity.Error
                    ? SourceDiagnosticSeverity.Error : SourceDiagnosticSeverity.Warning,
                Code = diagnostic.Code,
                Message = diagnostic.Message
            }).ToArray()
        }));
    }
}

internal sealed class ListImportsEndpoint(ImportOperations operations) : ListImportsEndpointBase
{
    public override Task<Results<Ok<OkResponse>, BadRequestProblem>> HandleAsync(
        Parameters parameters, CancellationToken cancellationToken)
    {
        int limit = parameters.Limit ?? 20;
        if (limit is < 1 or > 100)
            return Task.FromResult<Results<Ok<OkResponse>, BadRequestProblem>>(new BadRequestProblem(
                ApiMapping.Problem(400, "invalid-limit", "The limit must be between 1 and 100.")));
        return Task.FromResult<Results<Ok<OkResponse>, BadRequestProblem>>(TypedResults.Ok(new OkResponse
        {
            Operations = operations.List(limit).Select(ApiMapping.Map).ToArray()
        }));
    }
}

internal sealed class GetImportEndpoint(ImportOperations operations) : GetImportEndpointBase
{
    public override Task<Results<Ok<ImportOperation>, NotFoundProblem>> HandleAsync(
        Guid id, CancellationToken cancellationToken)
    {
        ImportOperationSnapshot? operation = operations.Get(id);
        return Task.FromResult<Results<Ok<ImportOperation>, NotFoundProblem>>(operation is null
            ? new NotFoundProblem(ApiMapping.Problem(404, "unknown-operation",
                "No such import operation. Operation identifiers do not survive a Companion restart."))
            : TypedResults.Ok(ApiMapping.Map(operation)));
    }
}

internal sealed class StartImportEndpoint(ImportOperations operations) : StartImportEndpointBase
{
    public override Task<Results<Accepted<ImportOperation>, BadRequestProblem, NotFoundProblem, ConflictProblem,
        Status429Problem, Status503Problem>> HandleAsync(Request request, CancellationToken cancellationToken)
    {
        ImportSubmission submission = operations.Submit(request.SourceId);
        return Task.FromResult<Results<Accepted<ImportOperation>, BadRequestProblem, NotFoundProblem, ConflictProblem,
            Status429Problem, Status503Problem>>(submission.Rejection switch
            {
                null => TypedResults.Accepted(
                    FormattableString.Invariant($"/api/v1/imports/{submission.Operation!.Id}"),
                    ApiMapping.Map(submission.Operation!)),
                ImportRejection.InvalidSourceId => new BadRequestProblem(ApiMapping.Problem(400, "invalid-source-id",
                    "The sourceId is not a valid source identifier.")),
                ImportRejection.UnknownSource => new NotFoundProblem(ApiMapping.Problem(404, "unknown-source",
                    "The sourceId does not identify a currently discovered source.")),
                ImportRejection.NoSources => new ConflictProblem(ApiMapping.Problem(409, "no-sources",
                    "No SavedVariables sources are currently discovered.")),
                ImportRejection.SourceBusy => new ConflictProblem(ApiMapping.Problem(409, "source-busy",
                    "A requested source already has a queued or running import.")),
                ImportRejection.CapacityExceeded => new Status429Problem(ApiMapping.Problem(429, "import-capacity-exceeded",
                    "Too many imports are queued; retry later.")),
                ImportRejection.CheckpointCapacityExceeded => new Status429Problem(ApiMapping.Problem(429, "checkpoint-capacity-exceeded",
                    "Monitoring metadata capacity is exhausted. Reconcile configured sources or reduce the import batch.")),
                _ => new Status503Problem(ApiMapping.Problem(503, "application-stopping",
                    "The Companion is stopping and is not accepting new imports."))
            });
    }
}
