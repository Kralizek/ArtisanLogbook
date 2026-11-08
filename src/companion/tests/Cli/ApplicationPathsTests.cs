using ArtisanLogbook.Cli;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class ApplicationPathsTests
{
    private static readonly string Root = Path.GetPathRoot(Path.GetTempPath())!;
    private static readonly string Home = Path.Combine(Root, "users", "test");
    private static readonly string LocalData = Path.Combine(Home, "local-data");
    private static readonly string WorkingDirectory = Path.Combine(Root, "working");
    private static readonly string Suffix = Path.Combine("ArtisanLogbook", "Companion", "history.duckdb");

    [Test]
    public void WindowsUsesLocalApplicationData() =>
        Assert.That(Paths(CompanionPlatform.Windows).ResolveDatabase(null),
            Is.EqualTo(Path.Combine(LocalData, Suffix)));

    [Test]
    public void MacOSUsesLibraryApplicationSupport() =>
        Assert.That(Paths(CompanionPlatform.MacOS).ResolveDatabase(null),
            Is.EqualTo(Path.Combine(Home, "Library", "Application Support", Suffix)));

    [TestCase(null)]
    [TestCase("")]
    [TestCase(" ")]
    [TestCase("relative/path")]
    public void LinuxFallsBackWhenXdgIsUnsetEmptyOrRelative(string? xdg) =>
        Assert.That(Paths(CompanionPlatform.Linux, xdg).ResolveDatabase(null),
            Is.EqualTo(Path.Combine(Home, ".local", "share", Suffix)));

    [Test]
    public void LinuxHonorsAbsoluteXdgDataHome()
    {
        string xdg = Path.Combine(Root, "xdg-data");
        Assert.That(Paths(CompanionPlatform.Linux, xdg).ResolveDatabase(null),
            Is.EqualTo(Path.Combine(xdg, Suffix)));
    }

    [TestCase(CompanionPlatform.Windows)]
    [TestCase(CompanionPlatform.MacOS)]
    [TestCase(CompanionPlatform.Linux)]
    public void AbsoluteAndRelativeOverridesReplaceDefault(CompanionPlatform platform)
    {
        ApplicationPaths paths = Paths(platform);
        string absolute = Path.Combine(Root, "override", "history.duckdb");
        Assert.Multiple(() =>
        {
            Assert.That(paths.ResolveDatabase(absolute), Is.EqualTo(absolute));
            Assert.That(paths.ResolveDatabase("history.duckdb"),
                Is.EqualTo(Path.Combine(WorkingDirectory, "history.duckdb")));
            Assert.That(paths.ResolveSource("snapshot.lua"),
                Is.EqualTo(Path.Combine(WorkingDirectory, "snapshot.lua")));
        });
    }

    [Test]
    public void MissingUserDirectoryRequiresExplicitOverrideInsteadOfExecutableFallback()
    {
        ApplicationPaths paths = new(CompanionPlatform.Windows, "", "", null, WorkingDirectory);
        Assert.That(() => paths.ResolveDatabase(null), Throws.InvalidOperationException
            .With.Message.Contains("--database"));
        Assert.That(paths.ResolveDatabase("override.duckdb"),
            Is.EqualTo(Path.Combine(WorkingDirectory, "override.duckdb")));
    }

    private static ApplicationPaths Paths(CompanionPlatform platform, string? xdg = null) =>
        new(platform, Home, LocalData, xdg, WorkingDirectory);
}
