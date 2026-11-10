using System.Collections;
using System.Globalization;
using System.Text;

using Microsoft.Extensions.Logging;

namespace ArtisanLogbook.Cli.Logging;

internal sealed class ConsolePropertyFormatter
{
    private const int MaximumItems = 16;
    private const int MaximumDepth = 3;
    private const int MaximumScalarLength = 512;
    private const int MaximumLength = 2048;
    private Dictionary<object, string>? _collections;

    public string Format(object? value)
    {
        bool collection = value is IEnumerable and not string;
        if (collection && _collections is not null && _collections.TryGetValue(value!, out string? cached))
            return cached;
        StringBuilder output = new();
        Append(output, value, 0);
        string rendered = output.ToString();
        if (collection) (_collections ??= new(ReferenceEqualityComparer.Instance))[value!] = rendered;
        return rendered;
    }

    public string Message<TState>(TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        // Reuse Microsoft's template formatter for its own structured state, replacing only collection presentation.
        // Custom ILogger formatters remain authoritative. The original state is never replaced or mutated.
        if (state?.GetType().Assembly != typeof(LoggerExtensions).Assembly ||
            state is not IEnumerable<KeyValuePair<string, object?>> properties)
            return formatter(state, exception);
        KeyValuePair<string, object?>[] values = properties.ToArray();
        if (!values.Any(pair => pair.Value is IEnumerable and not string) ||
            values.LastOrDefault(pair => pair.Key == "{OriginalFormat}").Value is not string template)
            return formatter(state, exception);
        object?[] arguments = values.Where(pair => pair.Key != "{OriginalFormat}")
            .Select(pair => pair.Value is IEnumerable and not string ? Format(pair.Value) : pair.Value).ToArray();
        TemplateFormatter message = new();
        message.LogInformation(template, arguments);
        return message.Text;
    }

    private sealed class TemplateFormatter : ILogger
    {
        public string Text { get; private set; } = "";
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel level) => true;
        public void Log<TState>(LogLevel level, EventId id, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter) => Text = formatter(state, exception);
    }

    private static void Append(StringBuilder output, object? value, int depth)
    {
        if (value is string || value is not IEnumerable values)
        {
            string text = value is null ? "(null)" : Convert.ToString(value, CultureInfo.InvariantCulture) ?? "";
            int limit = Math.Min(MaximumScalarLength, Math.Max(0, MaximumLength - output.Length));
            output.Append(text.AsSpan(0, Math.Min(text.Length, limit)));
            if (text.Length > limit) output.Append("...");
            return;
        }
        if (depth >= MaximumDepth)
        {
            output.Append("[...]");
            return;
        }
        output.Append('[');
        IEnumerator iterator = values.GetEnumerator();
        try
        {
            int count = 0;
            while (iterator.MoveNext())
            {
                if (count > 0) output.Append(", ");
                if (count++ >= MaximumItems || output.Length >= MaximumLength)
                {
                    output.Append("...");
                    break;
                }
                Append(output, iterator.Current, depth + 1);
            }
        }
        finally { (iterator as IDisposable)?.Dispose(); }
        output.Append(']');
    }
}
