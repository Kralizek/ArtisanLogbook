using System.Text;
using System.Text.RegularExpressions;

using ArtisanLogbook.Cli.Logging;

using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Console;

using NUnit.Framework;

using Spectre.Console;
using Spectre.Console.Testing;

namespace Tests.Cli;

[TestFixture]
public sealed class SpectreLoggingTests
{
    [Test]
    public void StructuredStateCategoryLevelAndEventArePreservedWithoutParsingTheMessage()
    {
        using TestConsole console = new();
        using ServiceProvider services = CreateServices(console);
        ILogger logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("Test.Worker");
        logger.Log(LogLevel.Warning, new EventId(42, "Imported"),
            new Dictionary<string, object?> { ["RecipeId"] = 123, ["Source"] = "file.lua", ["Missing"] = null },
            null, (_, _) => "Finished importing");

        Assert.That(console.Output, Does.Contain("WRN Finished importing")
            .And.Contain("category=Test.Worker event=42/Imported")
            .And.Contain("RecipeId=123").And.Contain("Source=file.lua").And.Contain("Missing=(null)"));
    }

    [Test]
    public void StandardConfigurationFiltersCategoriesAndProviderLevels()
    {
        using TestConsole console = new();
        IConfiguration configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Logging:LogLevel:Default"] = "Error",
            ["Logging:SpectreConsole:LogLevel:Verbose.Worker"] = "Debug"
        }).Build();
        using ServiceProvider services = CreateServices(console, logging =>
            logging.AddConfiguration(configuration.GetSection("Logging")));
        ILoggerFactory factory = services.GetRequiredService<ILoggerFactory>();
        ILogger regular = factory.CreateLogger("Regular");
        ILogger verbose = factory.CreateLogger("Verbose.Worker");

        regular.LogWarning("filtered");
        regular.LogError("visible error");
        verbose.LogDebug("visible debug");
        verbose.LogTrace("filtered trace");

        Assert.That(regular.IsEnabled(LogLevel.Warning), Is.False);
        Assert.That(verbose.IsEnabled(LogLevel.Debug), Is.True);
        Assert.That(console.Output, Does.Not.Contain("filtered"));
        Assert.That(console.Output, Does.Contain("visible error").And.Contain("visible debug"));
    }

    [Test]
    public void StandardFiltersSkipFormattingAndNoneNeverLogs()
    {
        using TestConsole console = new();
        using ServiceProvider services = CreateServices(console, logging => logging.SetMinimumLevel(LogLevel.Error));
        ILogger logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker");
        logger.Log<string>(LogLevel.Debug, default, "", null, (_, _) => throw new AssertionException("Must not format"));
        logger.Log<string>(LogLevel.None, default, "", null, (_, _) => throw new AssertionException("Must not format"));
        Assert.That(console.Output, Is.Empty);
    }

    [Test]
    public void ExceptionsRetainNestedMessagesAndReadableStackFrames()
    {
        using TestConsole console = new();
        using ServiceProvider services = CreateServices(console);
        Exception exception;
        try
        {
            ThrowFailure();
            throw new AssertionException("Expected exception");
        }
        catch (InvalidOperationException failure)
        {
            exception = failure;
        }
        services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker").LogError(exception, "Import failed");
        Assert.That(console.Output, Does.Contain("ERR Import failed")
            .And.Contain("System.InvalidOperationException: outer [red]")
            .And.Contain("System.ArgumentException: inner")
            .And.Contain(nameof(ThrowFailure)));
        Assert.That(console.Output, Does.Contain("\n     at "));
    }

    [Test]
    public void EveryExternalFieldIsLiteralAndControlSequencesCannotReachTheTerminal()
    {
        using TestConsole console = new();
        console.Profile.Capabilities.Ansi = true;
        console.EmitAnsiSequences = false;
        console.Width(300);
        using ServiceProvider services = CreateServices(console, options: options => options.IncludeScopes = true);
        ILogger logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("[red]category[/]\x1b[2J");
        using (logger.BeginScope("[link=https://bad]scope[/]\x1b]0;title\a"))
        {
            logger.Log(LogLevel.Error, new EventId(7, "[blue]event[/]\u009b31m"),
                new Dictionary<string, object?>
                {
                    ["[bold]key[/]\x1b[5m"] = "[green]value[/]\x1b]8;;https://bad\x1b\\\0"
                },
                new Exception("[red]failure[/]\b\u202e"), (_, _) => "[yellow]message[/]\x1b[31m\tend");
        }

        Assert.That(console.Output, Does.Contain("[yellow]message[/]    end")
            .And.Contain("[red]category[/]").And.Contain("[blue]event[/]")
            .And.Contain("[bold]key[/]=[green]value[/]").And.Contain("[red]failure[/]")
            .And.Contain("[link=https://bad]scope[/]"));
        Assert.That(console.Output.Any(character => char.IsControl(character) && character != '\n'), Is.False);
        Assert.That(console.Output.Contains('\u202e'), Is.False);
        Assert.That(console.Output, Does.Not.Contain("title"));
    }

    [Test]
    public void MultilineMessagesAndPropertiesAreIndentedAndCarriageReturnsCannotOverwrite()
    {
        using TestConsole console = new();
        using ServiceProvider services = CreateServices(console);
        services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker")
            .LogInformation("first\r\nsecond\rthird {Source}", "line1\nline2");

        Assert.That(console.Output, Does.Contain("INF first\n             second\n             third line1")
            .And.Contain("\n             line2")
            .And.Contain("Source=line1\n  line2"));
        Assert.That(console.Output, Does.Not.Contain("\r").And.Not.Contain("{OriginalFormat}"));
    }

    [TestCase(true)]
    [TestCase(false)]
    public void ScopesCanBeEnabledAndUseOriginalStructuredProperties(bool enabled)
    {
        using TestConsole console = new();
        using ServiceProvider services = CreateServices(console, options: options => options.IncludeScopes = enabled);
        ILogger logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker");
        using (logger.BeginScope("outer"))
        using (logger.BeginScope(new Dictionary<string, object?> { ["BatchId"] = 37 }))
            logger.LogInformation("inside");
        logger.LogInformation("outside");

        string[] entries = console.Output.Split("INF ");
        Assert.That(entries[1].Contains("scope: outer"), Is.EqualTo(enabled));
        Assert.That(entries[1].Contains("BatchId=37"), Is.EqualTo(enabled));
        Assert.That(entries[2], Does.Not.Contain("scope:").And.Not.Contain("BatchId"));
    }

    [Test]
    public void ScopeOptionIsReadFromProviderConfiguration()
    {
        using TestConsole console = new();
        IConfiguration configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Logging:SpectreConsole:IncludeScopes"] = "true"
        }).Build();
        using ServiceProvider services = CreateServices(console, logging =>
            logging.AddConfiguration(configuration.GetSection("Logging")));
        ILogger logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker");
        using (logger.BeginScope("configured-scope"))
            logger.LogInformation("message");
        Assert.That(console.Output, Does.Contain("scope: configured-scope"));
    }

    [Test]
    [NonParallelizable]
    public void EnvironmentConfigurationSupportsStandardCategoryFiltersAndProviderOptions()
    {
        const string prefix = "ARTISAN_LOGGING_TEST_";
        const string levelKey = prefix + "Logging__SpectreConsole__LogLevel__Worker";
        const string scopesKey = prefix + "Logging__SpectreConsole__IncludeScopes";
        string? originalLevel = Environment.GetEnvironmentVariable(levelKey);
        string? originalScopes = Environment.GetEnvironmentVariable(scopesKey);
        try
        {
            Environment.SetEnvironmentVariable(levelKey, "Error");
            Environment.SetEnvironmentVariable(scopesKey, "true");
            IConfiguration configuration = new ConfigurationBuilder().AddEnvironmentVariables(prefix).Build();
            using TestConsole console = new();
            using ServiceProvider services = CreateServices(console, logging =>
                logging.AddConfiguration(configuration.GetSection("Logging")));
            ILogger logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker");
            using (logger.BeginScope("environment-scope"))
            {
                logger.LogWarning("filtered warning");
                logger.LogError("visible error");
            }
            Assert.That(console.Output, Does.Not.Contain("filtered warning"));
            Assert.That(console.Output, Does.Contain("ERR visible error").And.Contain("scope: environment-scope"));
        }
        finally
        {
            Environment.SetEnvironmentVariable(levelKey, originalLevel);
            Environment.SetEnvironmentVariable(scopesKey, originalScopes);
        }
    }

    [TestCase(false, true, false)]
    [TestCase(true, false, false)]
    [TestCase(true, true, true)]
    public void RedirectedUnsupportedAndExplicitPlainConsolesNeverEmitAnsi(bool terminal, bool ansi, bool forcePlain)
    {
        using StringWriter writer = new();
        IAnsiConsole console = AnsiConsole.Create(new AnsiConsoleSettings
        {
            Ansi = ansi ? AnsiSupport.Yes : AnsiSupport.No,
            Out = new ControlledOutput(writer, terminal)
        });
        using ServiceProvider services = CreateServices(console, options: options => options.ForcePlainText = forcePlain);
        services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker").LogWarning("[red]literal[/]");
        Assert.That(writer.ToString(), Does.Contain("WRN [red]literal[/]"));
        Assert.That(writer.ToString().Contains('\x1b'), Is.False);
    }

    [Test]
    [NonParallelizable]
    public void CapableTerminalUsesColorAndHangingIndentWrappingWithoutInterpretingMarkup()
    {
        using CiEnvironment environment = new(false);
        using StringWriter writer = new();
        IAnsiConsole console = AnsiConsole.Create(new AnsiConsoleSettings
        {
            Ansi = AnsiSupport.Yes,
            Interactive = InteractionSupport.Yes,
            ColorSystem = ColorSystemSupport.Standard,
            Out = new ControlledOutput(writer, true, 44)
        });
        console.Profile.Capabilities.Interactive = true;
        using ServiceProvider services = CreateServices(console);
        ILogger logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker");
        logger.LogWarning("[red]literal[/] followed by enough words to wrap onto another line");
        logger.LogInformation("next entry");
        string rendered = writer.ToString();
        string text = Regex.Replace(rendered, @"\u001b\[[0-?]*[ -/]*[@-~]", "");

        Assert.That(rendered.Contains('\x1b'), Is.True);
        Assert.That(text, Does.Contain("WRN [red]literal[/]").And.Contain("INF next entry"));
        string[] lines = text.Split('\n');
        Assert.That(lines.Any(line => line.StartsWith("             ", StringComparison.Ordinal)
            && line.Trim().Length > 0), Is.True, text);
        Assert.That(lines.All(line => line.TrimEnd('\r').Length <= 44), Is.True, text);
    }

    [Test]
    [NonParallelizable]
    public void CiForcesPlainOutputEvenWithAnsiAndTerminalCapabilities()
    {
        using CiEnvironment environment = new(true);
        using StringWriter writer = new();
        IAnsiConsole console = AnsiConsole.Create(new AnsiConsoleSettings
        {
            Ansi = AnsiSupport.Yes,
            Interactive = InteractionSupport.Yes,
            Out = new ControlledOutput(writer, true)
        });
        console.Profile.Capabilities.Interactive = true;
        using ServiceProvider services = CreateServices(console);
        services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker").LogError("CI message");
        Assert.That(writer.ToString(), Does.Contain("ERR CI message"));
        Assert.That(writer.ToString().Contains('\x1b'), Is.False);
    }

    [TestCase(false)]
    [TestCase(true)]
    [NonParallelizable]
    public void RedirectedOrNoninteractiveLogsDoNotWrapLongUrlsAtTerminalWidth(bool terminal)
    {
        using CiEnvironment environment = new(false);
        using StringWriter writer = new();
        IAnsiConsole console = AnsiConsole.Create(new AnsiConsoleSettings
        {
            Ansi = AnsiSupport.Yes,
            Interactive = InteractionSupport.No,
            Out = new ControlledOutput(writer, terminal, 24)
        });
        using ServiceProvider services = CreateServices(console);
        const string url = "https://localhost:48721/api/v1/history?source=long-source-identifier&filter=crafts";
        services.GetRequiredService<ILoggerFactory>().CreateLogger("Long.Worker.Category")
            .LogInformation(new EventId(99, "Request"), "Request {Url}", url);

        string[] lines = writer.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.That(lines, Has.Length.EqualTo(2));
        Assert.That(lines[0], Does.EndWith("INF Request " + url));
        Assert.That(lines[1], Is.EqualTo("  category=Long.Worker.Category event=99/Request Url=" + url));
        Assert.That(writer.ToString().Contains('\x1b'), Is.False);
    }

    [Test]
    public void ConcurrentEntriesAndTheirPropertiesAndScopesDoNotInterleave()
    {
        using TestConsole console = new();
        using ServiceProvider services = CreateServices(console, options: options => options.IncludeScopes = true);
        ILogger logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker");
        Parallel.For(0, 100, id =>
        {
            using (logger.BeginScope(new Dictionary<string, object?> { ["ScopeId"] = id }))
                logger.LogInformation("begin-{Id}\nend-{Id}", id, id);
        });

        MatchCollection entries = Regex.Matches(console.Output,
            @"INF begin-(\d+)\n             end-\1\n  category=Worker event=0 Id=\1 Id=\1\n  scope: ScopeId=\1(?:\r?\n)");
        Assert.That(entries, Has.Count.EqualTo(100), console.Output);
    }

    [Test]
    public void FormattingDoesNotHoldTheRenderingLock()
    {
        using TestConsole console = new();
        using ServiceProvider services = CreateServices(console);
        ILogger logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker");
        logger.Log(LogLevel.Information, default, "outer", null, (state, _) =>
        {
            Task inner = Task.Run(() => logger.LogInformation("inner"));
            Assert.That(inner.Wait(TimeSpan.FromSeconds(5)), Is.True, "Formatting held the render lock");
            return state;
        });
        Assert.That(console.Output, Does.Contain("INF inner").And.Contain("INF outer"));
    }

    [Test]
    public void RegistrationIsIdempotentReplacesOnlyConsoleAndDoesNotOwnTheConsole()
    {
        using TestConsole console = new();
        ServiceCollection collection = new();
        using RecordingProvider other = new();
        collection.AddLogging(logging =>
        {
            logging.AddConsole();
            logging.AddProvider(other);
            logging.AddSpectreConsole(console);
            logging.AddSpectreConsole(console);
        });
        using (ServiceProvider services = collection.BuildServiceProvider())
        {
            ILoggerProvider[] providers = services.GetServices<ILoggerProvider>().ToArray();
            Assert.That(providers.OfType<ConsoleLoggerProvider>(), Is.Empty);
            Assert.That(providers.OfType<SpectreConsoleLoggerProvider>().Count(), Is.EqualTo(1));
            Assert.That(providers, Does.Contain(other));
            services.GetRequiredService<ILoggerFactory>().CreateLogger("Worker").LogInformation("one entry");
            Assert.That(Regex.Matches(console.Output, "INF one entry"), Has.Count.EqualTo(1));
            Assert.That(other.Messages, Is.EqualTo(1));
        }
        Assert.DoesNotThrow(() => console.WriteLine("still usable"));
    }

    private static ServiceProvider CreateServices(IAnsiConsole console, Action<ILoggingBuilder>? configure = null,
        Action<SpectreConsoleLoggerOptions>? options = null)
    {
        ServiceCollection collection = new();
        collection.AddLogging(logging =>
        {
            configure?.Invoke(logging);
            logging.AddSpectreConsole(console, options);
        });
        return collection.BuildServiceProvider();
    }

    private static void ThrowFailure() =>
        throw new InvalidOperationException("outer [red]", new ArgumentException("inner"));

    private sealed class ControlledOutput(TextWriter writer, bool terminal, int width = 100) : IAnsiConsoleOutput
    {
        public TextWriter Writer => writer;
        public bool IsTerminal => terminal;
        public int Width => width;
        public int Height => 30;
        public void SetEncoding(Encoding encoding) { }
    }

    private sealed class CiEnvironment : IDisposable
    {
        private readonly Dictionary<string, string?> original = [];

        public CiEnvironment(bool enabled)
        {
            foreach (string key in new[] { "CI", "TF_BUILD", "GITHUB_ACTIONS" })
            {
                original[key] = Environment.GetEnvironmentVariable(key);
                Environment.SetEnvironmentVariable(key, enabled ? "true" : "false");
            }
        }

        public void Dispose()
        {
            foreach ((string key, string? value) in original)
                Environment.SetEnvironmentVariable(key, value);
        }
    }

    private sealed class RecordingProvider : ILoggerProvider
    {
        public int Messages { get; private set; }
        public ILogger CreateLogger(string categoryName) => new RecordingLogger(this);
        public void Dispose() { }

        private sealed class RecordingLogger(RecordingProvider provider) : ILogger
        {
            public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
            public bool IsEnabled(LogLevel logLevel) => true;
            public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
                Func<TState, Exception?, string> formatter) => provider.Messages++;
        }
    }
}
