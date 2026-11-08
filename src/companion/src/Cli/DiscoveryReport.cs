using ArtisanLogbook.Runtime;

using Spectre.Console;

namespace ArtisanLogbook.Cli;

internal static class DiscoveryReport
{
    public static void Write(IAnsiConsole console, DiscoveryResult result)
    {
        foreach (DiscoveryDiagnostic diagnostic in result.Diagnostics)
        {
            string color = diagnostic.Severity == DiscoverySeverity.Error ? "red" : "yellow";
            console.MarkupLine($"[{color}]{diagnostic.Severity} ({Markup.Escape(diagnostic.Code)}):[/] " +
                $"{Markup.Escape(diagnostic.Path)}: {Markup.Escape(diagnostic.Message)}");
        }
    }
}
