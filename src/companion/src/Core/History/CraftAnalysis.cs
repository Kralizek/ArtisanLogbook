namespace ArtisanLogbook.History;

public enum AnalysisGranularity { Day, Week, Month }

/// <summary>One selected context and independently selected craft population.</summary>
public sealed record AnalysisQuery(CraftQuery Crafts, AnalysisGranularity Granularity = AnalysisGranularity.Day);

/// <summary>Exact decimal values are strings; null means that no measured quantity exists.</summary>
public sealed record AnalysisMeasure(string Attempts, string MeasuredAttempts, string IncompleteAttempts, string? Quantity);

public sealed record AnalysisContribution(string Key, AnalysisMeasure Measure, string? Name = null,
    int? Quality = null, AnalysisPopulationMetrics? Metrics = null);

public sealed record AnalysisBucket(string Start, AnalysisMeasure Measure);

public sealed record AnalysisCollection<T>(IReadOnlyList<T> Nodes, bool Truncated);

public sealed record AnalysisOutcome(
    string ObservedAttempts, string PositiveAttempts, string? Total,
    string UnknownAttempts);

public sealed record AnalysisPopulationMetrics(AnalysisMeasure Production,
    AnalysisOutcome Ingenuity, AnalysisOutcome Resourcefulness, AnalysisOutcome Multicraft,
    AnalysisOutcome Concentration, AnalysisOutcome Refund);

public sealed record RecipeAnalysis(int RecipeId, string? Name, AnalysisMeasure Outputs,
    AnalysisOutcome Ingenuity, AnalysisOutcome Resourcefulness, AnalysisOutcome Multicraft,
    AnalysisOutcome Concentration, AnalysisOutcome Refund);

public sealed record ConfigurationAnalysis(string Signature, string Payload, AnalysisMeasure Measure,
    AnalysisPopulationMetrics Metrics);

public sealed record AnalysisItemRelation(int? RecipeId, string? RecipeName,
    string CharacterKey, string? CharacterName, AnalysisMeasure Measure);

public sealed record AnalysisItemRelations(AnalysisCollection<AnalysisItemRelation> Outputs,
    AnalysisCollection<AnalysisItemRelation> Inputs,
    AnalysisCollection<AnalysisItemRelation>? Returns);

public sealed record AnalysisEvidenceCoverage(string RecordedAttempts, string EmptyAttempts, string UnknownAttempts);

public sealed record CraftAnalysis(
    string Signature, AnalysisMeasure Attempts,
    AnalysisEvidenceCoverage ConfigurationCoverage,
    AnalysisCollection<AnalysisBucket> Timeline,
    AnalysisCollection<RecipeAnalysis> Recipes,
    AnalysisCollection<AnalysisContribution> Outputs,
    AnalysisCollection<AnalysisContribution> Inputs,
    AnalysisCollection<AnalysisContribution> Returns,
    AnalysisCollection<AnalysisContribution> Characters,
    AnalysisCollection<AnalysisContribution> Qualities,
    AnalysisCollection<ConfigurationAnalysis> Configurations,
    AnalysisItemRelations? ItemRelations);
