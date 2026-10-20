namespace ArtisanLogbook.History;

/// <summary>A single completed craft attempt. Null measurements mean unobserved, not zero.</summary>
public sealed record CraftObservation(
    CraftIdentity Identity,
    GameContext Game,
    DateTimeOffset RecordedAt,
    int? RecipeId,
    CharacterIdentity Character,
    int? ProfessionId = null,
    string? ProfessionExpansionKey = null,
    int? ConcentrationSpent = null,
    int? IngenuityRefund = null,
    int? ConcentrationCurrencyId = null,
    bool? HasIngenuityProc = null,
    bool? HasResourcefulnessProc = null,
    int? MulticraftBonus = null,
    IReadOnlyList<CraftReagent>? Reagents = null,
    IReadOnlyList<CraftOutput>? Outputs = null,
    CraftProvenance? Provenance = null,
    bool? InputsComplete = null,
    bool? ResourcefulnessComplete = null)
{
    // Craft output/reagent collections have value semantics, not array reference semantics.
    // Their row order is not significant: the canonical grains are keyed by item and quality.
    public bool Equals(CraftObservation? other)
    {
        if (other is null) return false;
        if (ReferenceEquals(this, other)) return true;
        return Identity == other.Identity
            && RecordedAt == other.RecordedAt
            && RecipeId == other.RecipeId
            && Character == other.Character
            && ProfessionId == other.ProfessionId
            && ProfessionExpansionKey == other.ProfessionExpansionKey
            && ConcentrationSpent == other.ConcentrationSpent
            && IngenuityRefund == other.IngenuityRefund
            && ConcentrationCurrencyId == other.ConcentrationCurrencyId
            && HasIngenuityProc == other.HasIngenuityProc
            && HasResourcefulnessProc == other.HasResourcefulnessProc
            && MulticraftBonus == other.MulticraftBonus
            && InputsComplete == other.InputsComplete
            && ResourcefulnessComplete == other.ResourcefulnessComplete
            && Game == other.Game
            && Provenance == other.Provenance
            && EqualCollections(Reagents, other.Reagents, r => (r.ItemId, r.AllocatedQuantity, r.ReturnedQuantity))
            && EqualCollections(Outputs, other.Outputs, o => (o.ItemId, o.Quality, o.Quantity));
    }

    public override int GetHashCode()
    {
        HashCode hash = new();
        hash.Add(Identity);
        hash.Add(Game);
        hash.Add(RecordedAt);
        hash.Add(RecipeId);
        hash.Add(Character);
        hash.Add(ProfessionId);
        hash.Add(ProfessionExpansionKey);
        hash.Add(ConcentrationSpent);
        hash.Add(IngenuityRefund);
        hash.Add(ConcentrationCurrencyId);
        hash.Add(HasIngenuityProc);
        hash.Add(HasResourcefulnessProc);
        hash.Add(MulticraftBonus);
        hash.Add(InputsComplete);
        hash.Add(ResourcefulnessComplete);
        hash.Add(Provenance);
        AddCollectionHash(ref hash, Reagents, r => (r.ItemId, r.AllocatedQuantity, r.ReturnedQuantity));
        AddCollectionHash(ref hash, Outputs, o => (o.ItemId, o.Quality, o.Quantity));
        return hash.ToHashCode();
    }

    private static bool EqualCollections<T, TKey>(
        IReadOnlyList<T>? first, IReadOnlyList<T>? second, Func<T, TKey> key)
        where TKey : IComparable<TKey>
    {
        if (first is null || second is null) return first is null && second is null;
        return first.Select(key).Order().SequenceEqual(second.Select(key).Order());
    }

    private static void AddCollectionHash<T, TKey>(
        ref HashCode hash, IReadOnlyList<T>? items, Func<T, TKey> key)
        where TKey : IComparable<TKey>
    {
        hash.Add(items is not null);
        if (items is null) return;
        foreach (TKey item in items.Select(key).Order())
            hash.Add(item);
    }
}

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
public sealed record CraftProvenance(
    string SourceId,
    long? LocalCraftId = null,
    long? GameOperationId = null,
    long? LocalRequestId = null,
    string? SourceSessionId = null,
    string? ResourcefulnessEvidence = null);

/// <summary>Craft × reagent item grain. Allocated and returned quantities are independently nullable.</summary>
public sealed record CraftReagent(int ItemId, long? AllocatedQuantity, decimal? ReturnedQuantity);

/// <summary>Craft × output item × quality grain. Quality may be unavailable.</summary>
public sealed record CraftOutput(int ItemId, int? Quality, long Quantity);
