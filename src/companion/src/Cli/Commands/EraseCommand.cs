using System.ComponentModel;

using ArtisanLogbook.Runtime;

using Spectre.Console;
using Spectre.Console.Cli;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.Cli.Commands;

public sealed class EraseSettings : DatabaseSettings
{
    [CommandOption("-y|--yes")]
    [Description("Erase without asking for confirmation (required when not running interactively).")]
    public bool Yes { get; init; }
}

public sealed class EraseCommand(ApplicationPaths paths, IInitializationPrompts prompts, IAnsiConsole console)
    : Command<EraseSettings>
{
    public override int Execute(CommandContext context, EraseSettings settings)
    {
        string database = Path.GetFullPath(paths.ResolveDatabase(settings.Database));
        string checkpoints = ApplicationPaths.MonitoringCheckpointFile(database);
        console.WriteLine($"Database: {database}");
        if (Directory.Exists(database))
            throw new IOException("The database path is a directory; specify --database <file>.");
        if (!File.Exists(database))
        {
            if (File.Exists(checkpoints)) File.Delete(checkpoints);
            console.MarkupLine("[yellow]Database does not exist. Nothing to erase.[/]");
            return ExitCodes.Success;
        }

        if (!settings.Yes)
        {
            if (!prompts.IsInteractive)
            {
                console.MarkupLine("[red]Erasing requires confirmation.[/] Run interactively or pass --yes.");
                return ExitCodes.Usage;
            }
            console.WriteLine("This permanently deletes all imported crafting history in this database. " +
                "SavedVariables, settings, pins and saved investigations are kept; reimport to rebuild history.");
            if (!prompts.ConfirmErase(database))
            {
                console.WriteLine("Canceled. Nothing was erased.");
                return ExitCodes.Success;
            }
        }

        Store.Erase(database);
        File.Delete(checkpoints);
        console.MarkupLine("[green]History database erased.[/] Run [bold]artisanlogbook import[/] to rebuild it.");
        return ExitCodes.Success;
    }
}
