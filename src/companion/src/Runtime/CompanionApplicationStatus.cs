using System.Data.Common;
using System.Reflection;

using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.Runtime;

public enum CompanionLifecycleState { Created, Starting, Running, Stopping, Stopped, Failed }

public sealed record CompanionFailure(string Code, string Message);

/// <summary>Internal operational snapshot, not an HTTP contract. C11 must map to versioned public DTOs.</summary>
internal sealed record CompanionStatus(
    string ApplicationVersion,
    DateTimeOffset? StartupTime,
    CompanionLifecycleState LifecycleState,
    bool DatabaseAvailable,
    int? DatabaseSchemaVersion,
    long? CanonicalCraftCount,
    CompanionRuntimeConfiguration Configuration,
    CompanionFailure? CriticalFailure,
    IReadOnlyList<ArtisanLogbook.HistoryStore.GameContextCraftCount>? CanonicalContexts = null,
    bool ApplicationStateAvailable = false,
    CompanionFailure? ApplicationStateFailure = null);

/// <summary>Operational status; canonical counts are queried from C03, never cached.</summary>
internal sealed class CompanionApplicationStatus(
    CompanionRuntimeConfiguration configuration, IHostEnvironment environment, ILogger<CompanionApplicationStatus> logger)
{
    private readonly object _gate = new();
    private readonly string _version = Assembly.Load(environment.ApplicationName)
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion.Split('+')[0];
    private CompanionLifecycleState _state;
    private DateTimeOffset? _startupTime;
    private Store? _store;
    private CompanionFailure? _failure;
    private bool _applicationStateAvailable;
    private CompanionFailure? _applicationStateFailure;

    public CompanionStatus Read()
    {
        lock (_gate)
        {
            int? schema = null;
            long? count = null;
            IReadOnlyList<ArtisanLogbook.HistoryStore.GameContextCraftCount>? contexts = null;
            bool available = false;
            if (_store is not null)
            {
                try
                {
                    var history = _store.ReadStatus();
                    schema = history.SchemaVersion;
                    count = history.TotalCraftCount;
                    contexts = history.Contexts;
                    available = true;
                }
                catch (Exception exception) when (exception is DbException or IOException or InvalidOperationException)
                {
                    Fail("database-status-failed", "Cannot read canonical history status.", exception);
                }
            }
            return new(_version, _startupTime, _state, available, schema, count, configuration, _failure, contexts,
                _applicationStateAvailable, _applicationStateFailure);
        }
    }

    internal void Starting()
    {
        lock (_gate)
        {
            _state = CompanionLifecycleState.Starting;
            _startupTime = DateTimeOffset.UtcNow;
        }
    }

    internal void DatabaseOpened(Store store)
    {
        lock (_gate) _store = store;
    }

    internal bool Transition(CompanionLifecycleState state)
    {
        lock (_gate)
        {
            if (_failure is not null) return false;
            _state = state;
            return true;
        }
    }

    internal void DatabaseClosed()
    {
        lock (_gate) _store = null;
    }

    internal void ApplicationStateOpened()
    {
        lock (_gate)
        {
            _applicationStateAvailable = true;
            _applicationStateFailure = null;
        }
    }

    internal void ApplicationStateUnavailable(Exception exception)
    {
        lock (_gate)
        {
            _applicationStateAvailable = false;
            _applicationStateFailure = new(
                "application-state-unavailable", "Application-state persistence is unavailable.");
            logger.LogWarning("Companion capability {FailureCode}: {FailureMessage} ({ExceptionType})",
                _applicationStateFailure.Code, _applicationStateFailure.Message, exception.GetType().Name);
        }
    }

    internal void ApplicationStateClosed()
    {
        lock (_gate) _applicationStateAvailable = false;
    }

    internal void Fail(string code, string message, Exception exception)
    {
        lock (_gate)
        {
            if (_failure is not null) return;
            _failure = new(code, message);
            _state = CompanionLifecycleState.Failed;
            logger.LogError("Companion failure {FailureCode}: {FailureMessage} ({ExceptionType})",
                code, message, exception.GetType().Name);
        }
    }
}
