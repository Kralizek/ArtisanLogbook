using ArtisanLogbook.Runtime;

using Spectre.Console;

namespace ArtisanLogbook.Cli;

public enum RootSelectionKind { Installation, Manual, Cancel }
public sealed record RootSelection(RootSelectionKind Kind, string? Path = null);
public sealed record InstallationHints(IReadOnlyList<string> Paths);

public interface IInitializationPrompts
{
    bool IsInteractive { get; }
    RootSelection SelectRoot(IReadOnlyList<string> candidates, string? current);
    string? EnterRoot(string? current);
    bool Confirm(CompanionSettings proposed);
}

public sealed class SpectreInitializationPrompts(IAnsiConsole console) : IInitializationPrompts
{
    public bool IsInteractive => !Console.IsInputRedirected && !Console.IsOutputRedirected &&
        console.Profile.Capabilities.Interactive;

    public RootSelection SelectRoot(IReadOnlyList<string> candidates, string? current)
    {
        List<RootSelection> choices = candidates.Select(path => new RootSelection(RootSelectionKind.Installation, path)).ToList();
        if (current is not null)
        {
            choices.RemoveAll(choice => InstallationDiscovery.PathComparer.Equals(choice.Path, current));
            choices.Insert(0, new(RootSelectionKind.Installation, current));
        }
        choices.Add(new(RootSelectionKind.Manual));
        choices.Add(new(RootSelectionKind.Cancel));
        return console.Prompt(new SelectionPrompt<RootSelection>()
            .Title("Choose your [green]World of Warcraft installation root[/]")
            .UseConverter(choice => choice.Kind switch
            {
                RootSelectionKind.Installation => Markup.Escape(choice.Path!) +
                    (InstallationDiscovery.PathComparer.Equals(choice.Path, current) ? " [grey](current)[/]" : ""),
                RootSelectionKind.Manual => "Enter a path manually",
                _ => "Cancel (leave settings unchanged)"
            })
            .AddChoices(choices));
    }

    public string? EnterRoot(string? current)
    {
        TextPrompt<string> prompt = new TextPrompt<string>(
            "Installation root [grey](contains the client directories; empty cancels)[/]:").AllowEmpty();
        string answer = console.Prompt(prompt);
        return string.IsNullOrWhiteSpace(answer) ? null : answer;
    }

    public bool Confirm(CompanionSettings proposed) =>
        console.Confirm("Save this configuration?", defaultValue: false);
}
