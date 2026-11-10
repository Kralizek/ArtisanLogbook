using System.Collections.Immutable;

namespace ArtisanLogbook.Runtime;

internal sealed record CheckpointSnapshot(
    CheckpointDocument Document, long Revision = 0, long AcknowledgedRevision = 0, string? PersistenceFailure = null)
{
    public bool IsDirty => Revision != AcknowledgedRevision;
}

/// <summary>Durable acknowledgement belongs here, not to Rx delivery or C11's evictable operation history.</summary>
internal sealed class MonitoringCheckpoints : IDisposable
{
    public const int MaximumSources = 4096;
    public static TimeSpan RetryDelay { get; } = TimeSpan.FromSeconds(2);

    private readonly object _gate = new();
    private readonly SemaphoreSlim _persistence = new(1);
    private readonly MonitoringCheckpointStore _store;
    private readonly int _maximumSources;
    private CheckpointSnapshot _state;

    public MonitoringCheckpoints(MonitoringCheckpointStore store, int maximumSources = MaximumSources)
    {
        _store = store;
        _maximumSources = maximumSources;
        _state = new(store.Load());
    }

    public event EventHandler? CompletionRecorded;

    public CheckpointSnapshot Read()
    {
        lock (_gate) return _state;
    }

    public bool TryReserve(IReadOnlyList<string> sourceIds, DateTimeOffset now, out IReadOnlyDictionary<string, long> attempts)
    {
        lock (_gate)
        {
            if (_state.Document.Sources.Count + sourceIds.Distinct().Count(id => !_state.Document.Sources.ContainsKey(id)) > _maximumSources)
            {
                attempts = ImmutableDictionary<string, long>.Empty;
                return false;
            }
            ImmutableDictionary<string, SourceCheckpoint>.Builder sources = _state.Document.Sources.ToBuilder();
            Dictionary<string, long> reserved = [];
            long sequence = _state.Document.NextSequence;
            foreach (string id in sourceIds)
            {
                SourceCheckpoint checkpoint = sources.GetValueOrDefault(id) ?? new();
                reserved[id] = checked(++sequence);
                sources[id] = checkpoint with
                {
                    LastAttempt = new(sequence, checkpoint.Observed, CheckpointAttemptOutcome.Pending, now)
                };
            }
            _state = _state with
            {
                Document = _state.Document with { NextSequence = sequence, Sources = sources.ToImmutable() },
                Revision = _state.Revision + 1
            };
            attempts = reserved;
            return true;
        }
    }

    public SourceCheckpoint Observe(string id, string fingerprint)
    {
        lock (_gate)
        {
            SourceCheckpoint checkpoint = GetOrCreate(id).Observe(fingerprint);
            Set(id, checkpoint);
            return checkpoint;
        }
    }

    public void InspectionFailed(string id, string code, DateTimeOffset now)
    {
        lock (_gate)
            Set(id, GetOrCreate(id) with { InspectionFailure = code, RetryAfter = now + RetryDelay });
    }

    public void Complete(string id, long sequence, CheckpointAttemptOutcome outcome, string? fingerprint, DateTimeOffset now)
    {
        if (outcome == CheckpointAttemptOutcome.Successful && fingerprint is null)
            throw new InvalidOperationException("C07 did not identify the successfully imported bytes.");
        lock (_gate)
        {
            SourceCheckpoint checkpoint = _state.Document.Sources[id];
            if (sequence > _state.Document.NextSequence)
                throw new InvalidOperationException("An import completion must refer to a reserved attempt.");
            ImportReceipt receipt = new(sequence, fingerprint ?? checkpoint.LastAttempt?.Fingerprint, outcome, now);
            Set(id, checkpoint.Complete(receipt, RetryDelay));
        }
        CompletionRecorded?.Invoke(this, EventArgs.Empty);
    }

    public bool NeedsMaintenance(DateTimeOffset now, bool monitoringEnabled)
    {
        lock (_gate)
            return _state.IsDirty || (monitoringEnabled && _state.Document.Sources.Values.Any(source =>
                source.RetryAfter <= now));
    }

    public void Prune(IReadOnlySet<string> discovered)
    {
        lock (_gate)
        {
            if (_state.IsDirty) return;
            string[] absent = _state.Document.Sources.Where(pair => !discovered.Contains(pair.Key) &&
                pair.Value.LastAttempt?.Outcome != CheckpointAttemptOutcome.Pending).Select(pair => pair.Key).ToArray();
            if (absent.Length > 0)
                _state = _state with
                {
                    Document = _state.Document with { Sources = _state.Document.Sources.RemoveRange(absent) },
                    Revision = _state.Revision + 1
                };
        }
    }

    public async Task FlushAsync(CancellationToken cancellationToken = default)
    {
        // Serializes file replacements, not imports or event delivery. Completions remain free to update state.
        await _persistence.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            CheckpointSnapshot captured = Read();
            if (!captured.IsDirty) return;
            try
            {
                await _store.SaveAsync(captured.Document, cancellationToken).ConfigureAwait(false);
                lock (_gate)
                    _state = _state with { AcknowledgedRevision = captured.Revision, PersistenceFailure = null };
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or OperationCanceledException)
            {
                lock (_gate) _state = _state with { PersistenceFailure = "checkpoint-save-failed" };
                throw;
            }
        }
        finally { _persistence.Release(); }
    }

    private SourceCheckpoint GetOrCreate(string id)
    {
        if (_state.Document.Sources.TryGetValue(id, out SourceCheckpoint? checkpoint)) return checkpoint;
        if (_state.Document.Sources.Count >= _maximumSources)
            throw new InvalidOperationException("Monitoring checkpoint source capacity is exhausted.");
        return new();
    }

    private void Set(string id, SourceCheckpoint checkpoint)
    {
        if (_state.Document.Sources.GetValueOrDefault(id) == checkpoint) return;
        _state = _state with
        {
            Document = _state.Document with { Sources = _state.Document.Sources.SetItem(id, checkpoint) },
            Revision = _state.Revision + 1
        };
    }

    public void Dispose() => _persistence.Dispose();
}
