using System.Data.Common;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

using ArtisanLogbook.History;

using Dapper;

namespace ArtisanLogbook.HistoryStore;

public sealed partial class HistoryStore
{
    public const int MaximumAnalysisRows = 100;

    public CraftAnalysis Analyze(AnalysisQuery query, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(query);
        ValidateAnalysis(query.Crafts);
        if (!Enum.IsDefined(query.Granularity) || query.ReturnItemId is <= 0 ||
            (query.ReturnItemId is not null && query.Crafts.Game!.Project != GameProject.Retail))
            throw new ArgumentOutOfRangeException(nameof(query));
        return ReadSnapshot((transaction, token) => Analyze(query, transaction, token), cancellationToken);
    }

    public string AnalysisSignature(CraftQuery query, CancellationToken cancellationToken = default)
    {
        ValidateAnalysis(query);
        return ReadSnapshot((transaction, token) => Signature(query, Selection(query), transaction, token), cancellationToken);
    }

    private static void ValidateAnalysis(CraftQuery query)
    {
        ArgumentNullException.ThrowIfNull(query);
        if (query.Game is null || query.Identity is not null || query.RecipeId is <= 0 ||
            query.ProfessionId is <= 0 || query.InputItemId is <= 0 || query.OutputItemId is <= 0 ||
            query.ReturnedItemId is <= 0 || query.ItemId is <= 0 ||
            query.BuffSpellId is <= 0 || query.FinishingItemId is <= 0 ||
            query.AbsentBuffSpellId is <= 0 || query.AbsentFinishingItemId is <= 0 || query.AbsentInputItemId is <= 0 ||
            (query.ProfessionExpansionKey is not null && string.IsNullOrWhiteSpace(query.ProfessionExpansionKey)) ||
            (query.GameExpansionGroupKey is not null &&
                GameExpansionGroups.MemberKeys(query.Game, query.GameExpansionGroupKey) is null) ||
            (query.ConfigurationSignature is not null && !IsSignature(query.ConfigurationSignature)) ||
            query.From > query.To)
            throw new ArgumentException("Analysis requires one game context and valid criteria.", nameof(query));
    }

    private static bool IsSignature(string value) =>
        value.Length == 64 && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static (string Sql, DynamicParameters Parameters) Selection(CraftQuery query)
    {
        StringBuilder sql = new("""
            WITH selected AS (
                SELECT c.*
                FROM Craft c
                WHERE c.ContextKey = $ContextKey
            """);
        DynamicParameters parameters = new();
        parameters.Add("ContextKey", ContextKey(query.Game!));
        Add(query.Character?.Key, "c.CharacterKey", "CharacterKey");
        Add(query.RecipeId, "c.RecipeId", "RecipeId");
        Add(query.ProfessionId, "c.ProfessionId", "ProfessionId");
        Add(query.ProfessionExpansionKey, "c.ProfessionExpansionKey", "ExpansionKey");
        AppendGameExpansionGroupFilter(sql, parameters, query.Game!, query.GameExpansionGroupKey);
        Exists(query.InputItemId, "CraftReagent", "TRUE", "InputItemId");
        AppendAbsentInputSelection(query, sql, parameters);
        Exists(query.OutputItemId, "CraftOutput", "o.ItemId IS NOT NULL", "OutputItemId");
        Exists(query.ReturnedItemId, "CraftReagent", "TRY_CAST(r.ReturnedQuantity AS DOUBLE) > 0", "ReturnedItemId");
        if (query.ItemId is int itemId)
        {
            sql.Append("""
                 AND (EXISTS (SELECT 1 FROM CraftOutput o WHERE o.CraftKey = c.CraftKey AND o.ItemId = $ItemId)
                     OR EXISTS (SELECT 1 FROM CraftReagent r WHERE r.CraftKey = c.CraftKey AND r.ItemId = $ItemId))
                """);
            parameters.Add("ItemId", itemId);
        }
        AppendConfigurationSelection(query, sql, parameters);
        if (query.From is DateTimeOffset from)
        {
            sql.Append("""
                 AND (CAST(c.RecordedAt AS TIMESTAMPTZ) > CAST($From AS TIMESTAMPTZ)
                     OR (CAST(c.RecordedAt AS TIMESTAMPTZ) = CAST($From AS TIMESTAMPTZ)
                         AND SUBSTRING(c.RecordedAt, 27, 1) >= SUBSTRING($From, 27, 1)))
                """);
            parameters.Add("From", Timestamp(from));
        }

        if (query.To is DateTimeOffset to)
        {
            sql.Append("""
                 AND (CAST(c.RecordedAt AS TIMESTAMPTZ) < CAST($To AS TIMESTAMPTZ)
                     OR (CAST(c.RecordedAt AS TIMESTAMPTZ) = CAST($To AS TIMESTAMPTZ)
                         AND SUBSTRING(c.RecordedAt, 27, 1) <= SUBSTRING($To, 27, 1)))
                """);
            parameters.Add("To", Timestamp(to));
        }
        sql.Append("\n)");
        return (sql.ToString(), parameters);

        void Add<T>(T? value, string column, string name)
        {
            if (value is null) return;
            sql.Append($" AND {column} = ${name}");
            parameters.Add(name, value);
        }

        void Exists(int? id, string table, string condition, string name)
        {
            if (id is null) return;
            string alias = table == "CraftOutput" ? "o" : "r";
            sql.Append($" AND EXISTS (SELECT 1 FROM {table} {alias} WHERE {alias}.CraftKey = c.CraftKey AND {alias}.ItemId = ${name} AND ({condition}))");
            parameters.Add(name, id);
        }
    }

    private static void AppendAbsentInputSelection(CraftQuery query, StringBuilder sql, DynamicParameters parameters)
    {
        if (query.AbsentInputItemId is not int itemId) return;
        sql.Append("""
             AND c.InputsComplete = TRUE
             AND NOT EXISTS (SELECT 1 FROM CraftReagent r WHERE r.CraftKey = c.CraftKey
                 AND r.ItemId = $AbsentInputItemId AND (r.AllocatedQuantity IS NULL OR r.AllocatedQuantity <> 0))
            """);
        parameters.Add("AbsentInputItemId", itemId);
    }

    private static void AppendConfigurationSelection(CraftQuery query, StringBuilder sql, DynamicParameters parameters)
    {
        if (query.ConfigurationSignature is null && query.BuffSpellId is null && query.FinishingItemId is null &&
            query.AbsentBuffSpellId is null && query.AbsentFinishingItemId is null)
            return;
        sql.Append("""
             AND EXISTS (SELECT 1 FROM json_each(c.ConfigurationEvidenceJson) e
                 WHERE json_extract_string(e.value, '$.payload') IS NOT NULL
            """);
        if (query.ConfigurationSignature is string signature)
        {
            sql.Append(" AND sha256(json_extract_string(e.value, '$.payload')) = $ConfigurationSignature");
            parameters.Add("ConfigurationSignature", signature);
        }
        const string buffList = """(?:\["buffs"\]|buffs)\s*=\s*\{(?:\s*\[\d+\]\s*=\s*\{[^{}]*\}\s*,?)*\}""";
        const string finishingList = """(?:\["finishingReagents"\]|finishingReagents)\s*=\s*\{(?:\s*\[\d+\]\s*=\s*\{[^{}]*\}\s*,?)*\}""";
        if (query.BuffSpellId is not null || query.AbsentBuffSpellId is not null)
        {
            parameters.Add("BuffListPattern", buffList);
            if (query.BuffSpellId is int present)
            {
                sql.Append("""
                     AND regexp_matches(regexp_extract(json_extract_string(e.value, '$.payload'),
                         $BuffListPattern, 0), $BuffSpellPattern)
                    """);
                parameters.Add("BuffSpellPattern", $"""(?:\["spellID"\]|spellID)\s*=\s*{present}(?:[^0-9]|$)""");
            }
            if (query.AbsentBuffSpellId is int absent)
            {
                sql.Append("""
                     AND regexp_matches(json_extract_string(e.value, '$.payload'), $BuffCoveragePattern)
                     AND regexp_matches(json_extract_string(e.value, '$.payload'), $BuffListPattern)
                     AND regexp_matches(regexp_extract(json_extract_string(e.value, '$.payload'),
                         $BuffListPattern, 0), $BuffValidListPattern)
                     AND NOT regexp_matches(regexp_extract(json_extract_string(e.value, '$.payload'),
                         $BuffListPattern, 0), $AbsentBuffPattern)
                    """);
                parameters.Add("BuffCoveragePattern", """(?:\["buffsCoverage"\]|buffsCoverage)\s*=\s*"supported-list" """.TrimEnd());
                const string validBuffEntry =
                    """\[[1-9]\d*\]\s*=\s*\{\s*""" +
                    """(?:(?:\["applications"\]|applications)\s*=\s*\d+(?:\.\d+)?\s*,\s*)?""" +
                    """(?:\["spellID"\]|spellID)\s*=\s*[1-9]\d*""" +
                    """(?:\s*,\s*(?:\["applications"\]|applications)\s*=\s*\d+(?:\.\d+)?)?\s*\}""";
                parameters.Add("BuffValidListPattern",
                    """^(?:\["buffs"\]|buffs)\s*=\s*\{(?:\s*""" + validBuffEntry + """\s*,?)*\s*\}$""");
                parameters.Add("AbsentBuffPattern", $"""(?:\["spellID"\]|spellID)\s*=\s*{absent}(?:[^0-9]|$)""");
            }
        }
        if (query.FinishingItemId is int || query.AbsentFinishingItemId is int)
        {
            parameters.Add("FinishingListPattern", finishingList);
            if (query.FinishingItemId is int present)
            {
                sql.Append("""
                     AND regexp_matches(regexp_extract(json_extract_string(e.value, '$.payload'),
                         $FinishingListPattern, 0), $FinishingItemPattern)
                    """);
                parameters.Add("FinishingItemPattern", $"""(?:\["itemID"\]|itemID)\s*=\s*{present}(?:[^0-9]|$)""");
            }
            if (query.AbsentFinishingItemId is int absent)
            {
                sql.Append("""
                     AND regexp_matches(json_extract_string(e.value, '$.payload'), $FinishingCoveragePattern)
                     AND regexp_matches(json_extract_string(e.value, '$.payload'), $FinishingListPattern)
                     AND regexp_matches(regexp_extract(json_extract_string(e.value, '$.payload'),
                         $FinishingListPattern, 0), $FinishingValidListPattern)
                     AND NOT regexp_matches(regexp_extract(json_extract_string(e.value, '$.payload'),
                         $FinishingListPattern, 0), $AbsentFinishingPattern)
                    """);
                parameters.Add("FinishingCoveragePattern", """(?:\["finishingCoverage"\]|finishingCoverage)\s*=\s*"submitted" """.TrimEnd());
                const string validFinishingEntry =
                    """\[[1-9]\d*\]\s*=\s*\{\s*""" +
                    """(?:(?:\["quantity"\]|quantity)\s*=\s*\d+(?:\.\d+)?\s*,\s*)?""" +
                    """(?:\["itemID"\]|itemID)\s*=\s*[1-9]\d*""" +
                    """(?:\s*,\s*(?:\["quantity"\]|quantity)\s*=\s*\d+(?:\.\d+)?)?\s*\}""";
                parameters.Add("FinishingValidListPattern",
                    """^(?:\["finishingReagents"\]|finishingReagents)\s*=\s*\{(?:\s*""" + validFinishingEntry + """\s*,?)*\s*\}$""");
                parameters.Add("AbsentFinishingPattern", $"""(?:\["itemID"\]|itemID)\s*=\s*{absent}(?:[^0-9]|$)""");
            }
        }
        sql.Append(')');
    }

    private static string Signature(CraftQuery query, (string Sql, DynamicParameters Parameters) selection,
        DbTransaction transaction, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        // Include canonical children and all supplementary evidence. Hash each row before summing:
        // unlike string aggregation this keeps the read bounded independently of history size.
        string state = transaction.Connection!.QuerySingle<string>(selection.Sql + """
            , fingerprints AS (
                SELECT hash(CraftKey, RecordedAt, RecipeId, CharacterKey, ProfessionId, ProfessionExpansionKey,
                    ConcentrationSpent, IngenuityRefund, ConcentrationCurrencyId, HasIngenuityProc,
                    HasResourcefulnessProc, MulticraftBonus, InputsComplete, ResourcefulnessComplete,
                    OutputsComplete, ReagentsObserved, OutputsObserved, ProvenanceJson, OutputEvidenceJson,
                    ConfigurationEvidenceJson, RecipeSchematicEvidenceJson) AS h FROM selected
                UNION ALL
                SELECT hash(r.CraftKey, r.ItemId, r.AllocatedQuantity, r.ReturnedQuantity)
                    FROM CraftReagent r JOIN selected c USING (CraftKey)
                UNION ALL
                SELECT hash(o.CraftKey, o.ItemId, o.Quality, o.Quantity)
                    FROM CraftOutput o JOIN selected c USING (CraftKey)
                UNION ALL
                SELECT hash('recipe', d.RecipeId, d.Name, d.ProfessionId, d.ProfessionExpansionKey, d.MaxQuality)
                    FROM Recipe d JOIN (SELECT DISTINCT ContextKey, RecipeId FROM selected
                        WHERE RecipeId IS NOT NULL) s USING (ContextKey, RecipeId)
                UNION ALL
                SELECT hash('character', d.IdentityKey, d.Name, d.ClassFile)
                    FROM Character d JOIN (SELECT DISTINCT ContextKey, CharacterKey AS IdentityKey
                        FROM selected) s USING (ContextKey, IdentityKey)
                UNION ALL
                SELECT hash('profession', d.ProfessionId, d.Name, d.ParentId)
                    FROM Profession d JOIN (SELECT DISTINCT ContextKey, ProfessionId FROM selected
                        WHERE ProfessionId IS NOT NULL) s USING (ContextKey, ProfessionId)
                UNION ALL
                SELECT hash('expansion', d.ExpansionKey, d.Name)
                    FROM Expansion d JOIN (SELECT DISTINCT ContextKey,
                        ProfessionExpansionKey AS ExpansionKey FROM selected
                        WHERE ProfessionExpansionKey IS NOT NULL) s USING (ContextKey, ExpansionKey)
                UNION ALL
                SELECT hash('item', d.ItemId, d.Name)
                    FROM Item d JOIN (SELECT DISTINCT ContextKey, ItemId FROM (
                        SELECT c.ContextKey, r.ItemId FROM CraftReagent r JOIN selected c USING (CraftKey)
                        UNION
                        SELECT c.ContextKey, o.ItemId FROM CraftOutput o JOIN selected c USING (CraftKey)
                    )) s USING (ContextKey, ItemId)
            )
            SELECT CAST(COUNT(*) AS VARCHAR) || ':' ||
                CAST(COALESCE(SUM(CAST(h AS DECIMAL(38,0))), 0) AS VARCHAR)
            FROM fingerprints
            """, selection.Parameters, transaction);
        token.ThrowIfCancellationRequested();
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
            JsonSerializer.Serialize(query) + "|" + state))).ToLowerInvariant();
    }

    private CraftAnalysis Analyze(AnalysisQuery query, DbTransaction transaction, CancellationToken token)
    {
        const string outputTotals = """
            , output_totals AS (
                SELECT o.CraftKey, SUM(CAST(o.Quantity AS HUGEINT)) Quantity,
                    COUNT(o.Quantity) Measured, COUNT(*) RowCount
                FROM CraftOutput o JOIN selected c USING (CraftKey) GROUP BY o.CraftKey
            )
            """;
        const string metricsColumns = """
            CAST(COUNT(*) FILTER (WHERE c.OutputsComplete = TRUE AND c.OutputsObserved AND
                (t.RowCount IS NULL OR t.Measured = t.RowCount)) AS VARCHAR) ProductionMeasured,
            CAST(COUNT(*) FILTER (WHERE c.OutputsComplete IS DISTINCT FROM TRUE OR
                NOT c.OutputsObserved OR t.Measured IS DISTINCT FROM t.RowCount) AS VARCHAR) ProductionIncomplete,
            CAST(SUM(CASE WHEN c.OutputsComplete = TRUE AND c.OutputsObserved AND t.RowCount IS NULL
                THEN 0 ELSE t.Quantity END) AS VARCHAR) ProductionQuantity,
            CAST(COUNT(*) FILTER (WHERE c.HasIngenuityProc = TRUE OR
                (c.HasIngenuityProc = FALSE AND c.ConcentrationSpent > 0)) AS VARCHAR) IngenuityObserved,
            CAST(COUNT(*) FILTER (WHERE c.ConcentrationSpent = 0 AND
                c.HasIngenuityProc IS DISTINCT FROM TRUE) AS VARCHAR) IngenuityIneligible,
            CAST(COUNT(*) FILTER (WHERE c.HasIngenuityProc) AS VARCHAR) IngenuityPositive,
            CAST(COUNT(c.HasResourcefulnessProc) AS VARCHAR) ResourcefulnessObserved,
            CAST(COUNT(*) FILTER (WHERE c.HasResourcefulnessProc) AS VARCHAR) ResourcefulnessPositive,
            CAST(COUNT(c.MulticraftBonus) AS VARCHAR) MulticraftObserved,
            CAST(COUNT(*) FILTER (WHERE c.MulticraftBonus > 0) AS VARCHAR) MulticraftPositive,
            CAST(SUM(CAST(c.MulticraftBonus AS HUGEINT)) AS VARCHAR) MulticraftTotal,
            CAST(COUNT(c.ConcentrationSpent) AS VARCHAR) ConcentrationObserved,
            CAST(COUNT(*) FILTER (WHERE c.ConcentrationSpent > 0) AS VARCHAR) ConcentrationPositive,
            CAST(SUM(CAST(c.ConcentrationSpent AS HUGEINT)) AS VARCHAR) ConcentrationTotal,
            CAST(COUNT(*) FILTER (WHERE (c.HasIngenuityProc = FALSE AND c.ConcentrationSpent > 0) OR
                (c.HasIngenuityProc = TRUE AND c.IngenuityRefund IS NOT NULL)) AS VARCHAR) RefundObserved,
            CAST(COUNT(*) FILTER (WHERE c.HasIngenuityProc = TRUE AND c.IngenuityRefund > 0) AS VARCHAR) RefundPositive,
            CAST(SUM(CASE WHEN c.HasIngenuityProc = FALSE AND c.ConcentrationSpent > 0 THEN CAST(0 AS HUGEINT)
                WHEN c.HasIngenuityProc = TRUE THEN CAST(c.IngenuityRefund AS HUGEINT) END) AS VARCHAR) RefundTotal
            """;
        (string sql, DynamicParameters args) = Selection(query.Crafts);
        (string Sql, DynamicParameters Parameters) selection = (sql, args);
        string signature = Signature(query.Crafts, selection, transaction, token);
        OnReadCheckpoint("AnalysisSignature", transaction, token);
        MeasureRow totals = One<MeasureRow>("""
            SELECT CAST(COUNT(*) AS VARCHAR) Attempts, CAST(COUNT(*) AS VARCHAR) MeasuredAttempts,
                '0' IncompleteAttempts, NULL Quantity FROM selected
            """);
        MetricsRow population = One<MetricsRow>($"""
            {outputTotals}
            SELECT CAST(COUNT(*) AS VARCHAR) Attempts, {metricsColumns}
            FROM selected c LEFT JOIN output_totals t USING (CraftKey)
            """);
        EvidenceCoverageRow coverage = One<EvidenceCoverageRow>("""
            SELECT
                CAST(COUNT(*) FILTER (WHERE ConfigurationEvidenceJson IS NOT NULL AND
                    json_array_length(ConfigurationEvidenceJson) > 0) AS VARCHAR) RecordedAttempts,
                CAST(COUNT(*) FILTER (WHERE ConfigurationEvidenceJson IS NOT NULL AND
                    json_array_length(ConfigurationEvidenceJson) = 0) AS VARCHAR) EmptyAttempts,
                CAST(COUNT(*) FILTER (WHERE ConfigurationEvidenceJson IS NULL) AS VARCHAR) UnknownAttempts
            FROM selected
            """);
        string bucket = query.Granularity switch
        {
            AnalysisGranularity.Week => "week",
            AnalysisGranularity.Month => "month",
            _ => "day"
        };
        args.Add("Granularity", bucket);
        AnalysisCollection<AnalysisBucket> timeline = Page<BucketRow, AnalysisBucket>("""
            SELECT CAST(date_trunc($Granularity, CAST(RecordedAt AS TIMESTAMPTZ)) AS VARCHAR) BucketStart,
                CAST(COUNT(*) AS VARCHAR) Attempts, CAST(COUNT(*) AS VARCHAR) MeasuredAttempts,
                '0' IncompleteAttempts, NULL Quantity
            FROM selected GROUP BY 1 ORDER BY 1 DESC LIMIT $Limit
            """, row => new(row.BucketStart, row.Measure()));
        AnalysisCollection<RecipeAnalysis> recipes = Page<RecipeRow, RecipeAnalysis>($"""
            {outputTotals}
            SELECT c.RecipeId, MAX(d.Name) "Name",
                CAST(COUNT(*) AS VARCHAR) Attempts,
                {metricsColumns}
            FROM selected c LEFT JOIN output_totals t USING (CraftKey)
            LEFT JOIN Recipe d ON d.ContextKey = c.ContextKey AND d.RecipeId = c.RecipeId
            WHERE c.RecipeId IS NOT NULL
            GROUP BY c.RecipeId ORDER BY COUNT(*) DESC, c.RecipeId LIMIT $Limit
            """, r => new(r.RecipeId, r.Name, r.Metrics().Production,
                r.Metrics().Ingenuity, r.Metrics().Resourcefulness, r.Metrics().Multicraft,
                r.Metrics().Concentration, r.Metrics().Refund));
        AnalysisCollection<AnalysisContribution> outputs = Contributions("CraftOutput", "o.Quantity", true);
        AnalysisCollection<AnalysisContribution> inputs = Contributions("CraftReagent", "o.AllocatedQuantity", false);
        AnalysisCollection<AnalysisContribution> returns = query.Crafts.Game!.Project == GameProject.Retail
            ? ReturnContributions()
            : new([], false);
        int? finishingItemId = query.Crafts.FinishingItemId ?? query.Crafts.AbsentFinishingItemId;
        int? resourceItemId = finishingItemId ?? query.Crafts.AbsentInputItemId ?? query.Crafts.InputItemId;
        args.Add("AnalysisResourceItemId", resourceItemId);
        args.Add("AnalysisReturnItemId", query.ReturnItemId);
        string returnColumns = query.ReturnItemId is null ? """
            '0' ReturnMeasured, '0' ReturnIncomplete, NULL ReturnWhole, NULL ReturnFraction,
            """ : """
            CAST(COUNT(*) FILTER (WHERE c.ResourcefulnessComplete = TRUE AND c.ReagentsObserved
                AND (r.ItemId IS NULL OR r.ReturnedQuantity IS NOT NULL)) AS VARCHAR) ReturnMeasured,
            CAST(COUNT(*) FILTER (WHERE c.ResourcefulnessComplete IS DISTINCT FROM TRUE OR NOT c.ReagentsObserved
                OR (r.ItemId IS NOT NULL AND r.ReturnedQuantity IS NULL)) AS VARCHAR) ReturnIncomplete,
            SUM(CASE WHEN c.ResourcefulnessComplete = TRUE AND c.ReagentsObserved
                AND (r.ItemId IS NULL OR r.ReturnedQuantity IS NOT NULL)
                THEN CAST(split_part(COALESCE(r.ReturnedQuantity, '0'), '.', 1) AS HUGEINT) END) ReturnWhole,
            SUM(CASE WHEN c.ResourcefulnessComplete = TRUE AND c.ReagentsObserved
                AND (r.ItemId IS NULL OR r.ReturnedQuantity IS NOT NULL)
                THEN CAST(rpad(split_part(COALESCE(r.ReturnedQuantity, '0'), '.', 2), 28, '0') AS HUGEINT) END) ReturnFraction,
            """;
        string returnJoin = query.ReturnItemId is null ? "" :
            "LEFT JOIN CraftReagent r ON r.CraftKey = c.CraftKey AND r.ItemId = $AnalysisReturnItemId";
        AnalysisCollection<AnalysisContribution> characters = Page<MetricsRow, AnalysisContribution>($"""
            {outputTotals}
            , character_metrics AS (
            SELECT c.CharacterKey "Key", MAX(d.Name) "Name", CAST(COUNT(*) AS VARCHAR) Attempts,
                CAST(COUNT(*) FILTER (WHERE c.InputsComplete = TRUE AND (f.ItemId IS NULL OR f.AllocatedQuantity IS NOT NULL)) AS VARCHAR) ResourceMeasured,
                CAST(COUNT(*) FILTER (WHERE c.InputsComplete IS DISTINCT FROM TRUE OR (f.ItemId IS NOT NULL AND f.AllocatedQuantity IS NULL)) AS VARCHAR) ResourceIncomplete,
                CAST(SUM(CASE WHEN f.ItemId IS NULL AND c.InputsComplete = TRUE THEN 0
                    ELSE CAST(f.AllocatedQuantity AS HUGEINT) END) AS VARCHAR) ResourceQuantity,
                {returnColumns}
                {metricsColumns}
            FROM selected c LEFT JOIN output_totals t USING (CraftKey)
            LEFT JOIN CraftReagent f ON f.CraftKey = c.CraftKey AND f.ItemId = $AnalysisResourceItemId
            {returnJoin}
            LEFT JOIN Character d ON d.ContextKey = c.ContextKey AND d.IdentityKey = c.CharacterKey
            GROUP BY c.CharacterKey
            )
            SELECT *, CASE WHEN ReturnWhole IS NULL THEN NULL ELSE
                CAST(ReturnWhole + ReturnFraction // 10000000000000000000000000000 AS VARCHAR) || '.' ||
                lpad(CAST(ReturnFraction % 10000000000000000000000000000 AS VARCHAR), 28, '0')
                END ReturnQuantity
            FROM character_metrics ORDER BY CAST(Attempts AS HUGEINT) DESC, "Key" LIMIT $Limit
            """, r => new(r.Key!, new(r.Attempts, r.Attempts, "0", null), r.Name, Metrics: r.Metrics(),
                FinishingAllocation: finishingItemId is null ? null :
                    new(r.Attempts, r.ResourceMeasured, r.ResourceIncomplete, r.ResourceQuantity),
                ResourceAllocation: resourceItemId is null ? null :
                    new(r.Attempts, r.ResourceMeasured, r.ResourceIncomplete, r.ResourceQuantity),
                ReturnedItem: query.ReturnItemId is null ? null :
                    new(r.Attempts, r.ReturnMeasured, r.ReturnIncomplete, r.ReturnQuantity)));
        AnalysisCollection<AnalysisContribution> qualities = Page<ContributionRow, AnalysisContribution>("""
            SELECT CAST(o.Quality AS VARCHAR) "Key", CAST(o.Quality AS INTEGER) Quality,
                CAST(COUNT(DISTINCT c.CraftKey) AS VARCHAR) Attempts,
                CAST(COUNT(DISTINCT c.CraftKey) FILTER (WHERE o.Quantity IS NOT NULL) AS VARCHAR) MeasuredAttempts,
                CAST(COUNT(DISTINCT c.CraftKey) FILTER (WHERE o.Quantity IS NULL OR c.OutputsComplete IS DISTINCT FROM TRUE) AS VARCHAR) IncompleteAttempts,
                CAST(SUM(CAST(o.Quantity AS HUGEINT)) AS VARCHAR) Quantity
            FROM selected c JOIN CraftOutput o USING (CraftKey)
            GROUP BY o.Quality ORDER BY o.Quality NULLS LAST LIMIT $Limit
            """, r => new(r.Key ?? "unknown", r.Measure(), Quality: r.Quality));
        AnalysisCollection<ConfigurationAnalysis> configurations = Page<ConfigurationRow, ConfigurationAnalysis>($"""
            , evidence AS (
                SELECT DISTINCT c.CraftKey, sha256(json_extract_string(e.value, '$.payload')) Signature,
                    json_extract_string(e.value, '$.payload') Payload
                FROM selected c, json_each(c.ConfigurationEvidenceJson) e
                WHERE json_extract_string(e.value, '$.payload') IS NOT NULL
            )
            {outputTotals}
            SELECT e.Signature, MIN(CASE WHEN length(e.Payload) <= 65536 THEN e.Payload ELSE '' END) Payload,
                CAST(COUNT(*) AS VARCHAR) Attempts,
                {metricsColumns}
            FROM evidence e JOIN selected c USING (CraftKey)
            LEFT JOIN output_totals t USING (CraftKey)
            GROUP BY e.Signature
            ORDER BY COUNT(*) DESC, e.Signature LIMIT $Limit
            """, r => new(r.Signature, r.Payload, new(r.Attempts, r.Attempts, "0", null), r.Metrics()));
        AnalysisItemRelations? relations = null;
        if (query.Crafts.ItemId is int relationItem)
        {
            args.Add("RelatedItemId", relationItem);
            relations = new(Relations("CraftOutput", "o.Quantity", true),
                Relations("CraftReagent", "o.AllocatedQuantity", false),
                query.Crafts.Game!.Project == GameProject.Retail ? ReturnRelations() : null);
        }
        return new(signature, totals.Measure(), new(coverage.RecordedAttempts, coverage.EmptyAttempts,
            coverage.UnknownAttempts), timeline, recipes, outputs, inputs, returns,
            characters, qualities, configurations, relations, population.Metrics());

        T One<T>(string statement) => transaction.Connection!.QuerySingle<T>(sql + "\n" + statement, args, transaction);
        AnalysisCollection<TOut> Page<TRow, TOut>(string statement, Func<TRow, TOut> project)
        {
            token.ThrowIfCancellationRequested();
            args.Add("Limit", MaximumAnalysisRows + 1);
            List<TOut> rows = [];
            foreach (TRow row in transaction.Connection!.Query<TRow>(sql + "\n" + statement, args, transaction, buffered: false))
            {
                token.ThrowIfCancellationRequested();
                if (rows.Count < MaximumAnalysisRows) rows.Add(project(row));
                else return new(rows, true);
            }
            return new(rows, false);
        }
        AnalysisCollection<AnalysisContribution> Contributions(string table, string quantity, bool production) =>
            Page<ContributionRow, AnalysisContribution>($"""
            SELECT CAST(o.ItemId AS VARCHAR) "Key", MAX(d.Name) "Name",
                CAST(COUNT(DISTINCT c.CraftKey) AS VARCHAR) Attempts,
                CAST(COUNT(DISTINCT c.CraftKey) FILTER (WHERE {quantity} IS NOT NULL) AS VARCHAR) MeasuredAttempts,
                CAST(COUNT(DISTINCT c.CraftKey) FILTER (WHERE {quantity} IS NULL OR
                    c.{(production ? "OutputsComplete" : "InputsComplete")} IS DISTINCT FROM TRUE) AS VARCHAR) IncompleteAttempts,
                CAST(SUM(CAST({quantity} AS HUGEINT)) AS VARCHAR) Quantity
            FROM selected c JOIN {table} o USING (CraftKey)
            LEFT JOIN Item d ON d.ContextKey = c.ContextKey AND d.ItemId = o.ItemId
            GROUP BY o.ItemId ORDER BY SUM(CAST({quantity} AS HUGEINT)) DESC NULLS LAST, o.ItemId
            LIMIT $Limit
            """, r => new(r.Key!, r.Measure(), r.Name));

        AnalysisCollection<AnalysisContribution> ReturnContributions() =>
            Page<ContributionRow, AnalysisContribution>("""
            , amounts AS (
                SELECT c.CraftKey, c.ContextKey, c.ResourcefulnessComplete, o.ItemId,
                    o.ReturnedQuantity,
                    CAST(split_part(o.ReturnedQuantity, '.', 1) AS HUGEINT) Whole,
                    CAST(rpad(split_part(o.ReturnedQuantity, '.', 2), 28, '0') AS HUGEINT) Fraction
                FROM selected c JOIN CraftReagent o USING (CraftKey)
            ), grouped AS (
                SELECT a.ItemId, MAX(d.Name) "Name",
                    CAST(COUNT(*) AS VARCHAR) Attempts,
                    CAST(COUNT(a.ReturnedQuantity) AS VARCHAR) MeasuredAttempts,
                    CAST(COUNT(*) FILTER (WHERE a.ReturnedQuantity IS NULL OR
                        a.ResourcefulnessComplete IS DISTINCT FROM TRUE) AS VARCHAR) IncompleteAttempts,
                    SUM(a.Whole) Whole, SUM(a.Fraction) Fraction
                FROM amounts a LEFT JOIN Item d ON d.ContextKey = a.ContextKey AND d.ItemId = a.ItemId
                GROUP BY a.ItemId
            ), normalized AS (
                SELECT *, Whole + (Fraction // 10000000000000000000000000000) TotalWhole,
                    Fraction % 10000000000000000000000000000 TotalFraction
                FROM grouped
            )
            SELECT CAST(ItemId AS VARCHAR) "Key", "Name", Attempts, MeasuredAttempts,
                IncompleteAttempts,
                CASE WHEN TotalWhole IS NULL THEN NULL ELSE
                    CAST(TotalWhole AS VARCHAR) || '.' ||
                    lpad(CAST(TotalFraction AS VARCHAR), 28, '0')
                END Quantity
            FROM normalized ORDER BY TotalWhole DESC NULLS LAST, TotalFraction DESC NULLS LAST, ItemId
            LIMIT $Limit
            """, r => new(r.Key!, r.Measure(), r.Name));

        AnalysisCollection<AnalysisItemRelation> Relations(string table, string quantity, bool production) =>
            Page<RelationRow, AnalysisItemRelation>($"""
            SELECT c.RecipeId, MAX(recipe.Name) RecipeName,
                c.CharacterKey, MAX(character.Name) CharacterName,
                CAST(COUNT(DISTINCT c.CraftKey) AS VARCHAR) Attempts,
                CAST(COUNT(DISTINCT c.CraftKey) FILTER (WHERE {quantity} IS NOT NULL) AS VARCHAR) MeasuredAttempts,
                CAST(COUNT(DISTINCT c.CraftKey) FILTER (WHERE {quantity} IS NULL OR
                    c.{(production ? "OutputsComplete" : "InputsComplete")} IS DISTINCT FROM TRUE) AS VARCHAR) IncompleteAttempts,
                CAST(SUM(CAST({quantity} AS HUGEINT)) AS VARCHAR) Quantity
            FROM selected c JOIN {table} o USING (CraftKey)
            LEFT JOIN Recipe recipe ON recipe.ContextKey = c.ContextKey AND recipe.RecipeId = c.RecipeId
            LEFT JOIN Character character ON character.ContextKey = c.ContextKey AND character.IdentityKey = c.CharacterKey
            WHERE o.ItemId = $RelatedItemId
            GROUP BY c.RecipeId, c.CharacterKey
            ORDER BY SUM(CAST({quantity} AS HUGEINT)) DESC NULLS LAST,
                c.RecipeId NULLS LAST, c.CharacterKey LIMIT $Limit
            """, r => new(r.RecipeId, r.RecipeName, r.CharacterKey, r.CharacterName, r.Measure()));

        AnalysisCollection<AnalysisItemRelation> ReturnRelations() =>
            Page<RelationRow, AnalysisItemRelation>("""
            , amounts AS (
                SELECT c.CraftKey, c.ContextKey, c.RecipeId, c.CharacterKey, c.ResourcefulnessComplete,
                    o.ReturnedQuantity,
                    CAST(split_part(o.ReturnedQuantity, '.', 1) AS HUGEINT) Whole,
                    CAST(rpad(split_part(o.ReturnedQuantity, '.', 2), 28, '0') AS HUGEINT) Fraction
                FROM selected c JOIN CraftReagent o USING (CraftKey) WHERE o.ItemId = $RelatedItemId
            ), grouped AS (
                SELECT a.RecipeId, MAX(recipe.Name) RecipeName, a.CharacterKey,
                    MAX(character.Name) CharacterName,
                    CAST(COUNT(*) AS VARCHAR) Attempts,
                    CAST(COUNT(a.ReturnedQuantity) AS VARCHAR) MeasuredAttempts,
                    CAST(COUNT(*) FILTER (WHERE a.ReturnedQuantity IS NULL OR
                        a.ResourcefulnessComplete IS DISTINCT FROM TRUE) AS VARCHAR) IncompleteAttempts,
                    SUM(a.Whole) Whole, SUM(a.Fraction) Fraction
                FROM amounts a
                LEFT JOIN Recipe recipe ON recipe.ContextKey = a.ContextKey AND recipe.RecipeId = a.RecipeId
                LEFT JOIN Character character ON character.ContextKey = a.ContextKey AND character.IdentityKey = a.CharacterKey
                GROUP BY a.RecipeId, a.CharacterKey
            ), normalized AS (
                SELECT *, Whole + (Fraction // 10000000000000000000000000000) TotalWhole,
                    Fraction % 10000000000000000000000000000 TotalFraction
                FROM grouped
            )
            SELECT RecipeId, RecipeName, CharacterKey, CharacterName,
                Attempts, MeasuredAttempts, IncompleteAttempts,
                CASE WHEN TotalWhole IS NULL THEN NULL ELSE
                    CAST(TotalWhole AS VARCHAR) || '.' ||
                    lpad(CAST(TotalFraction AS VARCHAR), 28, '0')
                END Quantity
            FROM normalized ORDER BY TotalWhole DESC NULLS LAST, TotalFraction DESC NULLS LAST,
                RecipeId NULLS LAST, CharacterKey LIMIT $Limit
            """, r => new(r.RecipeId, r.RecipeName, r.CharacterKey, r.CharacterName, r.Measure()));
    }

    private static AnalysisOutcome Outcome(string observed, string positive, string? total, string attempts,
        string ineligible = "0") =>
        new(observed, positive, total,
            (long.Parse(attempts, CultureInfo.InvariantCulture) - long.Parse(observed, CultureInfo.InvariantCulture) -
                long.Parse(ineligible, CultureInfo.InvariantCulture)).ToString(CultureInfo.InvariantCulture),
            ineligible);

    private class MeasureRow
    {
        public string Attempts { get; set; } = "0";
        public string MeasuredAttempts { get; set; } = "0";
        public string IncompleteAttempts { get; set; } = "0";
        public string? Quantity { get; set; }
        public AnalysisMeasure Measure() => new(Attempts, MeasuredAttempts, IncompleteAttempts, Quantity);
    }
    private sealed class EvidenceCoverageRow
    {
        public string RecordedAttempts { get; set; } = "0";
        public string EmptyAttempts { get; set; } = "0";
        public string UnknownAttempts { get; set; } = "0";
    }
    private sealed class BucketRow : MeasureRow { public string BucketStart { get; set; } = ""; }
    private sealed class ContributionRow : MeasureRow
    {
        public string? Key { get; set; }
        public string? Name { get; set; }
        public int? Quality { get; set; }
    }
    private sealed class RelationRow : MeasureRow
    {
        public int? RecipeId { get; set; }
        public string? RecipeName { get; set; }
        public string CharacterKey { get; set; } = "";
        public string? CharacterName { get; set; }
    }
    private class MetricsRow : MeasureRow
    {
        public string Key { get; set; } = "";
        public string? Name { get; set; }
        public string ProductionMeasured { get; set; } = "0";
        public string ProductionIncomplete { get; set; } = "0";
        public string? ProductionQuantity { get; set; }
        public string IngenuityObserved { get; set; } = "0";
        public string IngenuityPositive { get; set; } = "0";
        public string IngenuityIneligible { get; set; } = "0";
        public string ResourcefulnessObserved { get; set; } = "0";
        public string ResourcefulnessPositive { get; set; } = "0";
        public string MulticraftObserved { get; set; } = "0";
        public string MulticraftPositive { get; set; } = "0";
        public string? MulticraftTotal { get; set; }
        public string ConcentrationObserved { get; set; } = "0";
        public string ConcentrationPositive { get; set; } = "0";
        public string? ConcentrationTotal { get; set; }
        public string RefundObserved { get; set; } = "0";
        public string RefundPositive { get; set; } = "0";
        public string? RefundTotal { get; set; }
        public string ResourceMeasured { get; set; } = "0";
        public string ResourceIncomplete { get; set; } = "0";
        public string? ResourceQuantity { get; set; }
        public string ReturnMeasured { get; set; } = "0";
        public string ReturnIncomplete { get; set; } = "0";
        public string? ReturnQuantity { get; set; }

        public AnalysisPopulationMetrics Metrics() => new(
            new(Attempts, ProductionMeasured, ProductionIncomplete, ProductionQuantity),
            Outcome(IngenuityObserved, IngenuityPositive, null, Attempts, IngenuityIneligible),
            Outcome(ResourcefulnessObserved, ResourcefulnessPositive, null, Attempts),
            Outcome(MulticraftObserved, MulticraftPositive, MulticraftTotal, Attempts),
            Outcome(ConcentrationObserved, ConcentrationPositive, ConcentrationTotal, Attempts),
            Outcome(RefundObserved, RefundPositive, RefundTotal, Attempts, IngenuityIneligible));
    }

    private sealed class ConfigurationRow : MetricsRow
    {
        public string Signature { get; set; } = "";
        public string Payload { get; set; } = "";
    }
    private sealed class RecipeRow : MetricsRow
    {
        public int RecipeId { get; set; }
    }
}
