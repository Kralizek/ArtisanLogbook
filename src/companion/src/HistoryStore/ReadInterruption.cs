using DuckDB.NET.Data;

namespace ArtisanLogbook.HistoryStore;

/// <summary>Connection-local interrupt signaling, stopped before transaction cleanup.</summary>
internal sealed class ReadInterruption : IDisposable
{
    private readonly Lock _gate = new();
    private readonly DuckDBCommand _command;
    private readonly Timer _retry;
    private readonly CancellationTokenRegistration _registration;
    private bool _stopped;

    internal ReadInterruption(DuckDBConnection connection, CancellationToken token)
    {
        _command = connection.CreateCommand();
        _retry = new Timer(_ => Interrupt(), null, Timeout.Infinite, Timeout.Infinite);
        _registration = token.UnsafeRegister(_ =>
        {
            lock (_gate)
            {
                if (_stopped) return;
                _command.Cancel();
                // Query startup resets DuckDB's interrupt flag. Retry covers cancellation racing with startup.
                _retry.Change(TimeSpan.FromMilliseconds(10), TimeSpan.FromMilliseconds(10));
            }
        }, null);
    }

    private void Interrupt()
    {
        lock (_gate)
        {
            if (!_stopped) _command.Cancel();
        }
    }

    public void Dispose()
    {
        _registration.Dispose();
        lock (_gate)
        {
            _stopped = true;
            _retry.Dispose();
            _command.Dispose();
        }
    }
}
