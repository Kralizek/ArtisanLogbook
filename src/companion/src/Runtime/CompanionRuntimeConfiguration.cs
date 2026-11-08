namespace ArtisanLogbook.Runtime;

/// <summary>Validated invocation settings; resolving overrides never writes settings.</summary>
public sealed record CompanionRuntimeConfiguration(string DatabasePath, CompanionSettings Settings)
{
    public static CompanionRuntimeConfiguration Resolve(
        ApplicationPaths paths, CompanionSettingsStore store, string? database = null,
        bool? monitoring = null, int? reconciliationIntervalSeconds = null, int? port = null)
    {
        SettingsLoadResult loaded = store.Load();
        if (!loaded.CanSave)
            throw new CompanionSettingsException(loaded.Diagnostic!);
        CompanionSettings settings = loaded.Settings ?? CompanionSettings.ForRoots();
        settings = settings with
        {
            Monitoring = settings.Monitoring with
            {
                Enabled = monitoring ?? settings.Monitoring.Enabled,
                ReconciliationIntervalSeconds = reconciliationIntervalSeconds ??
                    settings.Monitoring.ReconciliationIntervalSeconds
            },
            Http = settings.Http with { PreferredPort = port ?? settings.Http.PreferredPort }
        };
        return new(paths.ResolveDatabase(database), CompanionSettingsStore.Validate(settings));
    }
}
