namespace ArtisanLogbook.Runtime;

public sealed record CompanionInvocationOverrides(
    string? Database = null, bool? Monitoring = null, int? ReconciliationIntervalSeconds = null, int? Port = null);

/// <summary>Internal configuration snapshot with saved preferences and invocation-only overrides kept separate.</summary>
public sealed record CompanionRuntimeConfiguration
{
    public string DatabasePath { get; }
    public CompanionSettings? PersistedPreferences { get; }
    public CompanionInvocationOverrides InvocationOverrides { get; }
    public CompanionSettings EffectiveSettings { get; }

    private CompanionRuntimeConfiguration(
        string databasePath, CompanionSettings? persistedPreferences, CompanionInvocationOverrides overrides)
    {
        DatabasePath = databasePath;
        PersistedPreferences = persistedPreferences is null ? null : CompanionSettingsStore.Validate(persistedPreferences);
        InvocationOverrides = overrides;
        CompanionSettings preferences = PersistedPreferences ?? CompanionSettings.ForRoots();
        EffectiveSettings = CompanionSettingsStore.Validate(preferences with
        {
            Monitoring = preferences.Monitoring with
            {
                Enabled = overrides.Monitoring ?? preferences.Monitoring.Enabled,
                ReconciliationIntervalSeconds = overrides.ReconciliationIntervalSeconds ??
                    preferences.Monitoring.ReconciliationIntervalSeconds
            },
            Http = preferences.Http with { PreferredPort = overrides.Port ?? preferences.Http.PreferredPort }
        });
    }

    /// <summary>Pure resolution of a new saved snapshot; explicit invocation overrides remain authoritative.</summary>
    public CompanionRuntimeConfiguration WithPersistedPreferences(CompanionSettings? preferences) =>
        new(DatabasePath, preferences, InvocationOverrides);

    public static CompanionRuntimeConfiguration Resolve(
        ApplicationPaths paths, CompanionSettingsStore store, string? database = null,
        bool? monitoring = null, int? reconciliationIntervalSeconds = null, int? port = null)
    {
        SettingsLoadResult loaded = store.Load();
        if (!loaded.CanSave)
            throw new CompanionSettingsException(loaded.Diagnostic!);
        return new(paths.ResolveDatabase(database), loaded.Settings,
            new(database, monitoring, reconciliationIntervalSeconds, port));
    }
}
