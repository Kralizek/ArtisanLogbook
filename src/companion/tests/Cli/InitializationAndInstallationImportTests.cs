using System.Globalization;
using System.Text.RegularExpressions;

using ArtisanLogbook.Cli;
using ArtisanLogbook.Runtime;

using NUnit.Framework;

using Spectre.Console.Testing;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.Cli;

[TestFixture]
public sealed class InitializationAndInstallationImportTests
{
    private string _directory = null!;
    private string _root = null!;
    private ApplicationPaths _paths = null!;
    private CompanionSettingsStore _settings = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Init.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _root = Path.Combine(_directory, "World of Warcraft");
        Directory.CreateDirectory(Path.Combine(_root, "future-client", "Interface", "AddOns"));
        _paths = new(CompanionPlatform.Linux, _directory, _directory, null, _directory);
        _settings = new(_paths);
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [Test]
    public async Task GuidedDiscoveredInitializationSavesOnlyConfigurationAndShowsNextCommand()
    {
        FakePrompts prompts = new([new(RootSelectionKind.Installation, _root)], confirm: true);
        (int exit, string output) = await Run(["init"], prompts, [_root]);
        Assert.That(exit, Is.Zero, output);
        Assert.That(output, Does.Contain("Artisan Logbook Companion").And.Contain("Proposed configuration")
            .And.Contain("artisanlogbook import"));
        Assert.That(prompts.Candidates, Is.EqualTo(new[] { _root }));
        Assert.That(_settings.Load().Settings!.InstallationRoots, Is.EqualTo(new[] { _root }));
        Assert.That(Directory.GetFiles(_paths.DataDirectory), Is.EqualTo(new[] { _settings.FilePath }));
        Assert.That(Directory.GetFiles(_root, "*", SearchOption.AllDirectories), Is.Empty);
    }

    [Test]
    public async Task ManualSelectionWorksRegardlessOfCandidatesAndInvalidRootsAreExplained()
    {
        FakePrompts prompts = new(
            [new(RootSelectionKind.Manual), new(RootSelectionKind.Manual)], confirm: true)
        {
            ManualRoots = new([_directory, Path.GetRelativePath(_directory, _root)])
        };
        (int exit, string output) = await Run(["init"], prompts, [_root]);
        Assert.That(exit, Is.Zero, output);
        Assert.That(output, Does.Contain("invalid-installation").And.Contain("Expected an installation"));
        Assert.That(_settings.Load().Settings!.InstallationRoots.Single(), Is.EqualTo(_root));
    }

    [Test]
    public async Task ManualInitializationWithNoDetectedCandidates()
    {
        FakePrompts prompts = new([new(RootSelectionKind.Manual)], confirm: true) { ManualRoots = new([_root]) };
        Assert.That((await Run(["init"], prompts)).Exit, Is.Zero);
        Assert.That(prompts.Candidates, Is.Empty);
        Assert.That(_settings.Load().Status, Is.EqualTo(SettingsStatus.Loaded));
    }

    [TestCase(RootSelectionKind.Cancel)]
    [TestCase(RootSelectionKind.Manual)]
    [TestCase(RootSelectionKind.Installation)]
    public async Task CancelAtEveryWizardBoundaryLeavesSettingsAndDatabaseUnchanged(RootSelectionKind kind)
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        using (Store store = new(_paths.ResolveDatabase(null))) { }
        byte[] originalSettings = await File.ReadAllBytesAsync(_settings.FilePath);
        byte[] originalDatabase = await File.ReadAllBytesAsync(_paths.ResolveDatabase(null));
        FakePrompts prompts = new([new(kind, _root)], confirm: false) { ManualRoots = new([null]) };
        (int exit, string output) = await Run(["init"], prompts);
        Assert.That(exit, Is.Zero, output);
        Assert.That(output, Does.Contain("canceled").And.Contain("unchanged"));
        Assert.That(await File.ReadAllBytesAsync(_settings.FilePath), Is.EqualTo(originalSettings));
        Assert.That(await File.ReadAllBytesAsync(_paths.ResolveDatabase(null)), Is.EqualTo(originalDatabase));
        Assert.That(prompts.Current, Is.EqualTo(_root));
    }

    [Test]
    public async Task RepeatInitializationPreselectsExistingRootPreservesAdditionalRootsAndNeverOpensDatabase()
    {
        string other = Path.Combine(_directory, "second");
        _settings.Save(CompanionSettings.ForRoots(_root, other));
        using (Store store = new(_paths.ResolveDatabase(null))) { }
        byte[] database = await File.ReadAllBytesAsync(_paths.ResolveDatabase(null));
        for (int i = 0; i < 2; i++)
        {
            FakePrompts prompts = new([new(RootSelectionKind.Installation, _root)], confirm: true);
            (int exit, string output) = await Run(["init"], prompts);
            Assert.That(exit, Is.Zero, output);
            Assert.That(prompts.Current, Is.EqualTo(_root));
            Assert.That(_settings.Load().Settings!.InstallationRoots, Is.EqualTo(new[] { _root, other }));
        }
        Assert.That(await File.ReadAllBytesAsync(_paths.ResolveDatabase(null)), Is.EqualTo(database));
    }

    [Test]
    public async Task CancelFirstRunCreatesNeitherSettingsNorDatabase()
    {
        FakePrompts prompts = new([new(RootSelectionKind.Cancel)], confirm: false);
        Assert.That((await Run(["init"], prompts)).Exit, Is.Zero);
        Assert.That(Directory.Exists(_paths.DataDirectory), Is.False);
    }

    [Test]
    public async Task NoninteractiveInitializationClearlyFailsWithoutPromptingOrCreatingFiles()
    {
        FakePrompts prompts = new([], confirm: false) { IsInteractive = false };
        (int exit, string output) = await Run(["init"], prompts);
        Assert.That(exit, Is.EqualTo(ExitCodes.Usage), output);
        Assert.That(output, Does.Contain("requires an interactive terminal"));
        Assert.That(Directory.Exists(_paths.DataDirectory), Is.False);
        Assert.That(prompts.SelectionCalls, Is.Zero);
        // Exercise the production terminal guard as well as the injectable interaction boundary.
        (exit, output) = await Run(["init"]);
        Assert.That(exit, Is.EqualTo(ExitCodes.Usage), output);
    }

    [TestCase("{")]
    [TestCase("""{"version":100}""")]
    public async Task MalformedOrFutureSettingsFailInitAndBatchImportButNotExplicitFileImport(string json)
    {
        Directory.CreateDirectory(_paths.DataDirectory);
        await File.WriteAllTextAsync(_settings.FilePath, json);
        byte[] original = await File.ReadAllBytesAsync(_settings.FilePath);
        FakePrompts prompts = new([], confirm: true);
        foreach (string command in new[] { "init", "import" })
        {
            (int exit, string output) = await Run([command], prompts);
            Assert.That(exit, Is.EqualTo(ExitCodes.Failed), output);
            Assert.That(output, Does.Contain("Configuration error"));
        }
        Assert.That(prompts.SelectionCalls, Is.Zero);
        Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.False);
        string source = await WriteLedger("arbitrary-folder", "Sanitized", 1);
        Assert.That((await Run(["import", source])).Exit, Is.Zero);
        Assert.That(await File.ReadAllBytesAsync(_settings.FilePath), Is.EqualTo(original));
    }

    [Test]
    public async Task ConcurrentSettingsChangeAtConfirmationIsNotOverwritten()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        FakePrompts prompts = new([new(RootSelectionKind.Installation, _root)], confirm: true)
        {
            OnConfirm = () => _settings.Save(CompanionSettings.ForRoots(Path.Combine(_directory, "changed")))
        };
        (int exit, string output) = await Run(["init"], prompts);
        Assert.That(exit, Is.EqualTo(ExitCodes.Failed), output);
        Assert.That(output, Does.Contain("Settings changed"));
        Assert.That(_settings.Load().Settings!.InstallationRoots.Single(), Does.EndWith("changed"));
    }

    [Test]
    public async Task ArgumentFreeImportWithoutConfigurationOrWithEmptyRootsAdvisesInitAndCreatesNoDatabase()
    {
        foreach (bool configure in new[] { false, true })
        {
            if (configure) _settings.Save(CompanionSettings.ForRoots());
            (int exit, string output) = await Run(["import"]);
            Assert.That(exit, Is.EqualTo(ExitCodes.Usage), output);
            Assert.That(output, Does.Contain("artisanlogbook init"));
            Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.False);
        }
    }

    [Test]
    public async Task ExplicitFileWithoutInitializationDoesNotDiscoverOrChangeConfiguration()
    {
        string source = await WriteLedger("_retail_", "Sanitized", 1);
        (int exit, string output) = await Run(["import", source]);
        Assert.That(exit, Is.Zero, output);
        Assert.That(File.Exists(_settings.FilePath), Is.False);
        _settings.Save(CompanionSettings.ForRoots(Path.Combine(_directory, "missing")));
        byte[] before = await File.ReadAllBytesAsync(_settings.FilePath);
        (exit, output) = await Run(["import", source]);
        Assert.That(exit, Is.Zero, output);
        Assert.That(output, Does.Not.Contain("discovery-failed").And.Not.Contain("Discovered sources"));
        Assert.That(await File.ReadAllBytesAsync(_settings.FilePath), Is.EqualTo(before));
    }

    [Test]
    public async Task RetailAndForeverAcrossMultipleRootsImportIntoOneDatabaseAndReplayIdempotently()
    {
        // Deliberately misleading directory names: C04 ledger evidence is authoritative.
        string retail = await WriteLedger("_forever_", "Sanitized-A", 1);
        string forever = await WriteLedger("_retail_", "Sanitized-B", 18);
        string secondRoot = Path.Combine(_directory, "second-installation");
        string secondSource = await WriteLedger("future-client", "Sanitized-C", 2, secondRoot);
        _settings.Save(CompanionSettings.ForRoots(_root, secondRoot));
        Dictionary<string, byte[]> originals = new();
        foreach (string source in new[] { retail, forever, secondSource })
            originals.Add(source, await File.ReadAllBytesAsync(source));
        for (int i = 0; i < 2; i++)
        {
            (int exit, string output) = await Run(["import"]);
            Assert.That(exit, Is.Zero, output);
            Assert.That(output, Does.Contain("Source:").And.Contain("Installation import totals")
                .And.Contain("Import complete"));
            Count(output, "Successful files", 3);
            Count(output, "Committed inserted crafts", i == 0 ? 3 : 0);
            Count(output, "Committed already-present crafts", i == 0 ? 0 : 3);
            using Store store = new(_paths.ResolveDatabase(null), readOnly: true);
            Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(3));
            Assert.That(store.ReadStatus().Contexts.Select(context => (int)context.Game.Project), Is.EquivalentTo(new[] { 1, 18, 2 }));
        }
        foreach ((string path, byte[] original) in originals)
            Assert.That(await File.ReadAllBytesAsync(path), Is.EqualTo(original));
        Assert.That(Directory.GetFiles(_paths.DataDirectory, "*.duckdb"), Has.Length.EqualTo(1));
    }

    [Test]
    public async Task InvalidLedgerBetweenValidLedgersReportsPartialSuccessAndKeepsIndependentCommits()
    {
        string first = await WriteLedger("a-flavor", "Sanitized-A", 1);
        string invalid = await WriteLedger("b-flavor", "Sanitized-B", 1);
        await File.WriteAllTextAsync(invalid, "ArtisanLogbookDB = {");
        string last = await WriteLedger("c-flavor", "Sanitized-C", 18);
        _settings.Save(CompanionSettings.ForRoots(_root));
        byte[][] originals = await Task.WhenAll(new[] { first, invalid, last }.Select(path => File.ReadAllBytesAsync(path)));
        string database = Path.Combine(_directory, "override.duckdb");
        (int exit, string output) = await Run(["import", "--database", database]);
        Assert.That(exit, Is.EqualTo(ExitCodes.Rejected), output);
        Assert.That(output, Does.Contain("partial success").And.Contain("Import rejected")
            .And.Contain("Valid files remain committed").And.Contain("No craft or dimension changes were committed"));
        Count(output, "Successful files", 2);
        Count(output, "Rejected files", 1);
        Count(output, "Failed files", 0);
        Count(output, "Committed inserted crafts", 2);
        using (Store store = new(database, readOnly: true))
            Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(2));
        for (int i = 0; i < originals.Length; i++)
            Assert.That(await File.ReadAllBytesAsync(new[] { first, invalid, last }[i]), Is.EqualTo(originals[i]));
        Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.False);
        (exit, output) = await Run(["import", "--database", database]);
        Assert.That(exit, Is.EqualTo(ExitCodes.Rejected), output);
        Count(output, "Committed inserted crafts", 0);
        Count(output, "Committed already-present crafts", 2);
    }

    [Test]
    public async Task UnrelatedSkippedLinkPreservesWarningsWithoutFailingSuccessfulImports()
    {
        string source = await WriteLedger("_retail_", "Sanitized", 1);
        byte[] before = await File.ReadAllBytesAsync(source);
        _settings.Save(CompanionSettings.ForRoots(_root));
        string link = Path.Combine(_root, "unrelated-link");
        Directory.CreateSymbolicLink(link, _directory);
        try
        {
            (int exit, string output) = await Run(["import"]);
            Assert.That(exit, Is.EqualTo(ExitCodes.Success), output);
            Assert.That(output, Does.Contain("Warning (link-skipped)").And.Contain("Import complete")
                .And.Not.Contain("partial success").And.Not.Contain("Incomplete installation import"));
            Count(output, "Discovery errors", 0);
            Count(output, "Discovery warnings", 1);
            Count(output, "Successful files", 1);
            Count(output, "Committed inserted crafts", 1);
        }
        finally { Directory.Delete(link); }
        Assert.That(await File.ReadAllBytesAsync(source), Is.EqualTo(before));
    }

    [Test]
    public async Task IncidentalLayoutWarningsDoNotFailButAccountSourceErrorsProducePartialSuccess()
    {
        await WriteLedger("_retail_", "Sanitized", 1);
        _settings.Save(CompanionSettings.ForRoots(_root));
        File.WriteAllText(Path.Combine(_root, "_retail_", "Interface"), "unrelated");
        (int exit, string output) = await Run(["import"]);
        Assert.That(exit, Is.Zero, output);
        Assert.That(output, Does.Contain("Warning (discovery-failed)").And.Contain("Import complete")
            .And.Not.Contain("partial success"));
        Count(output, "Discovery errors", 0);
        Count(output, "Discovery warnings", 1);

        string account = Path.Combine(_root, "_retail_", "WTF", "Account", "Sanitized-B");
        Directory.CreateDirectory(account);
        File.WriteAllText(Path.Combine(account, "SavedVariables"), "invalid source directory");
        (exit, output) = await Run(["import"]);
        Assert.That(exit, Is.EqualTo(ExitCodes.Failed), output);
        Assert.That(output, Does.Contain("Error (discovery-failed)").And.Contain("partial success"));
        Count(output, "Discovery errors", 1);
        Count(output, "Discovery warnings", 1);
        Count(output, "Committed already-present crafts", 1);
    }

    [TestCase("unrelated", ExitCodes.Success)]
    [TestCase("root", ExitCodes.Failed)]
    [TestCase("savedVariables", ExitCodes.Failed)]
    public async Task InaccessibleLocationSeverityControlsImportExit(string location, int expectedExit)
    {
        if (OperatingSystem.IsWindows())
        {
            Assert.Ignore("Unix permissions; portable path failures and warning exits are tested separately.");
            return;
        }
        await WriteLedger("_retail_", "Sanitized-A", 1);
        string second = await WriteLedger("_forever_", "Sanitized-B", 18);
        string unrelated = Path.Combine(_root, "unrelated");
        Directory.CreateDirectory(unrelated);
        _settings.Save(CompanionSettings.ForRoots(_root));
        string inaccessible = location switch
        {
            "root" => _root,
            "savedVariables" => Path.GetDirectoryName(second)!,
            _ => unrelated
        };
        UnixFileMode mode = File.GetUnixFileMode(inaccessible);
        try
        {
            File.SetUnixFileMode(inaccessible, UnixFileMode.None);
            (int exit, string output) = await Run(["import"]);
            Assert.That(exit, Is.EqualTo(expectedExit), output);
            if (location == "unrelated")
            {
                Assert.That(output, Does.Contain("Warning (discovery-failed)").And.Contain("Import complete")
                    .And.Not.Contain("partial success"));
                Count(output, "Successful files", 2);
            }
            else
            {
                Assert.That(output, Does.Contain("Error (discovery-failed)"));
                if (location == "savedVariables")
                {
                    Assert.That(output, Does.Contain("partial success"));
                    Count(output, "Successful files", 1);
                }
                else
                    Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.False);
            }
        }
        finally { File.SetUnixFileMode(inaccessible, mode); }
    }

    [Test]
    public async Task DiscoveryFailureAlongsideValidSourceIsExplicitAndNonzero()
    {
        await WriteLedger("_retail_", "Sanitized", 1);
        _settings.Save(CompanionSettings.ForRoots(_root, Path.Combine(_directory, "missing")));
        (int exit, string output) = await Run(["import"]);
        Assert.That(exit, Is.EqualTo(ExitCodes.Failed), output);
        Assert.That(output, Does.Contain("discovery-failed").And.Contain("partial success"));
        Count(output, "Successful files", 1);
        Count(output, "Discovery errors", 1);
    }

    [Test]
    public async Task OversizedSourceAlongsideValidSourceContinuesWithRejectedExit()
    {
        string invalid = await WriteLedger("a-flavor", "Sanitized-A", 1);
        using (FileStream stream = new(invalid, FileMode.Open, FileAccess.Write)) stream.SetLength(64L * 1024 * 1024 + 1);
        await WriteLedger("b-flavor", "Sanitized-B", 18);
        _settings.Save(CompanionSettings.ForRoots(_root));
        (int exit, string output) = await Run(["import"]);
        Assert.That(exit, Is.EqualTo(ExitCodes.Rejected), output);
        Assert.That(output, Does.Contain("source-too-large").And.Contain("partial success"));
        Count(output, "Successful files", 1);
        Count(output, "Rejected files", 1);
    }

    [Test]
    public async Task LockedSourceAlongsideValidSourceContinuesWithFailedExit()
    {
        string locked = await WriteLedger("a-flavor", "Sanitized-A", 1);
        await WriteLedger("b-flavor", "Sanitized-B", 18);
        _settings.Save(CompanionSettings.ForRoots(_root));
        byte[] before = await File.ReadAllBytesAsync(locked);
        using (FileStream stream = new(locked, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            (int exit, string output) = await Run(["import"]);
            Assert.That(exit, Is.EqualTo(ExitCodes.Failed), output);
            Assert.That(output, Does.Contain("source-read-failed").And.Contain("partial success"));
            Count(output, "Failed files", 1);
            Count(output, "Successful files", 1);
            using Store store = new(_paths.ResolveDatabase(null), readOnly: true);
            Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(1));
        }
        Assert.That(await File.ReadAllBytesAsync(locked), Is.EqualTo(before));
    }

    [Test]
    public async Task NoLedgerFoundFailsClearlyWithoutCreatingDatabase()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        (int exit, string output) = await Run(["import"]);
        Assert.That(exit, Is.EqualTo(ExitCodes.Failed), output);
        Assert.That(output, Does.Contain("No ArtisanLogbook_Core.lua ledgers found").And.Contain("No import performed"));
        Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.False);
    }

    private async Task<string> WriteLedger(string flavor, string account, int project, string? root = null)
    {
        string directory = Path.Combine(root ?? _root, flavor, "WTF", "Account", account, "SavedVariables");
        Directory.CreateDirectory(directory);
        string file = Path.Combine(directory, "ArtisanLogbook_Core.lua");
        await File.WriteAllTextAsync(file, CompanionCommandAppTests.Snapshot(project, null, 1));
        return file;
    }

    private async Task<(int Exit, string Output)> Run(
        string[] args, IInitializationPrompts? prompts = null, IEnumerable<string>? hints = null)
    {
        using TestConsole console = new();
        console.Width(240);
        if (args[0] == "import") args = [.. args, "--verbose"];
        int exit = await CompanionCommandApp.Create(console, _paths, prompts, hints ?? []).RunAsync(args);
        return (exit, console.Output);
    }

    private static void Count(string output, string label, int count) =>
        Assert.That(output, Does.Match(Regex.Escape(label) + @"\s*[|\u2502]\s*" +
            count.ToString(CultureInfo.InvariantCulture) + @"\s*[|\u2502]"));

    private sealed class FakePrompts(IEnumerable<RootSelection> selections, bool confirm) : IInitializationPrompts
    {
        private readonly Queue<RootSelection> _selections = new(selections);
        public bool IsInteractive { get; init; } = true;
        public Queue<string?> ManualRoots { get; init; } = new();
        public IReadOnlyList<string>? Candidates { get; private set; }
        public string? Current { get; private set; }
        public int SelectionCalls { get; private set; }
        public Action? OnConfirm { get; init; }

        public RootSelection SelectRoot(IReadOnlyList<string> candidates, string? current)
        {
            SelectionCalls++;
            Candidates = candidates;
            Current = current;
            return _selections.Dequeue();
        }

        public string? EnterRoot(string? current) => ManualRoots.Dequeue();
        public bool Confirm(CompanionSettings proposed)
        {
            OnConfirm?.Invoke();
            return confirm;
        }
    }
}
