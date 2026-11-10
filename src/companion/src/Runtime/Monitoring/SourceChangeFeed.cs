using System.Reactive;
using System.Reactive.Concurrency;
using System.Reactive.Linq;
using System.Security;

using Microsoft.Extensions.Logging;

namespace ArtisanLogbook.Runtime;

[Flags]
internal enum SourceChangeReason
{
    None = 0, Activated = 1, FileSystem = 2, Periodic = 4, Requested = 8,
    WatcherUnavailable = 16, WatcherReady = 32, Checkpoint = 64
}
internal sealed record SourceInvalidation(SourceChangeReason Reason, string? Key = null);

/// <summary>Cold event producers. Each subscription owns all its watchers, groups and timers.</summary>
internal class SourceChangeFeed(IScheduler scheduler, ILogger<SourceChangeFeed> logger)
{
    internal static TimeSpan Debounce { get; } = TimeSpan.FromMilliseconds(250);
    internal static TimeSpan GroupIdle { get; } = TimeSpan.FromSeconds(30);
    internal static TimeSpan WatcherRetry { get; } = TimeSpan.FromSeconds(2);

    public IObservable<SourceInvalidation> Observe(
        IReadOnlyList<string> roots, TimeSpan interval, IObservable<Unit> requests)
    {
        IObservable<SourceInvalidation> watchers = roots.Select(RecoveringRoot).Merge();
        return Observable.Merge(
            watchers.Publish(shared => Observable.Merge(
                Coalesce(shared.Where(change => change.Reason == SourceChangeReason.FileSystem))
                    .Do(change => logger.LogDebug(MonitoringEvents.FileChanged,
                        "Filesystem change detected for {SourceId}.", change.Key)),
                shared.Where(change => change.Reason != SourceChangeReason.FileSystem))),
            Observable.Interval(interval, scheduler).Select(_ => new SourceInvalidation(SourceChangeReason.Periodic)),
            requests.Select(_ => new SourceInvalidation(SourceChangeReason.Requested)))
            .StartWith(new SourceInvalidation(SourceChangeReason.Activated));
    }

    internal IObservable<SourceInvalidation> Coalesce(IObservable<SourceInvalidation> changes) =>
        changes.GroupByUntil(change => change.Key, group => group.Throttle(GroupIdle, scheduler))
            .SelectMany(group => group.Throttle(Debounce, scheduler));

    private IObservable<SourceInvalidation> RecoveringRoot(string root) => Observable.Defer(() =>
    {
        bool unavailable = false;
        int attempt = 0;
        bool ready = false;
        string rootId = SourceCatalog.IdFor(root);
        return Observable.Defer(() =>
            {
                int subscription = ++attempt;
                ready = false;
                logger.LogDebug(MonitoringEvents.WatcherSubscribed,
                    "Subscribing filesystem watcher for {RootId} ({RootLabel}), attempt {WatcherAttempt}.",
                    rootId, root, subscription);
                return Observable.Defer(() => WatchRoot(root)).Finally(() => logger.LogDebug(MonitoringEvents.WatcherDisposed,
                    "Filesystem watcher subscription disposed for {RootId} ({RootLabel}), attempt {WatcherAttempt}.",
                    rootId, root, subscription));
            })
            .Do(change =>
            {
                if (change.Reason != SourceChangeReason.WatcherReady) return;
                ready = true;
                logger.LogInformation(MonitoringEvents.WatcherReady,
                    "Filesystem watcher {WatcherState} for {RootId} ({RootLabel}).",
                    unavailable ? "recovered" : "ready", rootId, root);
                unavailable = false;
            })
            .Catch<SourceInvalidation, Exception>(exception =>
            {
                if (!IsFileSystemFailure(exception)) return Observable.Throw<SourceInvalidation>(exception);
                if (!unavailable)
                    logger.LogWarning(MonitoringEvents.WatcherUnavailable,
                        "Filesystem watcher unavailable for {RootId} ({RootLabel}, {ExceptionType}); retrying every {RetrySeconds} seconds; periodic discovery remains active.",
                        rootId, root, exception.GetType().Name, WatcherRetry.TotalSeconds);
                logger.LogDebug(exception,
                    "Filesystem watcher failure detail for {RootId} ({RootLabel}): {ExceptionType}, HResult {HResult}, stage {WatcherStage}, attempt {WatcherAttempt}.",
                    rootId, root, exception.GetType().Name, exception.HResult, ready ? "Watching" : "Subscription", attempt);
                unavailable = true;
                return Observable.Return(new SourceInvalidation(SourceChangeReason.WatcherUnavailable, rootId))
                    .Concat(Observable.Empty<SourceInvalidation>().DelaySubscription(WatcherRetry, scheduler));
            }).Repeat();
    });

    protected virtual IObservable<SourceInvalidation> WatchRoot(string root) =>
        Observable.Using(() => CreateWatcher(root), watcher => Observable.Create<SourceInvalidation>(observer =>
        {
            IObserver<SourceInvalidation> serialized = Observer.Synchronize(observer);
            IObservable<FileSystemEventArgs> events = Observable.Merge(
                Observable.FromEventPattern<FileSystemEventHandler, FileSystemEventArgs>(
                    h => watcher.Changed += h, h => watcher.Changed -= h).Select(e => e.EventArgs),
                Observable.FromEventPattern<FileSystemEventHandler, FileSystemEventArgs>(
                    h => watcher.Created += h, h => watcher.Created -= h).Select(e => e.EventArgs),
                Observable.FromEventPattern<FileSystemEventHandler, FileSystemEventArgs>(
                    h => watcher.Deleted += h, h => watcher.Deleted -= h).Select(e => e.EventArgs),
                Observable.FromEventPattern<RenamedEventHandler, RenamedEventArgs>(
                    h => watcher.Renamed += h, h => watcher.Renamed -= h).Select(e => (FileSystemEventArgs)e.EventArgs),
                Observable.FromEventPattern<ErrorEventHandler, ErrorEventArgs>(
                    h => watcher.Error += h, h => watcher.Error -= h)
                    .Do(e =>
                    {
                        Exception exception = e.EventArgs.GetException();
                        logger.LogDebug(MonitoringEvents.WatcherNativeError,
                            "Native filesystem watcher error for {RootId} ({RootLabel}): {ExceptionType}, HResult {HResult}, buffer {BufferBytes} bytes, recursive {Recursive}, filters {NotifyFilter}.",
                            SourceCatalog.IdFor(root), root, exception.GetType().Name, exception.HResult,
                            watcher.InternalBufferSize, watcher.IncludeSubdirectories, watcher.NotifyFilter);
                    })
                    .SelectMany(e => Observable.Throw<FileSystemEventArgs>(e.EventArgs.GetException())));
            IDisposable subscription = events.SelectMany(change => Paths(change)
                .Select(path => Invalidate(root, path, change.ChangeType))
                .OfType<SourceInvalidation>()).Subscribe(serialized);
            try
            {
                watcher.EnableRaisingEvents = true;
                serialized.OnNext(new(SourceChangeReason.WatcherReady, SourceCatalog.IdFor(root)));
            }
            catch (Exception exception) when (IsFileSystemFailure(exception))
            {
                serialized.OnError(exception);
            }
            return subscription;
        }));

    protected virtual FileSystemWatcher CreateWatcher(string root)
    {
        for (DirectoryInfo? ancestor = new(root); ancestor is not null; ancestor = ancestor.Parent)
            if ((File.GetAttributes(ancestor.FullName) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Monitoring does not follow linked installation roots.");
        return new(root)
        {
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size
        };
    }

    private static IEnumerable<string> Paths(FileSystemEventArgs change) =>
        change is RenamedEventArgs renamed ? [renamed.OldFullPath, renamed.FullPath] : [change.FullPath];

    private static SourceInvalidation? Invalidate(string root, string path, WatcherChangeTypes kind)
    {
        string[] parts = Path.GetRelativePath(root, path).Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        bool prefix = parts.Length is >= 1 and <= 6 && parts[0] != ".." &&
            (parts.Length < 2 || InstallationDiscovery.PathComparer.Equals(parts[1], "WTF")) &&
            (parts.Length < 3 || InstallationDiscovery.PathComparer.Equals(parts[2], "Account")) &&
            (parts.Length < 5 || InstallationDiscovery.PathComparer.Equals(parts[4], "SavedVariables"));
        if (!prefix) return null;
        if (parts.Length == 6)
            return InstallationDiscovery.PathComparer.Equals(parts[5], "ArtisanLogbook_Core.lua")
                ? new(SourceChangeReason.FileSystem, SourceCatalog.IdFor(path)) : null;
        return kind != WatcherChangeTypes.Changed
            ? new(SourceChangeReason.FileSystem, SourceCatalog.IdFor(root)) : null;
    }

    private static bool IsFileSystemFailure(Exception exception) =>
        exception is IOException or UnauthorizedAccessException or SecurityException or ArgumentException or InternalBufferOverflowException;
}
