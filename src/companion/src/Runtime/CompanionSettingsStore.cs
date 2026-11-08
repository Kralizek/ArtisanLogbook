using System.Security;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ArtisanLogbook.Runtime;

/// <summary>Versioned per-user settings; independent of hosting, console and history storage.</summary>
public sealed class CompanionSettingsStore(ApplicationPaths paths)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public string FilePath => paths.SettingsFile;

    public SettingsLoadResult Load()
    {
        try
        {
            byte[]? bytes = ReadExisting();
            if (bytes is null)
                return new(SettingsStatus.Missing, null, $"No configuration at {FilePath}. Run artisanlogbook init.");

            using JsonDocument document = JsonDocument.Parse(bytes);
            if (document.RootElement.ValueKind != JsonValueKind.Object ||
                !document.RootElement.TryGetProperty("version", out JsonElement version) ||
                version.ValueKind != JsonValueKind.Number ||
                !version.TryGetInt32(out int number) || number < 1)
                return Invalid("Expected a settings object with a positive integer version.");
            if (number != CompanionSettings.CurrentVersion)
                return new(SettingsStatus.Unsupported, null,
                    $"Unsupported settings version {number} at {FilePath}; this Companion supports version 1. " +
                    "Use a compatible Companion or explicitly back up and repair the configuration.");
            if (HasDuplicateProperties(document.RootElement))
                return Invalid("Duplicate settings properties are not allowed.");

            CompanionSettings settings = JsonSerializer.Deserialize<CompanionSettings>(bytes, JsonOptions)!;
            return new(SettingsStatus.Loaded, Validate(settings), null, Revision(bytes));
        }
        catch (Exception exception) when (exception is JsonException or ArgumentException or NotSupportedException)
        {
            return Invalid(exception.Message);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SecurityException)
        {
            return new(SettingsStatus.Unreadable, null, $"Cannot read settings at {FilePath}: {exception.Message}");
        }
    }

    public void Save(
        CompanionSettings settings, CancellationToken cancellationToken = default, SettingsLoadResult? expected = null)
    {
        CompanionSettings normalized = Validate(settings);
        cancellationToken.ThrowIfCancellationRequested();
        SettingsLoadResult existing = Load();
        if (!existing.CanSave)
            throw new CompanionSettingsException(existing.Diagnostic!);
        if (expected is not null && (expected.Status != existing.Status || expected.Revision != existing.Revision))
            throw new CompanionSettingsException("Settings changed since initialization began; no configuration was replaced. Retry.");
        byte[]? before = ReadExisting();
        if (existing.Revision != (before is null ? null : Revision(before)))
            throw new CompanionSettingsException("Settings changed during saving; no configuration was replaced. Retry.");
        Directory.CreateDirectory(paths.DataDirectory);
        string temporary = Path.Combine(paths.DataDirectory, $".settings-{Guid.NewGuid():N}.tmp");
        try
        {
            using (FileStream stream = new(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, normalized, JsonOptions);
                stream.Flush(flushToDisk: true);
            }
            cancellationToken.ThrowIfCancellationRequested();
            SettingsLoadResult latest = Load();
            byte[]? after = ReadExisting();
            if (!latest.CanSave || !Equal(before, after))
                throw new CompanionSettingsException("Settings changed during saving; no configuration was replaced. Retry.");
            // Same-directory rename keeps the previous complete file intact until the commit point.
            File.Move(temporary, FilePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary))
                File.Delete(temporary);
        }
    }

    private byte[]? ReadExisting()
    {
        try
        {
            FileAttributes attributes = File.GetAttributes(FilePath);
            if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                throw new CompanionSettingsException("The settings path must be a regular file, not a directory or link.");
            using FileStream stream = new(FilePath, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            if (stream.Length > 1024 * 1024)
                throw new CompanionSettingsException("Settings exceed the 1 MiB size limit.");
            using MemoryStream buffer = new();
            stream.CopyTo(buffer);
            return buffer.ToArray();
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    public static CompanionSettings Validate(CompanionSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (settings.Version != CompanionSettings.CurrentVersion)
            throw new ArgumentException("Only settings version 1 can be saved.");
        if (settings.InstallationRoots is null)
            throw new ArgumentException("installationRoots must be an array of absolute installation paths.");
        if (settings.Monitoring is null || settings.Http is null)
            throw new ArgumentException("monitoring and http must be objects when specified.");
        if (settings.Monitoring.ReconciliationIntervalSeconds is < 1 or > 86400)
            throw new ArgumentException("monitoring.reconciliationIntervalSeconds must be between 1 and 86400.");
        if (settings.Http.PreferredPort is < 1 or > 65535)
            throw new ArgumentException("http.preferredPort must be between 1 and 65535.");
        List<string> roots = [];
        foreach (string root in settings.InstallationRoots)
        {
            if (string.IsNullOrWhiteSpace(root) || !Path.IsPathFullyQualified(root))
                throw new ArgumentException("Every installation root must be a nonempty absolute path.");
            string normalized = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
            if (roots.Contains(normalized, InstallationDiscovery.PathComparer))
                throw new ArgumentException("Duplicate installation roots are not allowed.");
            roots.Add(normalized);
        }
        return settings with { InstallationRoots = roots };
    }

    private static bool HasDuplicateProperties(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Object => element.EnumerateObject().Select(property => property.Name)
            .Distinct(StringComparer.Ordinal).Count() != element.EnumerateObject().Count() ||
            element.EnumerateObject().Any(property => HasDuplicateProperties(property.Value)),
        JsonValueKind.Array => element.EnumerateArray().Any(HasDuplicateProperties),
        _ => false
    };

    private SettingsLoadResult Invalid(string message) =>
        new(SettingsStatus.Invalid, null, $"Invalid settings at {FilePath}: {message} Back up and repair it; it was not overwritten.");

    private static bool Equal(byte[]? first, byte[]? second) =>
        first is null ? second is null : second is not null && first.AsSpan().SequenceEqual(second);

    private static string Revision(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
}
