using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Configuration;
using Microsoft.Extensions.Logging.Console;

using Spectre.Console;

namespace ArtisanLogbook.Cli.Logging;

public static class SpectreConsoleLoggingExtensions
{
    /// <summary>
    /// Add scrolling Spectre logs, replacing only the standard console provider.
    /// Supports Logging:SpectreConsole options and the usual Logging level/category filters.
    /// Repeated registration retains a single provider; the caller owns the console.
    /// </summary>
    public static ILoggingBuilder AddSpectreConsole(
        this ILoggingBuilder builder,
        IAnsiConsole console,
        Action<SpectreConsoleLoggerOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(builder);
        ArgumentNullException.ThrowIfNull(console);

        foreach (ServiceDescriptor descriptor in builder.Services
            .Where(item => item.ServiceType == typeof(ILoggerProvider)
                && (item.ImplementationType == typeof(ConsoleLoggerProvider)
                    || item.ImplementationInstance is ConsoleLoggerProvider))
            .ToArray())
            builder.Services.Remove(descriptor);

        builder.AddConfiguration();
        LoggerProviderOptions.RegisterProviderOptions<SpectreConsoleLoggerOptions, SpectreConsoleLoggerProvider>(builder.Services);
        if (configure is not null)
            builder.Services.Configure(configure);
        builder.Services.TryAddEnumerable(ServiceDescriptor.Singleton<ILoggerProvider, SpectreConsoleLoggerProvider>());
        builder.Services.TryAddSingleton(console);
        return builder;
    }
}
