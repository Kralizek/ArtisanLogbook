using ArtisanLogbook.Runtime;

using Spectre.Console;
using Spectre.Console.Cli;

namespace ArtisanLogbook.Cli.Commands;

public sealed class InitCommand(
    ApplicationPaths paths, CompanionSettingsStore settingsStore, InstallationDiscovery discovery,
    InstallationHints hints, IInitializationPrompts prompts, IAnsiConsole console) : Command
{
    public override int Execute(CommandContext context)
    {
        SettingsLoadResult loaded = settingsStore.Load();
        if (!loaded.CanSave)
        {
            console.MarkupLine($"[red]Configuration error:[/] {Markup.Escape(loaded.Diagnostic!)}");
            return ExitCodes.Failed;
        }
        if (!prompts.IsInteractive)
        {
            console.MarkupLine("[red]Initialization requires an interactive terminal.[/] " +
                "Run artisanlogbook init in a terminal, or use artisanlogbook import <source-file>.");
            return ExitCodes.Usage;
        }
        console.Write(new Panel("The Companion preserves crafting history in one local database for all WoW flavors.\n" +
            "Configure an installation root, not an individual flavor. Initialization does not import, " +
            "modify SavedVariables, or open the database.").Header("Artisan Logbook Companion"));
        DiscoveryResult detected = discovery.Detect(hints.Paths);
        DiscoveryReport.Write(console, detected);
        string? current = loaded.Settings?.InstallationRoots.FirstOrDefault();
        while (true)
        {
            RootSelection selection = prompts.SelectRoot(detected.Paths, current);
            if (selection.Kind == RootSelectionKind.Cancel) return Cancel();
            string? selected = selection.Kind == RootSelectionKind.Manual ? prompts.EnterRoot(current) : selection.Path;
            if (selected is null) return Cancel();
            string root;
            try { root = paths.ResolveSource(selected); }
            catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
            {
                console.MarkupLine($"[red]Invalid path:[/] {Markup.Escape(exception.Message)}");
                continue;
            }
            DiscoveryResult validation = discovery.ValidateRoot(root);
            DiscoveryReport.Write(console, validation);
            if (validation.Paths.Count == 0 || validation.HasErrors) continue;

            string[] roots = new[] { validation.Paths[0] }
                .Concat(loaded.Settings?.InstallationRoots.Skip(1) ?? [])
                .Distinct(InstallationDiscovery.PathComparer).ToArray();
            CompanionSettings proposed = (loaded.Settings ?? CompanionSettings.ForRoots()) with { InstallationRoots = roots };
            Table table = new Table().AddColumn("Proposed configuration").AddColumn("Value");
            table.AddRow("Schema version", "1");
            table.AddRow("Settings file", Markup.Escape(settingsStore.FilePath));
            foreach (string path in roots) table.AddRow("Installation root", Markup.Escape(path));
            console.Write(table);
            if (!prompts.Confirm(proposed)) return Cancel();
            settingsStore.Save(proposed, expected: loaded);
            console.MarkupLine("[green]Configuration saved.[/] Next: [bold]artisanlogbook import[/]");
            return ExitCodes.Success;
        }

        int Cancel()
        {
            console.WriteLine("Initialization canceled. Settings unchanged; no import performed.");
            return ExitCodes.Success;
        }
    }
}
