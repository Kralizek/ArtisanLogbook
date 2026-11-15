using System.Globalization;
using System.Text;

using ArtisanLogbook.History;

namespace ArtisanLogbook.Runtime;

internal sealed record ResolvedGameContext(
    GameContext Value, string CanonicalId, string RouteAlias, string DisplayName);

internal static class GameContextRouteResolver
{
    private sealed record ProjectName(string Alias, string DisplayName);

    private static readonly IReadOnlyDictionary<int, ProjectName> KnownProjects =
        new Dictionary<int, ProjectName>
        {
            [(int)GameProject.Retail] = new("retail", "Retail"),
            [(int)GameProject.ClassicEra] = new("classic-era", "Classic Era"),
            [(int)GameProject.WowLabs] = new("wow-labs", "WoW Labs"),
            [(int)GameProject.BurningCrusadeClassic] = new("burning-crusade-classic", "Burning Crusade Classic"),
            [(int)GameProject.WrathClassic] = new("wrath-classic", "Wrath Classic"),
            [(int)GameProject.CataclysmClassic] = new("cataclysm-classic", "Cataclysm Classic"),
            [(int)GameProject.Forever] = new("forever", "Forever"),
            [(int)GameProject.MistsClassic] = new("mists-classic", "Mists of Pandaria Classic")
        };

    private static readonly IReadOnlyDictionary<string, GameContext> KnownAliases =
        CreateKnownAliases();

    private static readonly HashSet<string> ReservedRouteNames = new(StringComparer.Ordinal)
    {
        "health",
        "status",
        "monitoring",
        "imports",
        "sources",
        "entity-preferences",
        "saved-investigations",
        "game-contexts",
        "openapi",
        "graphql"
    };

    public static ResolvedGameContext Describe(GameContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        ProjectName? project = KnownProjects.GetValueOrDefault((int)context.Project);
        string baseName = project?.DisplayName ?? $"Project {(int)context.Project}";
        string alias;
        string displayName;

        if (context.ProgressionTrack is null)
        {
            alias = project?.Alias ?? $"project-{(int)context.Project}";
            displayName = baseName;
        }
        else if (context.Project == GameProject.Forever &&
                 string.Equals(context.ProgressionTrack, "Hardcore", StringComparison.Ordinal))
        {
            alias = "forever-hardcore";
            displayName = "Forever Hardcore";
        }
        else
        {
            alias = $"ctx-{(int)context.Project}-t-{EncodeTrack(context.ProgressionTrack)}";
            displayName = $"{baseName} {context.ProgressionTrack}";
        }

        return new(context, GameContextCodec.Encode(context), alias, displayName);
    }

    public static bool TryResolve(string? locator, out ResolvedGameContext? resolved)
    {
        resolved = null;
        if (string.IsNullOrEmpty(locator) || ReservedRouteNames.Contains(locator))
            return false;

        if (KnownAliases.TryGetValue(locator, out GameContext? known))
        {
            resolved = Describe(known);
            return true;
        }

        if (GameContextCodec.TryDecode(locator, out GameContext? canonical))
        {
            resolved = Describe(canonical!);
            return true;
        }

        if (TryDecodeProjectAlias(locator, out GameContext? projectContext) ||
            TryDecodeTrackAlias(locator, out projectContext))
        {
            ResolvedGameContext candidate = Describe(projectContext!);
            if (!string.Equals(candidate.RouteAlias, locator, StringComparison.Ordinal))
                return false;
            resolved = candidate;
            return true;
        }

        return false;
    }

    private static IReadOnlyDictionary<string, GameContext> CreateKnownAliases()
    {
        Dictionary<string, GameContext> aliases = KnownProjects
            .ToDictionary(
                pair => pair.Value.Alias,
                pair => new GameContext((GameProject)pair.Key),
                StringComparer.Ordinal);
        aliases.Add("forever-hardcore", new(GameProject.Forever, "Hardcore"));
        return aliases;
    }

    private static string EncodeTrack(string track)
    {
        StringBuilder encoded = new(checked(track.Length * 4));
        foreach (char character in track)
            encoded.Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
        return encoded.ToString();
    }

    private static bool TryDecodeProjectAlias(string locator, out GameContext? context)
    {
        context = null;
        const string prefix = "project-";
        if (!locator.StartsWith(prefix, StringComparison.Ordinal) ||
            !TryParseProject(locator.AsSpan(prefix.Length), out int projectId) ||
            KnownProjects.ContainsKey(projectId))
            return false;
        context = new((GameProject)projectId);
        return true;
    }

    private static bool TryDecodeTrackAlias(string locator, out GameContext? context)
    {
        context = null;
        const string prefix = "ctx-";
        if (!locator.StartsWith(prefix, StringComparison.Ordinal))
            return false;

        ReadOnlySpan<char> payload = locator.AsSpan(prefix.Length);
        int separator = payload.IndexOf("-t-", StringComparison.Ordinal);
        if (separator <= 0 ||
            !TryParseProject(payload[..separator], out int projectId))
            return false;

        ReadOnlySpan<char> encodedTrack = payload[(separator + 3)..];
        if (encodedTrack.IsEmpty || encodedTrack.Length % 4 != 0)
            return false;

        char[] track = new char[encodedTrack.Length / 4];
        for (int index = 0; index < track.Length; index++)
        {
            if (!ushort.TryParse(encodedTrack.Slice(index * 4, 4), NumberStyles.AllowHexSpecifier,
                    CultureInfo.InvariantCulture, out ushort character))
                return false;
            track[index] = (char)character;
        }

        try
        {
            context = new((GameProject)projectId, new string(track));
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private static bool TryParseProject(ReadOnlySpan<char> value, out int projectId)
    {
        projectId = 0;
        if (value.IsEmpty)
            return false;
        foreach (char character in value)
            if (character is < '0' or > '9')
                return false;
        return int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out projectId) &&
            projectId > 0 &&
            string.Equals(projectId.ToString(CultureInfo.InvariantCulture), value.ToString(), StringComparison.Ordinal);
    }
}
