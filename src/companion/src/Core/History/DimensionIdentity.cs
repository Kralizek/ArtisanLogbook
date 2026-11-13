namespace ArtisanLogbook.History;

/// <summary>Canonical identity of an entity scoped to a game context.</summary>
public sealed record DimensionIdentity<T>(GameContext Game, T Key) where T : notnull;

/// <summary>One keyset page of canonical dimensions.</summary>
public sealed record DimensionPage<T, TKey>(
    IReadOnlyList<T> Items,
    bool HasNextPage,
    DimensionIdentity<TKey>? EndPosition) where TKey : notnull;

/// <summary>Supported recipe collection criteria. Search is a case-insensitive literal substring.</summary>
public sealed record RecipeQuery(
    GameContext? Game = null,
    int? ProfessionId = null,
    string? ExpansionKey = null,
    string? Search = null);

/// <summary>Supported item collection criteria. Search is a case-insensitive literal substring.</summary>
public sealed record ItemQuery(GameContext? Game = null, string? Search = null);

/// <summary>Supported profession collection criteria.</summary>
public sealed record ProfessionQuery(GameContext? Game = null, int? ParentId = null);

/// <summary>One keyset page of canonical game contexts.</summary>
public sealed record GameContextPage(IReadOnlyList<GameContext> Items, bool HasNextPage, GameContext? EndPosition);
