using ArtisanLogbook.CompanionApi.Contracts;
using ArtisanLogbook.CompanionApi.Endpoints;

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace ArtisanLogbook.Runtime;

internal static class InstallationApiMapping
{
    public static InstallationSelection Map(InstallationOptionsSnapshot snapshot) => new()
    {
        Revision = snapshot.Revision,
        ConfiguredRoots = snapshot.ConfiguredRoots,
        ActiveRoots = snapshot.ActiveRoots,
        RestartRequired = snapshot.RestartRequired,
        Candidates = snapshot.Candidates.Select(candidate => new InstallationSelectionCandidatesItem
        {
            Token = candidate.Token,
            Label = candidate.Label,
            Configured = candidate.Configured
        }).ToArray()
    };
}

internal sealed class GetInstallationOptionsEndpoint(InstallationOptions options) : GetInstallationOptionsEndpointBase
{
    public override Task<Results<Ok<InstallationSelection>, ConflictProblem>> HandleAsync(CancellationToken cancellationToken)
    {
        try
        {
            return Task.FromResult<Results<Ok<InstallationSelection>, ConflictProblem>>(
                TypedResults.Ok(InstallationApiMapping.Map(options.Read())));
        }
        catch (CompanionSettingsException)
        {
            return Task.FromResult<Results<Ok<InstallationSelection>, ConflictProblem>>(
                new ConflictProblem(ApiMapping.Problem(409, "settings-conflict",
                    "Settings cannot be read. Back up and repair the settings file.")));
        }
    }
}

internal sealed class UpdateInstallationRootsEndpoint(
    InstallationOptions options, IHostApplicationLifetime lifetime, ILogger<UpdateInstallationRootsEndpoint> logger)
    : UpdateInstallationRootsEndpointBase
{
    public override Task<Results<Ok<InstallationSelection>, BadRequestProblem, ConflictProblem, Status503Problem>> HandleAsync(
        Request request, CancellationToken cancellationToken)
    {
        if (lifetime.ApplicationStopping.IsCancellationRequested)
            return Result(new Status503Problem(ApiMapping.Problem(503, "application-stopping",
                "The Companion is stopping and is not accepting preference changes.")));
        try
        {
            return Result(TypedResults.Ok(InstallationApiMapping.Map(
                options.Save(request.Revision, request.CandidateTokens, cancellationToken))));
        }
        catch (ArgumentException)
        {
            return Result(new BadRequestProblem(ApiMapping.Problem(400, "invalid-installation-selection",
                "Select distinct, currently offered installation candidates only.")));
        }
        catch (CompanionSettingsException)
        {
            return Result(new ConflictProblem(ApiMapping.Problem(409, "settings-conflict",
                "Installation selection changed or is no longer available. Refresh and retry.")));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            logger.LogWarning("Installation selection could not be persisted ({ExceptionType}).", exception.GetType().Name);
            return Result(new Status503Problem(ApiMapping.Problem(503, "settings-save-failed",
                "Installation selection could not be saved; the running configuration was not changed.")));
        }
    }

    private static Task<Results<Ok<InstallationSelection>, BadRequestProblem, ConflictProblem, Status503Problem>> Result(
        Results<Ok<InstallationSelection>, BadRequestProblem, ConflictProblem, Status503Problem> result) =>
        Task.FromResult(result);
}
