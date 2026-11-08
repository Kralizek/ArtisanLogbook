using System.Security;

namespace ArtisanLogbook.Runtime;

public enum DiscoverySeverity { Warning, Error }
public sealed record DiscoveryDiagnostic(string Path, string Code, string Message, DiscoverySeverity Severity);
public sealed record DiscoveryResult(IReadOnlyList<string> Paths, IReadOnlyList<DiscoveryDiagnostic> Diagnostics)
{
    public bool HasErrors => Diagnostics.Any(diagnostic => diagnostic.Severity == DiscoverySeverity.Error);
}

/// <summary>Bounded layout inspection. Directory names locate sources, never establish GameContext.</summary>
public sealed class InstallationDiscovery
{
    public static StringComparer PathComparer { get; } =
        OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    public DiscoveryResult ValidateRoot(string root)
    {
        List<DiscoveryDiagnostic> diagnostics = [];
        string? normalized = Normalize(root, diagnostics);
        List<string> flavors = normalized is null ? [] : Flavors(normalized, diagnostics);
        if (normalized is not null && flavors.Count == 0 && diagnostics.Count == 0)
            diagnostics.Add(new(normalized, "invalid-installation",
                "Expected an installation containing a client directory with WTF/Account or Interface/AddOns.",
                DiscoverySeverity.Error));
        return new(flavors.Count > 0 ? [normalized!] : [], diagnostics);
    }

    public DiscoveryResult Detect(IEnumerable<string> hints)
    {
        SortedSet<string> roots = new(PathComparer);
        List<DiscoveryDiagnostic> diagnostics = [];
        foreach (string hint in hints.Distinct(PathComparer))
        {
            // Absent hints are normal; only plausible, present locations are inspected.
            try { _ = File.GetAttributes(hint); }
            catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException) { continue; }
            catch (Exception exception) when (IsFileSystemFailure(exception))
            {
                diagnostics.Add(Failure(hint, exception));
                continue;
            }
            DiscoveryResult result = ValidateRoot(hint);
            roots.UnionWith(result.Paths);
            diagnostics.AddRange(result.Diagnostics);
        }
        return new(roots.ToArray(), diagnostics);
    }

    public DiscoveryResult DiscoverSavedVariables(IEnumerable<string> roots)
    {
        SortedSet<string> files = new(PathComparer);
        List<DiscoveryDiagnostic> diagnostics = [];
        HashSet<string> visited = new(PathComparer);
        foreach (string root in roots)
        {
            string? normalized = Normalize(root, diagnostics);
            if (normalized is null || !visited.Add(normalized)) continue;
            foreach (string flavor in Flavors(normalized, diagnostics))
            {
                string accounts = Path.Combine(flavor, "WTF", "Account");
                if (!SafeDirectory(accounts, diagnostics, optional: true)) continue;
                foreach (string account in Directories(accounts, diagnostics))
                {
                    if (!SafeDirectory(account, diagnostics)) continue;
                    string savedVariables = Path.Combine(account, "SavedVariables");
                    if (!SafeDirectory(savedVariables, diagnostics, optional: true)) continue;
                    string ledger = Path.Combine(savedVariables, "ArtisanLogbook_Core.lua");
                    try
                    {
                        FileAttributes attributes = File.GetAttributes(ledger);
                        if ((attributes & FileAttributes.ReparsePoint) != 0)
                            diagnostics.Add(Link(ledger));
                        else if ((attributes & FileAttributes.Directory) == 0)
                            files.Add(ledger);
                        else
                            diagnostics.Add(new(ledger, "invalid-ledger-path", "Expected a regular SavedVariables file.", DiscoverySeverity.Error));
                    }
                    catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException) { }
                    catch (Exception exception) when (IsFileSystemFailure(exception)) { diagnostics.Add(Failure(ledger, exception)); }
                }
            }
        }
        return new(files.ToArray(), diagnostics);
    }

    public static IReadOnlyList<string> DefaultHints(
        CompanionPlatform platform, string home, string programFiles, string programFilesX86, string systemDrive)
    {
        return platform switch
        {
            CompanionPlatform.Windows => new[]
            {
                Path.Combine(programFiles, "World of Warcraft"),
                Path.Combine(programFilesX86, "World of Warcraft"),
                Path.Combine(systemDrive, "Games", "World of Warcraft"),
                Path.Combine(home, "Games", "World of Warcraft")
            }.Where(Path.IsPathFullyQualified).Distinct(PathComparer).ToArray(),
            CompanionPlatform.MacOS =>
            [
                "/Applications/World of Warcraft",
                Path.Combine(home, "Applications", "World of Warcraft")
            ],
            CompanionPlatform.Linux =>
            [
                Path.Combine(home, "Games", "World of Warcraft"),
                Path.Combine(home, ".wine", "drive_c", "Program Files (x86)", "World of Warcraft"),
                Path.Combine(home, "Games", "world-of-warcraft", "drive_c", "Program Files (x86)", "World of Warcraft")
            ],
            _ => throw new NotSupportedException("Unsupported operating system.")
        };
    }

    public static IReadOnlyList<string> CurrentHints() => DefaultHints(
        OperatingSystem.IsWindows() ? CompanionPlatform.Windows :
            OperatingSystem.IsMacOS() ? CompanionPlatform.MacOS : CompanionPlatform.Linux,
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
        Path.GetPathRoot(Environment.SystemDirectory) ?? "");

    private static List<string> Flavors(string root, List<DiscoveryDiagnostic> diagnostics)
    {
        if (!SafeDirectory(root, diagnostics)) return [];
        List<string> flavors = [];
        foreach (string directory in Directories(root, diagnostics))
        {
            if (!SafeDirectory(directory, diagnostics)) continue;
            if (SafeDirectory(Path.Combine(directory, "WTF"), diagnostics, optional: true) &&
                SafeDirectory(Path.Combine(directory, "WTF", "Account"), diagnostics, optional: true) ||
                SafeDirectory(Path.Combine(directory, "Interface"), diagnostics, optional: true) &&
                SafeDirectory(Path.Combine(directory, "Interface", "AddOns"), diagnostics, optional: true))
                flavors.Add(directory);
        }
        return flavors;
    }

    private static string? Normalize(string root, List<DiscoveryDiagnostic> diagnostics)
    {
        try
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(root);
            if (!Path.IsPathFullyQualified(root)) throw new ArgumentException("An absolute installation root is required.");
            string normalized = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
            for (DirectoryInfo? ancestor = new(normalized); ancestor is not null; ancestor = ancestor.Parent)
                if (!SafeDirectory(ancestor.FullName, diagnostics)) return null;
            return normalized;
        }
        catch (Exception exception) when (IsFileSystemFailure(exception))
        {
            diagnostics.Add(Failure(root, exception));
            return null;
        }
    }

    private static bool SafeDirectory(string path, List<DiscoveryDiagnostic> diagnostics, bool optional = false)
    {
        try
        {
            FileAttributes attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                diagnostics.Add(Link(path));
                return false;
            }
            if ((attributes & FileAttributes.Directory) == 0)
                throw new IOException("Expected a directory.");
            return true;
        }
        catch (Exception exception) when (optional && exception is FileNotFoundException or DirectoryNotFoundException) { return false; }
        catch (Exception exception) when (IsFileSystemFailure(exception))
        {
            diagnostics.Add(Failure(path, exception));
            return false;
        }
    }

    private static string[] Directories(string path, List<DiscoveryDiagnostic> diagnostics)
    {
        try
        {
            List<string> directories = [];
            foreach (string entry in Directory.GetFileSystemEntries(path).Order(PathComparer))
            {
                try
                {
                    FileAttributes attributes = File.GetAttributes(entry);
                    if ((attributes & FileAttributes.ReparsePoint) != 0)
                        diagnostics.Add(Link(entry));
                    else if ((attributes & FileAttributes.Directory) != 0)
                        directories.Add(entry);
                }
                catch (Exception exception) when (IsFileSystemFailure(exception)) { diagnostics.Add(Failure(entry, exception)); }
            }
            return directories.ToArray();
        }
        catch (Exception exception) when (IsFileSystemFailure(exception))
        {
            diagnostics.Add(Failure(path, exception));
            return [];
        }
    }

    private static bool IsFileSystemFailure(Exception exception) =>
        exception is IOException or UnauthorizedAccessException or SecurityException or ArgumentException or NotSupportedException;

    private static DiscoveryDiagnostic Failure(string path, Exception exception) =>
        new(path, "discovery-failed", exception.Message, DiscoverySeverity.Error);
    private static DiscoveryDiagnostic Link(string path) =>
        new(path, "link-skipped", "Filesystem links are not followed; select a physical installation path.", DiscoverySeverity.Warning);
}
