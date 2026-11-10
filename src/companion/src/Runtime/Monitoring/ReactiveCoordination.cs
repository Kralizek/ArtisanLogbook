using System.Reactive;
using System.Reactive.Disposables;
using System.Reactive.Linq;
using System.Reactive.Subjects;

namespace ArtisanLogbook.Runtime;

internal static class ReactiveCoordination
{
    private enum Phase { Idle, Running, Completing, Faulted, Disposed }

    /// <summary>
    /// Concat with one replaceable pending observable. Plain Concat queues without a bound;
    /// Switch cannot await cancellation. A synchronized admission stream keeps observer callbacks outside the state
    /// lock, while source failures cancel active work instead of waiting for a possibly non-terminating inner.
    /// Inner subscriptions must not perform blocking work inline.
    /// </summary>
    internal static IObservable<T> ConcatLatest<T>(this IObservable<IObservable<T>> source) =>
        Observable.Create<T>(observer =>
        {
            object gate = new();
            Phase phase = Phase.Idle;
            IObservable<T>? pending = null;
            ISubject<IObservable<T>> admitted = Subject.Synchronize(new Subject<IObservable<T>>());
            Subject<Unit> failures = new();

            IObservable<T> Advance()
            {
                IObservable<T>? next = null;
                bool complete = false;
                lock (gate)
                {
                    if (phase is Phase.Disposed or Phase.Faulted) return Observable.Empty<T>();
                    if (pending is { } queued)
                    {
                        pending = null;
                        next = queued;
                    }
                    else if (phase == Phase.Completing)
                        complete = true;
                    else
                        phase = Phase.Idle;
                }
                if (next is not null) admitted.OnNext(next);
                if (complete) admitted.OnCompleted();
                return Observable.Empty<T>();
            }

            IDisposable processing = admitted.Select(inner => inner.Concat(Observable.Defer(Advance)))
                .Concat().TakeUntil(failures).Subscribe(observer);
            IDisposable producing = source.Subscribe(inner =>
            {
                bool start = false;
                lock (gate)
                {
                    if (phase is Phase.Disposed or Phase.Completing or Phase.Faulted) return;
                    if (phase == Phase.Running)
                        pending = inner;
                    else
                    {
                        phase = Phase.Running;
                        start = true;
                    }
                }
                if (start) admitted.OnNext(inner);
            }, exception =>
            {
                lock (gate)
                {
                    if (phase is Phase.Disposed or Phase.Faulted or Phase.Completing) return;
                    phase = Phase.Faulted;
                    pending = null;
                }
                failures.OnError(exception);
            }, () =>
            {
                bool complete = false;
                lock (gate)
                {
                    if (phase is Phase.Disposed or Phase.Faulted or Phase.Completing) return;
                    complete = phase == Phase.Idle;
                    phase = Phase.Completing;
                }
                if (complete) admitted.OnCompleted();
            });
            return Disposable.Create(() =>
            {
                lock (gate)
                {
                    phase = Phase.Disposed;
                    pending = null;
                }
                producing.Dispose();
                processing.Dispose();
            });
        });

    internal static IObservable<Unit> WhenCancelled(this CancellationToken token) =>
        Observable.Create<Unit>(observer => token.Register(() =>
        {
            observer.OnNext(Unit.Default);
            observer.OnCompleted();
        }));
}
