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
    /// <summary>Committed outcomes keyed by canonical observation identity, never source-local ID.</summary>
    public IReadOnlyList<CraftWriteResult> Observations { get; init; } = [];
    public string? SourceFingerprint { get; init; }
}
