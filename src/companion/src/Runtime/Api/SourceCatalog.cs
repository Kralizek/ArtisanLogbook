using System.Security.Cryptography;
using System.Text;

namespace ArtisanLogbook.Runtime;

public sealed record DiscoveredSource(string Id, string Path, string Client, string FileName, long? SizeBytes, DateTimeOffset? ModifiedAt);
public sealed record SourceCatalogDiagnostic(DiscoverySeverity Severity, string Code, string Message);
public sealed record SourceCatalogSnapshot(IReadOnlyList<DiscoveredSource> Sources, IReadOnlyList<SourceCatalogDiagnostic> Diagnostics);

/// <summary>
/// Read-only view of SavedVariables files under the configured installation roots.
/// Identifiers are opaque hashes of the normalized location; they never imply a GameContext.
/// </summary>
public sealed class SourceCatalog(CompanionRuntimeConfiguration configuration, InstallationDiscovery discovery)
{
    private static readonly Dictionary<string, string> DiagnosticMessages = new(StringComparer.Ordinal)
    {
        ["discovery-failed"] = "A location under a configured installation root could not be inspected.",
        ["link-skipped"] = "A filesystem link was skipped; links are not followed.",
        ["invalid-source-path"] = "An expected SavedVariables location is not a regular file or directory.",
        ["invalid-ledger-path"] = "An expected SavedVariables file is not a regular file.",
        ["invalid-installation"] = "A configured installation root does not contain a recognised client layout."
    };

    public SourceCatalogSnapshot Discover()
    {
        DiscoveryResult result = discovery.DiscoverSavedVariables(configuration.EffectiveSettings.InstallationRoots);
        List<DiscoveredSource> sources = [];
        foreach (string path in result.Paths)
        {
            long? size = null;
            DateTimeOffset? modified = null;
            try
            {
                FileInfo info = new(path);
                size = info.Length;
                modified = info.LastWriteTimeUtc;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
            }
            sources.Add(new(IdFor(path), path, ClientLabel(path), Path.GetFileName(path), size, modified));
        }
        List<SourceCatalogDiagnostic> diagnostics = result.Diagnostics
            .Select(d => new SourceCatalogDiagnostic(d.Severity, d.Code,
                DiagnosticMessages.GetValueOrDefault(d.Code, "Source discovery reported a problem.")))
            .Distinct()
            .ToList();
        if (configuration.EffectiveSettings.InstallationRoots.Count == 0)
            diagnostics.Add(new(DiscoverySeverity.Warning, "no-installation-roots",
                "No installation roots are configured; run `artisanlogbook init`."));
        return new(sources, diagnostics);
    }

    public static string IdFor(string path)
    {
        string normalized = OperatingSystem.IsWindows() ? path.ToUpperInvariant() : path;
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(normalized));
        return "src_" + Convert.ToHexString(hash, 0, 12).ToLowerInvariant();
    }

    public static bool IsWellFormedId(string id) =>
        id.Length == 28 && id.StartsWith("src_", StringComparison.Ordinal) &&
        id.AsSpan(4).IndexOfAnyExcept("0123456789abcdef") < 0;

    // <client>/WTF/Account/<account>/SavedVariables/<file>; account names are deliberately not exposed.
    private static string ClientLabel(string path)
    {
        DirectoryInfo? directory = new FileInfo(path).Directory?.Parent?.Parent?.Parent?.Parent;
        return directory?.Name ?? "unknown";
    }
}
