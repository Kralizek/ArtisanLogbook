using Microsoft.Extensions.Logging;

namespace ArtisanLogbook.Runtime;

/// <summary>Stable operational event identities for application log consumers.</summary>
public static class CompanionEvents
{
    public static readonly EventId Started = new(6100, nameof(Started));
    public static readonly EventId MonitoringPreference = new(6101, nameof(MonitoringPreference));
    public static readonly EventId ReconciliationInterval = new(6102, nameof(ReconciliationInterval));
    public static readonly EventId Listening = new(6103, nameof(Listening));
    public static readonly EventId Installation = new(6104, nameof(Installation));
    public static readonly EventId InstalledFlavors = new(6105, nameof(InstalledFlavors));
    public static readonly EventId Stopped = new(6106, nameof(Stopped));
    public static readonly EventId NoInstallations = new(6107, nameof(NoInstallations));
}
