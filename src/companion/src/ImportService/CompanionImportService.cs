using System.Data.Common;

using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;
using ArtisanLogbook.SavedVariables;

using HistoryStoreClient = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.ImportService;

/// <summary>Orchestrates SavedVariables parsing, validation, reconciliation, and atomic persistence.</summary>
public sealed class CompanionImportService
{
    private readonly HistoryStoreClient _historyStore;
    private readonly SavedVariablesSnapshotReader _snapshots;

    public CompanionImportService(HistoryStoreClient historyStore, SavedVariablesSnapshotReader? snapshots = null)
    {
        _historyStore = historyStore ?? throw new ArgumentNullException(nameof(historyStore));
        _snapshots = snapshots ?? new();
    }

    /// <summary>Imports one in-memory SavedVariables snapshot without reading or retaining its source.</summary>
    public Task<CompanionImportResult> ImportSavedVariablesAsync(
        string content,
        string sourceName = "<memory>",
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(content);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceName);
        cancellationToken.ThrowIfCancellationRequested();

        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(content, sourceName);
        CraftHistory? history = parsed.History;
        int sourceCrafts = history?.Crafts.Count ?? 0;
        IReadOnlyList<HistoryValidationError> validationErrors = history is null
            ? []
            : CraftHistoryValidator.Validate(history);
        if (!parsed.IsSuccessful || validationErrors.Count > 0 || history is null)
            return Task.FromResult(Result(
                CompanionImportOutcome.Rejected,
                sourceCrafts,
                rejectedCrafts: sourceCrafts,
                parsed,
                validationErrors));

        try
        {
            CraftHistoryBatchWriteResult persisted = _historyStore.WriteBatch(history, cancellationToken);
            if (!persisted.IsSuccessful)
            {
                bool dimensionConflict = persisted.DimensionConflicts.Count > 0;
                int rejectedCrafts = dimensionConflict
                    ? sourceCrafts
                    : persisted.CraftConflicts.Select(conflict => conflict.Identity).Distinct().Count();
                return Task.FromResult(Result(
                    CompanionImportOutcome.Rejected,
                    sourceCrafts,
                    rejectedCrafts,
                    parsed,
                    persisted.ValidationErrors,
                    persisted.CraftConflicts,
                    persisted.DimensionConflicts));
            }

            return Task.FromResult(Result(
                CompanionImportOutcome.Successful,
                sourceCrafts,
                rejectedCrafts: 0,
                parsed,
                [],
                insertedCrafts: persisted.InsertedCrafts,
                alreadyPresentCrafts: persisted.AlreadyPresentCrafts,
                enrichedCrafts: persisted.EnrichedCrafts,
                dimensionsInserted: persisted.InsertedDimensions,
                dimensionsEnriched: persisted.EnrichedDimensions) with
            { Observations = persisted.Observations });
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (DbException exception)
        {
            return Task.FromResult(Failure(sourceCrafts, parsed, "history-store-failure", exception.Message));
        }
        catch (IOException exception)
        {
            return Task.FromResult(Failure(sourceCrafts, parsed, "history-store-failure", exception.Message));
        }
        catch (InvalidOperationException exception)
        {
            return Task.FromResult(Failure(sourceCrafts, parsed, "history-store-failure", exception.Message));
        }
    }

    /// <summary>
    /// Reads one stable byte snapshot from an explicit path, then imports only that snapshot.
    /// A successful read does not assert that the game has finished writing the file.
    /// </summary>
    public async Task<CompanionImportResult> ImportSavedVariablesFileAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        cancellationToken.ThrowIfCancellationRequested();

        try
        {
            SavedVariablesSnapshot snapshot = await _snapshots.ReadAsync(path, cancellationToken).ConfigureAwait(false);
            CompanionImportResult result = await ImportSavedVariablesAsync(
                snapshot.Content, Path.GetFullPath(path), cancellationToken).ConfigureAwait(false);
            return result with { SourceFingerprint = snapshot.Fingerprint };
        }
        catch (SourceSnapshotException exception)
        {
            return FileInputFailure(exception.Outcome, exception.Code, exception.Message);
        }
    }

    private static CompanionImportResult Failure(
        int sourceCrafts,
        SavedVariablesImportResult parsed,
        string code,
        string message) =>
        Result(
            CompanionImportOutcome.Failed,
            sourceCrafts,
            rejectedCrafts: 0,
            parsed,
            [],
            persistenceDiagnostics: [new(code, message)]);

    private static CompanionImportResult FileInputFailure(
        CompanionImportOutcome outcome,
        string code,
        string message) =>
        new(
            outcome,
            0, 0, 0, 0, 0, 0, 0, null,
            [],
            [],
            [],
            [],
            [],
            [new(code, message)],
            []);

    private static CompanionImportResult Result(
        CompanionImportOutcome outcome,
        int sourceCrafts,
        int rejectedCrafts,
        SavedVariablesImportResult parsed,
        IReadOnlyList<HistoryValidationError> validationErrors,
        IReadOnlyList<HistoryConflict>? craftConflicts = null,
        IReadOnlyList<DimensionConflict>? dimensionConflicts = null,
        int insertedCrafts = 0,
        int alreadyPresentCrafts = 0,
        int enrichedCrafts = 0,
        int dimensionsInserted = 0,
        int dimensionsEnriched = 0,
        IReadOnlyList<CompanionImportDiagnostic>? inputDiagnostics = null,
        IReadOnlyList<CompanionImportDiagnostic>? persistenceDiagnostics = null)
    {
        SavedVariablesDiagnostic[] coverageWarnings = parsed.Diagnostics
            .Where(diagnostic => diagnostic.Severity == SavedVariablesDiagnosticSeverity.Warning)
            .ToArray();
        return new(
            outcome,
            sourceCrafts,
            insertedCrafts,
            alreadyPresentCrafts,
            enrichedCrafts,
            rejectedCrafts,
            dimensionsInserted,
            dimensionsEnriched,
            parsed.Coverage,
            parsed.Diagnostics,
            coverageWarnings,
            validationErrors,
            craftConflicts ?? [],
            dimensionConflicts ?? [],
            inputDiagnostics ?? [],
            persistenceDiagnostics ?? []);
    }

}
