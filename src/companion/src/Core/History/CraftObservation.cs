namespace ArtisanLogbook.History;

/// <summary>
/// Minimal craft-level observation used to establish identity and merge behavior.
/// Reagents, outputs, outcomes and dimension contracts will be expanded after
/// validating the source ledger's current capture semantics.
/// </summary>
public sealed record CraftObservation(
    CraftIdentity Identity,
    DateTimeOffset RecordedAt,
    int RecipeId,
    int CharacterId);
