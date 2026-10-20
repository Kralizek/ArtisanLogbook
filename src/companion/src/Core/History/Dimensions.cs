namespace ArtisanLogbook.History;

/// <summary>Blizzard item ID, optionally enriched with localized display metadata.</summary>
public sealed record ItemDimension(GameContext Game, int Id, string? Name = null);

/// <summary>Blizzard recipe ID, optionally enriched with localized display metadata.</summary>
public sealed record RecipeDimension(GameContext Game, int Id, string? Name = null, int? ProfessionId = null, string? ProfessionExpansionKey = null, int? MaxQuality = null);

/// <summary>Blizzard skill line ID, including expansion-specific child skill lines.</summary>
public sealed record ProfessionDimension(GameContext Game, int Id, string? Name = null, int? ParentId = null);

/// <summary>Blizzard expansion identifier; never inferred from the crafting timestamp.</summary>
public sealed record ExpansionDimension(GameContext Game, string Key, string? Name = null);

/// <summary>A character's stable identity and optional mutable display metadata.</summary>
public sealed record CharacterDimension(GameContext Game, CharacterIdentity Identity, string? Name = null, string? ClassFile = null);

/// <summary>
/// Canonical, unordered dimension metadata. Local SavedVariables dimension IDs
/// must be resolved to these identities by the importing adapter.
/// </summary>
public sealed record CraftDimensions(
    IReadOnlyList<CharacterDimension> Characters,
    IReadOnlyList<RecipeDimension> Recipes,
    IReadOnlyList<ProfessionDimension> Professions,
    IReadOnlyList<ItemDimension> Items,
    IReadOnlyList<ExpansionDimension> Expansions)
{
    public static CraftDimensions Empty { get; } = new([], [], [], [], []);
}

/// <summary>Craft-level facts and metadata; excludes all addon rollups.</summary>
public sealed record CraftHistory(
    IReadOnlyList<CraftObservation> Crafts,
    CraftDimensions Dimensions)
{
    public static CraftHistory Empty { get; } = new([], CraftDimensions.Empty);
}
