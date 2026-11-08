using ArtisanLogbook.Cli;
using ArtisanLogbook.Runtime;

using NUnit.Framework;

using Spectre.Console.Testing;

namespace Tests.Cli;

[TestFixture]
public sealed class InitializationPromptsTests
{
    [Test]
    public void ExistingRootIsFirstSelectionEvenWhenNotDetectedAndMarkupIsEscaped()
    {
        using TestConsole console = new();
        console.Interactive();
        console.Input.PushKey(ConsoleKey.Enter);
        string current = Path.Combine(Path.GetTempPath(), "[red]existing");
        RootSelection selected = new SpectreInitializationPrompts(console)
            .SelectRoot([Path.Combine(Path.GetTempPath(), "other")], current);
        Assert.That(selected, Is.EqualTo(new RootSelection(RootSelectionKind.Installation, current)));
        Assert.That(console.Output, Does.Contain("[red]existing").And.Contain("(current)"));
    }

    [Test]
    public void ManualAndCancelChoicesExistWhenDiscoveryIsEmpty()
    {
        using TestConsole console = new();
        console.Interactive();
        console.Input.PushKey(ConsoleKey.Enter);
        SpectreInitializationPrompts prompts = new(console);
        Assert.That(prompts.SelectRoot([], null).Kind, Is.EqualTo(RootSelectionKind.Manual));
        console.Input.PushKey(ConsoleKey.DownArrow);
        console.Input.PushKey(ConsoleKey.Enter);
        Assert.That(prompts.SelectRoot([], null).Kind, Is.EqualTo(RootSelectionKind.Cancel));
    }

    [Test]
    public void EmptyManualEntryCancelsEvenWithExistingRootAndConfirmationDefaultsToNo()
    {
        using TestConsole console = new();
        console.Interactive();
        console.Input.PushKey(ConsoleKey.Enter);
        SpectreInitializationPrompts prompts = new(console);
        Assert.That(prompts.EnterRoot(Path.GetTempPath()), Is.Null);
        console.Input.PushKey(ConsoleKey.Enter);
        Assert.That(prompts.Confirm(CompanionSettings.ForRoots(Path.GetTempPath())), Is.False);
    }
}
