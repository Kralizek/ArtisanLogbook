using System.Reactive.Concurrency;
using System.Threading.Channels;

using ArtisanLogbook.ImportService;

using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace ArtisanLogbook.Runtime;

public enum ImportOperationStatus { Queued, Running, Completed, Failed, Cancelled }
public enum ImportOperationOutcome { Successful, Partial, Failed }
public enum ImportRejection { InvalidSourceId, UnknownSource, NoSources, SourceBusy, CapacityExceeded, Stopping }

public sealed record ImportDiagnosticInfo(string Category, string Code, string Message);
public sealed record ImportCounts(
    int Observations, int Inserted, int AlreadyPresent, int Enriched, int RejectedOrConflicting,
    int DimensionsInserted, int DimensionsEnriched);
public sealed record ImportSourceSnapshot(
    string SourceId, ImportOperationStatus Status, CompanionImportOutcome? Outcome, ImportCounts? Counts,
    IReadOnlyList<ImportDiagnosticInfo> Diagnostics, bool DiagnosticsTruncated);
public sealed record ImportOperationSnapshot(
    Guid Id, ImportOperationStatus Status, ImportOperationOutcome? Outcome, string? RequestedSourceId,
    DateTimeOffset CreatedAt, DateTimeOffset? StartedAt, DateTimeOffset? CompletedAt,
    IReadOnlyList<ImportSourceSnapshot> Sources, IReadOnlyList<ImportDiagnosticInfo> Diagnostics);
public sealed record ImportSubmission(ImportOperationSnapshot? Operation, ImportRejection? Rejection)
{
    public static ImportSubmission Accept(ImportOperationSnapshot operation) => new(operation, null);
    public static ImportSubmission Reject(ImportRejection rejection) => new(null, rejection);
}

/// <summary>Bounds for process-local import tracking.</summary>
public sealed record ImportOperationLimits(int MaxActiveOperations = 8, int MaxRetainedOperations = 100);

/// <summary>
/// Owns accepted manual and automatic imports independently of their initiating requests. A single worker serializes
/// execution against the C03 writer through C10 admission; state is process-local and bounded.
/// </summary>
public sealed class ImportOperations(
    IServiceProvider services, SourceCatalog catalog, IHostApplicationLifetime lifetime,
    ImportOperationLimits limits, ILogger<ImportOperations> logger) : IHostedService, IDisposable
{
    private const int MaxDiagnosticsPerSource = 50;

    private readonly object _gate = new();
    private readonly MonitoringCheckpoints _checkpoints = services.GetRequiredService<MonitoringCheckpoints>();
    private readonly IScheduler _clock = services.GetRequiredService<IScheduler>();
    private readonly Channel<OperationState> _queue = Channel.CreateBounded<OperationState>(
        new BoundedChannelOptions(Math.Max(1, limits.MaxActiveOperations)) { SingleReader = true });
    private readonly Dictionary<Guid, OperationState> _operations = [];
    private readonly LinkedList<Guid> _order = new();
    private readonly HashSet<string> _activeSources = [];
    private readonly CancellationTokenSource _importCancellation = new();
    private Task _worker = Task.CompletedTask;
    private CancellationTokenRegistration _stopping;
    private bool _accepting;

    public Task StartAsync(CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            _accepting = true;
            _stopping = lifetime.ApplicationStopping.Register(StopAccepting);
            _worker = Task.Run(RunAsync, CancellationToken.None);
        }
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        StopAccepting();
        // Running work may finish; only an expired shutdown deadline cancels the active import.
        using CancellationTokenRegistration deadline = cancellationToken.Register(_importCancellation.Cancel);
        await _worker.ConfigureAwait(false);
    }

    private void StopAccepting()
    {
        lock (_gate) _accepting = false;
        _queue.Writer.TryComplete();
    }

    public ImportSubmission Submit(string? sourceId)
    {
        if (sourceId is not null && !SourceCatalog.IsWellFormedId(sourceId))
            return ImportSubmission.Reject(ImportRejection.InvalidSourceId);
        lock (_gate)
        {
            if (!_accepting) return ImportSubmission.Reject(ImportRejection.Stopping);
        }

        IReadOnlyList<DiscoveredSource> sources = catalog.Discover().Sources;
        if (sourceId is not null)
        {
            sources = sources.Where(source => source.Id == sourceId).ToArray();
            if (sources.Count == 0) return ImportSubmission.Reject(ImportRejection.UnknownSource);
        }
        else if (sources.Count == 0)
        {
            return ImportSubmission.Reject(ImportRejection.NoSources);
        }

        lock (_gate)
        {
            if (!_accepting) return ImportSubmission.Reject(ImportRejection.Stopping);
            if (sources.Any(source => _activeSources.Contains(source.Id)))
                return ImportSubmission.Reject(ImportRejection.SourceBusy);
            if (!_checkpoints.TryReserve(sources.Select(source => source.Id).ToArray(), _clock.Now, out var attempts))
                return ImportSubmission.Reject(ImportRejection.CapacityExceeded);
            OperationState operation = new(Guid.NewGuid(), sourceId, DateTimeOffset.UtcNow, sources, attempts);
            if (!_queue.Writer.TryWrite(operation))
            {
                foreach ((string id, long sequence) in attempts)
                    _checkpoints.Complete(id, sequence, CheckpointAttemptOutcome.Cancelled, null, _clock.Now);
                return ImportSubmission.Reject(ImportRejection.CapacityExceeded);
            }
            _operations[operation.Id] = operation;
            _order.AddFirst(operation.Id);
            foreach (DiscoveredSource source in sources) _activeSources.Add(source.Id);
            Trim();
            return ImportSubmission.Accept(operation.Snapshot());
        }
    }

    public ImportOperationSnapshot? Get(Guid id)
    {
        lock (_gate) return _operations.GetValueOrDefault(id)?.Snapshot();
    }

    internal bool IsSourceActive(string id)
    {
        lock (_gate) return _activeSources.Contains(id);
    }

    /// <summary>Newest first.</summary>
    public IReadOnlyList<ImportOperationSnapshot> List(int limit)
    {
        lock (_gate)
            return _order.Take(limit).Select(id => _operations[id].Snapshot()).ToArray();
    }

    private void Trim()
    {
        // Active operations are bounded by the queue; only finished ones are evicted, oldest first.
        LinkedListNode<Guid>? node = _order.Last;
        while (_order.Count > limits.MaxRetainedOperations && node is not null)
        {
            LinkedListNode<Guid>? previous = node.Previous;
            if (_operations[node.Value].IsFinished)
            {
                _operations.Remove(node.Value);
                _order.Remove(node);
            }
            node = previous;
        }
    }

    private async Task RunAsync()
    {
        await foreach (OperationState operation in _queue.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try
            {
                await ExecuteAsync(operation).ConfigureAwait(false);
            }
            catch (Exception exception)
            {
                logger.LogError(exception, "Import operation {OperationId} failed unexpectedly.", operation.Id);
                lock (_gate)
                {
                    operation.FailUnfinished("import-failed", "The import could not be completed.");
                    Finish(operation);
                }
            }
        }
    }

    private async Task ExecuteAsync(OperationState operation)
    {
        lock (_gate) operation.Start();
        foreach (SourceState source in operation.Sources)
        {
            lock (_gate) source.Status = ImportOperationStatus.Running;
            CompanionImportResult? result = null;
            try
            {
                if (IsStopping) throw new StoppingException();
                try
                {
                    result = await services.GetRequiredService<CompanionRuntimeImports>().ImportSavedVariablesFileAsync(source.Source.Path, _importCancellation.Token)
                        .ConfigureAwait(false);
                }
                catch (InvalidOperationException) when (IsStopping)
                {
                    throw new StoppingException();
                }
                lock (_gate) source.Complete(result);
            }
            catch (Exception exception) when (exception is StoppingException or OperationCanceledException)
            {
                lock (_gate)
                    source.Cancel(exception is StoppingException ? "application-stopping" : "import-cancelled",
                        "The application is stopping; the source was not imported.");
            }
            catch (Exception exception)
            {
                logger.LogError(exception, "Import of source {SourceId} failed unexpectedly.", source.Source.Id);
                lock (_gate)
                    source.Fail("import-failed", "The source could not be imported; see the Companion log.");
            }
            finally
            {
                _checkpoints.Complete(source.Source.Id, source.Attempt,
                    source.Status == ImportOperationStatus.Completed ? CheckpointAttemptOutcome.Successful :
                    source.Status == ImportOperationStatus.Cancelled ? CheckpointAttemptOutcome.Cancelled : CheckpointAttemptOutcome.Failed,
                    result?.SourceFingerprint, _clock.Now);
                lock (_gate) _activeSources.Remove(source.Source.Id);
            }
        }
        lock (_gate) Finish(operation);
    }

    private bool IsStopping
    {
        get
        {
            lock (_gate) return !_accepting || lifetime.ApplicationStopping.IsCancellationRequested;
        }
    }

    private void Finish(OperationState operation)
    {
        foreach (SourceState source in operation.Sources) _activeSources.Remove(source.Source.Id);
        operation.Finish();
        Trim();
    }

    public void Dispose()
    {
        _stopping.Dispose();
        _importCancellation.Dispose();
    }

    private sealed class StoppingException : Exception;

    private sealed class SourceState(DiscoveredSource source, long attempt)
    {
        public DiscoveredSource Source { get; } = source;
        public long Attempt { get; } = attempt;
        public ImportOperationStatus Status { get; set; } = ImportOperationStatus.Queued;
        public CompanionImportOutcome? Outcome { get; private set; }
        public ImportCounts? Counts { get; private set; }
        public List<ImportDiagnosticInfo> Diagnostics { get; } = [];
        public bool Truncated { get; private set; }

        public void Complete(CompanionImportResult result)
        {
            Outcome = result.Outcome;
            Status = result.Outcome == CompanionImportOutcome.Successful
                ? ImportOperationStatus.Completed : ImportOperationStatus.Failed;
            Counts = new(result.TotalSourceCraftObservations, result.InsertedCrafts, result.AlreadyPresentCrafts,
                result.EnrichedCrafts, result.RejectedOrConflictingCrafts, result.DimensionsInserted,
                result.DimensionsEnriched);
            List<ImportDiagnosticInfo> all = ImportDiagnosticMapper.Map(result);
            Diagnostics.AddRange(all.Take(MaxDiagnosticsPerSource));
            Truncated = all.Count > MaxDiagnosticsPerSource;
        }

        public void Fail(string code, string message)
        {
            Status = ImportOperationStatus.Failed;
            Outcome = CompanionImportOutcome.Failed;
            Diagnostics.Add(new("operation", code, message));
        }

        public void Cancel(string code, string message)
        {
            Status = ImportOperationStatus.Cancelled;
            Diagnostics.Add(new("operation", code, message));
        }

        public ImportSourceSnapshot Snapshot() =>
            new(Source.Id, Status, Outcome, Counts, Diagnostics.ToArray(), Truncated);
    }

    private sealed class OperationState
    {
        private readonly List<ImportDiagnosticInfo> _diagnostics = [];

        public OperationState(Guid id, string? requestedSourceId, DateTimeOffset createdAt, IEnumerable<DiscoveredSource> sources,
            IReadOnlyDictionary<string, long> attempts)
        {
            Id = id;
            RequestedSourceId = requestedSourceId;
            CreatedAt = createdAt;
            Sources = sources.Select(source => new SourceState(source, attempts[source.Id])).ToArray();
        }

        public Guid Id { get; }
        public string? RequestedSourceId { get; }
        public DateTimeOffset CreatedAt { get; }
        public IReadOnlyList<SourceState> Sources { get; }
        public ImportOperationStatus Status { get; private set; } = ImportOperationStatus.Queued;
        public ImportOperationOutcome? Outcome { get; private set; }
        public DateTimeOffset? StartedAt { get; private set; }
        public DateTimeOffset? CompletedAt { get; private set; }
        public bool IsFinished => CompletedAt is not null;

        public void Start()
        {
            Status = ImportOperationStatus.Running;
            StartedAt = DateTimeOffset.UtcNow;
        }

        public void FailUnfinished(string code, string message)
        {
            foreach (SourceState source in Sources.Where(source => source.Status is
                ImportOperationStatus.Queued or ImportOperationStatus.Running))
                source.Fail(code, message);
            _diagnostics.Add(new("operation", code, message));
        }

        public void Finish()
        {
            foreach (SourceState source in Sources.Where(source => source.Status == ImportOperationStatus.Queued))
                source.Cancel("application-stopping", "The application is stopping; the source was not imported.");
            int successful = Sources.Count(source => source.Outcome == CompanionImportOutcome.Successful);
            if (Sources.Any(source => source.Status == ImportOperationStatus.Cancelled))
            {
                Status = ImportOperationStatus.Cancelled;
            }
            else if (successful == Sources.Count)
            {
                Status = ImportOperationStatus.Completed;
                Outcome = ImportOperationOutcome.Successful;
            }
            else if (successful == 0)
            {
                Status = ImportOperationStatus.Failed;
                Outcome = ImportOperationOutcome.Failed;
            }
            else
            {
                Status = ImportOperationStatus.Completed;
                Outcome = ImportOperationOutcome.Partial;
            }
            CompletedAt = DateTimeOffset.UtcNow;
        }

        public ImportOperationSnapshot Snapshot() =>
            new(Id, Status, Outcome, RequestedSourceId, CreatedAt, StartedAt, CompletedAt,
                Sources.Select(source => source.Snapshot()).ToArray(), _diagnostics.ToArray());
    }
}

/// <summary>Translates C07 results to operator-safe diagnostics: codes, categories and counts, never paths or content.</summary>
internal static class ImportDiagnosticMapper
{
    private static readonly Dictionary<string, string> InputMessages = new(StringComparer.Ordinal)
    {
        ["source-too-large"] = "The source file exceeds the supported size.",
        ["source-changed-during-read"] = "The source file kept changing while it was read; retry later.",
        ["source-read-failed"] = "The source file could not be read.",
        ["invalid-source-encoding"] = "The source file is not valid UTF-8 text.",
        ["history-store-failure"] = "The history database rejected the import; nothing was committed."
    };

    public static List<ImportDiagnosticInfo> Map(CompanionImportResult result)
    {
        List<ImportDiagnosticInfo> list = [];
        foreach (var group in result.SourceDiagnostics.GroupBy(d => (d.Severity, d.Code)))
            list.Add(new("source", group.Key.Code,
                $"{group.Count()} {group.Key.Severity.ToString().ToLowerInvariant()} diagnostic(s) reported while reading the source."));
        foreach (var group in result.CoverageWarnings.GroupBy(d => d.Code))
            list.Add(new("coverage", group.Key, $"{group.Count()} coverage warning(s) reported."));
        foreach (var group in result.ValidationErrors.GroupBy(e => e.Field))
            list.Add(new("validation", "validation-failed", $"{group.Count()} observation(s) failed validation of '{group.Key}'."));
        foreach (var group in result.CraftConflicts.GroupBy(c => c.Field))
            list.Add(new("conflict", "craft-conflict", $"{group.Count()} craft(s) conflict with canonical history on '{group.Key}'."));
        foreach (var group in result.DimensionConflicts.GroupBy(c => c.Dimension))
            list.Add(new("dimension-conflict", "dimension-conflict", $"{group.Count()} '{group.Key}' dimension value(s) conflict with canonical history."));
        foreach (CompanionImportDiagnostic diagnostic in result.InputDiagnostics)
            list.Add(new("input", diagnostic.Code, Message(diagnostic.Code)));
        foreach (CompanionImportDiagnostic diagnostic in result.PersistenceDiagnostics)
            list.Add(new("persistence", diagnostic.Code, Message(diagnostic.Code)));
        return list;
    }

    private static string Message(string code) =>
        InputMessages.GetValueOrDefault(code, "The import reported a problem; see `artisanlogbook import --verbose` for details.");
}
