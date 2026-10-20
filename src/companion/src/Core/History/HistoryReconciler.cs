namespace ArtisanLogbook.History;

public sealed record HistoryConflict(CraftIdentity Identity, string Field, string Description);

public sealed record HistoryMergeResult(
    IReadOnlyList<CraftObservation>? Observations,
    IReadOnlyList<HistoryConflict> Conflicts)
{
    /// <summary>Callers MUST NOT persist Observations when conflicts exist.</summary>
    public bool IsSuccessful => Observations is not null && Conflicts.Count == 0;
}

/// <summary>
/// Deterministic, database-independent reconciliation of identified crafts.
/// Missing scalar measurements can be filled from another copy. Explicitly
/// observed values (including false/zero) never yield to contradictory values.
/// </summary>
public static class HistoryReconciler
{
    public static HistoryMergeResult Merge(
        IEnumerable<CraftObservation> left, IEnumerable<CraftObservation> right)
    {
        ArgumentNullException.ThrowIfNull(left);
        ArgumentNullException.ThrowIfNull(right);
        Dictionary<CraftIdentity, CraftObservation> observations = [];
        List<HistoryConflict> conflicts = [];

        foreach (CraftObservation craft in left.Concat(right))
        {
            ArgumentNullException.ThrowIfNull(craft);
            ArgumentNullException.ThrowIfNull(craft.Identity);

            if (observations.TryGetValue(craft.Identity, out CraftObservation? previous))
                observations[craft.Identity] = Combine(previous, craft, conflicts);
            else
                observations.Add(craft.Identity, craft);
        }

        CraftObservation[] resolved = observations.Values.OrderBy(x => x.Identity.Origin, StringComparer.Ordinal)
                .ThenBy(x => x.Identity.Observation, StringComparer.Ordinal).ToArray();
        HistoryConflict[] orderedConflicts = conflicts.OrderBy(x => x.Identity.Origin, StringComparer.Ordinal)
                .ThenBy(x => x.Identity.Observation, StringComparer.Ordinal)
                .ThenBy(x => x.Field, StringComparer.Ordinal).ToArray();
        return new(orderedConflicts.Length == 0 ? resolved : null, orderedConflicts);
    }

    private static CraftObservation Combine(
        CraftObservation a, CraftObservation b, List<HistoryConflict> conflicts)
    {
        CraftIdentity identity = a.Identity;

        T? Optional<T>(string field, T? x, T? y) where T : struct
        {
            if (x.HasValue && y.HasValue && !EqualityComparer<T>.Default.Equals(x.Value, y.Value))
                conflicts.Add(new(identity, field, "Two different known values; correction precedence is unknown."));
            return x ?? y;
        }

        string? OptionalText(string field, string? x, string? y)
        {
            if (x is not null && y is not null && !string.Equals(x, y, StringComparison.Ordinal))
                conflicts.Add(new(identity, field, "Two different known values; correction precedence is unknown."));
            return x ?? y;
        }

        CraftProvenance? MergeProvenance()
        {
            if (a.Provenance is null) return b.Provenance;
            if (b.Provenance is null) return a.Provenance;
            if (!string.Equals(a.Provenance.SourceId, b.Provenance.SourceId, StringComparison.Ordinal))
                conflicts.Add(new(identity, nameof(a.Provenance), "Source identity differs."));
            return a.Provenance with
            {
                LocalCraftId = Optional(nameof(CraftProvenance.LocalCraftId),
                    a.Provenance.LocalCraftId, b.Provenance.LocalCraftId),
                GameOperationId = Optional(nameof(CraftProvenance.GameOperationId),
                    a.Provenance.GameOperationId, b.Provenance.GameOperationId),
                LocalRequestId = Optional(nameof(CraftProvenance.LocalRequestId),
                    a.Provenance.LocalRequestId, b.Provenance.LocalRequestId),
                SourceSessionId = OptionalText(nameof(CraftProvenance.SourceSessionId),
                    a.Provenance.SourceSessionId, b.Provenance.SourceSessionId),
                ResourcefulnessEvidence = OptionalText(nameof(CraftProvenance.ResourcefulnessEvidence),
                    a.Provenance.ResourcefulnessEvidence, b.Provenance.ResourcefulnessEvidence)
            };
        }

        if (a.Game != b.Game)
            conflicts.Add(new(identity, nameof(a.Game), "Game contexts differ for the same craft identity."));
        if (a.ProfessionExpansionKey is not null && b.ProfessionExpansionKey is not null && a.ProfessionExpansionKey != b.ProfessionExpansionKey)
            conflicts.Add(new(identity, nameof(a.ProfessionExpansionKey), "Profession expansion keys disagree."));
        if (a.RecordedAt != b.RecordedAt)
            conflicts.Add(new(identity, nameof(a.RecordedAt), "Timestamp differs for the same craft identity."));
        if (a.Character != b.Character)
            conflicts.Add(new(identity, nameof(a.Character), "Character identity differs for the same craft."));
        IReadOnlyList<CraftReagent>? MergeReagents()
        {
            if (a.Reagents is null) return b.Reagents;
            if (b.Reagents is null) return a.Reagents;
            Dictionary<int, CraftReagent> byItem = [];
            foreach (CraftReagent reagent in a.Reagents)
                if (!byItem.TryAdd(reagent.ItemId, reagent))
                    conflicts.Add(new(identity, nameof(a.Reagents), "Duplicate item in first reagent set."));
            foreach (CraftReagent reagent in b.Reagents)
            {
                if (!byItem.TryGetValue(reagent.ItemId, out CraftReagent? existing))
                {
                    conflicts.Add(new(identity, nameof(a.Reagents), "Returned set adds an item to an already observed collection."));
                    continue;
                }

                byItem[reagent.ItemId] = existing with
                {
                    AllocatedQuantity = Optional($"Reagents[{reagent.ItemId}].AllocatedQuantity",
                        existing.AllocatedQuantity, reagent.AllocatedQuantity),
                    ReturnedQuantity = Optional($"Reagents[{reagent.ItemId}].ReturnedQuantity",
                        existing.ReturnedQuantity, reagent.ReturnedQuantity)
                };
            }
            if (byItem.Count != b.Reagents.Select(x => x.ItemId).Distinct().Count())
                conflicts.Add(new(identity, nameof(a.Reagents), "Observed reagent sets contain different items."));
            return byItem.Values.OrderBy(x => x.ItemId).ToArray();
        }

        IReadOnlyList<CraftOutput>? MergeOutputs()
        {
            if (a.Outputs is null) return b.Outputs;
            if (b.Outputs is null) return a.Outputs;
            static string Key(CraftOutput o) => $"{o.ItemId}:{o.Quality?.ToString() ?? "unknown"}:{o.Quantity}";
            string[] left = a.Outputs.Select(Key).OrderBy(x => x, StringComparer.Ordinal).ToArray();
            string[] right = b.Outputs.Select(Key).OrderBy(x => x, StringComparer.Ordinal).ToArray();
            if (!left.SequenceEqual(right))
                conflicts.Add(new(identity, nameof(a.Outputs), "Two different observed output collections."));
            return a.Outputs.OrderBy(x => x.ItemId).ThenBy(x => x.Quality).ThenBy(x => x.Quantity).ToArray();
        }

        return a with
        {
            RecipeId = Optional(nameof(a.RecipeId), a.RecipeId, b.RecipeId),
            ProfessionId = Optional(nameof(a.ProfessionId), a.ProfessionId, b.ProfessionId),
            ProfessionExpansionKey = a.ProfessionExpansionKey ?? b.ProfessionExpansionKey,
            ConcentrationSpent = Optional(nameof(a.ConcentrationSpent), a.ConcentrationSpent, b.ConcentrationSpent),
            IngenuityRefund = Optional(nameof(a.IngenuityRefund), a.IngenuityRefund, b.IngenuityRefund),
            ConcentrationCurrencyId = Optional(nameof(a.ConcentrationCurrencyId), a.ConcentrationCurrencyId, b.ConcentrationCurrencyId),
            HasIngenuityProc = Optional(nameof(a.HasIngenuityProc), a.HasIngenuityProc, b.HasIngenuityProc),
            HasResourcefulnessProc = Optional(nameof(a.HasResourcefulnessProc), a.HasResourcefulnessProc, b.HasResourcefulnessProc),
            MulticraftBonus = Optional(nameof(a.MulticraftBonus), a.MulticraftBonus, b.MulticraftBonus),
            InputsComplete = Optional(nameof(a.InputsComplete), a.InputsComplete, b.InputsComplete),
            ResourcefulnessComplete = Optional(nameof(a.ResourcefulnessComplete), a.ResourcefulnessComplete, b.ResourcefulnessComplete),
            Reagents = MergeReagents(),
            Outputs = MergeOutputs(),
            Provenance = MergeProvenance()
        };
    }
}
