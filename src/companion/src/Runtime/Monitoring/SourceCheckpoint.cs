namespace ArtisanLogbook.Runtime;

internal enum CheckpointAttemptOutcome { Pending, Successful, Failed, Cancelled }

internal sealed record ImportReceipt(
    long Sequence, string? Fingerprint, CheckpointAttemptOutcome Outcome, DateTimeOffset At);

internal sealed record SourceCheckpoint(
    string? Observed = null,
    ImportReceipt? Successful = null,
    ImportReceipt? LastAttempt = null,
    DateTimeOffset? RetryAfter = null,
    string? InspectionFailure = null)
{
    public bool RequiresImport => Observed is not null && Observed != Successful?.Fingerprint;
    public bool NeedsReconciliation => RequiresImport || InspectionFailure is not null ||
        (Observed is null && LastAttempt?.Outcome == CheckpointAttemptOutcome.Failed);

    public bool IsEligible(DateTimeOffset now) => RequiresImport && (RetryAfter is null || RetryAfter <= now);

    public SourceCheckpoint Observe(string fingerprint) => this with
    {
        Observed = fingerprint,
        InspectionFailure = null,
        RetryAfter = fingerprint == LastAttempt?.Fingerprint && LastAttempt.Outcome != CheckpointAttemptOutcome.Successful
            ? RetryAfter : null
    };

    public SourceCheckpoint Complete(ImportReceipt receipt, TimeSpan retryDelay)
    {
        if (receipt.Outcome == CheckpointAttemptOutcome.Successful && receipt.Fingerprint is null)
            throw new InvalidOperationException("A successful file import must identify the bytes ingested by C07.");
        if (receipt.Sequence == LastAttempt?.Sequence && LastAttempt.Outcome != CheckpointAttemptOutcome.Pending)
            return this;
        ImportReceipt? success = receipt.Outcome == CheckpointAttemptOutcome.Successful &&
            receipt.Sequence > (Successful?.Sequence ?? 0) ? receipt : Successful;
        if (receipt.Sequence < (LastAttempt?.Sequence ?? 0))
            return this with { Successful = success };
        return this with
        {
            Successful = success,
            LastAttempt = receipt,
            RetryAfter = receipt.Outcome == CheckpointAttemptOutcome.Successful ? null : receipt.At + retryDelay
        };
    }
}
