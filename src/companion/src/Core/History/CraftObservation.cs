namespace ArtisanLogbook.History;

/// <summary>A single completed craft attempt. Null measurements mean unobserved, not zero.</summary>
public sealed record CraftObservation(
    CraftIdentity Identity,
    DateTimeOffset RecordedAt,
    int? RecipeId,
    CharacterIdentity Character,
    int? ProfessionId = null,
    int? ExpansionId = null,
    int? ConcentrationSpent = null,
    int? ConcentrationRefunded = null,
    bool? HasIngenuityProc = null,
    bool? HasResourcefulnessProc = null,
    int? MulticraftBonus = null,
    IReadOnlyList<CraftReagent>? Reagents = null,
    IReadOnlyList<CraftOutput>? Outputs = null,
    CraftProvenance? Provenance = null);

/// <summary>Stable character identity, not the ledger's local dimension ID.</summary>
public sealed record CharacterIdentity
{
    /// <summary>Blizzard project/region/realm/GUID key; not a local dimension ID or character name.</summary>
    public string Key { get; }

    public CharacterIdentity(string key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        Key = key;
    }
}

/// <summary>Source evidence for an observation. A timestamp or operation ID alone is not a globally unique craft key.</summary>
public sealed record CraftProvenance(string SourceId, long? LocalCraftId = null, long? GameOperationId = null);

/// <summary>Craft × reagent item grain. Allocated and returned quantities are independently nullable.</summary>
public sealed record CraftReagent(int ItemId, long? AllocatedQuantity, long? ReturnedQuantity);

/// <summary>Craft × output item × quality grain. Quality may be unavailable.</summary>
public sealed record CraftOutput(int ItemId, int? Quality, long Quantity);

/// <summary>Optional metadata for a WoW item, recipe or profession; names can be enriched independently.</summary>
public sealed record NamedDimension(int Id, string? Name);
