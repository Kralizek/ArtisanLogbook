using System.Collections.Concurrent;

using Microsoft.Extensions.Logging;

namespace Tests.Cli;

internal sealed record CapturedLog(
    string Category, LogLevel Level, EventId Event, string Message,
    IReadOnlyDictionary<string, object?> Properties, Exception? Exception);

internal sealed class CapturingLoggerProvider : ILoggerProvider
{
    public ConcurrentQueue<CapturedLog> Entries { get; } = new();
    public ILogger CreateLogger(string categoryName) => new Logger(categoryName, Entries);
    public ILogger<T> CreateLogger<T>() => new TypedLogger<T>(Entries);
    public void Dispose() { }

    private sealed class TypedLogger<T>(ConcurrentQueue<CapturedLog> entries)
        : Logger(typeof(T).FullName!, entries), ILogger<T>;

    private class Logger(string category, ConcurrentQueue<CapturedLog> entries) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => logLevel != LogLevel.None;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            IReadOnlyDictionary<string, object?> properties = state is IEnumerable<KeyValuePair<string, object?>> values
                ? values.ToDictionary(pair => pair.Key, pair => pair.Value) : new Dictionary<string, object?>();
            entries.Enqueue(new(category, logLevel, eventId, formatter(state, exception), properties, exception));
        }
    }
}
