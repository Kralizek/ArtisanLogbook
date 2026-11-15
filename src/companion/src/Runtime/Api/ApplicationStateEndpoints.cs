using System.Text.Json;

using ArtisanLogbook.CompanionApi.Contracts;
using ArtisanLogbook.CompanionApi.Endpoints;
using ArtisanLogbook.History;

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.Extensions.Logging;

using ApiEntityPreference = ArtisanLogbook.CompanionApi.Contracts.EntityPreference;
using ApiEntityPreferenceKind = ArtisanLogbook.CompanionApi.Contracts.EntityPreferenceKind;
using ApiGameContext = ArtisanLogbook.CompanionApi.Contracts.GameContext;
using ApiSavedInvestigation = ArtisanLogbook.CompanionApi.Contracts.SavedInvestigation;
using ApiSavedInvestigationSummary = ArtisanLogbook.CompanionApi.Contracts.SavedInvestigationSummary;
using DomainGameContext = ArtisanLogbook.History.GameContext;
using StoredEntityPreference = ArtisanLogbook.Runtime.EntityPreference;
using StoredSavedInvestigation = ArtisanLogbook.Runtime.SavedInvestigation;

namespace ArtisanLogbook.Runtime;

internal static class ApplicationStateApiMapping
{
    public static ApiEntityPreference Map(StoredEntityPreference preference) => new()
    {
        Context = Map(preference.Context),
        Kind = Enum.Parse<ApiEntityPreferenceKind>(preference.Kind.ToString(), ignoreCase: false),
        EntityId = preference.EntityId,
        Pinned = preference.Pinned,
        Hidden = preference.Hidden
    };

    public static ApiSavedInvestigation Map(StoredSavedInvestigation investigation) => new()
    {
        Id = Guid.ParseExact(investigation.Id, "D"),
        Name = investigation.Name,
        Context = Map(investigation.Context),
        DefinitionVersion = investigation.DefinitionVersion,
        Definition = investigation.Definition.EnumerateObject()
            .ToDictionary(property => property.Name, property => property.Value.Clone(), StringComparer.Ordinal),
        CreatedAt = investigation.CreatedAt,
        UpdatedAt = investigation.UpdatedAt,
        Revision = investigation.Revision
    };

    public static ApiSavedInvestigationSummary Map(SavedInvestigationSummary investigation) => new()
    {
        Id = Guid.ParseExact(investigation.Id, "D"),
        Name = investigation.Name,
        Context = Map(investigation.Context),
        DefinitionVersion = investigation.DefinitionVersion,
        CreatedAt = investigation.CreatedAt,
        UpdatedAt = investigation.UpdatedAt,
        Revision = investigation.Revision
    };

    private static ApiGameContext Map(DomainGameContext context) => new()
    {
        Project = (int)context.Project,
        ProgressionTrack = context.ProgressionTrack
    };

    public static bool TryContext(ApiGameContext? apiContext, out DomainGameContext? context)
    {
        if (apiContext is null)
        {
            context = null;
            return false;
        }
        return TryContext(apiContext.Project, apiContext.ProgressionTrack, out context);
    }

    public static bool TryContext(int project, string? progressionTrack, out DomainGameContext? context)
    {
        context = null;
        if (progressionTrack is { Length: > ApplicationStateStore.MaximumProgressionTrackLength } ||
            progressionTrack is not null && string.IsNullOrWhiteSpace(progressionTrack))
            return false;
        try
        {
            context = new((GameProject)project, progressionTrack);
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    public static Problem InvalidRequest(string detail) =>
        ApiMapping.Problem(StatusCodes.Status400BadRequest, "invalid-request", detail);

    public static Problem MissingInvestigation() =>
        ApiMapping.Problem(StatusCodes.Status404NotFound, "unknown-investigation",
            "The saved investigation does not exist.");

    public static Problem RevisionConflict() =>
        ApiMapping.Problem(StatusCodes.Status409Conflict, "investigation-revision-conflict",
            "The saved investigation changed since it was read. Reload it before saving.");

    public static Problem Unavailable() =>
        ApiMapping.Problem(StatusCodes.Status503ServiceUnavailable, "application-state-unavailable",
            "Application-state persistence is unavailable or the Companion is stopping.");

    public static JsonHttpResult<Problem> Response(Problem problem, int statusCode) =>
        TypedResults.Json(problem, contentType: "application/problem+json", statusCode: statusCode);

    public static JsonHttpResult<Problem> InvalidRequestResponse(string detail) =>
        Response(InvalidRequest(detail), StatusCodes.Status400BadRequest);

    public static JsonHttpResult<Problem> MissingInvestigationResponse() =>
        Response(MissingInvestigation(), StatusCodes.Status404NotFound);

    public static JsonHttpResult<Problem> RevisionConflictResponse() =>
        Response(RevisionConflict(), StatusCodes.Status409Conflict);

    public static JsonHttpResult<Problem> UnavailableResponse() =>
        Response(Unavailable(), StatusCodes.Status503ServiceUnavailable);

    public static Results<T1, T2, IResult> AsResult<T1, T2>(JsonHttpResult<Problem> result)
        where T1 : IResult where T2 : IResult => result;

    public static Results<T1, T2, T3, IResult> AsResult<T1, T2, T3>(JsonHttpResult<Problem> result)
        where T1 : IResult where T2 : IResult where T3 : IResult =>
        result;

    public static Results<T1, T2, T3, T4, IResult> AsResult<T1, T2, T3, T4>(JsonHttpResult<Problem> result)
        where T1 : IResult where T2 : IResult where T3 : IResult where T4 : IResult =>
        result;

    public static void LogPersistenceFailure(ILogger logger, Exception exception) =>
        logger.LogWarning("Application-state persistence failed ({ExceptionType}).", exception.GetType().Name);
}

internal sealed class GetEntityPreferencesEndpoint(
    ApplicationStateStore store, ILogger<GetEntityPreferencesEndpoint> logger) : GetEntityPreferencesEndpointBase
{
    public override async Task<Results<Ok<EntityPreferenceList>, BadRequest, IResult>> HandleAsync(
        Parameters parameters, CancellationToken cancellationToken)
    {
        if (!ApplicationStateApiMapping.TryContext(parameters.Project, parameters.ProgressionTrack, out DomainGameContext? context))
            return ApplicationStateApiMapping.AsResult<Ok<EntityPreferenceList>, BadRequest>(
                ApplicationStateApiMapping.InvalidRequestResponse("The game context is invalid."));
        try
        {
            IReadOnlyList<StoredEntityPreference> preferences =
                await store.GetEntityPreferencesAsync(context!, cancellationToken).ConfigureAwait(false);
            return TypedResults.Ok(new EntityPreferenceList
            {
                Preferences = preferences.Select(ApplicationStateApiMapping.Map).ToArray()
            });
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return ApplicationStateApiMapping.AsResult<Ok<EntityPreferenceList>, BadRequest>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
        catch (InvalidOperationException)
        {
            return ApplicationStateApiMapping.AsResult<Ok<EntityPreferenceList>, BadRequest>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
    }
}

internal sealed class SetEntityPinnedEndpoint(
    ApplicationStateStore store, ILogger<SetEntityPinnedEndpoint> logger) : SetEntityPinnedEndpointBase
{
    public override async Task<Results<Ok<ApiEntityPreference>, BadRequest, IResult>> HandleAsync(
        string kind, int id, SetPinnedPreference request, CancellationToken cancellationToken)
    {
        if (!TryKind(kind, id, request.Context, out PreferredEntityKind entityKind,
                out DomainGameContext? context, out Problem? problem))
            return ApplicationStateApiMapping.AsResult<Ok<ApiEntityPreference>, BadRequest>(
                ApplicationStateApiMapping.Response(problem!, StatusCodes.Status400BadRequest));
        try
        {
            StoredEntityPreference preference = await store.SetPinnedAsync(
                context!, entityKind, id, request.Pinned, cancellationToken).ConfigureAwait(false);
            return TypedResults.Ok(ApplicationStateApiMapping.Map(preference));
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return ApplicationStateApiMapping.AsResult<Ok<ApiEntityPreference>, BadRequest>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
        catch (InvalidOperationException)
        {
            return ApplicationStateApiMapping.AsResult<Ok<ApiEntityPreference>, BadRequest>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
    }

    internal static bool TryKind(string kind, int id, ApiGameContext? apiContext,
        out PreferredEntityKind entityKind, out DomainGameContext? context, out Problem? problem)
    {
        entityKind = default;
        context = null;
        problem = null;
        if (kind is not (nameof(PreferredEntityKind.Recipe) or nameof(PreferredEntityKind.Item)) ||
            !Enum.TryParse(kind, ignoreCase: false, out entityKind) || id <= 0 ||
            !ApplicationStateApiMapping.TryContext(apiContext, out context))
        {
            problem = ApplicationStateApiMapping.InvalidRequest(
                "The entity kind, entity ID or game context is invalid.");
            return false;
        }
        return true;
    }
}

internal sealed class SetEntityHiddenEndpoint(
    ApplicationStateStore store, ILogger<SetEntityHiddenEndpoint> logger) : SetEntityHiddenEndpointBase
{
    public override async Task<Results<Ok<ApiEntityPreference>, BadRequest, IResult>> HandleAsync(
        string kind, int id, SetHiddenPreference request, CancellationToken cancellationToken)
    {
        if (!SetEntityPinnedEndpoint.TryKind(kind, id, request.Context,
                out PreferredEntityKind entityKind, out DomainGameContext? context, out Problem? problem))
            return ApplicationStateApiMapping.AsResult<Ok<ApiEntityPreference>, BadRequest>(
                ApplicationStateApiMapping.Response(problem!, StatusCodes.Status400BadRequest));
        try
        {
            StoredEntityPreference preference = await store.SetHiddenAsync(
                context!, entityKind, id, request.Hidden, cancellationToken).ConfigureAwait(false);
            return TypedResults.Ok(ApplicationStateApiMapping.Map(preference));
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return ApplicationStateApiMapping.AsResult<Ok<ApiEntityPreference>, BadRequest>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
        catch (InvalidOperationException)
        {
            return ApplicationStateApiMapping.AsResult<Ok<ApiEntityPreference>, BadRequest>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
    }
}

internal sealed class ListSavedInvestigationsEndpoint(
    ApplicationStateStore store, ILogger<ListSavedInvestigationsEndpoint> logger) : ListSavedInvestigationsEndpointBase
{
    public override async Task<Results<Ok<SavedInvestigationList>, BadRequest, IResult>> HandleAsync(
        Parameters parameters, CancellationToken cancellationToken)
    {
        DomainGameContext? context = null;
        if (parameters.Project is int project)
        {
            if (!ApplicationStateApiMapping.TryContext(project, parameters.ProgressionTrack, out context))
                return ApplicationStateApiMapping.AsResult<Ok<SavedInvestigationList>, BadRequest>(
                    ApplicationStateApiMapping.InvalidRequestResponse("The game-context filter is invalid."));
        }
        else if (parameters.ProgressionTrack is not null)
        {
            return ApplicationStateApiMapping.AsResult<Ok<SavedInvestigationList>, BadRequest>(
                ApplicationStateApiMapping.InvalidRequestResponse("A progression-track filter requires a project."));
        }
        try
        {
            IReadOnlyList<SavedInvestigationSummary> investigations =
                await store.ListInvestigationsAsync(context, cancellationToken).ConfigureAwait(false);
            return TypedResults.Ok(new SavedInvestigationList
            {
                Investigations = investigations.Select(ApplicationStateApiMapping.Map).ToArray()
            });
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return ApplicationStateApiMapping.AsResult<Ok<SavedInvestigationList>, BadRequest>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
        catch (InvalidOperationException)
        {
            return ApplicationStateApiMapping.AsResult<Ok<SavedInvestigationList>, BadRequest>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
    }
}

internal sealed class CreateSavedInvestigationEndpoint(
    ApplicationStateStore store, ILogger<CreateSavedInvestigationEndpoint> logger) : CreateSavedInvestigationEndpointBase
{
    public override async Task<Results<Created<ApiSavedInvestigation>, BadRequest, IResult>> HandleAsync(
        CreateSavedInvestigation request, CancellationToken cancellationToken)
    {
        if (!ApplicationStateApiMapping.TryContext(request.Context, out DomainGameContext? context))
            return ApplicationStateApiMapping.AsResult<Created<ApiSavedInvestigation>, BadRequest>(
                ApplicationStateApiMapping.InvalidRequestResponse("The game context is invalid."));
        try
        {
            StoredSavedInvestigation investigation = await store.CreateInvestigationAsync(
                request.Name, context!, request.DefinitionVersion, JsonSerializer.SerializeToElement(request.Definition),
                cancellationToken).ConfigureAwait(false);
            ApiSavedInvestigation result = ApplicationStateApiMapping.Map(investigation);
            return TypedResults.Created($"/api/v1/saved-investigations/{investigation.Id}", result);
        }
        catch (ArgumentException)
        {
            return ApplicationStateApiMapping.AsResult<Created<ApiSavedInvestigation>, BadRequest>(
                ApplicationStateApiMapping.InvalidRequestResponse(
                    "The saved investigation name or definition is invalid."));
        }
        catch (JsonException)
        {
            return ApplicationStateApiMapping.AsResult<Created<ApiSavedInvestigation>, BadRequest>(
                ApplicationStateApiMapping.InvalidRequestResponse(
                    "The saved investigation definition is invalid."));
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return ApplicationStateApiMapping.AsResult<Created<ApiSavedInvestigation>, BadRequest>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
        catch (InvalidOperationException)
        {
            return ApplicationStateApiMapping.AsResult<Created<ApiSavedInvestigation>, BadRequest>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
    }
}

internal sealed class GetSavedInvestigationEndpoint(
    ApplicationStateStore store, ILogger<GetSavedInvestigationEndpoint> logger) : GetSavedInvestigationEndpointBase
{
    public override async Task<Results<Ok<ApiSavedInvestigation>, NotFound, IResult>> HandleAsync(
        Guid id, CancellationToken cancellationToken)
    {
        try
        {
            StoredSavedInvestigation? investigation = await store.GetInvestigationAsync(id.ToString("D"), cancellationToken)
                .ConfigureAwait(false);
            if (investigation is null)
                return ApplicationStateApiMapping.AsResult<Ok<ApiSavedInvestigation>, NotFound>(
                    ApplicationStateApiMapping.MissingInvestigationResponse());
            return TypedResults.Ok(ApplicationStateApiMapping.Map(investigation));
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return ApplicationStateApiMapping.AsResult<Ok<ApiSavedInvestigation>, NotFound>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
        catch (InvalidOperationException)
        {
            return ApplicationStateApiMapping.AsResult<Ok<ApiSavedInvestigation>, NotFound>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
    }
}

internal sealed class DeleteSavedInvestigationEndpoint(
    ApplicationStateStore store, ILogger<DeleteSavedInvestigationEndpoint> logger) : DeleteSavedInvestigationEndpointBase
{
    public override async Task<Results<NoContent, BadRequest, NotFound, Conflict, IResult>>
        HandleAsync(Guid id, Parameters parameters, CancellationToken cancellationToken)
    {
        if (parameters.Revision <= 0)
            return ApplicationStateApiMapping.AsResult<NoContent, BadRequest, NotFound, Conflict>(
                ApplicationStateApiMapping.InvalidRequestResponse("The revision must be positive."));
        try
        {
            bool deleted = await store.DeleteInvestigationAsync(id.ToString("D"), parameters.Revision, cancellationToken)
                .ConfigureAwait(false);
            if (!deleted)
                return ApplicationStateApiMapping.AsResult<NoContent, BadRequest, NotFound, Conflict>(
                    ApplicationStateApiMapping.MissingInvestigationResponse());
            return TypedResults.NoContent();
        }
        catch (ArgumentException)
        {
            return ApplicationStateApiMapping.AsResult<NoContent, BadRequest, NotFound, Conflict>(
                ApplicationStateApiMapping.InvalidRequestResponse("The saved investigation ID is invalid."));
        }
        catch (SavedInvestigationRevisionConflictException)
        {
            return ApplicationStateApiMapping.AsResult<NoContent, BadRequest, NotFound, Conflict>(
                ApplicationStateApiMapping.RevisionConflictResponse());
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return ApplicationStateApiMapping.AsResult<NoContent, BadRequest, NotFound, Conflict>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
        catch (InvalidOperationException)
        {
            return ApplicationStateApiMapping.AsResult<NoContent, BadRequest, NotFound, Conflict>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
    }
}

internal sealed class UpdateSavedInvestigationEndpoint(
    ApplicationStateStore store, ILogger<UpdateSavedInvestigationEndpoint> logger)
    : UpdateSavedInvestigationEndpointBase
{
    public override async Task<Results<Ok<ApiSavedInvestigation>, BadRequest, NotFound, Conflict, IResult>>
        HandleAsync(Guid id, UpdateSavedInvestigation request, CancellationToken cancellationToken)
    {
        if (request.Revision <= 0)
            return ApplicationStateApiMapping.AsResult<Ok<ApiSavedInvestigation>, BadRequest, NotFound, Conflict>(
                ApplicationStateApiMapping.InvalidRequestResponse("The revision must be positive."));
        try
        {
            StoredSavedInvestigation? investigation = await store.UpdateInvestigationAsync(
                id.ToString("D"), request.Name, request.DefinitionVersion,
                JsonSerializer.SerializeToElement(request.Definition), request.Revision, cancellationToken)
                .ConfigureAwait(false);
            if (investigation is null)
                return ApplicationStateApiMapping.AsResult<Ok<ApiSavedInvestigation>, BadRequest, NotFound, Conflict>(
                    ApplicationStateApiMapping.MissingInvestigationResponse());
            return TypedResults.Ok(ApplicationStateApiMapping.Map(investigation));
        }
        catch (ArgumentException)
        {
            return ApplicationStateApiMapping.AsResult<Ok<ApiSavedInvestigation>, BadRequest, NotFound, Conflict>(
                ApplicationStateApiMapping.InvalidRequestResponse(
                    "The saved investigation name or definition is invalid."));
        }
        catch (JsonException)
        {
            return ApplicationStateApiMapping.AsResult<Ok<ApiSavedInvestigation>, BadRequest, NotFound, Conflict>(
                ApplicationStateApiMapping.InvalidRequestResponse(
                    "The saved investigation definition is invalid."));
        }
        catch (SavedInvestigationRevisionConflictException)
        {
            return ApplicationStateApiMapping.AsResult<Ok<ApiSavedInvestigation>, BadRequest, NotFound, Conflict>(
                ApplicationStateApiMapping.RevisionConflictResponse());
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return ApplicationStateApiMapping.AsResult<Ok<ApiSavedInvestigation>, BadRequest, NotFound, Conflict>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
        catch (InvalidOperationException)
        {
            return ApplicationStateApiMapping.AsResult<Ok<ApiSavedInvestigation>, BadRequest, NotFound, Conflict>(
                ApplicationStateApiMapping.UnavailableResponse());
        }
    }
}
