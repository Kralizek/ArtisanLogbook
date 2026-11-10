using ArtisanLogbook.Runtime;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class SourceLogLabelsTests
{
    [Test]
    public void SingleSourceDoesNotExposeInstallationOrAccount()
    {
        DiscoveredSource source = Source("WoW", "_retail_", "PRIVATE_ACCOUNT");
        Assert.That(SourceLogLabels.Apply([source]).Single().LogLabel, Is.EqualTo("_retail_"));
    }

    [Test]
    public void MultipleInstallationsAreDistinguishedWithoutUnnecessaryAccountNames()
    {
        DiscoveredSource first = Source("WoW", "_retail_", "PRIVATE_ACCOUNT");
        DiscoveredSource second = Source("OtherWoW", "_retail_", "PRIVATE_ACCOUNT");
        Assert.That(SourceLogLabels.Apply([first, second]).Select(source => source.LogLabel),
            Is.EqualTo(new[] { "_retail_ / WoW", "_retail_ / OtherWoW" }));
    }

    [Test]
    public void AccountsAreIncludedOnlyWhenInstallationAndClientAreAmbiguous()
    {
        DiscoveredSource first = Source("WoW", "_retail_", "FIRST_ACCOUNT");
        DiscoveredSource second = Source("WoW", "_retail_", "SECOND_ACCOUNT");
        DiscoveredSource forever = Source("WoW", "_forever_", "PRIVATE_ACCOUNT");
        Assert.That(SourceLogLabels.Apply([first, second, forever]).Select(source => source.LogLabel),
            Is.EqualTo(new[] { "_retail_ / WoW / FIRST_ACCOUNT", "_retail_ / WoW / SECOND_ACCOUNT", "_forever_" }));
    }

    [Test]
    public void IdenticalInstallationAndAccountNamesHaveAStableShortIdentifierAsLastResort()
    {
        DiscoveredSource first = Source(Path.Combine("one", "WoW"), "_retail_", "ACCOUNT");
        DiscoveredSource second = Source(Path.Combine("two", "WoW"), "_retail_", "ACCOUNT");
        IReadOnlyList<DiscoveredSource> labeled = SourceLogLabels.Apply([first, second]);
        Assert.That(labeled[0].LogLabel, Is.EqualTo("_retail_ / WoW / ACCOUNT / " + first.Id[^6..]));
        Assert.That(labeled[1].LogLabel, Is.EqualTo("_retail_ / WoW / ACCOUNT / " + second.Id[^6..]));
        Assert.That(labeled.Select(source => source.LogLabel).Distinct().Count(), Is.EqualTo(2));
    }

    private static DiscoveredSource Source(string installation, string client, string account)
    {
        string path = Path.Combine(Path.GetTempPath(), "SourceLogLabels", installation, client,
            "WTF", "Account", account, "SavedVariables", "ArtisanLogbook_Core.lua");
        return new(SourceCatalog.IdFor(path), path, client, "ArtisanLogbook_Core.lua", null, null);
    }
}
