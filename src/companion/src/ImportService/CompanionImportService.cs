using System.Data.Common;
using System.Security;
using System.Text;

using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;
using ArtisanLogbook.SavedVariables;

using HistoryStoreClient = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.ImportService;

/// <summary>Orchestrates SavedVariables parsing, validation, reconciliation, and atomic persistence.</summary>
public sealed class CompanionImportService
{
    private const long MaximumSnapshotBytes = 64L * 1024 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    private readonly HistoryStoreClient _historyStore;

    public CompanionImportService(HistoryStoreClient historyStore) =>
        _historyStore = historyStore ?? throw new ArgumentNullException(nameof(historyStore));

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

        string fullPath;
        byte[] snapshot;
        try
        {
            fullPath = Path.GetFullPath(path);
            snapshot = await ReadStableSnapshotAsync(fullPath, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (SourceTooLargeException exception)
        {
            return FileInputFailure(CompanionImportOutcome.Rejected, "source-too-large", exception.Message);
        }
        catch (StableSnapshotException exception)
        {
            return FileInputFailure(CompanionImportOutcome.Failed, "source-changed-during-read", exception.Message);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or SecurityException or ArgumentException or NotSupportedException)
        {
            return FileInputFailure(CompanionImportOutcome.Failed, "source-read-failed", exception.Message);
        }

        string content;
        try
        {
            content = StrictUtf8.GetString(snapshot);
        }
        catch (DecoderFallbackException exception)
        {
            return FileInputFailure(CompanionImportOutcome.Rejected, "invalid-source-encoding", exception.Message);
        }

        return await ImportSavedVariablesAsync(content, fullPath, cancellationToken).ConfigureAwait(false);
    }

    private static async Task<byte[]> ReadStableSnapshotAsync(
        string path,
        CancellationToken cancellationToken)
    {
        FileInfo before = new(path);
        before.Refresh();
        if (!before.Exists)
            throw new FileNotFoundException("The SavedVariables file does not exist.", path);

        await using FileStream stream = new(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            81920,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        long lengthBefore = stream.Length;
        DateTime lastWriteBefore = before.LastWriteTimeUtc;
        if (lengthBefore > MaximumSnapshotBytes)
            throw new SourceTooLargeException(
                $"The SavedVariables file exceeds the {MaximumSnapshotBytes} byte import limit.");

        using MemoryStream buffer = new((int)Math.Min(lengthBefore, int.MaxValue));
        byte[] chunk = new byte[81920];
        while (true)
        {
            int read = await stream.ReadAsync(chunk, cancellationToken).ConfigureAwait(false);
            if (read == 0) break;
            if (buffer.Length + read > MaximumSnapshotBytes)
                throw new SourceTooLargeException(
                    $"The SavedVariables file exceeds the {MaximumSnapshotBytes} byte import limit.");
            await buffer.WriteAsync(chunk.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
        }

        before.Refresh();
        long lengthAfter = stream.Length;
        if (buffer.Length != lengthBefore || lengthAfter != lengthBefore ||
            before.Length != lengthBefore || before.LastWriteTimeUtc != lastWriteBefore)
            throw new StableSnapshotException(
                "The SavedVariables file changed while it was being read; retry after the write settles.");

        return buffer.ToArray();
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

    private sealed class SourceTooLargeException(string message) : IOException(message);

    private sealed class StableSnapshotException(string message) : IOException(message);
}
