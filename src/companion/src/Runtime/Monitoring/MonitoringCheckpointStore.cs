using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ArtisanLogbook.Runtime;

internal sealed record CheckpointDocument(int Version, long NextSequence, ImmutableDictionary<string, SourceCheckpoint> Sources)
{
    public static CheckpointDocument Empty { get; } = new(1, 0, ImmutableDictionary<string, SourceCheckpoint>.Empty);
}

/// <summary>Single-writer, database-scoped metadata; never stores source paths or canonical history.</summary>
internal class MonitoringCheckpointStore(string path)
{
    private const int MaximumBytes = 8 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        Converters = { new JsonStringEnumConverter() }
    };
    private string? _revision;

    public virtual CheckpointDocument Load()
    {
        byte[]? bytes = ReadExisting();
        _revision = Revision(bytes);
        if (bytes is null) return CheckpointDocument.Empty;
        try
        {
            CheckpointDocument document = JsonSerializer.Deserialize<CheckpointDocument>(bytes, JsonOptions)
                ?? throw new JsonException("Expected a checkpoint document.");
            Validate(document);
            return document;
        }
        catch (Exception exception) when (exception is JsonException or ArgumentException or NotSupportedException)
        {
            throw new IOException("Monitoring checkpoints are invalid or unsupported; back up and repair the sidecar.", exception);
        }
    }

    public virtual async Task SaveAsync(CheckpointDocument document, CancellationToken cancellationToken)
    {
        Validate(document);
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(document, JsonOptions);
        if (bytes.Length > MaximumBytes)
            throw new IOException("Monitoring checkpoints exceed the 8 MiB limit.");
        if (Revision(ReadExisting()) != _revision)
            throw new IOException("Monitoring checkpoints changed externally; no metadata was replaced.");
        string directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        string temporary = Path.Combine(directory, $".monitoring-{Guid.NewGuid():N}.tmp");
        try
        {
            await using (FileStream stream = new(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                81920, FileOptions.Asynchronous))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            cancellationToken.ThrowIfCancellationRequested();
            if (Revision(ReadExisting()) != _revision)
                throw new IOException("Monitoring checkpoints changed during saving; no metadata was replaced.");
            File.Move(temporary, path, overwrite: true);
            _revision = Revision(bytes);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private byte[]? ReadExisting()
    {
        try
        {
            if ((File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                throw new IOException("The monitoring checkpoint path must be a regular file.");
            using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            if (stream.Length > MaximumBytes) throw new IOException("Monitoring checkpoints exceed the 8 MiB limit.");
            using MemoryStream buffer = new();
            stream.CopyTo(buffer);
            if (buffer.Length > MaximumBytes) throw new IOException("Monitoring checkpoints exceed the 8 MiB limit.");
            return buffer.ToArray();
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    internal static void Validate(CheckpointDocument document)
    {
        if (document.Version != 1 || document.NextSequence < 0 || document.Sources is null ||
            document.Sources.Count > MonitoringCheckpoints.MaximumSources)
            throw new ArgumentException("Unsupported or invalid monitoring checkpoint document.");
        foreach ((string id, SourceCheckpoint checkpoint) in document.Sources)
        {
            if (!SourceCatalog.IsWellFormedId(id) || checkpoint is null || !ValidFingerprint(checkpoint.Observed))
                throw new ArgumentException("Invalid source checkpoint.");
            foreach (ImportReceipt receipt in new[] { checkpoint.Successful, checkpoint.LastAttempt }.OfType<ImportReceipt>())
            {
                if (receipt.Sequence <= 0 || receipt.Sequence > document.NextSequence ||
                    !Enum.IsDefined(receipt.Outcome) || !ValidFingerprint(receipt.Fingerprint))
                    throw new ArgumentException("Invalid import receipt.");
            }
            if (checkpoint.Successful is { } success &&
                (success.Outcome != CheckpointAttemptOutcome.Successful || success.Fingerprint is null ||
                 success.Sequence > (checkpoint.LastAttempt?.Sequence ?? 0)))
                throw new ArgumentException("Invalid successful import checkpoint.");
        }
    }

    private static bool ValidFingerprint(string? value) =>
        value is null || (value.Length == 64 && value.AsSpan().IndexOfAnyExcept("0123456789ABCDEF") < 0);

    private static string? Revision(byte[]? bytes) => bytes is null ? null : Convert.ToHexString(SHA256.HashData(bytes));
}
