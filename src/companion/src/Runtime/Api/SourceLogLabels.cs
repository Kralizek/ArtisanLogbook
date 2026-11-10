namespace ArtisanLogbook.Runtime;

/// <summary>Presentation metadata from already discovered locations, never game identity or additional I/O.</summary>
internal static class SourceLogLabels
{
    public static IReadOnlyList<DiscoveredSource> Apply(IReadOnlyList<DiscoveredSource> sources)
    {
        Dictionary<string, string> labels = sources.ToDictionary(source => source.Id, source => source.Client);
        foreach (var clients in sources.GroupBy(source => source.Client, InstallationDiscovery.PathComparer))
        {
            if (clients.Count() == 1) continue;
            foreach (DiscoveredSource source in clients)
            {
                string? installation = new FileInfo(source.Path).Directory?.Parent?.Parent?.Parent?.Parent?.Parent?.Name;
                labels[source.Id] += " / " + installation;
            }
            foreach (var installations in clients.GroupBy(source => labels[source.Id], InstallationDiscovery.PathComparer))
            {
                if (installations.Count() == 1) continue;
                foreach (DiscoveredSource source in installations)
                {
                    string? account = new FileInfo(source.Path).Directory?.Parent?.Name;
                    labels[source.Id] += " / " + account;
                }
                foreach (var accounts in installations.GroupBy(source => labels[source.Id], InstallationDiscovery.PathComparer))
                {
                    if (accounts.Count() == 1) continue;
                    foreach (DiscoveredSource source in accounts)
                        labels[source.Id] += " / " + source.Id[^6..];
                }
            }
        }
        return sources.Select(source => source with { LogLabel = labels[source.Id] }).ToArray();
    }
}
