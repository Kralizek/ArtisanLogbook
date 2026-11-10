using System.Reactive;
using System.Reactive.Disposables;
using System.Reactive.Linq;
using System.Reactive.Subjects;

namespace ArtisanLogbook.Runtime;

internal static class ReactiveCoordination
{
    private enum Phase { Idle, Running, Completing, Disposed }

    /// <summary>
    /// Concat with one replaceable pending observable. Plain Concat queues without a bound;
    /// Switch cannot await cancellation. Inner subscriptions must not perform blocking work inline.
    /// </summary>
    internal static IObservable<T> ConcatLatest<T>(this IObservable<IObservable<T>> source) =>
        Observable.Create<T>(observer =>
        {
            object gate = new();
            Phase phase = Phase.Idle;
            IObservable<T>? pending = null;
            Subject<IObservable<T>> admitted = new();

            IObservable<T> Advance()
            {
                lock (gate)
                {
                    if (phase == Phase.Disposed) return Observable.Empty<T>();
                    if (pending is { } next)
                    {
                        pending = null;
                        admitted.OnNext(next);
                    }
                    else if (phase == Phase.Completing)
                        admitted.OnCompleted();
                    else
                        phase = Phase.Idle;
                }
                return Observable.Empty<T>();
            }

            IDisposable processing = admitted.Select(inner => inner.Concat(Observable.Defer(Advance)))
                .Concat().Subscribe(observer);
            IDisposable producing = source.Subscribe(inner =>
            {
                lock (gate)
                {
                    if (phase is Phase.Disposed or Phase.Completing) return;
                    if (phase == Phase.Running)
                        pending = inner;
                    else
                    {
                        phase = Phase.Running;
                        admitted.OnNext(inner);
                    }
                }
            }, observer.OnError, () =>
            {
                lock (gate)
                {
                    if (phase == Phase.Disposed) return;
                    if (phase == Phase.Idle) admitted.OnCompleted();
                    else phase = Phase.Completing;
                }
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
                admitted.Dispose();
            });
        });

    internal static IObservable<Unit> WhenCancelled(this CancellationToken token) =>
        Observable.Create<Unit>(observer => token.Register(() =>
        {
            observer.OnNext(Unit.Default);
            observer.OnCompleted();
        }));
}
