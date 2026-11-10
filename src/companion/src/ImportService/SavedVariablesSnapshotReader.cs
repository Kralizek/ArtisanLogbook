using System.Security;
using System.Security.Cryptography;
using System.Text;

namespace ArtisanLogbook.ImportService;

public sealed record SavedVariablesSnapshot
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    private SavedVariablesSnapshot(string content, string fingerprint) =>
        (Content, Fingerprint) = (content, fingerprint);

    public string Content { get; }
    public string Fingerprint { get; }

    public static SavedVariablesSnapshot FromBytes(ReadOnlySpan<byte> bytes) =>
        new(StrictUtf8.GetString(bytes), Convert.ToHexString(SHA256.HashData(bytes)));
}

public sealed class SourceSnapshotException(
    string code, string message, CompanionImportOutcome outcome = CompanionImportOutcome.Failed,
    Exception? innerException = null) : IOException(message, innerException)
{
    public string Code { get; } = code;
    public CompanionImportOutcome Outcome { get; } = outcome;
}

/// <summary>Shared C06/C07 inspection; stability is byte-based, not a claim that the game has finished saving.</summary>
public class SavedVariablesSnapshotReader(TimeProvider? timeProvider = null, TimeSpan? quietPeriod = null)
{
    public const long MaximumSnapshotBytes = 64L * 1024 * 1024;

    public virtual async Task<SavedVariablesSnapshot> ReadAsync(string path, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            string fullPath = Path.GetFullPath(path);
            byte[] first = await ReadBytesAsync(fullPath, cancellationToken).ConfigureAwait(false);
            await WaitForQuietAsync(cancellationToken).ConfigureAwait(false);
            byte[] second = await ReadBytesAsync(fullPath, cancellationToken).ConfigureAwait(false);
            if (!first.AsSpan().SequenceEqual(second))
                throw Changed();
            return SavedVariablesSnapshot.FromBytes(second);
        }
        catch (SourceSnapshotException) { throw; }
        catch (DecoderFallbackException exception)
        {
            throw new SourceSnapshotException("invalid-source-encoding", exception.Message,
                CompanionImportOutcome.Rejected, exception);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or SecurityException or ArgumentException or NotSupportedException)
        {
            throw new SourceSnapshotException("source-read-failed", exception.Message, innerException: exception);
        }
    }

    protected virtual Task WaitForQuietAsync(CancellationToken cancellationToken) =>
        Task.Delay(quietPeriod ?? TimeSpan.FromMilliseconds(250), timeProvider ?? TimeProvider.System, cancellationToken);

    protected virtual async Task<byte[]> ReadBytesAsync(string path, CancellationToken cancellationToken)
    {
        FileInfo before = new(path);
        before.Refresh();
        if (!before.Exists)
            throw new FileNotFoundException("The SavedVariables file does not exist.", path);

        await using FileStream stream = new(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 81920, FileOptions.Asynchronous | FileOptions.SequentialScan);
        long length = stream.Length;
        DateTime lastWrite = before.LastWriteTimeUtc;
        if (length > MaximumSnapshotBytes) throw TooLarge();

        using MemoryStream buffer = new((int)length);
        byte[] chunk = new byte[81920];
        while (true)
        {
            int read = await stream.ReadAsync(chunk, cancellationToken).ConfigureAwait(false);
            if (read == 0) break;
            if (buffer.Length + read > MaximumSnapshotBytes) throw TooLarge();
            await buffer.WriteAsync(chunk.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
        }

        before.Refresh();
        if (buffer.Length != length || stream.Length != length ||
            before.Length != length || before.LastWriteTimeUtc != lastWrite)
            throw Changed();
        return buffer.ToArray();
    }

    private static SourceSnapshotException Changed() => new("source-changed-during-read",
        "The SavedVariables file changed while it was being read; retry after the write settles.");

    private static SourceSnapshotException TooLarge() => new("source-too-large",
        $"The SavedVariables file exceeds the {MaximumSnapshotBytes} byte import limit.", CompanionImportOutcome.Rejected);
}
