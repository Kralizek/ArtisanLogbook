using System.Reactive;
using System.Reactive.Disposables;
using System.Reactive.Linq;
using System.Reactive.Subjects;

namespace ArtisanLogbook.Runtime;

internal sealed class SerializedNotifications(object gate)
{
    private readonly Queue<Action> _notifications = [];
    private bool _draining;

    public bool Enqueue(Action notification)
    {
        lock (gate)
        {
            _notifications.Enqueue(notification);
            if (_draining) return false;
            _draining = true;
            return true;
        }
    }

    public void Drain()
    {
        while (true)
        {
            Action? notification;
            lock (gate)
            {
                if (!_notifications.TryDequeue(out notification))
                {
                    _draining = false;
                    return;
                }
            }

            try { notification(); }
            catch
            {
                lock (gate) _draining = false;
                throw;
            }
        }
    }

    public void Clear()
    {
        lock (gate) _notifications.Clear();
    }
}

internal static class ReactiveCoordination
{
    private enum Phase { Idle, Running, Completing, Faulted, Disposed }

    /// <summary>
    /// Concat with one replaceable pending observable. Plain Concat queues without a bound;
    /// Switch cannot await cancellation. Notifications are queued in state-transition order and drained outside the
    /// state lock; source failures cancel active work instead of waiting for a possibly non-terminating inner.
    /// Inner subscriptions must not perform blocking work inline.
    /// </summary>
    internal static IObservable<T> ConcatLatest<T>(this IObservable<IObservable<T>> source) =>
        Observable.Create<T>(observer =>
        {
            object gate = new();
            Phase phase = Phase.Idle;
            IObservable<T>? pending = null;
            SerializedNotifications notifications = new(gate);
            Subject<IObservable<T>> admitted = new();
            Subject<Exception> failures = new();

            IObservable<T> Advance()
            {
                bool drain = false;
                lock (gate)
                {
                    if (phase is Phase.Disposed or Phase.Faulted) return Observable.Empty<T>();
                    if (pending is { } queued)
                    {
                        pending = null;
                        drain = notifications.Enqueue(() => admitted.OnNext(queued));
                    }
                    else if (phase == Phase.Completing)
                        drain = notifications.Enqueue(admitted.OnCompleted);
                    else
                        phase = Phase.Idle;
                }
                if (drain) notifications.Drain();
                return Observable.Empty<T>();
            }

            IDisposable processing = admitted.Select(inner => inner.Concat(Observable.Defer(Advance)))
                .Concat().TakeUntil(failures.SelectMany(exception => Observable.Throw<Unit>(exception)))
                .Subscribe(observer);
            IDisposable producing = source.Subscribe(inner =>
            {
                bool drain = false;
                lock (gate)
                {
                    if (phase is Phase.Disposed or Phase.Completing or Phase.Faulted) return;
                    if (phase == Phase.Running)
                        pending = inner;
                    else
                    {
                        phase = Phase.Running;
                        drain = notifications.Enqueue(() => admitted.OnNext(inner));
                    }
                }
                if (drain) notifications.Drain();
            }, exception =>
            {
                bool drain;
                lock (gate)
                {
                    if (phase is Phase.Disposed or Phase.Faulted or Phase.Completing) return;
                    phase = Phase.Faulted;
                    pending = null;
                    drain = notifications.Enqueue(() => failures.OnNext(exception));
                }
                if (drain) notifications.Drain();
            }, () =>
            {
                bool drain = false;
                lock (gate)
                {
                    if (phase is Phase.Disposed or Phase.Faulted or Phase.Completing) return;
                    bool idle = phase == Phase.Idle;
                    phase = Phase.Completing;
                    if (idle)
                        drain = notifications.Enqueue(admitted.OnCompleted);
                }
                if (drain) notifications.Drain();
            });
            return Disposable.Create(() =>
            {
                lock (gate)
                {
                    phase = Phase.Disposed;
                    pending = null;
                    notifications.Clear();
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
