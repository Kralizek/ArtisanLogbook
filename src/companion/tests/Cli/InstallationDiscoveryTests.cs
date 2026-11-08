using ArtisanLogbook.Runtime;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class InstallationDiscoveryTests
{
    private string _directory = null!;
    private string _root = null!;
    private readonly InstallationDiscovery _discovery = new();

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Discovery.Tests", Guid.NewGuid().ToString("N"));
        _root = Path.Combine(_directory, "installation");
        Directory.CreateDirectory(_root);
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [Test]
    public void FindsAllFlavorsAndAccountsSortedAndDeduplicatedWithoutReadingOrModifyingFiles()
    {
        string[] files =
        [
            Ledger("_retail_", "Sanitized-A"),
            Ledger("_classic_era_", "Sanitized-B"),
            Ledger("_forever_", "Sanitized-C"),
            Ledger("future-client", "Sanitized-D"),
            Ledger("future-client", "Sanitized-E")
        ];
        foreach (string file in files) File.WriteAllText(file, "This service does not parse ledgers.");
        DiscoveryResult result = _discovery.DiscoverSavedVariables([_root, _root + Path.DirectorySeparatorChar, Path.Combine(_root, ".")]);
        Assert.That(result.Paths, Is.EqualTo(files.Order(InstallationDiscovery.PathComparer)));
        Assert.That(result.Diagnostics, Is.Empty);
        foreach (string file in files) Assert.That(File.ReadAllText(file), Is.EqualTo("This service does not parse ledgers."));
    }

    [Test]
    public void EmptyClientAndMissingAddonLedgersAreNormalAndUnrelatedFilesAreIgnored()
    {
        Directory.CreateDirectory(Path.Combine(_root, "empty-client", "Interface", "AddOns"));
        string path = Ledger("_retail_", "Sanitized-A");
        foreach (string name in new[]
        {
            "ArtisanLogbook_Core.lua.bak", "ArtisanLogbook_Core.lua.tmp", "ArtisanLogbook.lua",
            "ArtisanLogbook_Tracer.lua", "ArtisanLogbook_Core.lua~"
        })
            File.WriteAllText(Path.Combine(Path.GetDirectoryName(path)!, name), "ignore");
        string unrelated = Path.Combine(_root, "unrelated", "deep", "SavedVariables");
        Directory.CreateDirectory(unrelated);
        File.WriteAllText(Path.Combine(unrelated, "ArtisanLogbook_Core.lua"), "ignore");
        DiscoveryResult result = _discovery.DiscoverSavedVariables([_root]);
        Assert.That(result.Paths, Is.Empty);
        Assert.That(result.Diagnostics, Is.Empty);
        Assert.That(_discovery.ValidateRoot(_root).Paths, Is.EqualTo(new[] { _root }));
    }

    [Test]
    public void RootNameAloneIsNotValidationAndBrokenRootsAreDiagnosed()
    {
        Assert.That(_discovery.ValidateRoot(_root).Paths, Is.Empty);
        Assert.That(_discovery.ValidateRoot(_root).Diagnostics.Single().Code, Is.EqualTo("invalid-installation"));
        DiscoveryResult result = _discovery.DiscoverSavedVariables([Path.Combine(_directory, "missing"), "relative"]);
        Assert.That(result.Paths, Is.Empty);
        Assert.That(result.Diagnostics, Has.Count.EqualTo(2));
        Assert.That(result.HasErrors, Is.True);
    }

    [Test]
    public void DetectOnlyInspectsHintsAndValidatesLayout()
    {
        _ = Ledger("future-client", "Sanitized");
        string fake = Path.Combine(_directory, "World of Warcraft");
        Directory.CreateDirectory(fake);
        DiscoveryResult detected = _discovery.Detect([fake, _root, _root, Path.Combine(_directory, "absent")]);
        Assert.That(detected.Paths, Is.EqualTo(new[] { _root }));
        Assert.That(detected.Diagnostics.Single().Code, Is.EqualTo("invalid-installation"));
        Assert.That(_discovery.Detect([Path.Combine(_directory, "absent")]).Diagnostics, Is.Empty);
    }

    [TestCase(CompanionPlatform.Windows)]
    [TestCase(CompanionPlatform.MacOS)]
    [TestCase(CompanionPlatform.Linux)]
    public void OsHintsAreBoundedAndSupportHomeLocations(CompanionPlatform platform)
    {
        IReadOnlyList<string> hints = InstallationDiscovery.DefaultHints(platform, _directory,
            Path.Combine(_directory, "program-files"), Path.Combine(_directory, "program-files-x86"), Path.GetPathRoot(_directory)!);
        Assert.That(hints.Count, Is.InRange(2, 4));
        if (platform == CompanionPlatform.MacOS)
            Assert.That(hints, Is.EqualTo(new[]
            {
                "/Applications/World of Warcraft", Path.Combine(_directory, "Applications", "World of Warcraft")
            }));
        else
            Assert.That(hints.All(Path.IsPathFullyQualified), Is.True);
        Assert.That(hints.Any(path => path.StartsWith(_directory, StringComparison.Ordinal)), Is.True);
    }

    [Test]
    public void DirectoryAndFileLinksAreSkippedIncludingRootAncestorsAndBrokenLinks()
    {
        string ledger = Ledger("_retail_", "Sanitized");
        File.WriteAllText(ledger, "unchanged");
        string outside = Path.Combine(_directory, "outside");
        Directory.CreateDirectory(Path.Combine(outside, "WTF", "Account", "Other", "SavedVariables"));
        string linkedFlavor = Path.Combine(_root, "linked-client");
        Directory.CreateSymbolicLink(linkedFlavor, outside);
        string linkedAccount = Path.Combine(_root, "_retail_", "WTF", "Account", "Linked");
        Directory.CreateSymbolicLink(linkedAccount, Path.GetDirectoryName(Path.GetDirectoryName(ledger)!)!);
        string linkedRoot = Path.Combine(_directory, "root-link");
        Directory.CreateSymbolicLink(linkedRoot, _root);
        string broken = Path.Combine(_root, "broken-client");
        Directory.CreateSymbolicLink(broken, Path.Combine(_directory, "absent"));
        string fileLink = Ledger("_forever_", "Sanitized");
        File.CreateSymbolicLink(fileLink, ledger);
        try
        {
            DiscoveryResult result = _discovery.DiscoverSavedVariables([_root, linkedRoot, Path.Combine(linkedRoot, "_retail_")]);
            Assert.That(result.Paths, Is.EqualTo(new[] { ledger }));
            Assert.That(result.Diagnostics.Count(diagnostic => diagnostic.Code == "link-skipped"), Is.GreaterThanOrEqualTo(5));
            Assert.That(File.ReadAllText(ledger), Is.EqualTo("unchanged"));
        }
        finally
        {
            File.Delete(fileLink);
            Directory.Delete(linkedFlavor);
            Directory.Delete(linkedAccount);
            Directory.Delete(linkedRoot);
            if (OperatingSystem.IsWindows()) Directory.Delete(broken);
            else File.Delete(broken);
        }
    }

    [Test]
    public void IncidentalLayoutFailuresAreWarningsButKnownSourceFailuresAreErrors()
    {
        string ledger = Ledger("_retail_", "Sanitized");
        File.WriteAllText(ledger, "unchanged");
        string interfacePath = Path.Combine(_root, "_retail_", "Interface");
        File.WriteAllText(interfacePath, "unrelated file");
        string unknown = Path.Combine(_root, "unrelated");
        Directory.CreateDirectory(unknown);
        File.WriteAllText(Path.Combine(unknown, "WTF"), "not a client");
        DiscoveryResult result = _discovery.DiscoverSavedVariables([_root]);
        Assert.That(result.Paths, Is.EqualTo(new[] { ledger }));
        Assert.That(result.Diagnostics, Has.Count.EqualTo(2));
        Assert.That(result.Diagnostics.All(diagnostic => diagnostic.Severity == DiscoverySeverity.Warning), Is.True);
        Assert.That(result.HasErrors, Is.False);

        string known = Path.Combine(_root, "known-client");
        Directory.CreateDirectory(Path.Combine(known, "Interface", "AddOns"));
        string sourceBranch = Path.Combine(known, "WTF");
        File.WriteAllText(sourceBranch, "invalid source directory");
        result = _discovery.DiscoverSavedVariables([_root]);
        Assert.That(result.Paths, Is.EqualTo(new[] { ledger }));
        Assert.That(result.Diagnostics.Single(diagnostic => diagnostic.Path == sourceBranch).Severity,
            Is.EqualTo(DiscoverySeverity.Error));
        Assert.That(result.HasErrors, Is.True);
    }

    [TestCase("unrelated", DiscoverySeverity.Warning)]
    [TestCase("root", DiscoverySeverity.Error)]
    [TestCase("accounts", DiscoverySeverity.Error)]
    [TestCase("savedVariables", DiscoverySeverity.Error)]
    public void InaccessibleLocationsAreClassifiedBySourceBoundary(string location, DiscoverySeverity severity)
    {
        if (OperatingSystem.IsWindows())
        {
            Assert.Ignore("Unix permissions; portable malformed-layout classification is tested separately.");
            return;
        }
        string ledger = Ledger("_retail_", "Sanitized");
        File.WriteAllText(ledger, "unchanged");
        string unrelated = Path.Combine(_root, "unrelated");
        Directory.CreateDirectory(unrelated);
        string inaccessible = location switch
        {
            "root" => _root,
            "accounts" => Path.Combine(_root, "_retail_", "WTF", "Account"),
            "savedVariables" => Path.GetDirectoryName(ledger)!,
            _ => unrelated
        };
        UnixFileMode mode = File.GetUnixFileMode(inaccessible);
        try
        {
            File.SetUnixFileMode(inaccessible, UnixFileMode.None);
            DiscoveryResult result = _discovery.DiscoverSavedVariables([_root]);
            Assert.That(result.Diagnostics, Is.Not.Empty);
            Assert.That(result.Diagnostics.All(diagnostic => diagnostic.Severity == severity), Is.True);
            Assert.That(result.HasErrors, Is.EqualTo(severity == DiscoverySeverity.Error));
            Assert.That(result.Paths, location == "unrelated" ? Is.EqualTo(new[] { ledger }) : Is.Empty);
        }
        finally { File.SetUnixFileMode(inaccessible, mode); }
    }

    [Test]
    public void InvalidDirectoryAndInaccessibleAccountsAreDiagnosedWhileOtherLedgersSurvive()
    {
        string ledger = Ledger("_retail_", "Sanitized");
        File.WriteAllText(ledger, "unchanged");
        string badAccount = Path.Combine(_root, "_retail_", "WTF", "Account", "Bad");
        Directory.CreateDirectory(badAccount);
        File.WriteAllText(Path.Combine(badAccount, "SavedVariables"), "not a directory");
        DiscoveryResult result = _discovery.DiscoverSavedVariables([_root]);
        Assert.That(result.Paths, Is.EqualTo(new[] { ledger }));
        Assert.That(result.HasErrors, Is.True);
        if (OperatingSystem.IsWindows()) return;
        string accounts = Path.GetDirectoryName(badAccount)!;
        UnixFileMode mode = File.GetUnixFileMode(accounts);
        try
        {
            File.SetUnixFileMode(accounts, UnixFileMode.None);
            result = _discovery.DiscoverSavedVariables([_root]);
            Assert.That(result.HasErrors, Is.True);
            Assert.That(result.Paths, Is.Empty);
            Assert.That(result.Diagnostics.Any(diagnostic => diagnostic.Path == accounts), Is.True);
        }
        finally { File.SetUnixFileMode(accounts, mode); }
    }

    private string Ledger(string flavor, string account)
    {
        string directory = Path.Combine(_root, flavor, "WTF", "Account", account, "SavedVariables");
        Directory.CreateDirectory(directory);
        return Path.Combine(directory, "ArtisanLogbook_Core.lua");
    }
}
