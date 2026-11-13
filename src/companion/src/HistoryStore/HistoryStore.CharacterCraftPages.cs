using System.Text;

using ArtisanLogbook.History;

using Dapper;

namespace ArtisanLogbook.HistoryStore;

public sealed partial class HistoryStore
{
    public IReadOnlyDictionary<CharacterCraftPageRequest, CraftPage> QueryCharacterCraftPages(
        IReadOnlyCollection<CharacterCraftPageRequest> requests, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(requests);
        if (requests.Count > 50)
            throw new ArgumentOutOfRangeException(nameof(requests), "A batch may contain at most 50 pages.");
        foreach (CharacterCraftPageRequest request in requests)
        {
            if (request is null || request.Character is null || request.Character.Game is null ||
                request.Character.Key is null || request.First is < 1 or > MaximumCraftPageSize ||
                (request.After is not null && request.After.Identity is null))
                throw new ArgumentException("The character page request is invalid.", nameof(requests));
        }

        return ReadSnapshot((transaction, token) =>
        {
            CharacterCraftPageRequest[] distinct = requests.Distinct().ToArray();
            if (distinct.Length == 0) return new Dictionary<CharacterCraftPageRequest, CraftPage>();
            StringBuilder values = new();
            DynamicParameters parameters = new();
            for (int i = 0; i < distinct.Length; i++)
            {
                if (i > 0) values.Append(", ");
                values.Append($"($Index{i}, $Context{i}, $Character{i}, $First{i}, CAST($After{i} AS VARCHAR), CAST($Origin{i} AS VARCHAR), CAST($Observation{i} AS VARCHAR))");
                CharacterCraftPageRequest request = distinct[i];
                parameters.Add($"Index{i}", i);
                parameters.Add($"Context{i}", ContextKey(request.Character.Game));
                parameters.Add($"Character{i}", request.Character.Key.Key);
                parameters.Add($"First{i}", request.First);
                parameters.Add($"After{i}", request.After is null ? null : Timestamp(request.After.RecordedAt));
                parameters.Add($"Origin{i}", request.After?.Identity.Origin);
                parameters.Add($"Observation{i}", request.After?.Identity.Observation);
            }
            List<CanonicalCraftRow> rows = [];
            foreach (CanonicalCraftRow row in transaction.Connection!.Query<CanonicalCraftRow>($"""
                WITH requested(BatchIndex, ContextKey, CharacterKey, PageSize, AfterTime, AfterOrigin, AfterObservation) AS
                    (VALUES {values}),
                ranked AS (
                    SELECT r.BatchIndex, r.PageSize, c.CraftKey, i.IdentityOrigin, i.IdentityObservation,
                        g.ProjectId, g.ProgressionTrack, c.RecordedAt, c.RecipeId, c.CharacterKey,
                        c.ProfessionId, c.ProfessionExpansionKey, c.ConcentrationSpent, c.IngenuityRefund,
                        c.ConcentrationCurrencyId, c.HasIngenuityProc, c.HasResourcefulnessProc, c.MulticraftBonus,
                        c.InputsComplete, c.ResourcefulnessComplete, c.OutputsComplete,
                        c.ReagentsObserved, c.OutputsObserved,
                        ROW_NUMBER() OVER (PARTITION BY r.BatchIndex
                            ORDER BY CAST(c.RecordedAt AS TIMESTAMPTZ) DESC, SUBSTRING(c.RecordedAt, 27, 1) DESC,
                                i.IdentityOrigin, i.IdentityObservation) AS RowNumber
                    FROM requested r
                    JOIN Craft c ON c.ContextKey = r.ContextKey AND c.CharacterKey = r.CharacterKey
                    JOIN CraftIdentity i USING (CraftKey)
                    JOIN GameContext g ON g.ContextKey = c.ContextKey
                    WHERE r.AfterTime IS NULL
                        OR CAST(c.RecordedAt AS TIMESTAMPTZ) < CAST(r.AfterTime AS TIMESTAMPTZ)
                        OR (CAST(c.RecordedAt AS TIMESTAMPTZ) = CAST(r.AfterTime AS TIMESTAMPTZ)
                            AND (SUBSTRING(c.RecordedAt, 27, 1) < SUBSTRING(r.AfterTime, 27, 1)
                                OR (SUBSTRING(c.RecordedAt, 27, 1) = SUBSTRING(r.AfterTime, 27, 1)
                                    AND (i.IdentityOrigin > r.AfterOrigin OR
                                        (i.IdentityOrigin = r.AfterOrigin AND i.IdentityObservation > r.AfterObservation)))))
                )
                SELECT * FROM ranked WHERE RowNumber <= PageSize + 1 ORDER BY BatchIndex, RowNumber
                """, parameters, transaction, buffered: false))
            {
                token.ThrowIfCancellationRequested();
                rows.Add(row);
            }
            OnReadCheckpoint("CharacterCraftPageHeaders", transaction, token);
            Dictionary<int, List<CanonicalCraftRow>> selected = [];
            bool[] hasNext = new bool[distinct.Length];
            foreach (CanonicalCraftRow row in rows)
            {
                if (!selected.TryGetValue(row.BatchIndex, out List<CanonicalCraftRow>? pageRows))
                    selected.Add(row.BatchIndex, pageRows = []);
                if (pageRows.Count < distinct[row.BatchIndex].First) pageRows.Add(row);
                else hasNext[row.BatchIndex] = true;
            }
            CanonicalCraftRow[] materializationRows = selected.OrderBy(x => x.Key).SelectMany(x => x.Value).ToArray();
            IReadOnlyList<CraftQueryProjection> observations = MaterializeCraftProjections(materializationRows, transaction, token);
            Dictionary<CharacterCraftPageRequest, CraftPage> pages = [];
            int offset = 0;
            for (int i = 0; i < distinct.Length; i++)
            {
                token.ThrowIfCancellationRequested();
                int count = selected.TryGetValue(i, out List<CanonicalCraftRow>? pageRows) ? pageRows.Count : 0;
                CraftQueryProjection[] crafts = observations.Skip(offset).Take(count).ToArray();
                offset += count;
                CraftObservation? last = crafts.LastOrDefault()?.Facts;
                pages.Add(distinct[i], new(crafts, hasNext[i],
                    last is null ? null : new(last.RecordedAt, last.Identity)));
            }
            return (IReadOnlyDictionary<CharacterCraftPageRequest, CraftPage>)pages;
        }, cancellationToken);
    }
}
