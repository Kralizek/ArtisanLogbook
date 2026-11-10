using System.Security;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ArtisanLogbook.Runtime;

public interface IMonitoringCheckpointPersistence
{
    IReadOnlyList<MonitoringCheckpoint> Load();
    void Save(IEnumerable<MonitoringCheckpoint> checkpoints, CancellationToken cancellationToken = default);
}

public sealed record MonitoringCheckpoint(
    string SourceId,
    string? ObservedFingerprint,
    DateTimeOffset? ObservedAt,
    string? IngestedFingerprint,
    DateTimeOffset? RetryAfter,
    bool Available,
    bool ReconciliationPending);

internal sealed record MonitoringCheckpointDocument(int Version, IReadOnlyList<MonitoringCheckpoint> Sources);

/// <summary>Atomic, non-canonical monitoring state kept separately from user settings and craft history.</summary>
public sealed class MonitoringCheckpointStore(ApplicationPaths paths) : IMonitoringCheckpointPersistence
{
    private const int CurrentVersion = 1;
    private const long MaximumCheckpointBytes = 4L * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public string FilePath => Path.Combine(paths.DataDirectory, "monitoring-checkpoints.json");

    public IReadOnlyList<MonitoringCheckpoint> Load()
    {
        byte[] bytes;
        try
        {
            using FileStream stream = new(FilePath, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            if (stream.Length > MaximumCheckpointBytes)
                throw new IOException("Monitoring checkpoints exceed the size limit.");
            using MemoryStream buffer = new();
            stream.CopyTo(buffer);
            bytes = buffer.ToArray();
        }
        catch (FileNotFoundException) { return []; }
        catch (DirectoryNotFoundException) { return []; }

        MonitoringCheckpointDocument document = JsonSerializer.Deserialize<MonitoringCheckpointDocument>(bytes, JsonOptions)
            ?? throw new InvalidDataException("Monitoring checkpoints are empty.");
        if (document.Version != CurrentVersion || document.Sources is null)
            throw new InvalidDataException("Monitoring checkpoints have an unsupported format.");
        HashSet<string> ids = new(StringComparer.Ordinal);
        foreach (MonitoringCheckpoint checkpoint in document.Sources)
        {
            if (!SourceCatalog.IsWellFormedId(checkpoint.SourceId) || !ids.Add(checkpoint.SourceId) ||
                !IsFingerprint(checkpoint.ObservedFingerprint) || !IsFingerprint(checkpoint.IngestedFingerprint))
                throw new InvalidDataException("Monitoring checkpoints contain invalid source state.");
        }
        return document.Sources;
    }

    public void Save(IEnumerable<MonitoringCheckpoint> checkpoints, CancellationToken cancellationToken = default)
    {
        MonitoringCheckpoint[] sources = checkpoints.OrderBy(item => item.SourceId, StringComparer.Ordinal).ToArray();
        foreach (MonitoringCheckpoint checkpoint in sources)
        {
            if (!SourceCatalog.IsWellFormedId(checkpoint.SourceId) ||
                !IsFingerprint(checkpoint.ObservedFingerprint) || !IsFingerprint(checkpoint.IngestedFingerprint))
                throw new ArgumentException("Monitoring checkpoints contain invalid source state.", nameof(checkpoints));
        }

        cancellationToken.ThrowIfCancellationRequested();
        Directory.CreateDirectory(paths.DataDirectory);
        string temporary = Path.Combine(paths.DataDirectory, $".monitoring-{Guid.NewGuid():N}.tmp");
        try
        {
            using (FileStream stream = new(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, new MonitoringCheckpointDocument(CurrentVersion, sources), JsonOptions);
                stream.Flush(flushToDisk: true);
            }
            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporary, FilePath, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SecurityException)
        {
            throw new IOException("Monitoring checkpoints could not be saved.", exception);
        }
        finally
        {
            if (File.Exists(temporary))
                File.Delete(temporary);
        }
    }

    private static bool IsFingerprint(string? value) =>
        value is null || value.Length == 64 && value.AsSpan().IndexOfAnyExcept("0123456789abcdef") < 0;
}
