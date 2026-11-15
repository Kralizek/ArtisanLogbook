using System.Text.Json;

using ArtisanLogbook.CompanionApi.Contracts;
using ArtisanLogbook.CompanionApi.Endpoints;
using ArtisanLogbook.History;

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.Extensions.Logging;

using ApiEntityPreference = ArtisanLogbook.CompanionApi.Contracts.EntityPreference;
using ApiEntityPreferenceKind = ArtisanLogbook.CompanionApi.Contracts.EntityPreferenceKind;
using ApiLastSelectedContextContext = ArtisanLogbook.CompanionApi.Contracts.LastSelectedContextContext;
using ApiSavedInvestigation = ArtisanLogbook.CompanionApi.Contracts.SavedInvestigation;
using DomainGameContext = ArtisanLogbook.History.GameContext;
using StoredEntityPreference = ArtisanLogbook.Runtime.EntityPreference;
using StoredSavedInvestigation = ArtisanLogbook.Runtime.SavedInvestigation;

namespace ArtisanLogbook.Runtime;

internal static class ApplicationStateApiMapping
{
    public static ApiEntityPreference Map(StoredEntityPreference preference) => new()
    {
        Project = (int)preference.Context.Project,
        ProgressionTrack = preference.Context.ProgressionTrack,
        Kind = Enum.Parse<ApiEntityPreferenceKind>(preference.Kind.ToString(), ignoreCase: false),
        EntityId = preference.EntityId,
        Pinned = preference.Pinned,
        Hidden = preference.Hidden
    };

    public static ApiSavedInvestigation Map(StoredSavedInvestigation investigation) => new()
    {
        Id = Guid.ParseExact(investigation.Id, "D"),
        Name = investigation.Name,
        Project = (int)investigation.Context.Project,
        ProgressionTrack = investigation.Context.ProgressionTrack,
        DefinitionVersion = investigation.DefinitionVersion,
        Definition = investigation.Definition.EnumerateObject()
            .ToDictionary(property => property.Name, property => property.Value.Clone(), StringComparer.Ordinal),
        CreatedAt = investigation.CreatedAt,
        UpdatedAt = investigation.UpdatedAt,
        Revision = investigation.Revision
    };

    public static LastSelectedContext Map(DomainGameContext? context) => new()
    {
        Context = context is null ? null : new ApiLastSelectedContextContext
        {
            Project = (int)context.Project,
            ProgressionTrack = context.ProgressionTrack
        }
    };

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

    public static void LogPersistenceFailure(ILogger logger, Exception exception) =>
        logger.LogWarning("Application-state persistence failed ({ExceptionType}).", exception.GetType().Name);
}

internal sealed class GetEntityPreferencesEndpoint(
    ApplicationStateStore store, ILogger<GetEntityPreferencesEndpoint> logger) : GetEntityPreferencesEndpointBase
{
    public override async Task<Results<Ok<EntityPreferenceList>, BadRequestProblem, Status503Problem>> HandleAsync(
        Parameters parameters, CancellationToken cancellationToken)
    {
        if (!ApplicationStateApiMapping.TryContext(parameters.Project, parameters.ProgressionTrack, out DomainGameContext? context))
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest("The game context is invalid."));
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
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
        catch (InvalidOperationException)
        {
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
    }
}

internal sealed class SetEntityPinnedEndpoint(
    ApplicationStateStore store, ILogger<SetEntityPinnedEndpoint> logger) : SetEntityPinnedEndpointBase
{
    public override async Task<Results<Ok<ApiEntityPreference>, SetEntityPinnedEndpointBase.BadRequestProblem,
        SetEntityPinnedEndpointBase.Status503Problem>> HandleAsync(
        string kind, int id, SetPinnedPreference request, CancellationToken cancellationToken)
    {
        if (!TryKind(kind, id, request.Project, request.ProgressionTrack, out PreferredEntityKind entityKind,
                out DomainGameContext? context, out Problem? problem))
            return new BadRequestProblem(problem!);
        try
        {
            StoredEntityPreference preference = await store.SetPinnedAsync(
                context!, entityKind, id, request.Pinned, cancellationToken).ConfigureAwait(false);
            return TypedResults.Ok(ApplicationStateApiMapping.Map(preference));
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
        catch (InvalidOperationException)
        {
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
    }

    internal static bool TryKind(string kind, int id, int project, string? progressionTrack,
        out PreferredEntityKind entityKind, out DomainGameContext? context, out Problem? problem)
    {
        entityKind = default;
        context = null;
        problem = null;
        if (kind is not (nameof(PreferredEntityKind.Recipe) or nameof(PreferredEntityKind.Item)) ||
            !Enum.TryParse(kind, ignoreCase: false, out entityKind) || id <= 0 ||
            !ApplicationStateApiMapping.TryContext(project, progressionTrack, out context))
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
    public override async Task<Results<Ok<ApiEntityPreference>, SetEntityHiddenEndpointBase.BadRequestProblem,
        SetEntityHiddenEndpointBase.Status503Problem>> HandleAsync(
        string kind, int id, SetHiddenPreference request, CancellationToken cancellationToken)
    {
        if (!SetEntityPinnedEndpoint.TryKind(kind, id, request.Project, request.ProgressionTrack,
                out PreferredEntityKind entityKind, out DomainGameContext? context, out Problem? problem))
            return new BadRequestProblem(problem!);
        try
        {
            StoredEntityPreference preference = await store.SetHiddenAsync(
                context!, entityKind, id, request.Hidden, cancellationToken).ConfigureAwait(false);
            return TypedResults.Ok(ApplicationStateApiMapping.Map(preference));
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
        catch (InvalidOperationException)
        {
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
    }
}

internal sealed class GetLastSelectedContextEndpoint(
    ApplicationStateStore store, ILogger<GetLastSelectedContextEndpoint> logger) : GetLastSelectedContextEndpointBase
{
    public override async Task<Results<Ok<LastSelectedContext>, Status503Problem>> HandleAsync(
        CancellationToken cancellationToken)
    {
        try
        {
            DomainGameContext? context = await store.GetLastSelectedContextAsync(cancellationToken).ConfigureAwait(false);
            return TypedResults.Ok(ApplicationStateApiMapping.Map(context));
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
        catch (InvalidOperationException)
        {
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
    }
}

internal sealed class SetLastSelectedContextEndpoint(
    ApplicationStateStore store, ILogger<SetLastSelectedContextEndpoint> logger) : SetLastSelectedContextEndpointBase
{
    public override async Task<Results<Ok<LastSelectedContext>, BadRequestProblem, Status503Problem>> HandleAsync(
        GameContextPreference request, CancellationToken cancellationToken)
    {
        if (!ApplicationStateApiMapping.TryContext(request.Project, request.ProgressionTrack, out DomainGameContext? context))
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest("The game context is invalid."));
        try
        {
            await store.SetLastSelectedContextAsync(context!, cancellationToken).ConfigureAwait(false);
            return TypedResults.Ok(ApplicationStateApiMapping.Map(context));
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
        catch (InvalidOperationException)
        {
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
    }
}

internal sealed class ListSavedInvestigationsEndpoint(
    ApplicationStateStore store, ILogger<ListSavedInvestigationsEndpoint> logger) : ListSavedInvestigationsEndpointBase
{
    public override async Task<Results<Ok<SavedInvestigationList>, BadRequestProblem, Status503Problem>> HandleAsync(
        Parameters parameters, CancellationToken cancellationToken)
    {
        try
        {
            IReadOnlyList<StoredSavedInvestigation> investigations = await store.ListInvestigationsAsync(
                parameters.Project, parameters.ProgressionTrack, cancellationToken).ConfigureAwait(false);
            return TypedResults.Ok(new SavedInvestigationList
            {
                Investigations = investigations.Select(ApplicationStateApiMapping.Map).ToArray()
            });
        }
        catch (ArgumentException)
        {
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest("The game-context filter is invalid."));
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
        catch (InvalidOperationException)
        {
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
    }
}

internal sealed class CreateSavedInvestigationEndpoint(
    ApplicationStateStore store, ILogger<CreateSavedInvestigationEndpoint> logger) : CreateSavedInvestigationEndpointBase
{
    public override async Task<Results<Created<ApiSavedInvestigation>, CreateSavedInvestigationEndpointBase.BadRequestProblem,
        CreateSavedInvestigationEndpointBase.Status503Problem>> HandleAsync(
        CreateSavedInvestigation request, CancellationToken cancellationToken)
    {
        if (!ApplicationStateApiMapping.TryContext(request.Project, request.ProgressionTrack, out DomainGameContext? context))
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest("The game context is invalid."));
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
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest(
                "The saved investigation name or definition is invalid."));
        }
        catch (JsonException)
        {
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest("The saved investigation definition is invalid."));
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
        catch (InvalidOperationException)
        {
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
    }
}

internal sealed class GetSavedInvestigationEndpoint(
    ApplicationStateStore store, ILogger<GetSavedInvestigationEndpoint> logger) : GetSavedInvestigationEndpointBase
{
    public override async Task<Results<Ok<ApiSavedInvestigation>, GetSavedInvestigationEndpointBase.NotFoundProblem,
        GetSavedInvestigationEndpointBase.Status503Problem>> HandleAsync(
        Guid id, CancellationToken cancellationToken)
    {
        try
        {
            StoredSavedInvestigation? investigation = await store.GetInvestigationAsync(id.ToString("D"), cancellationToken)
                .ConfigureAwait(false);
            return investigation is null
                ? new NotFoundProblem(ApplicationStateApiMapping.MissingInvestigation())
                : TypedResults.Ok(ApplicationStateApiMapping.Map(investigation));
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
        catch (InvalidOperationException)
        {
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
    }
}

internal sealed class DeleteSavedInvestigationEndpoint(
    ApplicationStateStore store, ILogger<DeleteSavedInvestigationEndpoint> logger) : DeleteSavedInvestigationEndpointBase
{
    public override async Task<Results<NoContent, DeleteSavedInvestigationEndpointBase.BadRequestProblem,
        DeleteSavedInvestigationEndpointBase.NotFoundProblem, DeleteSavedInvestigationEndpointBase.ConflictProblem,
        DeleteSavedInvestigationEndpointBase.Status503Problem>>
        HandleAsync(Guid id, Parameters parameters, CancellationToken cancellationToken)
    {
        if (parameters.Revision <= 0)
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest("The revision must be positive."));
        try
        {
            bool deleted = await store.DeleteInvestigationAsync(id.ToString("D"), parameters.Revision, cancellationToken)
                .ConfigureAwait(false);
            return deleted ? TypedResults.NoContent() :
                new NotFoundProblem(ApplicationStateApiMapping.MissingInvestigation());
        }
        catch (ArgumentException)
        {
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest("The saved investigation ID is invalid."));
        }
        catch (SavedInvestigationRevisionConflictException)
        {
            return new ConflictProblem(ApplicationStateApiMapping.RevisionConflict());
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
        catch (InvalidOperationException)
        {
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
    }
}

internal sealed class RenameSavedInvestigationEndpoint(
    ApplicationStateStore store, ILogger<RenameSavedInvestigationEndpoint> logger) : RenameSavedInvestigationEndpointBase
{
    public override async Task<Results<Ok<ApiSavedInvestigation>, RenameSavedInvestigationEndpointBase.BadRequestProblem,
        RenameSavedInvestigationEndpointBase.NotFoundProblem, RenameSavedInvestigationEndpointBase.ConflictProblem,
        RenameSavedInvestigationEndpointBase.Status503Problem>>
        HandleAsync(Guid id, RenameSavedInvestigation request, CancellationToken cancellationToken)
    {
        if (request.Revision <= 0)
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest("The revision must be positive."));
        try
        {
            StoredSavedInvestigation? investigation = await store.RenameInvestigationAsync(
                id.ToString("D"), request.Name, request.Revision, cancellationToken).ConfigureAwait(false);
            return investigation is null
                ? new NotFoundProblem(ApplicationStateApiMapping.MissingInvestigation())
                : TypedResults.Ok(ApplicationStateApiMapping.Map(investigation));
        }
        catch (ArgumentException)
        {
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest(
                "The saved investigation name is invalid."));
        }
        catch (SavedInvestigationRevisionConflictException)
        {
            return new ConflictProblem(ApplicationStateApiMapping.RevisionConflict());
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
        catch (InvalidOperationException)
        {
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
    }
}

internal sealed class ReplaceSavedInvestigationDefinitionEndpoint(
    ApplicationStateStore store, ILogger<ReplaceSavedInvestigationDefinitionEndpoint> logger)
    : ReplaceSavedInvestigationDefinitionEndpointBase
{
    public override async Task<Results<Ok<ApiSavedInvestigation>, ReplaceSavedInvestigationDefinitionEndpointBase.BadRequestProblem,
        ReplaceSavedInvestigationDefinitionEndpointBase.NotFoundProblem,
        ReplaceSavedInvestigationDefinitionEndpointBase.ConflictProblem,
        ReplaceSavedInvestigationDefinitionEndpointBase.Status503Problem>>
        HandleAsync(Guid id, ReplaceSavedInvestigationDefinition request, CancellationToken cancellationToken)
    {
        if (request.Revision <= 0)
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest("The revision must be positive."));
        try
        {
            StoredSavedInvestigation? investigation = await store.ReplaceInvestigationDefinitionAsync(
                id.ToString("D"), request.DefinitionVersion, JsonSerializer.SerializeToElement(request.Definition),
                request.Revision, cancellationToken)
                .ConfigureAwait(false);
            return investigation is null
                ? new NotFoundProblem(ApplicationStateApiMapping.MissingInvestigation())
                : TypedResults.Ok(ApplicationStateApiMapping.Map(investigation));
        }
        catch (ArgumentException)
        {
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest(
                "The saved investigation definition is invalid."));
        }
        catch (JsonException)
        {
            return new BadRequestProblem(ApplicationStateApiMapping.InvalidRequest("The saved investigation definition is invalid."));
        }
        catch (SavedInvestigationRevisionConflictException)
        {
            return new ConflictProblem(ApplicationStateApiMapping.RevisionConflict());
        }
        catch (ApplicationStatePersistenceException exception)
        {
            ApplicationStateApiMapping.LogPersistenceFailure(logger, exception);
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
        catch (InvalidOperationException)
        {
            return new Status503Problem(ApplicationStateApiMapping.Unavailable());
        }
    }
}
