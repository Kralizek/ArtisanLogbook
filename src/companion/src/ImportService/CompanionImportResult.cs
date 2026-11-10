using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;
using ArtisanLogbook.SavedVariables;

namespace ArtisanLogbook.ImportService;

public enum CompanionImportOutcome
{
    Successful,
    Rejected,
    Failed
}

public sealed record CompanionImportDiagnostic(string Code, string Message);

public sealed record CompanionImportResult(
    CompanionImportOutcome Outcome,
    int TotalSourceCraftObservations,
    int InsertedCrafts,
    int AlreadyPresentCrafts,
    int EnrichedCrafts,
    int RejectedOrConflictingCrafts,
    int DimensionsInserted,
    int DimensionsEnriched,
    SavedVariablesCoverage? Coverage,
    IReadOnlyList<SavedVariablesDiagnostic> SourceDiagnostics,
    IReadOnlyList<SavedVariablesDiagnostic> CoverageWarnings,
    IReadOnlyList<HistoryValidationError> ValidationErrors,
    IReadOnlyList<HistoryConflict> CraftConflicts,
    IReadOnlyList<DimensionConflict> DimensionConflicts,
    IReadOnlyList<CompanionImportDiagnostic> InputDiagnostics,
    IReadOnlyList<CompanionImportDiagnostic> PersistenceDiagnostics)
{
    /// <summary>SHA-256 of the exact file bytes read by C07; null for in-memory imports or failed reads.</summary>
    public string? SourceFingerprint { get; init; }

    /// <summary>Committed outcomes keyed by canonical observation identity, never source-local ID.</summary>
    public IReadOnlyList<CraftWriteResult> Observations { get; init; } = [];
}
