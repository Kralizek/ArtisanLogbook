using System.Globalization;
using System.Security.Cryptography;
using System.Text;

using ArtisanLogbook.History;
using ArtisanLogbook.SavedVariables;

using HotChocolate;
using HotChocolate.CostAnalysis.Types;
using HotChocolate.Types;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.Runtime.GraphQL;

[GraphQLName("Analysis")]
public sealed class AnalysisGraph(GameContext game, CraftAnalysis value)
{
    public string Signature => value.Signature;
    public AnalysisEvidenceCoverage ConfigurationCoverage => value.ConfigurationCoverage;
    public string InputMeasureLabel => game.Project switch
    {
        GameProject.Retail => "Gross allocated inputs",
        GameProject.Forever => "Attributed schematic requirements",
        _ => "Recorded inputs"
    };
    public bool SupportsReturns => game.Project == GameProject.Retail;
    public AnalysisMeasure Attempts => value.Attempts;
    [Cost(100)]
    public AnalysisTimeline GetTimeline() => new(value.Timeline);
    [Cost(100)]
    public AnalysisRecipes GetRecipes() => new(game, value.Recipes);
    [Cost(100)]
    public AnalysisContributions GetOutputs() => new(game, "item", value.Outputs);
    [Cost(100)]
    public AnalysisContributions GetInputs() => new(game, "item", value.Inputs);
    public AnalysisContributions? GetReturns() => SupportsReturns
        ? new(game, "item", value.Returns) : null;
    [Cost(100)]
    public AnalysisContributions GetCharacters() => new(game, "character", value.Characters);
    [Cost(100)]
    public AnalysisContributions GetQualities() => new(game, "quality", value.Qualities);
    [Cost(100)]
    public AnalysisConfigurations GetConfigurations() => new(game, value.Configurations);
    [Cost(100)]
    public AnalysisItemRelationsGraph? GetItemRelations() => value.ItemRelations is null
        ? null : new(game, value.ItemRelations);
}

public sealed class AnalysisItemRelationsGraph(GameContext game, AnalysisItemRelations value)
{
    public AnalysisRelations Outputs => new(game, value.Outputs);
    public AnalysisRelations Inputs => new(game, value.Inputs);
    public AnalysisRelations? Returns => game.Project == GameProject.Retail && value.Returns is { } returns
        ? new(game, returns) : null;
}

public sealed class AnalysisRelations(GameContext game, AnalysisCollection<AnalysisItemRelation> value)
{
    [ListSize(AssumedSize = 100)]
    public IReadOnlyList<AnalysisRelationGraph> Nodes =>
        value.Nodes.Select(row => new AnalysisRelationGraph(game, row)).ToArray();
    public bool Truncated => value.Truncated;
}

public sealed class AnalysisRelationGraph(GameContext game, AnalysisItemRelation value)
{
    [GraphQLType(typeof(IdType))]
    public string? RecipeId => value.RecipeId is int id
        ? HistoryTokens.Dimension("recipe", game, id.ToString(CultureInfo.InvariantCulture)) : null;
    public string? RecipeName => value.RecipeName;
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string CharacterId => HistoryTokens.Dimension("character", game, value.CharacterKey);
    public string? CharacterName => value.CharacterName;
    public AnalysisMeasure Measure => value.Measure;
}

public sealed class AnalysisTimeline(AnalysisCollection<AnalysisBucket> value)
{
    [ListSize(AssumedSize = 100)]
    public IReadOnlyList<AnalysisBucket> Nodes => value.Nodes;
    public bool Truncated => value.Truncated;
}

public sealed class AnalysisRecipes(GameContext game, AnalysisCollection<RecipeAnalysis> value)
{
    [ListSize(AssumedSize = 100)]
    public IReadOnlyList<RecipeAnalysisGraph> Nodes => value.Nodes.Select(row => new RecipeAnalysisGraph(game, row)).ToArray();
    public bool Truncated => value.Truncated;
}

public sealed class RecipeAnalysisGraph(GameContext game, RecipeAnalysis value)
{
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string Id => HistoryTokens.Dimension("recipe", game, value.RecipeId.ToString(CultureInfo.InvariantCulture));
    public string? Name => value.Name;
    public AnalysisMeasure Outputs => value.Outputs;
    public AnalysisOutcome? Ingenuity => game.Project == GameProject.Retail ? value.Ingenuity : null;
    public AnalysisOutcome? Resourcefulness => game.Project == GameProject.Retail ? value.Resourcefulness : null;
    public AnalysisOutcome? Multicraft => game.Project == GameProject.Retail ? value.Multicraft : null;
    public AnalysisOutcome? Concentration => game.Project == GameProject.Retail ? value.Concentration : null;
    public AnalysisOutcome? Refund => game.Project == GameProject.Retail ? value.Refund : null;
}

public sealed class AnalysisContributions(GameContext game, string kind, AnalysisCollection<AnalysisContribution> value)
{
    [ListSize(AssumedSize = 100)]
    public IReadOnlyList<AnalysisContributionGraph> Nodes => value.Nodes.Select(row => new AnalysisContributionGraph(game, kind, row)).ToArray();
    public bool Truncated => value.Truncated;
}

public sealed class AnalysisContributionGraph(GameContext game, string kind, AnalysisContribution value)
{
    [GraphQLType(typeof(IdType))]
    public string? Id => kind == "quality" ? null : HistoryTokens.Dimension(kind, game, value.Key);
    public string? Name => value.Name;
    public int? Quality => value.Quality;
    public AnalysisMeasure Measure => value.Measure;
    public AnalysisPopulationMetricsGraph? GetMetrics() =>
        value.Metrics is null ? null : new(game, value.Metrics);
}

public sealed class AnalysisConfigurations(GameContext game, AnalysisCollection<ConfigurationAnalysis> value)
{
    [ListSize(AssumedSize = 100)]
    public IReadOnlyList<AnalysisConfigurationGraph> Nodes =>
        value.Nodes.Select(row => new AnalysisConfigurationGraph(game, row)).ToArray();
    public bool Truncated => value.Truncated;
}

public sealed class AnalysisConfigurationGraph(GameContext game, ConfigurationAnalysis value)
{
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string Id => HistoryTokens.Dimension("configuration", game, value.Signature);
    public AnalysisMeasure Measure => value.Measure;
    public AnalysisPopulationMetricsGraph Metrics => new(game, value.Metrics);
    public bool EvidenceAvailable => value.Payload.Length is > 0 and <= 65536;
    public RecordedConfiguration Evidence => RecordedConfiguration.FromPayload(value.Payload);
}

public sealed class RecordedCraftConfigurations(GameContext game, IReadOnlyList<string> payloads, bool observed)
{
    public bool Observed => observed;
    [ListSize(AssumedSize = 100)]
    public IReadOnlyList<RecordedCraftConfiguration> Nodes => payloads.Take(Store.MaximumAnalysisRows)
        .Select(payload => new RecordedCraftConfiguration(game, payload)).ToArray();
    public bool Truncated => payloads.Count > Store.MaximumAnalysisRows;
}

public sealed class RecordedCraftConfiguration(GameContext game, string payload)
{
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string Id => HistoryTokens.Dimension("configuration", game,
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(payload))).ToLowerInvariant());
    public bool EvidenceAvailable => payload.Length <= 65536;
    public RecordedConfiguration Evidence => EvidenceAvailable
        ? RecordedConfiguration.FromPayload(payload) : new();
}

public sealed class AnalysisPopulationMetricsGraph(GameContext game, AnalysisPopulationMetrics value)
{
    public AnalysisMeasure Production => value.Production;
    public AnalysisOutcome? Ingenuity => game.Project == GameProject.Retail ? value.Ingenuity : null;
    public AnalysisOutcome? Resourcefulness => game.Project == GameProject.Retail ? value.Resourcefulness : null;
    public AnalysisOutcome? Multicraft => game.Project == GameProject.Retail ? value.Multicraft : null;
    public AnalysisOutcome? Concentration => game.Project == GameProject.Retail ? value.Concentration : null;
    public AnalysisOutcome? Refund => game.Project == GameProject.Retail ? value.Refund : null;
}

/// <summary>Supported, recorded evidence only; unrecorded selections remain null.</summary>
public sealed class RecordedConfiguration
{
    public string? Scope { get; init; }
    public string? StatsCoverage { get; init; }
    public string? EquipmentCoverage { get; init; }
    public string? BuffsCoverage { get; init; }
    public string? FinishingCoverage { get; init; }
    public bool? UseConcentration { get; init; }
    public IReadOnlyList<RecordedStatistic>? Statistics { get; init; }
    public IReadOnlyList<RecordedEquipment>? Equipment { get; init; }
    public IReadOnlyList<RecordedBuff>? Buffs { get; init; }
    public IReadOnlyList<RecordedFinishingReagent>? FinishingReagents { get; init; }
    public bool EquipmentTruncated { get; init; }
    public bool BuffsTruncated { get; init; }
    public bool FinishingReagentsTruncated { get; init; }

    public static RecordedConfiguration FromPayload(string payload)
    {
        try
        {
            if (!LuaDataParser.Parse(payload).Assignments.TryGetValue("CraftConfigurationEvidence", out object? root) ||
                root is not LuaTable snapshot)
                return new();
            LuaTable? conditions = snapshot.Get("conditions") as LuaTable;
            LuaTable? fields = snapshot.Get("craftFields") as LuaTable;
            string? equipmentCoverage = fields?.Get("equipmentCoverage") as string;
            string? buffsCoverage = fields?.Get("buffsCoverage") as string;
            string? finishingCoverage = fields?.Get("finishingCoverage") as string;
            LuaTable? stats = conditions?.Get("stats") as LuaTable;
            IReadOnlyList<LuaTable>? equipment = equipmentCoverage == "observed" ? Rows(conditions?.Get("equipment")) : null;
            IReadOnlyList<LuaTable>? buffs = buffsCoverage == "supported-list" ? Rows(conditions?.Get("buffs")) : null;
            IReadOnlyList<LuaTable>? finishing = finishingCoverage == "submitted" ? Rows(conditions?.Get("finishingReagents")) : null;
            return new()
            {
                Scope = fields?.Get("configurationScope") as string,
                StatsCoverage = fields?.Get("statsCoverage") as string,
                EquipmentCoverage = equipmentCoverage,
                BuffsCoverage = buffsCoverage,
                FinishingCoverage = finishingCoverage,
                UseConcentration = conditions?.Get("useConcentration") as bool?,
                Statistics = fields?.Get("statsCoverage") is "reported" or "partial"
                    ? StatisticsFrom(stats) : null,
                Equipment = equipment is null ? null
                    : equipment.Take(100).Select(x => new RecordedEquipment(
                        Number(x.Get("slot")), Number(x.Get("itemID")), x.Get("empty") as bool?)).ToArray(),
                Buffs = buffs is null ? null
                    : buffs.Take(100).Select(x => new RecordedBuff(
                        Number(x.Get("spellID")), Number(x.Get("applications")))).ToArray(),
                FinishingReagents = finishing is null ? null
                    : finishing.Take(100).Select(x => new RecordedFinishingReagent(
                        Number(x.Get("itemID")), Number(x.Get("quantity")))).ToArray(),
                EquipmentTruncated = equipment?.Count > 100,
                BuffsTruncated = buffs?.Count > 100,
                FinishingReagentsTruncated = finishing?.Count > 100
            };
        }
        catch (FormatException) { return new(); }
        catch (ArgumentException) { return new(); }
    }

    private static IReadOnlyList<LuaTable>? Rows(object? value)
    {
        if (value is not LuaTable table) return null;
        if (table.Any(entry => entry.Key is not double || entry.Value is not LuaTable))
            return null;
        List<LuaTable> rows = new(table.Count);
        double expectedIndex = 1;
        foreach (KeyValuePair<object, object?> entry in table.OrderBy(pair => (double)pair.Key))
        {
            if ((double)entry.Key != expectedIndex)
                return null;
            rows.Add((LuaTable)entry.Value!);
            expectedIndex++;
        }
        return rows;
    }

    private static int? Number(object? value) =>
        value is double number && number >= 0 && number <= int.MaxValue && number == Math.Truncate(number)
            ? (int)number : null;

    private static IReadOnlyList<RecordedStatistic>? StatisticsFrom(LuaTable? stats)
    {
        if (stats is null) return null;
        List<RecordedStatistic> result = [];
        foreach ((string key, string label) in new (string, string)[]
        {
            ("baseSkill", "Base skill"), ("bonusSkill", "Bonus skill"),
            ("baseDifficulty", "Base difficulty"), ("bonusDifficulty", "Bonus difficulty"),
            ("craftingQuality", "Crafting quality"), ("concentrationCost", "Concentration cost"),
            ("lowerSkillThreshold", "Lower skill threshold"), ("upperSkillTreshold", "Upper skill threshold"),
            ("ingenuityRefund", "Ingenuity refund")
        })
            Add(label, stats.Get(key));
        foreach ((string key, string label) in new (string, string)[]
        {
            ("multicraft", "Multicraft"), ("resourcefulness", "Resourcefulness"),
            ("ingenuity", "Ingenuity"), ("craftingSpeed", "Crafting speed")
        })
        {
            if (stats.Get(key) is not LuaTable rating) continue;
            Add(label + " rating", rating.Get("rating"));
            Add(label + " percent", rating.Get("ratingPct"));
            Add(label + " bonus percent", rating.Get("bonusRatingPct"));
        }
        return result;

        void Add(string label, object? value)
        {
            if (value is double number && double.IsFinite(number))
                result.Add(new(label, number.ToString("R", CultureInfo.InvariantCulture)));
        }
    }
}

public sealed record RecordedStatistic(string Label, string Value);
public sealed record RecordedEquipment(int? Slot, int? ItemId, bool? Empty);
public sealed record RecordedBuff(int? SpellId, int? Applications);
public sealed record RecordedFinishingReagent(int? ItemId, int? Quantity);
