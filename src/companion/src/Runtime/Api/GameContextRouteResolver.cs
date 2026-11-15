using System.Globalization;

using ArtisanLogbook.History;

namespace ArtisanLogbook.Runtime;

internal sealed record ResolvedGameContext(
    GameContext Value, string CanonicalId, string RouteAlias, string DisplayName);

internal static class GameContextRouteResolver
{
    private sealed record SupportedProject(string Alias, string DisplayName);

    private static readonly IReadOnlyDictionary<int, SupportedProject> SupportedProjects =
        new Dictionary<int, SupportedProject>
        {
            [(int)GameProject.Retail] = new("retail", "Retail"),
            [(int)GameProject.Forever] = new("forever", "Forever")
        };

    private static readonly IReadOnlyDictionary<string, GameContext> KnownAliases =
        SupportedProjects.ToDictionary(
            pair => pair.Value.Alias,
            pair => new GameContext((GameProject)pair.Key),
            StringComparer.Ordinal);

    public static ResolvedGameContext Describe(GameContext context)
    {
        ArgumentNullException.ThrowIfNull(context);

        int projectId = (int)context.Project;
        string canonicalId = GameContextCodec.Encode(context);
        bool isSupportedProject = SupportedProjects.TryGetValue(projectId, out SupportedProject? project);
        string displayName = isSupportedProject
            ? project!.DisplayName
            : $"Project {projectId.ToString(CultureInfo.InvariantCulture)}";
        if (context.ProgressionTrack is not null)
            displayName = $"{displayName} {context.ProgressionTrack}";

        string routeAlias = isSupportedProject && context.ProgressionTrack is null
            ? project!.Alias
            : canonicalId;

        return new(context, canonicalId, routeAlias, displayName);
    }

    public static bool TryResolve(string? locator, out ResolvedGameContext? resolved)
    {
        resolved = null;
        if (string.IsNullOrEmpty(locator))
            return false;

        if (KnownAliases.TryGetValue(locator, out GameContext? known))
        {
            resolved = Describe(known);
            return true;
        }

        if (!GameContextCodec.TryDecode(locator, out GameContext? canonical))
            return false;

        resolved = Describe(canonical!);
        return true;
    }
}
