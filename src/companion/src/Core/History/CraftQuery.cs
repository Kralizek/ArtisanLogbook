namespace ArtisanLogbook.History;

/// <summary>Criteria for canonical craft history. Dimension identities require a game context.</summary>
public sealed record CraftQuery(
    GameContext? Game = null,
    CharacterIdentity? Character = null,
    int? RecipeId = null,
    int? ProfessionId = null,
    string? ProfessionExpansionKey = null,
    DateTimeOffset? From = null,
    DateTimeOffset? To = null,
    int? InputItemId = null,
    int? OutputItemId = null,
    CraftIdentity? Identity = null);

/// <summary>A continuation position in descending recorded-time and ascending identity order.</summary>
public sealed record CraftPagePosition(DateTimeOffset RecordedAt, CraftIdentity Identity);

/// <summary>
/// Canonical facts materialized for queries. This projection intentionally excludes recorder evidence and
/// provenance and must not be used as a complete persisted observation.
/// </summary>
public sealed record CraftQueryProjection(CraftObservation Facts);

/// <summary>A bounded page of canonical craft query projections.</summary>
public sealed record CraftPage(
    IReadOnlyList<CraftQueryProjection> Crafts,
    bool HasNextPage,
    CraftPagePosition? EndPosition);

/// <summary>One independently bounded character-history page in a batch.</summary>
public sealed record CharacterCraftPageRequest(
    DimensionIdentity<CharacterIdentity> Character,
    int First = 20,
    CraftPagePosition? After = null);
