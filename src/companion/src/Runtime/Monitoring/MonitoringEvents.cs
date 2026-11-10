using Microsoft.Extensions.Logging;

namespace ArtisanLogbook.Runtime;

internal static class MonitoringEvents
{
    public static readonly EventId Enabled = new(6000, nameof(Enabled));
    public static readonly EventId Disabled = new(6001, nameof(Disabled));
    public static readonly EventId Stopped = new(6002, nameof(Stopped));
    public static readonly EventId Stopping = new(6003, nameof(Stopping));
    public static readonly EventId ReconciliationStarted = new(6010, nameof(ReconciliationStarted));
    public static readonly EventId ReconciliationCompleted = new(6011, nameof(ReconciliationCompleted));
    public static readonly EventId ReconciliationFailed = new(6012, nameof(ReconciliationFailed));
    public static readonly EventId CompositionFailed = new(6013, nameof(CompositionFailed));
    public static readonly EventId SourceInspectionFailed = new(6020, nameof(SourceInspectionFailed));
    public static readonly EventId SourceUnchanged = new(6021, nameof(SourceUnchanged));
    public static readonly EventId FingerprintSuperseded = new(6022, nameof(FingerprintSuperseded));
    public static readonly EventId FileChanged = new(6030, nameof(FileChanged));
    public static readonly EventId WatcherUnavailable = new(6031, nameof(WatcherUnavailable));
    public static readonly EventId WatcherReady = new(6032, nameof(WatcherReady));
    public static readonly EventId CheckpointSaveFailed = new(6040, nameof(CheckpointSaveFailed));
    public static readonly EventId CheckpointSaveRecovered = new(6041, nameof(CheckpointSaveRecovered));
    public static readonly EventId AutomaticImportAdmitted = new(6050, nameof(AutomaticImportAdmitted));
    public static readonly EventId ImportCompleted = new(6051, nameof(ImportCompleted));
}
