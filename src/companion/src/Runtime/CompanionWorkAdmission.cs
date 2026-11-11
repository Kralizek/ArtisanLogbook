using Microsoft.Extensions.Logging;

namespace ArtisanLogbook.Runtime;

/// <summary>Application-level admission only; no queue or import scheduling. Hold a lease until work finishes or rolls back.</summary>
public sealed class CompanionWorkAdmission(ILogger<CompanionWorkAdmission> logger)
{
    private readonly object _gate = new();
    private AdmissionState _state;
    private int _active;
    private TaskCompletionSource _drained = Completed();

    public IDisposable Admit()
    {
        lock (_gate)
        {
            if (_state != AdmissionState.Accepting)
            {
                logger.LogWarning("Runtime work rejected: application is not accepting new work.");
                throw new InvalidOperationException("The Companion is not accepting new work; it has not started or is stopping.");
            }
            if (_active++ == 0) _drained = new(TaskCreationOptions.RunContinuationsAsynchronously);
            return new Lease(this);
        }
    }

    internal void Open()
    {
        lock (_gate)
        {
            if (_state == AdmissionState.Created) _state = AdmissionState.Accepting;
        }
    }

    internal void StopAccepting()
    {
        lock (_gate)
            _state = AdmissionState.Stopping;
    }

    internal Task DrainAsync(CancellationToken cancellationToken)
    {
        lock (_gate)
            return _drained.Task.WaitAsync(cancellationToken);
    }

    private void Release()
    {
        lock (_gate)
        {
            if (--_active == 0) _drained.TrySetResult();
        }
    }

    private static TaskCompletionSource Completed()
    {
        TaskCompletionSource result = new(TaskCreationOptions.RunContinuationsAsynchronously);
        result.SetResult();
        return result;
    }

    private enum AdmissionState { Created, Accepting, Stopping }

    private sealed class Lease(CompanionWorkAdmission owner) : IDisposable
    {
        private CompanionWorkAdmission? _owner = owner;
        public void Dispose() => Interlocked.Exchange(ref _owner, null)?.Release();
    }
}
