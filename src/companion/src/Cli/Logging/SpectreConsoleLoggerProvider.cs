using System.Globalization;
using System.Text;

using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

using Spectre.Console;
using Spectre.Console.Rendering;

namespace ArtisanLogbook.Cli.Logging;

/// <summary>Synchronous, entry-atomic output without queues or terminal ownership.</summary>
[ProviderAlias("SpectreConsole")]
public sealed class SpectreConsoleLoggerProvider(
    IAnsiConsole console,
    IOptionsMonitor<SpectreConsoleLoggerOptions> options) : ILoggerProvider, ISupportExternalScope
{
    private readonly object renderLock = new();
    private IExternalScopeProvider scopeProvider = new LoggerExternalScopeProvider();

    public ILogger CreateLogger(string categoryName) => new Logger(this, categoryName);

    public void SetScopeProvider(IExternalScopeProvider scopeProvider) => this.scopeProvider = scopeProvider;

    public void Dispose() { }

    private void Write<TState>(string category, LogLevel level, EventId eventId, TState state,
        Exception? exception, Func<TState, Exception?, string> formatter)
    {
        SpectreConsoleLoggerOptions settings = options.CurrentValue;
        string message = Sanitize(formatter(state, exception));
        string prefix = $"{DateTimeOffset.Now:HH:mm:ss} {LevelLabel(level)}";
        StringBuilder context = new();
        context.Append("category=").Append(Sanitize(category))
            .Append(" event=").Append(eventId.Id.ToString(CultureInfo.InvariantCulture));
        if (eventId.Name is not null)
            context.Append('/').Append(Sanitize(eventId.Name));
        AppendProperties(context, state);

        List<string> lines = [message, context.ToString()];
        if (settings.IncludeScopes)
        {
            scopeProvider.ForEachScope((scope, output) =>
            {
                StringBuilder text = new("scope:");
                if (!AppendProperties(text, scope))
                    text.Append(' ').Append(Sanitize(Convert.ToString(scope, CultureInfo.InvariantCulture) ?? ""));
                output.Add(text.ToString());
            }, lines);
        }
        if (exception is not null)
            lines.Add(Sanitize(exception.ToString()));

        bool plain = settings.ForcePlainText || !console.Profile.Capabilities.Ansi
            || !console.Profile.Out.IsTerminal || !console.Profile.Capabilities.Interactive
            || IsContinuousIntegration();
        // Keep entry separators consistent with sanitized multiline content on every platform.
        string output = string.Join("\n", lines.Select((line, index) => index == 0
            ? prefix + " " + Indent(line, "             ")
            : "  " + Indent(line, "  "))) + "\n";
        Grid heading = new Grid()
            .AddColumn(new GridColumn { Width = 12, NoWrap = true, Padding = new Padding(0, 0, 1, 0) })
            .AddColumn(new GridColumn { Padding = new Padding(0) })
            .AddRow(new Text(prefix, LevelStyle(level)), new Text(message));
        IRenderable rendered = new Rows(new[] { (IRenderable)heading }.Concat(lines.Skip(1)
            .Select(line => new Padder(new Text(line, Style.Parse("grey")), new Padding(2, 0, 0, 0)))));

        // State formatting and exception traversal can execute caller code; only rendering is serialized.
        lock (renderLock)
        {
            if (plain)
                console.Profile.Out.Writer.Write(output);
            else
                console.Write(rendered);
        }
    }

    private static bool AppendProperties(StringBuilder text, object? state)
    {
        if (state is not IEnumerable<KeyValuePair<string, object?>> properties)
            return false;
        foreach ((string key, object? value) in properties)
        {
            if (key == "{OriginalFormat}")
                continue;
            text.Append(' ').Append(Sanitize(key)).Append('=')
                .Append(Sanitize(value is null ? "(null)" : Convert.ToString(value, CultureInfo.InvariantCulture) ?? ""));
        }
        return true;
    }

    private static string Indent(string text, string indentation) => text.Replace("\n", "\n" + indentation);

    private static string LevelLabel(LogLevel level) => level switch
    {
        LogLevel.Trace => "TRC",
        LogLevel.Debug => "DBG",
        LogLevel.Information => "INF",
        LogLevel.Warning => "WRN",
        LogLevel.Error => "ERR",
        LogLevel.Critical => "CRT",
        _ => level.ToString()
    };

    private static Style LevelStyle(LogLevel level) => Style.Parse(level switch
    {
        LogLevel.Trace or LogLevel.Debug => "grey",
        LogLevel.Warning => "yellow",
        LogLevel.Error or LogLevel.Critical => "red",
        _ => "default"
    });

    private static bool IsContinuousIntegration() =>
        IsSet("CI") || IsSet("TF_BUILD") || IsSet("GITHUB_ACTIONS");

    private static bool IsSet(string name) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } value
        && !string.Equals(value, "false", StringComparison.OrdinalIgnoreCase)
        && value != "0";

    private static string Sanitize(string value)
    {
        StringBuilder safe = new(value.Length);
        for (int index = 0; index < value.Length; index++)
        {
            char character = value[index];
            if (character == '\x1b' && index + 1 < value.Length)
            {
                char next = value[++index];
                if (next == '[')
                    SkipCsi(value, ref index);
                else if (next is ']' or 'P' or 'X' or '^' or '_')
                    SkipControlString(value, ref index);
                continue;
            }
            if (character == '\x9b')
            {
                SkipCsi(value, ref index);
                continue;
            }
            if (character is '\x90' or '\x9d' or '\x98' or '\x9e' or '\x9f')
            {
                SkipControlString(value, ref index);
                continue;
            }
            if (character == '\r')
            {
                if (index + 1 >= value.Length || value[index + 1] != '\n')
                    safe.Append('\n');
            }
            else if (character == '\n')
                safe.Append('\n');
            else if (character == '\t')
                safe.Append("    ");
            else if (!char.IsControl(character) && CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.Format)
                safe.Append(character);
        }
        return safe.ToString();
    }

    private static void SkipCsi(string value, ref int index)
    {
        while (++index < value.Length)
            if (value[index] is >= '@' and <= '~')
                break;
    }

    private static void SkipControlString(string value, ref int index)
    {
        while (++index < value.Length)
        {
            if (value[index] is '\a' or '\x9c')
                break;
            if (value[index] == '\x1b' && index + 1 < value.Length && value[index + 1] == '\\')
            {
                index++;
                break;
            }
        }
    }

    private sealed class Logger(SpectreConsoleLoggerProvider provider, string category) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull =>
            provider.scopeProvider.Push(state);

        public bool IsEnabled(LogLevel logLevel) => logLevel != LogLevel.None;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (IsEnabled(logLevel))
                provider.Write(category, logLevel, eventId, state, exception, formatter);
        }
    }
}
