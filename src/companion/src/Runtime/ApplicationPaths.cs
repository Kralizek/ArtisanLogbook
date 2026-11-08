namespace ArtisanLogbook.Runtime;

public enum CompanionPlatform
{
    Windows,
    MacOS,
    Linux
}

/// <summary>Resolves shared application storage independently of command execution.</summary>
public sealed class ApplicationPaths
{
    private readonly CompanionPlatform _platform;
    private readonly string _home;
    private readonly string _localApplicationData;
    private readonly string? _xdgDataHome;
    private readonly string _workingDirectory;

    public ApplicationPaths(
        CompanionPlatform platform,
        string home,
        string localApplicationData,
        string? xdgDataHome,
        string workingDirectory)
    {
        _platform = platform;
        _home = home;
        _localApplicationData = localApplicationData;
        _xdgDataHome = xdgDataHome;
        _workingDirectory = workingDirectory;
    }

    public static ApplicationPaths ForCurrentUser() => new(
        OperatingSystem.IsWindows() ? CompanionPlatform.Windows :
            OperatingSystem.IsMacOS() ? CompanionPlatform.MacOS : CompanionPlatform.Linux,
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        Environment.GetEnvironmentVariable("XDG_DATA_HOME"),
        Directory.GetCurrentDirectory());

    public string ResolveDatabase(string? databasePath)
    {
        if (databasePath is not null)
            return ResolveSource(databasePath);

        return Path.Combine(DataDirectory, "history.duckdb");
    }

    public string SettingsFile => Path.Combine(DataDirectory, "settings.json");

    public string DataDirectory
    {
        get
        {
            string dataDirectory = _platform switch
            {
                CompanionPlatform.Windows => RequireBaseDirectory(_localApplicationData),
                CompanionPlatform.MacOS => Path.Combine(RequireBaseDirectory(_home), "Library", "Application Support"),
                CompanionPlatform.Linux => !string.IsNullOrWhiteSpace(_xdgDataHome) && Path.IsPathFullyQualified(_xdgDataHome)
                    ? _xdgDataHome
                    : Path.Combine(RequireBaseDirectory(_home), ".local", "share"),
                _ => throw new NotSupportedException("Unsupported operating system.")
            };
            return Path.Combine(dataDirectory, "ArtisanLogbook", "Companion");
        }
    }

    public string ResolveSource(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        return Path.GetFullPath(path, _workingDirectory);
    }

    private static string RequireBaseDirectory(string path) =>
        Path.IsPathFullyQualified(path) ? path :
            throw new InvalidOperationException("The user application data directory is unavailable; specify --database <path>.");
}
