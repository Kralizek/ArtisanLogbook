using System.Globalization;
using System.Text;
using System.Text.Json;

using ArtisanLogbook.History;

using HotChocolate;

namespace ArtisanLogbook.Runtime.GraphQL;

internal static class HistoryTokens
{
    private sealed record Payload(int Version, string Kind, int? Project, string? Track, string? Key,
        string? Origin, string? Observation, DateTimeOffset? RecordedAt);

    public static string Craft(CraftIdentity identity) =>
        Encode(new(1, "craft", null, null, null, identity.Origin, identity.Observation, null));

    public static CraftIdentity ParseCraft(string value)
    {
        Payload payload = Decode(value, "craft");
        if (string.IsNullOrWhiteSpace(payload.Origin) || string.IsNullOrWhiteSpace(payload.Observation))
            throw InvalidToken();
        return new(payload.Origin, payload.Observation);
    }

    public static string Dimension(string kind, GameContext game, string key) =>
        Encode(new(1, kind, (int)game.Project, game.ProgressionTrack, key, null, null, null));

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

    public static string CraftCursor(CraftPagePosition position) =>
        Encode(new(1, "cursor:craft", null, null, null, position.Identity.Origin, position.Identity.Observation, position.RecordedAt));

    public static CraftPagePosition ParseCraftCursor(string value)
    {
        Payload payload = Decode(value, "cursor:craft");
        if (payload.RecordedAt is null || string.IsNullOrWhiteSpace(payload.Origin) ||
            string.IsNullOrWhiteSpace(payload.Observation))
            throw InvalidToken();
        return new(payload.RecordedAt.Value, new(payload.Origin, payload.Observation));
    }

    private static string Encode(Payload payload) =>
        Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload))).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static Payload Decode(string value, string kind)
    {
        if (string.IsNullOrEmpty(value) || value.Length > 4096) throw InvalidToken();
        try
        {
            string encoded = value.Replace('-', '+').Replace('_', '/');
            encoded = encoded.PadRight((encoded.Length + 3) / 4 * 4, '=');
            Payload? payload = JsonSerializer.Deserialize<Payload>(Convert.FromBase64String(encoded));
            if (payload is null || payload.Version != 1 || payload.Kind != kind)
                throw InvalidToken();
            return payload;
        }
        catch (FormatException)
        {
            throw InvalidToken();
        }
        catch (JsonException)
        {
            throw InvalidToken();
        }
    }

    private static GraphQLException InvalidToken() =>
        new(ErrorBuilder.New().SetMessage("The supplied ID or cursor is invalid.").SetCode("INVALID_ID_OR_CURSOR").Build());
}
