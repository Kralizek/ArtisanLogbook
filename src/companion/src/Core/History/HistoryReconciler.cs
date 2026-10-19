namespace ArtisanLogbook.History;

public sealed record HistoryConflict(
    CraftIdentity Identity,
    CraftObservation Existing,
    CraftObservation Incoming);

public sealed record HistoryMergeResult(
    IReadOnlyList<CraftObservation> Observations,
    IReadOnlyList<HistoryConflict> Conflicts)
{
    public bool IsSuccessful => Conflicts.Count == 0;
}

/// <summary>
/// Conservative, deterministic reconciliation of identified craft observations.
/// Conflicting revisions are surfaced and never silently overwritten.
/// </summary>
public static class HistoryReconciler
{
    public static HistoryMergeResult Merge(
        IEnumerable<CraftObservation> left,
        IEnumerable<CraftObservation> right)
    {
        ArgumentNullException.ThrowIfNull(left);
        ArgumentNullException.ThrowIfNull(right);

        Dictionary<CraftIdentity, CraftObservation> known = new();
        List<HistoryConflict> conflicts = new();

        foreach (CraftObservation observation in left.Concat(right))
        {
            ArgumentNullException.ThrowIfNull(observation);
            ArgumentNullException.ThrowIfNull(observation.Identity);

            if (known.TryGetValue(observation.Identity, out CraftObservation? existing))
            {
                if (existing != observation)
                {
                    conflicts.Add(new HistoryConflict(observation.Identity, existing, observation));
                }
            }
            else
            {
                known.Add(observation.Identity, observation);
            }
        }

        CraftObservation[] merged = known.Values
            .OrderBy(craft => craft.Identity.Origin, StringComparer.Ordinal)
            .ThenBy(craft => craft.Identity.Observation, StringComparer.Ordinal)
            .ToArray();

        return new HistoryMergeResult(merged, conflicts);
    }
}
