using System.Reactive;
using System.Reactive.Linq;
using System.Reactive.Subjects;

using ArtisanLogbook.Runtime;

using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Reactive.Testing;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class ReactiveMonitoringTests
{
    [Test]
    public void ClientBurstsSettleIndependentlyAndIdleGroupsCanBeRecreated()
    {
        TestScheduler scheduler = new();
        SourceChangeFeed feed = new(scheduler, NullLogger<SourceChangeFeed>.Instance);
        using Subject<SourceInvalidation> changes = new();
        List<(string? Key, long At)> observed = [];
        using IDisposable subscription = feed.Coalesce(changes).Subscribe(change => observed.Add((change.Key, scheduler.Clock)));
        changes.OnNext(new(SourceChangeReason.FileSystem, "retail"));
        scheduler.AdvanceBy(TimeSpan.FromMilliseconds(100).Ticks);
        changes.OnNext(new(SourceChangeReason.FileSystem, "classic"));
        scheduler.AdvanceBy(TimeSpan.FromMilliseconds(100).Ticks);
        changes.OnNext(new(SourceChangeReason.FileSystem, "retail"));
        scheduler.AdvanceBy(TimeSpan.FromMilliseconds(150).Ticks);
        Assert.That(observed, Is.EqualTo(new[] { ("classic", TimeSpan.FromMilliseconds(350).Ticks) }));
        scheduler.AdvanceBy(TimeSpan.FromMilliseconds(100).Ticks);
        Assert.That(observed[1], Is.EqualTo(("retail", TimeSpan.FromMilliseconds(450).Ticks)));

        scheduler.AdvanceBy(SourceChangeFeed.GroupIdle.Ticks);
        changes.OnNext(new(SourceChangeReason.FileSystem, "classic"));
        scheduler.AdvanceBy(SourceChangeFeed.Debounce.Ticks);
        Assert.That(observed.Select(value => value.Key), Is.EqualTo(new[] { "classic", "retail", "classic" }));
    }

    [Test]
    public void HundredThousandInvalidationsRetainOnlyOneTrailingPassAndCompletionDrainsIt()
    {
        TestScheduler scheduler = new();
        using Subject<IObservable<int>> work = new();
        List<int> started = [];
        List<int> finished = [];
        bool completed = false;
        using IDisposable subscription = work.ConcatLatest().Subscribe(finished.Add, () => completed = true);
        IObservable<int> Pass(int id) => Observable.Defer(() =>
        {
            started.Add(id);
            return scheduler.CreateColdObservable(ReactiveTest.OnNext(10, id), ReactiveTest.OnCompleted<int>(10));
        });
        work.OnNext(Pass(0));
        for (int i = 1; i <= 100_000; i++) work.OnNext(Pass(i));
        work.OnCompleted();
        Assert.That(started, Is.EqualTo(new[] { 0 }));
        scheduler.AdvanceBy(10);
        Assert.That(started, Is.EqualTo(new[] { 0, 100_000 }));
        Assert.That(completed, Is.False);
        scheduler.AdvanceBy(10);
        Assert.That(finished, Is.EqualTo(new[] { 0, 100_000 }));
        Assert.That(completed, Is.True);
    }

    [Test]
    public void DisposalCancelsActiveSubscriptionAndDiscardsPendingWork()
    {
        using Subject<IObservable<int>> work = new();
        int disposed = 0;
        int pendingStarted = 0;
        IDisposable subscription = work.ConcatLatest().Subscribe();
        work.OnNext(Observable.Never<int>().Finally(() => disposed++));
        work.OnNext(Observable.Defer(() =>
        {
            pendingStarted++;
            return Observable.Return(1);
        }));
        subscription.Dispose();
        Assert.That(disposed, Is.EqualTo(1));
        Assert.That(pendingStarted, Is.Zero);
        work.OnNext(Observable.Return(2));
        Assert.That(pendingStarted, Is.Zero);
    }

    [Test]
    public void PerOperationCatchKeepsLaterReconciliationAlive()
    {
        using Subject<IObservable<int>> work = new();
        List<int> results = [];
        using IDisposable subscription = work.Select(operation => operation.Catch(Observable.Return(-1)))
            .ConcatLatest().Subscribe(results.Add);
        work.OnNext(Observable.Throw<int>(new IOException("controlled failure")));
        work.OnNext(Observable.Return(2));
        Assert.That(results, Is.EqualTo(new[] { -1, 2 }));
    }

    [Test]
    public async Task ConcurrentCompletionAndInvalidationNeverLoseWorkOrOverlap()
    {
        for (int iteration = 0; iteration < 100; iteration++)
        {
            using Subject<IObservable<Unit>> work = new();
            using Subject<Unit> first = new();
            using ManualResetEventSlim race = new();
            TaskCompletionSource completed = new(TaskCreationOptions.RunContinuationsAsynchronously);
            int active = 0;
            int trailing = 0;
            using IDisposable subscription = work.ConcatLatest().Subscribe(_ => { },
                exception => completed.TrySetException(exception), () => completed.TrySetResult());
            work.OnNext(Observable.Defer(() =>
            {
                Assert.That(Interlocked.Increment(ref active), Is.EqualTo(1));
                return first.Do(_ => { }, () => Interlocked.Decrement(ref active));
            }));
            Task finish = Task.Run(() => { race.Wait(); first.OnCompleted(); });
            Task invalidate = Task.Run(() =>
            {
                race.Wait();
                work.OnNext(Observable.Defer(() =>
                {
                    Assert.That(Interlocked.Increment(ref active), Is.EqualTo(1));
                    Interlocked.Increment(ref trailing);
                    return Observable.Return(Unit.Default).Do(_ => { }, () => Interlocked.Decrement(ref active));
                }));
            });
            race.Set();
            await Task.WhenAll(finish, invalidate).WaitAsync(TimeSpan.FromSeconds(10));
            work.OnCompleted();
            await completed.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.That(trailing, Is.EqualTo(1), $"lost invalidation at iteration {iteration}");
            Assert.That(active, Is.Zero);
        }
    }

    [Test]
    public void WatcherFailureRetriesAndShutdownDisposesBothWatcherAndBackoff()
    {
        TestScheduler scheduler = new();
        ControlledFeed feed = new(scheduler) { Failure = new IOException("unavailable root") };
        using Subject<Unit> requests = new();
        List<SourceChangeReason> reasons = [];
        IDisposable subscription = feed.Observe(["/root"], TimeSpan.FromMinutes(1), requests)
            .Subscribe(signal => reasons.Add(signal.Reason));
        Assert.That(feed.Attempts, Is.EqualTo(1));
        Assert.That(reasons, Does.Contain(SourceChangeReason.WatcherUnavailable));
        feed.Failure = null;
        scheduler.AdvanceBy(SourceChangeFeed.WatcherRetry.Ticks);
        Assert.That(feed.Attempts, Is.EqualTo(2));
        Assert.That(feed.Subscriptions, Is.EqualTo(1));
        Assert.That(reasons, Does.Contain(SourceChangeReason.WatcherReady));
        requests.OnNext(Unit.Default);
        Assert.That(reasons.Last(), Is.EqualTo(SourceChangeReason.Requested));
        scheduler.AdvanceBy(TimeSpan.FromMinutes(1).Ticks);
        Assert.That(reasons, Does.Contain(SourceChangeReason.Periodic));
        subscription.Dispose();
        Assert.That(feed.Subscriptions, Is.Zero);
        int count = reasons.Count;
        scheduler.AdvanceBy(TimeSpan.FromDays(1).Ticks);
        Assert.That(reasons, Has.Count.EqualTo(count));

        feed.Failure = new IOException("unavailable again");
        IDisposable backoff = feed.Observe(["/root"], TimeSpan.FromMinutes(1), requests).Subscribe();
        int attempts = feed.Attempts;
        backoff.Dispose();
        scheduler.AdvanceBy(TimeSpan.FromDays(1).Ticks);
        Assert.That(feed.Attempts, Is.EqualTo(attempts), "disposed backoff must not reconnect");
    }

    internal sealed class ControlledFeed(TestScheduler scheduler, ILogger<SourceChangeFeed>? logger = null)
        : SourceChangeFeed(scheduler, logger ?? NullLogger<SourceChangeFeed>.Instance)
    {
        private int _subscriptions;
        private int _attempts;
        public Subject<SourceInvalidation> Events { get; } = new();
        public Exception? Failure { get; set; }
        public int Subscriptions => Volatile.Read(ref _subscriptions);
        public int Attempts => Volatile.Read(ref _attempts);

        protected override IObservable<SourceInvalidation> WatchRoot(string root) => Observable.Defer(() =>
        {
            Interlocked.Increment(ref _attempts);
            if (Failure is not null) return Observable.Throw<SourceInvalidation>(Failure);
            Interlocked.Increment(ref _subscriptions);
            return Observable.Return(new SourceInvalidation(SourceChangeReason.WatcherReady, SourceCatalog.IdFor(root)))
                .Concat(Events).Finally(() => Interlocked.Decrement(ref _subscriptions));
        });
    }
}
