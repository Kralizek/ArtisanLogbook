using System.Globalization;
using System.Text;

using ArtisanLogbook.History;

using HotChocolate;

namespace ArtisanLogbook.Runtime.GraphQL;

/// <summary>
/// Opaque, URL-friendly IDs and cursors. A dimension token is <c>{kind code}{project}[.{track}]-{key}</c>, for
/// example <c>r1-1230868</c> for a Retail recipe; keys are written with <see cref="Escape"/>, so tokens need no
/// percent-encoding. A craft is <c>k-{short ID}</c> (see <see cref="CraftIdentity.ShortId"/>), and a craft cursor
/// <c>nk-{UTC ticks}*{offset minutes}*{short ID}</c>. Only the exact spelling the encoder produces is accepted.
/// </summary>
internal static class HistoryTokens
{
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

    public static string Craft(CraftIdentity identity) => Code("craft") + "-" + identity.ShortId;

    /// <summary>The craft short ID a craft token names; the caller resolves the craft.</summary>
    public static string ParseCraft(string value)
    {
        string prefix = Code("craft") + "-";
        return value is not null && value.StartsWith(prefix, StringComparison.Ordinal) &&
            CraftShortIds.IsValid(value[prefix.Length..])
            ? value[prefix.Length..]
            : throw InvalidToken();
    }

    public static string Dimension(string kind, GameContext game, string key) =>
        Code(kind) + ((int)game.Project).ToString(CultureInfo.InvariantCulture) +
        (game.ProgressionTrack is null ? "" : "." + Escape(game.ProgressionTrack, keepDash: false)) +
        "-" + Escape(key);

    public static string Context(GameContext game) => Dimension("context", game, "");

    public static (GameContext Game, string Key) ParseDimension(string token, string kind)
    {
        (GameContext game, string key) = DecodeDimension(token, kind);
        if (kind is not ("context" or "cursor:context") && string.IsNullOrWhiteSpace(key))
            throw InvalidToken();
        return (game, key);
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
        CraftCursor(position.RecordedAt, position.Identity.ShortId);

    private static string CraftCursor(DateTimeOffset recordedAt, string shortId) =>
        Code("cursor:craft") + "-" + recordedAt.UtcTicks.ToString(CultureInfo.InvariantCulture) + "*" +
        ((int)recordedAt.Offset.TotalMinutes).ToString(CultureInfo.InvariantCulture) + "*" + shortId;

    /// <summary>The recorded instant and craft short ID of a craft cursor; the caller resolves the craft.</summary>
    public static (DateTimeOffset RecordedAt, string ShortId) ParseCraftCursor(string value)
    {
        string prefix = Code("cursor:craft") + "-";
        string[] fields = value is not null && value.StartsWith(prefix, StringComparison.Ordinal)
            ? value[prefix.Length..].Split('*')
            : [];
        if (fields.Length != 3 ||
            !long.TryParse(fields[0], NumberStyles.None, CultureInfo.InvariantCulture, out long ticks) ||
            !int.TryParse(fields[1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out int minutes) ||
            !CraftShortIds.IsValid(fields[2]))
            throw InvalidToken();
        DateTimeOffset recordedAt;
        try
        {
            recordedAt = new DateTimeOffset(ticks, TimeSpan.Zero).ToOffset(TimeSpan.FromMinutes(minutes));
        }
        catch (ArgumentException)
        {
            throw InvalidToken();
        }
        return CraftCursor(recordedAt, fields[2]) == value ? (recordedAt, fields[2]) : throw InvalidToken();
    }

    public static GraphQLException InvalidCursor() => InvalidToken();

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

    private static (GameContext Game, string Key) DecodeDimension(string value, string kind)
    {
        if (string.IsNullOrEmpty(value)) throw InvalidToken();
        int dash = value.IndexOf('-', StringComparison.Ordinal);
        if (dash <= 0) throw InvalidToken();
        string head = value[..dash], body = value[(dash + 1)..];
        int letters = 0;
        while (letters < head.Length && char.IsAsciiLetterLower(head[letters])) letters++;
        if (KindOf(head[..letters]) != kind) throw InvalidToken();
        string rest = head[letters..];
        int dot = rest.IndexOf('.', StringComparison.Ordinal);
        string projectText = dot < 0 ? rest : rest[..dot];
        string? track = dot < 0 ? null : Unescape(rest[(dot + 1)..]);
        if (projectText.Length is 0 or > 9 || !projectText.All(char.IsAsciiDigit) || projectText[0] == '0' ||
            (dot >= 0 && string.IsNullOrWhiteSpace(track)) || Unescape(body) is not string key)
            throw InvalidToken();
        GameContext game = new((GameProject)int.Parse(projectText, CultureInfo.InvariantCulture), track);
        // Only the exact spelling the encoder produces is accepted, so each entity has one ID.
        return Dimension(kind, game, key) == value ? (game, key) : throw InvalidToken();
    }

    private static GraphQLException InvalidToken() =>
        new(ErrorBuilder.New().SetMessage("The supplied ID or cursor is invalid.").SetCode("INVALID_ID_OR_CURSOR").Build());
}
