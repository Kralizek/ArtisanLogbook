using System.Text.Json;

using ArtisanLogbook.Runtime;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class CompanionSettingsTests
{
    private string _directory = null!;
    private ApplicationPaths _paths = null!;
    private CompanionSettingsStore _store = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Settings.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _paths = new(CompanionPlatform.Linux, _directory, _directory, null, _directory);
        _store = new(_paths);
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [Test]
    public void MissingSettingsDoNotCreateAnything()
    {
        Assert.That(_store.Load().Status, Is.EqualTo(SettingsStatus.Missing));
        Assert.That(Directory.Exists(_paths.DataDirectory), Is.False);
        Assert.That(_paths.SettingsFile, Is.EqualTo(Path.Combine(Path.GetDirectoryName(_paths.ResolveDatabase(null))!, "settings.json")));
    }

    [Test]
    public void HumanReadableVersionedRoundTripNormalizesMultipleRootsWithoutDatabase()
    {
        string first = Path.Combine(_directory, "wow");
        string second = Path.Combine(_directory, "other");
        _store.Save(CompanionSettings.ForRoots(first + Path.DirectorySeparatorChar, second));
        SettingsLoadResult loaded = _store.Load();
        Assert.That(loaded.Status, Is.EqualTo(SettingsStatus.Loaded), loaded.Diagnostic);
        Assert.That(loaded.Settings!.Version, Is.EqualTo(1));
        Assert.That(loaded.Settings.InstallationRoots, Is.EqualTo(new[] { first, second }));
        string json = File.ReadAllText(_store.FilePath);
        Assert.That(json, Does.Contain("\n").And.Contain("\"version\": 1").And.Contain("\"installationRoots\""));
        Assert.That(Directory.GetFiles(_paths.DataDirectory), Is.EqualTo(new[] { _store.FilePath }));
        Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.False);
    }

    [TestCase("{", SettingsStatus.Invalid)]
    [TestCase("null", SettingsStatus.Invalid)]
    [TestCase("[]", SettingsStatus.Invalid)]
    [TestCase("{}", SettingsStatus.Invalid)]
    [TestCase("""{"version":"1","installationRoots":[]}""", SettingsStatus.Invalid)]
    [TestCase("""{"version":0,"installationRoots":[]}""", SettingsStatus.Invalid)]
    [TestCase("""{"version":1.5,"installationRoots":[]}""", SettingsStatus.Invalid)]
    [TestCase("""{"version":2,"future":true}""", SettingsStatus.Unsupported)]
    [TestCase("""{"version":1}""", SettingsStatus.Invalid)]
    [TestCase("""{"version":1,"installationRoots":null}""", SettingsStatus.Invalid)]
    [TestCase("""{"version":1,"installationRoots":[null]}""", SettingsStatus.Invalid)]
    [TestCase("""{"version":1,"installationRoots":["relative"]}""", SettingsStatus.Invalid)]
    [TestCase("""{"version":1,"installationRoots":[],"other":true}""", SettingsStatus.Invalid)]
    [TestCase("""{"version":1,"version":1,"installationRoots":[]}""", SettingsStatus.Invalid)]
    public void InvalidOrUnsupportedSettingsAreNeverOverwritten(string json, SettingsStatus status)
    {
        Directory.CreateDirectory(_paths.DataDirectory);
        File.WriteAllText(_store.FilePath, json);
        byte[] before = File.ReadAllBytes(_store.FilePath);
        SettingsLoadResult loaded = _store.Load();
        Assert.That(loaded.Status, Is.EqualTo(status), loaded.Diagnostic);
        Assert.That(loaded.Diagnostic, Does.Contain(_store.FilePath));
        Assert.That(() => _store.Save(CompanionSettings.ForRoots(_directory)), Throws.TypeOf<CompanionSettingsException>());
        Assert.That(File.ReadAllBytes(_store.FilePath), Is.EqualTo(before));
        Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.False);
    }

    [Test]
    public void DirectoryAtSettingsPathIsUnreadableAndCannotBeReplaced()
    {
        Directory.CreateDirectory(_store.FilePath);
        Assert.That(_store.Load().Status, Is.EqualTo(SettingsStatus.Unreadable));
        Assert.That(() => _store.Save(CompanionSettings.ForRoots()), Throws.TypeOf<CompanionSettingsException>());
        Assert.That(Directory.Exists(_store.FilePath), Is.True);
    }

    [Test]
    public void DuplicateNormalizedRootsAndInvalidSaveVersionAreRejected()
    {
        Assert.That(() => _store.Save(CompanionSettings.ForRoots(_directory, _directory + Path.DirectorySeparatorChar)),
            Throws.ArgumentException);
        Assert.That(() => _store.Save(new() { Version = 2, InstallationRoots = [] }), Throws.ArgumentException);
        Assert.That(File.Exists(_store.FilePath), Is.False);
    }

    [Test]
    public void CancellationAndStaleWizardLeavePreviousConfigurationByteForByte()
    {
        _store.Save(CompanionSettings.ForRoots(_directory));
        SettingsLoadResult earlier = _store.Load();
        _store.Save(CompanionSettings.ForRoots(Path.Combine(_directory, "new")));
        byte[] before = File.ReadAllBytes(_store.FilePath);
        Assert.That(() => _store.Save(CompanionSettings.ForRoots(), new CancellationToken(canceled: true)),
            Throws.TypeOf<OperationCanceledException>());
        Assert.That(() => _store.Save(CompanionSettings.ForRoots(), expected: earlier),
            Throws.TypeOf<CompanionSettingsException>().With.Message.Contains("changed"));
        Assert.That(File.ReadAllBytes(_store.FilePath), Is.EqualTo(before));
        Assert.That(Directory.GetFiles(_paths.DataDirectory), Is.EqualTo(new[] { _store.FilePath }));
    }

    [Test]
    public async Task ReplacementReadersOnlySeeCompleteSettings()
    {
        _store.Save(CompanionSettings.ForRoots(_directory));
        Task reader = Task.Run(() =>
        {
            for (int i = 0; i < 200; i++)
            {
                using FileStream stream = new(_store.FilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using JsonDocument document = JsonDocument.Parse(stream);
                Assert.That(document.RootElement.GetProperty("version").GetInt32(), Is.EqualTo(1));
                Assert.That(document.RootElement.GetProperty("installationRoots").GetArrayLength(), Is.EqualTo(1));
            }
        });
        for (int i = 0; i < 30; i++)
            _store.Save(CompanionSettings.ForRoots(Path.Combine(_directory, i.ToString(System.Globalization.CultureInfo.InvariantCulture))));
        await reader;
        Assert.That(Directory.GetFiles(_paths.DataDirectory), Is.EqualTo(new[] { _store.FilePath }));
    }

    [Test]
    public void OversizedSettingsAreUnreadableAndNotOverwritten()
    {
        Directory.CreateDirectory(_paths.DataDirectory);
        using (FileStream stream = new(_store.FilePath, FileMode.CreateNew, FileAccess.Write))
            stream.SetLength(1024 * 1024 + 1);
        Assert.That(_store.Load().Status, Is.EqualTo(SettingsStatus.Unreadable));
        Assert.That(() => _store.Save(CompanionSettings.ForRoots()), Throws.TypeOf<CompanionSettingsException>());
        Assert.That(new FileInfo(_store.FilePath).Length, Is.EqualTo(1024 * 1024 + 1));
    }

    [Test]
    public void LinkedSettingsAreNotReadOrReplaced()
    {
        Directory.CreateDirectory(_paths.DataDirectory);
        string target = Path.Combine(_directory, "external.json");
        File.WriteAllText(target, """{"version":1,"installationRoots":[]}""");
        byte[] before = File.ReadAllBytes(target);
        File.CreateSymbolicLink(_store.FilePath, target);
        try
        {
            Assert.That(_store.Load().Status, Is.EqualTo(SettingsStatus.Unreadable));
            Assert.That(() => _store.Save(CompanionSettings.ForRoots()), Throws.TypeOf<CompanionSettingsException>());
            Assert.That(File.ReadAllBytes(target), Is.EqualTo(before));
            Assert.That(new FileInfo(_store.FilePath).LinkTarget, Is.Not.Null);
        }
        finally { File.Delete(_store.FilePath); }
    }

    [Test]
    public void WindowsRenameFailureLeavesCompleteOriginalAndCleansTemporaryFile()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Ignore("Windows sharing denies replacement; Unix write failure is covered separately.");
            return;
        }
        _store.Save(CompanionSettings.ForRoots(_directory));
        byte[] before = File.ReadAllBytes(_store.FilePath);
        using (FileStream locked = new(_store.FilePath, FileMode.Open, FileAccess.Read, FileShare.Read))
            Assert.That(() => _store.Save(CompanionSettings.ForRoots()), Throws.InstanceOf<IOException>());
        Assert.That(File.ReadAllBytes(_store.FilePath), Is.EqualTo(before));
        Assert.That(Directory.GetFiles(_paths.DataDirectory), Is.EqualTo(new[] { _store.FilePath }));
    }

    [Test]
    public void UnixPermissionsProduceExplicitReadAndSaveFailuresWithoutReplacement()
    {
        if (OperatingSystem.IsWindows())
        {
            Assert.Ignore("Unix permission test; Windows path failure is covered separately.");
            return;
        }
        _store.Save(CompanionSettings.ForRoots(_directory));
        byte[] before = File.ReadAllBytes(_store.FilePath);
        UnixFileMode fileMode = File.GetUnixFileMode(_store.FilePath);
        UnixFileMode directoryMode = File.GetUnixFileMode(_paths.DataDirectory);
        try
        {
            File.SetUnixFileMode(_store.FilePath, UnixFileMode.None);
            Assert.That(_store.Load().Status, Is.EqualTo(SettingsStatus.Unreadable));
            Assert.That(() => _store.Save(CompanionSettings.ForRoots()), Throws.TypeOf<CompanionSettingsException>());
            File.SetUnixFileMode(_store.FilePath, fileMode);
            File.SetUnixFileMode(_paths.DataDirectory, UnixFileMode.UserRead | UnixFileMode.UserExecute);
            Assert.That(() => _store.Save(CompanionSettings.ForRoots()), Throws.TypeOf<UnauthorizedAccessException>());
        }
        finally
        {
            File.SetUnixFileMode(_paths.DataDirectory, directoryMode);
            File.SetUnixFileMode(_store.FilePath, fileMode);
        }
        Assert.That(File.ReadAllBytes(_store.FilePath), Is.EqualTo(before));
    }
}
