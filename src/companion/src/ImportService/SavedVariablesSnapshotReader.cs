using System.Security.Cryptography;

namespace ArtisanLogbook.ImportService;

public sealed record SavedVariablesFileSnapshot(byte[] Bytes, string Fingerprint);

public sealed class SavedVariablesSnapshotTooLargeException(string message) : IOException(message);
public sealed class SavedVariablesSnapshotUnstableException(string message) : IOException(message);

public static class SavedVariablesSnapshotReader
{
    public const long MaximumSnapshotBytes = 64L * 1024 * 1024;

    public static async Task<SavedVariablesFileSnapshot> ReadAsync(
        string path, CancellationToken cancellationToken = default)
    {
        string fullPath = Path.GetFullPath(path);
        FileInfo before = new(fullPath);
        before.Refresh();
        if (!before.Exists)
            throw new FileNotFoundException("The SavedVariables file does not exist.", fullPath);

        await using FileStream stream = new(
            fullPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            81920,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        long lengthBefore = stream.Length;
        DateTime lastWriteBefore = before.LastWriteTimeUtc;
        if (lengthBefore > MaximumSnapshotBytes)
            throw new SavedVariablesSnapshotTooLargeException(
                $"The SavedVariables file exceeds the {MaximumSnapshotBytes} byte import limit.");

        using MemoryStream buffer = new((int)Math.Min(lengthBefore, int.MaxValue));
        byte[] chunk = new byte[81920];
        while (true)
        {
            int read = await stream.ReadAsync(chunk, cancellationToken).ConfigureAwait(false);
            if (read == 0) break;
            if (buffer.Length + read > MaximumSnapshotBytes)
                throw new SavedVariablesSnapshotTooLargeException(
                    $"The SavedVariables file exceeds the {MaximumSnapshotBytes} byte import limit.");
            await buffer.WriteAsync(chunk.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
        }

        before.Refresh();
        if (buffer.Length != lengthBefore || stream.Length != lengthBefore ||
            before.Length != lengthBefore || before.LastWriteTimeUtc != lastWriteBefore)
            throw new SavedVariablesSnapshotUnstableException(
                "The SavedVariables file changed while it was being read; retry after the write settles.");

        byte[] bytes = buffer.ToArray();
        return new(bytes, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant());
    }
}
