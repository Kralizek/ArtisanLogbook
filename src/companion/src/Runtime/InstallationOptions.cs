using System.Security.Cryptography;
using System.Text;

namespace ArtisanLogbook.Runtime;

public sealed record InstallationCandidate(string Token, string Label, bool Configured);
public sealed record InstallationOptionsSnapshot(
    string Revision, IReadOnlyList<InstallationCandidate> Candidates,
    int ConfiguredRoots, int ActiveRoots, bool RestartRequired);

/// <summary>Only server-inspected hints and already saved roots can be selected in the browser.</summary>
public sealed class InstallationOptions(
    CompanionSettingsStore settings, CompanionRuntimeConfiguration configuration,
    InstallationDiscovery discovery, InstallationCandidateHints hints, CompanionSettingsMutationGate mutations)
{
    public InstallationOptionsSnapshot Read()
    {
        lock (mutations.Gate)
        {
            SettingsLoadResult loaded = settings.Load();
            if (!loaded.CanSave) throw new CompanionSettingsException(loaded.Diagnostic!);
            return Snapshot(loaded);
        }
    }

    public InstallationOptionsSnapshot Save(string revision, IReadOnlyList<string> tokens, CancellationToken cancellationToken)
    {
        lock (mutations.Gate)
        {
            SettingsLoadResult loaded = settings.Load();
            if (!loaded.CanSave || revision != Revision(loaded))
                throw new CompanionSettingsException("Settings changed; refresh installations and retry.");
            if (tokens is null || tokens.Count > 32 || tokens.Distinct(StringComparer.Ordinal).Count() != tokens.Count)
                throw new ArgumentException("Select at most 32 distinct installation candidates.");

            var candidates = Candidates(loaded);
            if (tokens.Any(token => token is null || !candidates.ContainsKey(token)))
                throw new ArgumentException("Unknown installation candidate. Refresh and retry.");
            foreach (string token in tokens)
            {
                var (path, configured) = candidates[token];
                if (!configured && !discovery.ValidateRoot(path).Paths.Any())
                    throw new CompanionSettingsException("A detected installation is no longer available; refresh and retry.");
            }
            CompanionSettings saved = (loaded.Settings ?? CompanionSettings.ForRoots()) with
            {
                InstallationRoots = tokens.Select(token => candidates[token].Path).ToArray()
            };
            settings.Save(saved, cancellationToken, loaded);
            return Snapshot(settings.Load());
        }
    }

    private InstallationOptionsSnapshot Snapshot(SettingsLoadResult loaded)
    {
        var candidates = Candidates(loaded);
        HashSet<string> configured = new(loaded.Settings?.InstallationRoots ?? [], InstallationDiscovery.PathComparer);
        var listed = candidates.OrderBy(pair => pair.Value.Path, InstallationDiscovery.PathComparer)
            .Select((pair, index) => new InstallationCandidate(pair.Key,
                $"{(pair.Value.Configured ? "Configured" : "Detected")} installation {index + 1}",
                pair.Value.Configured)).ToArray();
        return new(Revision(loaded), listed, configured.Count, configuration.EffectiveSettings.InstallationRoots.Count,
            !configured.SetEquals(configuration.EffectiveSettings.InstallationRoots));
    }

    private Dictionary<string, (string Path, bool Configured)> Candidates(SettingsLoadResult loaded)
    {
        HashSet<string> configured = new(loaded.Settings?.InstallationRoots ?? [], InstallationDiscovery.PathComparer);
        var roots = discovery.Detect(hints.Current()).Paths
            .Concat(configured).Distinct(InstallationDiscovery.PathComparer);
        return roots.ToDictionary(Token, root => (root, configured.Contains(root)), StringComparer.Ordinal);
    }

    private static string Token(string path) => "installation_" +
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(path)))[..24].ToLowerInvariant();

    private static string Revision(SettingsLoadResult loaded) => loaded.Revision ?? "missing";
}

public sealed class CompanionSettingsMutationGate
{
    public object Gate { get; } = new();
}

public sealed class InstallationCandidateHints(Func<IReadOnlyList<string>> current)
{
    public IReadOnlyList<string> Current() => current();
}
