namespace ArtisanLogbook.History;

public sealed record HistoryConflict(CraftIdentity Identity, string Field, string Description);

public sealed record HistoryMergeResult(
    IReadOnlyList<CraftObservation> Observations,
    IReadOnlyList<HistoryConflict> Conflicts)
{
    public bool IsSuccessful => Conflicts.Count == 0;
}

/// <summary>
/// Merges canonical craft observations. Unknown measurements can be enriched
/// by known values; contradictory known values remain unresolved conflicts.
/// Incoming collection order never determines a winner.
/// </summary>
public static class HistoryReconciler
{
    public static HistoryMergeResult Merge(
        IEnumerable<CraftObservation> left,
        IEnumerable<CraftObservation> right)
    {
        ArgumentNullException.ThrowIfNull(left);
        ArgumentNullException.ThrowIfNull(right);

        List<HistoryConflict> conflicts = [];
        Dictionary<CraftIdentity, CraftObservation> merged = [];
        foreach (CraftObservation craft in left.Concat(right))
        {
            ArgumentNullException.ThrowIfNull(craft);
            ArgumentNullException.ThrowIfNull(craft.Identity);

            if (merged.TryGetValue(craft.Identity, out CraftObservation? existing))
                merged[craft.Identity] = Combine(existing, craft, conflicts);
            else
                merged.Add(craft.Identity, craft);
        }

        return new(
            merged.Values.OrderBy(c => c.Identity.Origin, StringComparer.Ordinal)
                .ThenBy(c => c.Identity.Observation, StringComparer.Ordinal).ToArray(),
            conflicts.OrderBy(c => c.Identity.Origin, StringComparer.Ordinal)
                .ThenBy(c => c.Identity.Observation, StringComparer.Ordinal)
                .ThenBy(c => c.Field, StringComparer.Ordinal).ToArray());
    }

    private static CraftObservation Combine(
        CraftObservation a, CraftObservation b, List<HistoryConflict> errors)
    {
        CraftIdentity id = a.Identity;
        T? Field<T>(string name, T? x, T? y) where T : struct
        {
            if (x.HasValue && y.HasValue && !EqualityComparer<T>.Default.Equals(x.Value, y.Value))
                errors.Add(new(id, name, "Conflicting known measurements; no revision authority supplied."));
            return x ?? y;
        }

        T Reference<T>(string name, T x, T y) where T : class
        {
            if (!EqualityComparer<T>.Default.Equals(x, y))
                errors.Add(new(id, name, "Conflicting identity or source context."));
            return x;
        }

        IReadOnlyList<T>? Collection<T>(
            string name, IReadOnlyList<T>? x, IReadOnlyList<T>? y, Func<T, string> key)
        {
            if (x is null) return y;
            if (y is null) return x;
            string[] left = x.Select(key).OrderBy(v => v, StringComparer.Ordinal).ToArray();
            string[] right = y.Select(key).OrderBy(v => v, StringComparer.Ordinal).ToArray();
            if (!left.SequenceEqual(right))
                errors.Add(new(id, name, "Conflicting observed collection; incomplete collections cannot be silently combined."));
            return x;
        }

        if (a.RecordedAt != b.RecordedAt)
            errors.Add(new(id, nameof(a.RecordedAt), "Conflicting craft timestamps."));

        return a with
        {
            RecipeId = Field(nameof(a.RecipeId), a.RecipeId, b.RecipeId),
            Character = Reference(nameof(a.Character), a.Character, b.Character),
            ProfessionId = Field(nameof(a.ProfessionId), a.ProfessionId, b.ProfessionId),
            ExpansionId = Field(nameof(a.ExpansionId), a.ExpansionId, b.ExpansionId),
            ConcentrationSpent = Field(nameof(a.ConcentrationSpent), a.ConcentrationSpent, b.ConcentrationSpent),
            ConcentrationRefunded = Field(nameof(a.ConcentrationRefunded), a.ConcentrationRefunded, b.ConcentrationRefunded),
            HasIngenuityProc = Field(nameof(a.HasIngenuityProc), a.HasIngenuityProc, b.HasIngenuityProc),
            HasResourcefulnessProc = Field(nameof(a.HasResourcefulnessProc), a.HasResourcefulnessProc, b.HasResourcefulnessProc),
            MulticraftBonus = Field(nameof(a.MulticraftBonus), a.MulticraftBonus, b.MulticraftBonus),
            Reagents = Collection(nameof(a.Reagents), a.Reagents, b.Reagents,
                r => $"{r.ItemId}:{r.AllocatedQuantity?.ToString() ?? "?"}:{r.ReturnedQuantity?.ToString() ?? "?"}"),
            Outputs = Collection(nameof(a.Outputs), a.Outputs, b.Outputs,
                o => $"{o.ItemId}:{o.Quality?.ToString() ?? "?"}:{o.Quantity}"),
            Provenance = a.Provenance ?? b.Provenance
        };
    }
}
