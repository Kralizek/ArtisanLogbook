namespace ArtisanLogbook.Runtime;

public sealed record CompanionSettings
{
    public const int CurrentVersion = 1;

    public required int Version { get; init; }
    public required IReadOnlyList<string> InstallationRoots { get; init; }

    public static CompanionSettings ForRoots(params string[] roots) =>
        new() { Version = CurrentVersion, InstallationRoots = roots };
}

public enum SettingsStatus { Loaded, Missing, Invalid, Unsupported, Unreadable }

public sealed record SettingsLoadResult(
    SettingsStatus Status, CompanionSettings? Settings, string? Diagnostic, string? Revision = null)
{
    public bool CanSave => Status is SettingsStatus.Loaded or SettingsStatus.Missing;
}

public sealed class CompanionSettingsException(string message) : IOException(message);
