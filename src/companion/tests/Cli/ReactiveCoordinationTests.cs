using System.Reactive.Disposables;
using System.Reactive.Linq;
using System.Reactive.Subjects;

using ArtisanLogbook.Runtime;

using Microsoft.Reactive.Testing;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class ReactiveCoordinationTests
{
    [Test]
    public void EmptySourceCompletesWithoutStartingWork()
    {
        using Subject<IObservable<int>> work = new();
        bool completed = false;
        using IDisposable subscription = work.ConcatLatest().Subscribe(
            _ => Assert.Fail("No inner operation should run."),
            exception => Assert.Fail(exception.ToString()),
            () => completed = true);

        work.OnCompleted();

        Assert.That(completed, Is.True);
    }

    [Test]
    public void TestSchedulerRunsOneOperationAndOnlyTheLatestBurstedInvalidation()
    {
        TestScheduler scheduler = new();
        using Subject<IObservable<int>> work = new();
        List<int> started = [];
        List<int> results = [];
        bool completed = false;
        IObservable<int> Pass(int id) => Observable.Defer(() =>
        {
            started.Add(id);
            return scheduler.CreateColdObservable(
                ReactiveTest.OnNext(10, id),
                ReactiveTest.OnCompleted<int>(11));
        });
        using IDisposable subscription = work.ConcatLatest().Subscribe(
            results.Add, exception => Assert.Fail(exception.ToString()), () => completed = true);

        work.OnNext(Pass(1));
        for (int id = 2; id <= 10_000; id++) work.OnNext(Pass(id));
        work.OnCompleted();
        Assert.That(started, Is.EqualTo(new[] { 1 }));

        scheduler.AdvanceBy(11);
        Assert.That(started, Is.EqualTo(new[] { 1, 10_000 }));
        Assert.That(results, Is.EqualTo(new[] { 1 }));
        Assert.That(completed, Is.False);

        scheduler.AdvanceBy(11);
        Assert.That(results, Is.EqualTo(new[] { 1, 10_000 }));
        Assert.That(completed, Is.True);
    }

    [Test]
    public void InvalidationDuringInnerCompletionIsRetained()
    {
        using Subject<IObservable<int>> work = new();
        List<int> results = [];
        int trailingStarts = 0;
        bool completed = false;
        using IDisposable subscription = work.ConcatLatest().Subscribe(
            results.Add, exception => Assert.Fail(exception.ToString()), () => completed = true);
        IObservable<int> first = Observable.Create<int>(observer =>
        {
            work.OnNext(Observable.Defer(() =>
            {
                trailingStarts++;
                return Observable.Return(2);
            }));
            observer.OnNext(1);
            observer.OnCompleted();
            return Disposable.Empty;
        });

        work.OnNext(first);
        work.OnCompleted();

        Assert.That(results, Is.EqualTo(new[] { 1, 2 }));
        Assert.That(trailingStarts, Is.EqualTo(1));
        Assert.That(completed, Is.True);
    }

    [Test]
    public void SourceCompletionWaitsForActiveWorkThenDrainsItsTrailingOperation()
    {
        using Subject<IObservable<int>> work = new();
        using Subject<int> active = new();
        List<int> results = [];
        int trailingStarts = 0;
        bool completed = false;
        using IDisposable subscription = work.ConcatLatest().Subscribe(
            results.Add, exception => Assert.Fail(exception.ToString()), () => completed = true);
        work.OnNext(active);
        work.OnNext(Observable.Defer(() =>
        {
            trailingStarts++;
            return Observable.Return(2);
        }));
        work.OnCompleted();

        Assert.That(trailingStarts, Is.Zero);
        Assert.That(completed, Is.False);
        active.OnNext(1);
        active.OnCompleted();

        Assert.That(results, Is.EqualTo(new[] { 1, 2 }));
        Assert.That(trailingStarts, Is.EqualTo(1));
        Assert.That(completed, Is.True);
    }

    [Test]
    public void DisposalCancelsActiveWorkAndDiscardsPendingInvalidation()
    {
        using Subject<IObservable<int>> work = new();
        int activeDisposals = 0;
        int pendingStarts = 0;
        IDisposable subscription = work.ConcatLatest().Subscribe();
        work.OnNext(Observable.Never<int>().Finally(() => activeDisposals++));
        work.OnNext(Observable.Defer(() =>
        {
            pendingStarts++;
            return Observable.Return(1);
        }));

        subscription.Dispose();
        work.OnNext(Observable.Return(2));

        Assert.That(activeDisposals, Is.EqualTo(1));
        Assert.That(pendingStarts, Is.Zero);
    }

    [Test]
    public void InnerFailureIsPropagatedAndReleasesItsSubscription()
    {
        using Subject<IObservable<int>> work = new();
        InvalidOperationException failure = new("controlled inner failure");
        Exception? observed = null;
        using IDisposable subscription = work.ConcatLatest().Subscribe(
            _ => Assert.Fail("A failing inner must not emit a value."),
            exception => observed = exception);

        work.OnNext(Observable.Throw<int>(failure));
        work.OnNext(Observable.Return(2));

        Assert.That(observed, Is.SameAs(failure));
    }

    [Test]
    public void SourceFailureCancelsActiveWorkAndPropagates()
    {
        using Subject<IObservable<int>> work = new();
        InvalidOperationException failure = new("controlled source failure");
        Exception? observed = null;
        int disposed = 0;
        using IDisposable subscription = work.ConcatLatest().Subscribe(
            _ => Assert.Fail("No inner operation should emit."),
            exception => observed = exception);
        work.OnNext(Observable.Never<int>().Finally(() => disposed++));

        work.OnError(failure);

        Assert.That(observed, Is.SameAs(failure));
        Assert.That(disposed, Is.EqualTo(1));
    }

    [Test]
    public void ConcurrentProducersRetainAtMostOneTrailingOperationWithoutOverlappingInners()
    {
        IObserver<IObservable<int>>? producer = null;
        IObservable<IObservable<int>> source = Observable.Create<IObservable<int>>(observer =>
        {
            producer = observer;
            return Disposable.Empty;
        });
        using Subject<int> first = new();
        int active = 0;
        int maximumActive = 0;
        int maximumNotifications = 0;
        int notifications = 0;
        int started = 0;
        using IDisposable subscription = source.ConcatLatest().Subscribe(_ =>
        {
            int current = Interlocked.Increment(ref notifications);
            UpdateMaximum(ref maximumNotifications, current);
            Thread.SpinWait(1_000);
            Interlocked.Decrement(ref notifications);
        });
        IObserver<IObservable<int>> observer = producer!;

        observer.OnNext(Observable.Defer(() =>
        {
            started++;
            Interlocked.Increment(ref active);
            return first.Finally(() => Interlocked.Decrement(ref active));
        }));
        first.OnNext(0);
        Parallel.For(1, 2_001, id => observer.OnNext(Observable.Defer(() =>
        {
            Interlocked.Increment(ref started);
            int current = Interlocked.Increment(ref active);
            UpdateMaximum(ref maximumActive, current);
            return Observable.Return(id).Finally(() => Interlocked.Decrement(ref active));
        })));
        observer.OnCompleted();
        first.OnCompleted();

        Assert.Multiple(() =>
        {
            Assert.That(started, Is.EqualTo(2));
            Assert.That(maximumActive, Is.EqualTo(1));
            Assert.That(maximumNotifications, Is.EqualTo(1));
            Assert.That(active, Is.Zero);
        });
    }

    [Test]
    public void SynchronousAndReentrantObserversRemainSerialized()
    {
        using Subject<IObservable<int>> work = new();
        List<int> results = [];
        int active = 0;
        int maximumActive = 0;
        bool completed = false;
        using IDisposable subscription = work.ConcatLatest().Subscribe(value =>
        {
            results.Add(value);
            if (value == 1) work.OnNext(Synchronous(2));
        }, exception => Assert.Fail(exception.ToString()), () => completed = true);

        for (int id = 1; id <= 2_000; id++) work.OnNext(Synchronous(id));
        work.OnCompleted();

        Assert.That(results.Take(2), Is.EqualTo(new[] { 1, 2 }));
        Assert.That(results.Count, Is.EqualTo(2_001));
        Assert.That(results.Distinct().Count(), Is.EqualTo(2_000));
        Assert.That(maximumActive, Is.EqualTo(1));
        Assert.That(completed, Is.True);

        IObservable<int> Synchronous(int value) => Observable.Defer(() =>
        {
            int current = Interlocked.Increment(ref active);
            UpdateMaximum(ref maximumActive, current);
            return Observable.Return(value).Finally(() => Interlocked.Decrement(ref active));
        });
    }

    private static void UpdateMaximum(ref int maximum, int value)
    {
        int observed;
        do
        {
            observed = Volatile.Read(ref maximum);
            if (observed >= value) return;
        } while (Interlocked.CompareExchange(ref maximum, value, observed) != observed);
    }
}
