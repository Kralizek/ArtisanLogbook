using System.Globalization;
using System.Text;

using ArtisanLogbook.History;

using HotChocolate;

namespace ArtisanLogbook.Runtime.GraphQL;

/// <summary>
/// Opaque, URL-friendly IDs and cursors. A token is <c>{kind code}{project}[.{track}]-{key}</c>, for example
/// <c>r1-1230868</c> for a Retail recipe; craft tokens carry their origin and observation instead of a context.
/// Fields are written with <see cref="Escape"/>, so tokens need no percent-encoding in paths or query strings.
/// </summary>
internal static class HistoryTokens
{
    private sealed record Payload(string Kind, int? Project, string? Track, string? Key,
        string? Origin, string? Observation, DateTimeOffset? RecordedAt);

    private static readonly IReadOnlyDictionary<string, string> Codes = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["context"] = "x",
        ["recipe"] = "r",
        ["item"] = "i",
        ["profession"] = "p",
        ["character"] = "c",
        ["expansion"] = "e",
        ["game-expansion"] = "g",
        ["configuration"] = "s",
        ["recipe-slot"] = "t",
        ["craft"] = "k",
    };

    private static readonly IReadOnlyDictionary<string, string> Kinds =
        Codes.ToDictionary(pair => pair.Value, pair => pair.Key, StringComparer.Ordinal);

    public static string Craft(CraftIdentity identity) =>
        Code("craft") + "-" + Escape(identity.Origin) + "*" + Escape(identity.Observation);

    public static CraftIdentity ParseCraft(string value)
    {
        Payload payload = Decode(value, "craft");
        if (string.IsNullOrWhiteSpace(payload.Origin) || string.IsNullOrWhiteSpace(payload.Observation))
            throw InvalidToken();
        return new(payload.Origin, payload.Observation);
    }

    public static string Dimension(string kind, GameContext game, string key) =>
        Code(kind) + ((int)game.Project).ToString(CultureInfo.InvariantCulture) +
        (game.ProgressionTrack is null ? "" : "." + Escape(game.ProgressionTrack, keepDash: false)) +
        "-" + Escape(key);

    public static string Context(GameContext game) => Dimension("context", game, "");

    public static (GameContext Game, string Key) ParseDimension(string token, string kind)
    {
        Payload payload = Decode(token, kind);
        if (payload.Project is null or <= 0 || payload.Key is null ||
            (kind is not ("context" or "cursor:context") && string.IsNullOrWhiteSpace(payload.Key)) ||
            (payload.Track is not null && string.IsNullOrWhiteSpace(payload.Track)))
            throw InvalidToken();
        return (new((GameProject)payload.Project.Value, payload.Track), payload.Key);
    }

    public static GameContext ParseContext(string token) => ParseDimension(token, "context").Game;

    public static DimensionIdentity<int> ParseIntegerDimension(string token, string kind)
    {
        (GameContext game, string key) = ParseDimension(token, kind);
        if (!int.TryParse(key, NumberStyles.None, CultureInfo.InvariantCulture, out int id) || id <= 0)
            throw InvalidToken();
        return new(game, id);
    }

    public static string DimensionCursor<TKey>(string kind, DimensionIdentity<TKey> position) where TKey : notnull =>
        Dimension("cursor:" + kind, position.Game, Convert.ToString(position.Key, CultureInfo.InvariantCulture)!);

    public static string CharacterCursor(DimensionIdentity<CharacterIdentity> position) =>
        Dimension("cursor:character", position.Game, position.Key.Key);

    // The recorded instant keeps its 100 ns precision and its original offset.
    public static string CraftCursor(CraftPagePosition position) =>
        Code("cursor:craft") + "-" + position.RecordedAt.UtcTicks.ToString(CultureInfo.InvariantCulture) + "*" +
        ((int)position.RecordedAt.Offset.TotalMinutes).ToString(CultureInfo.InvariantCulture) + "*" +
        Escape(position.Identity.Origin) + "*" + Escape(position.Identity.Observation);

    public static CraftPagePosition ParseCraftCursor(string value)
    {
        Payload payload = Decode(value, "cursor:craft");
        if (payload.RecordedAt is null || string.IsNullOrWhiteSpace(payload.Origin) ||
            string.IsNullOrWhiteSpace(payload.Observation))
            throw InvalidToken();
        return new(payload.RecordedAt.Value, new(payload.Origin, payload.Observation));
    }

    private static string Code(string kind)
    {
        bool cursor = kind.StartsWith("cursor:", StringComparison.Ordinal);
        return Codes.TryGetValue(cursor ? kind["cursor:".Length..] : kind, out string? code)
            ? (cursor ? "n" : "") + code
            : throw new InvalidOperationException($"Token kind '{kind}' has no registered code.");
    }

    private static string? KindOf(string code) =>
        code.StartsWith('n') && code.Length > 1
            ? Kinds.TryGetValue(code[1..], out string? cursor) ? "cursor:" + cursor : null
            : Kinds.GetValueOrDefault(code);

    /// <summary>
    /// Keeps ASCII letters, digits and (unless excluded) '-', writes ':' as '.', and every other UTF-8 byte as
    /// '_' plus two hex digits. The result is reversible and safe in URL paths and query strings.
    /// </summary>
    private static string Escape(string value, bool keepDash = true)
    {
        StringBuilder output = new();
        foreach (byte b in Encoding.UTF8.GetBytes(value))
        {
            char c = (char)b;
            if (char.IsAsciiLetterOrDigit(c) || (keepDash && c == '-')) output.Append(c);
            else if (c == ':') output.Append('.');
            else output.Append('_').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return output.ToString();
    }

    private static string? Unescape(string value)
    {
        List<byte> bytes = [];
        for (int index = 0; index < value.Length; index++)
        {
            char c = value[index];
            if (c == '.') bytes.Add((byte)':');
            else if (c == '_')
            {
                if (index + 2 >= value.Length ||
                    !byte.TryParse(value.AsSpan(index + 1, 2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture,
                        out byte b))
                    return null;
                bytes.Add(b);
                index += 2;
            }
            else if (char.IsAsciiLetterOrDigit(c) || c == '-') bytes.Add((byte)c);
            else return null;
        }
        try
        {
            return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes.ToArray());
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    private static Payload Decode(string value, string kind)
    {
        if (string.IsNullOrEmpty(value)) throw InvalidToken();
        Payload payload = DecodeCompact(value);
        // Only the exact spelling the encoder produces is accepted, so each entity has one compact ID.
        string canonical = payload.Kind switch
        {
            "craft" => Craft(new(payload.Origin!, payload.Observation!)),
            "cursor:craft" => CraftCursor(new(payload.RecordedAt!.Value, new(payload.Origin!, payload.Observation!))),
            _ => Dimension(payload.Kind, new((GameProject)payload.Project!.Value, payload.Track), payload.Key!)
        };
        return payload.Kind == kind && canonical == value ? payload : throw InvalidToken();
    }

    private static Payload DecodeCompact(string value)
    {
        int dash = value.IndexOf('-', StringComparison.Ordinal);
        if (dash <= 0) throw InvalidToken();
        string head = value[..dash], body = value[(dash + 1)..];
        int letters = 0;
        while (letters < head.Length && char.IsAsciiLetterLower(head[letters])) letters++;
        string? kind = KindOf(head[..letters]);
        if (kind is null) throw InvalidToken();
        if (kind is "craft" or "cursor:craft")
        {
            if (letters != head.Length) throw InvalidToken();
            string[] fields = body.Split('*');
            if (kind == "craft")
                return fields.Length == 2 && Unescape(fields[0]) is string origin && Unescape(fields[1]) is string observation
                    ? new(kind, null, null, null, origin, observation, null)
                    : throw InvalidToken();
            if (fields.Length != 4 ||
                !long.TryParse(fields[0], NumberStyles.None, CultureInfo.InvariantCulture, out long ticks) ||
                !int.TryParse(fields[1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out int minutes) ||
                Unescape(fields[2]) is not string cursorOrigin || Unescape(fields[3]) is not string cursorObservation)
                throw InvalidToken();
            try
            {
                TimeSpan offset = TimeSpan.FromMinutes(minutes);
                DateTimeOffset recordedAt = new DateTimeOffset(ticks, TimeSpan.Zero).ToOffset(offset);
                return new(kind, null, null, null, cursorOrigin, cursorObservation, recordedAt);
            }
            catch (ArgumentException)
            {
                throw InvalidToken();
            }
        }
        string rest = head[letters..];
        int dot = rest.IndexOf('.', StringComparison.Ordinal);
        string projectText = dot < 0 ? rest : rest[..dot];
        string? track = dot < 0 ? null : Unescape(rest[(dot + 1)..]);
        if (projectText.Length is 0 or > 9 || !projectText.All(char.IsAsciiDigit) || projectText[0] == '0' ||
            (dot >= 0 && string.IsNullOrEmpty(track)) || Unescape(body) is not string key)
            throw InvalidToken();
        return new(kind, int.Parse(projectText, CultureInfo.InvariantCulture), track, key, null, null, null);
    }

    private static GraphQLException InvalidToken() =>
        new(ErrorBuilder.New().SetMessage("The supplied ID or cursor is invalid.").SetCode("INVALID_ID_OR_CURSOR").Build());
}
