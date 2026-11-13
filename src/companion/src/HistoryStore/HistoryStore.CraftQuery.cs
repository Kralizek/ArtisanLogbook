using System.Data.Common;
using System.Globalization;
using System.Text;

using ArtisanLogbook.History;

using Dapper;

namespace ArtisanLogbook.HistoryStore;

public sealed partial class HistoryStore
{
    public const int MaximumCraftPageSize = 100;

    /// <summary>
    /// Reads a bounded page in one snapshot. Recorder evidence and provenance are intentionally excluded.
    /// Date bounds are inclusive. Dimension criteria must be scoped by game context.
    /// </summary>
    public CraftPage QueryCrafts(CraftQuery query, int first = 20, CraftPagePosition? after = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(query);
        if (first is < 1 or > MaximumCraftPageSize)
            throw new ArgumentOutOfRangeException(nameof(first));
        if (query.Game is null && (query.Character is not null || query.RecipeId is not null ||
            query.ProfessionId is not null || query.ProfessionExpansionKey is not null ||
            query.InputItemId is not null || query.OutputItemId is not null))
            throw new ArgumentException("Dimension criteria require a game context.", nameof(query));
        if (query.RecipeId is <= 0 || query.ProfessionId is <= 0 ||
            query.InputItemId is <= 0 || query.OutputItemId is <= 0 ||
            (query.ProfessionExpansionKey is not null && string.IsNullOrWhiteSpace(query.ProfessionExpansionKey)) ||
            query.From > query.To)
            throw new ArgumentException("Craft query criteria are invalid.", nameof(query));
        if (after is not null && after.Identity is null)
            throw new ArgumentException("The continuation position requires a craft identity.", nameof(after));

        return ReadSnapshot((transaction, token) => QueryCrafts(query, first, after, transaction, token), cancellationToken);
    }

    private CraftPage QueryCrafts(CraftQuery query, int first, CraftPagePosition? after,
        DbTransaction transaction, CancellationToken token)
    {
        // DuckDB TIMESTAMPTZ has microsecond precision, while stored round-trip timestamps have seven
        // fractional digits. The final digit preserves .NET's 100 ns precision after offset conversion.
        const string timeKey = "CAST(c.RecordedAt AS TIMESTAMPTZ)";
        const string tickKey = "SUBSTRING(c.RecordedAt, 27, 1)";
        StringBuilder sql = new("""
            SELECT c.CraftKey, i.IdentityOrigin, i.IdentityObservation,
                g.ProjectId, g.ProgressionTrack, c.RecordedAt, c.RecipeId, c.CharacterKey,
                c.ProfessionId, c.ProfessionExpansionKey, c.ConcentrationSpent, c.IngenuityRefund,
                c.ConcentrationCurrencyId, c.HasIngenuityProc, c.HasResourcefulnessProc, c.MulticraftBonus,
                c.InputsComplete, c.ResourcefulnessComplete, c.OutputsComplete,
                c.ReagentsObserved, c.OutputsObserved
            FROM Craft c
            JOIN CraftIdentity i USING (CraftKey)
            JOIN GameContext g USING (ContextKey)
            WHERE TRUE
            """);
        DynamicParameters parameters = new();
        if (query.Game is not null)
        {
            sql.Append(" AND c.ContextKey = $ContextKey");
            parameters.Add("ContextKey", ContextKey(query.Game));
        }
        if (query.Character is not null)
        {
            sql.Append(" AND c.CharacterKey = $CharacterKey");
            parameters.Add("CharacterKey", query.Character.Key);
        }
        AddFilter(query.RecipeId, " AND c.RecipeId = $RecipeId", "RecipeId");
        AddFilter(query.ProfessionId, " AND c.ProfessionId = $ProfessionId", "ProfessionId");
        AddFilter(query.ProfessionExpansionKey, " AND c.ProfessionExpansionKey = $ExpansionKey", "ExpansionKey");
        AddFilter(query.InputItemId, " AND EXISTS (SELECT 1 FROM CraftReagent r WHERE r.CraftKey = c.CraftKey AND r.ItemId = $InputItemId)", "InputItemId");
        AddFilter(query.OutputItemId, " AND EXISTS (SELECT 1 FROM CraftOutput o WHERE o.CraftKey = c.CraftKey AND o.ItemId = $OutputItemId)", "OutputItemId");
        if (query.Identity is not null)
        {
            sql.Append(" AND i.IdentityOrigin = $IdentityOrigin AND i.IdentityObservation = $IdentityObservation");
            parameters.Add("IdentityOrigin", query.Identity.Origin);
            parameters.Add("IdentityObservation", query.Identity.Observation);
        }
        if (query.From is DateTimeOffset from)
        {
            sql.Append($" AND ({timeKey} > CAST($From AS TIMESTAMPTZ) OR ({timeKey} = CAST($From AS TIMESTAMPTZ) AND {tickKey} >= SUBSTRING($From, 27, 1)))");
            parameters.Add("From", Timestamp(from));
        }
        if (query.To is DateTimeOffset to)
        {
            sql.Append($" AND ({timeKey} < CAST($To AS TIMESTAMPTZ) OR ({timeKey} = CAST($To AS TIMESTAMPTZ) AND {tickKey} <= SUBSTRING($To, 27, 1)))");
            parameters.Add("To", Timestamp(to));
        }
        if (after is not null)
        {
            sql.Append($"""
                 AND ({timeKey} < CAST($After AS TIMESTAMPTZ)
                   OR ({timeKey} = CAST($After AS TIMESTAMPTZ)
                       AND ({tickKey} < SUBSTRING($After, 27, 1)
                         OR ({tickKey} = SUBSTRING($After, 27, 1)
                           AND (i.IdentityOrigin > $Origin OR
                             (i.IdentityOrigin = $Origin AND i.IdentityObservation > $Observation))))))
                """);
            parameters.Add("After", Timestamp(after.RecordedAt));
            parameters.Add("Origin", after.Identity.Origin);
            parameters.Add("Observation", after.Identity.Observation);
        }
        sql.Append($" ORDER BY {timeKey} DESC, {tickKey} DESC, i.IdentityOrigin ASC, i.IdentityObservation ASC LIMIT $Limit");
        parameters.Add("Limit", first + 1);

        List<CanonicalCraftRow> rows = [];
        token.ThrowIfCancellationRequested();
        foreach (CanonicalCraftRow row in transaction.Connection!.Query<CanonicalCraftRow>(
            sql.ToString(), parameters, transaction, buffered: false))
        {
            token.ThrowIfCancellationRequested();
            rows.Add(row);
        }
        bool hasNext = rows.Count > first;
        if (hasNext) rows.RemoveAt(first);
        OnReadCheckpoint("CraftPageHeaders", transaction, token);
        if (rows.Count == 0) return new([], false, null);
        IReadOnlyList<CraftObservation> crafts = MaterializeCanonicalCrafts(rows, transaction, token);
        CraftObservation last = crafts[^1];
        return new(crafts, hasNext, new(last.RecordedAt, last.Identity));

        void AddFilter<T>(T? value, string predicate, string parameter)
        {
            if (value is null) return;
            sql.Append(predicate);
            parameters.Add(parameter, value);
        }
    }

    private static IReadOnlyList<CraftObservation> MaterializeCanonicalCrafts(
        IReadOnlyList<CanonicalCraftRow> rows, DbTransaction transaction, CancellationToken token)
    {
        if (rows.Count == 0) return [];
        long[] keys = rows.Select(row => row.CraftKey).Distinct().ToArray();
        Dictionary<long, List<CraftReagent>> reagents = [];
        foreach ((long CraftKey, int ItemId, long? Allocated, string? Returned) row in
            transaction.Connection!.Query<(long, int, long?, string?)>("""
                SELECT CraftKey, ItemId, AllocatedQuantity, ReturnedQuantity FROM CraftReagent
                WHERE CraftKey IN $keys ORDER BY CraftKey, ItemId
                """, new { keys }, transaction, buffered: false))
        {
            token.ThrowIfCancellationRequested();
            if (!reagents.TryGetValue(row.CraftKey, out List<CraftReagent>? items))
                reagents.Add(row.CraftKey, items = []);
            items.Add(new(row.ItemId, row.Allocated, row.Returned is null
                ? null : decimal.Parse(row.Returned, NumberStyles.Number, CultureInfo.InvariantCulture)));
        }
        Dictionary<long, List<CraftOutput>> outputs = [];
        foreach ((long CraftKey, int ItemId, int? Quality, long? Quantity) row in
            transaction.Connection!.Query<(long, int, int?, long?)>("""
                SELECT CraftKey, ItemId, Quality, Quantity FROM CraftOutput
                WHERE CraftKey IN $keys ORDER BY CraftKey, ItemId, QualityKey
                """, new { keys }, transaction, buffered: false))
        {
            token.ThrowIfCancellationRequested();
            if (!outputs.TryGetValue(row.CraftKey, out List<CraftOutput>? items))
                outputs.Add(row.CraftKey, items = []);
            items.Add(new(row.ItemId, row.Quality, row.Quantity));
        }
        List<CraftObservation> crafts = new(rows.Count);
        foreach (CanonicalCraftRow row in rows)
        {
            token.ThrowIfCancellationRequested();
            reagents.TryGetValue(row.CraftKey, out List<CraftReagent>? reagentRows);
            outputs.TryGetValue(row.CraftKey, out List<CraftOutput>? outputRows);
            if ((!row.ReagentsObserved && reagentRows is not null) || (!row.OutputsObserved && outputRows is not null))
                throw new InvalidDataException("A craft has child rows for an unobserved collection.");
            crafts.Add(new CraftObservation(
                new(row.IdentityOrigin, row.IdentityObservation),
                new((GameProject)row.ProjectId, row.ProgressionTrack),
                DateTimeOffset.ParseExact(row.RecordedAt, "O", CultureInfo.InvariantCulture, DateTimeStyles.None),
                row.RecipeId, new(row.CharacterKey), row.ProfessionId, row.ProfessionExpansionKey,
                row.ConcentrationSpent, row.IngenuityRefund, row.ConcentrationCurrencyId,
                row.HasIngenuityProc, row.HasResourcefulnessProc, row.MulticraftBonus,
                row.ReagentsObserved ? reagentRows ?? [] : null,
                row.OutputsObserved ? outputRows ?? [] : null,
                InputsComplete: row.InputsComplete, ResourcefulnessComplete: row.ResourcefulnessComplete,
                OutputsComplete: row.OutputsComplete));
        }
        return crafts;
    }

    private static string Timestamp(DateTimeOffset value) => value.ToString("O", CultureInfo.InvariantCulture);

    private sealed class CanonicalCraftRow
    {
        public int BatchIndex { get; set; }
        public long CraftKey { get; set; }
        public string IdentityOrigin { get; set; } = null!;
        public string IdentityObservation { get; set; } = null!;
        public int ProjectId { get; set; }
        public string? ProgressionTrack { get; set; }
        public string RecordedAt { get; set; } = null!;
        public int? RecipeId { get; set; }
        public string CharacterKey { get; set; } = null!;
        public int? ProfessionId { get; set; }
        public string? ProfessionExpansionKey { get; set; }
        public int? ConcentrationSpent { get; set; }
        public int? IngenuityRefund { get; set; }
        public int? ConcentrationCurrencyId { get; set; }
        public bool? HasIngenuityProc { get; set; }
        public bool? HasResourcefulnessProc { get; set; }
        public int? MulticraftBonus { get; set; }
        public bool? InputsComplete { get; set; }
        public bool? ResourcefulnessComplete { get; set; }
        public bool? OutputsComplete { get; set; }
        public bool ReagentsObserved { get; set; }
        public bool OutputsObserved { get; set; }
    }
}
