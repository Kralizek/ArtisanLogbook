using ArtisanLogbook.History;
using ArtisanLogbook.Runtime;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class GameContextRouteResolverTests
{
    [TestCase("retail", 1, null, "Retail")]
    [TestCase("classic-era", 2, null, "Classic Era")]
    [TestCase("wow-labs", 3, null, "WoW Labs")]
    [TestCase("burning-crusade-classic", 5, null, "Burning Crusade Classic")]
    [TestCase("wrath-classic", 11, null, "Wrath Classic")]
    [TestCase("cataclysm-classic", 14, null, "Cataclysm Classic")]
    [TestCase("forever", 18, null, "Forever")]
    [TestCase("mists-classic", 19, null, "Mists of Pandaria Classic")]
    [TestCase("forever-hardcore", 18, "Hardcore", "Forever Hardcore")]
    public void EstablishedAliasesResolveWithoutHistory(
        string alias, int project, string? track, string displayName)
    {
        Assert.That(GameContextRouteResolver.TryResolve(alias, out ResolvedGameContext? resolved), Is.True);
        Assert.That(resolved, Is.EqualTo(new ResolvedGameContext(
            new((GameProject)project, track), GameContextCodec.Encode(new((GameProject)project, track)),
            alias, displayName)));
    }

    [Test]
    public void CanonicalIdsAndAliasesResolveToTheSameCompleteContext()
    {
        GameContext[] contexts =
        [
            new(GameProject.Retail),
            new(GameProject.Forever, "Hardcore"),
            new((GameProject)98765),
            new((GameProject)98765, "Track-A"),
            new((GameProject)98765, "Track A"),
            new((GameProject)98765, "track /?%#雪")
        ];

        foreach (GameContext context in contexts)
        {
            ResolvedGameContext expected = GameContextRouteResolver.Describe(context);
            Assert.That(GameContextRouteResolver.TryResolve(expected.RouteAlias, out ResolvedGameContext? byAlias), Is.True);
            Assert.That(GameContextRouteResolver.TryResolve(expected.CanonicalId, out ResolvedGameContext? byId), Is.True);
            Assert.That(byAlias, Is.EqualTo(expected));
            Assert.That(byId, Is.EqualTo(expected));
        }
    }

    [Test]
    public void FallbackAliasesAreReversibleUniqueAndReservedRouteSafe()
    {
        GameContext spaceTrack = new((GameProject)98765, "Track A");
        GameContext hyphenTrack = new((GameProject)98765, "Track-A");
        ResolvedGameContext space = GameContextRouteResolver.Describe(spaceTrack);
        ResolvedGameContext hyphen = GameContextRouteResolver.Describe(hyphenTrack);

        Assert.Multiple(() =>
        {
            Assert.That(GameContextRouteResolver.Describe(new((GameProject)98765)).RouteAlias,
                Is.EqualTo("project-98765"));
            Assert.That(space.RouteAlias, Is.Not.EqualTo(hyphen.RouteAlias));
            Assert.That(space.RouteAlias, Does.StartWith("ctx-"));
            Assert.That(space.RouteAlias, Does.Not.Contain("/"));
            Assert.That(space.RouteAlias, Does.Not.Contain("?"));
            Assert.That(space.CanonicalId, Does.StartWith("98765-"));
            Assert.That(space.RouteAlias, Is.Not.EqualTo(space.CanonicalId));
        });
    }

    [TestCase("status")]
    [TestCase("health")]
    [TestCase("monitoring")]
    [TestCase("imports")]
    [TestCase("sources")]
    [TestCase("saved-investigations")]
    [TestCase("entity-preferences")]
    [TestCase("game-contexts")]
    [TestCase("openapi")]
    [TestCase("graphql")]
    [TestCase("project-1")]
    [TestCase("ctx-1-t-")]
    [TestCase("project-0")]
    [TestCase("ctx-18-t-")]
    [TestCase("ctx-18-t-00zz")]
    [TestCase("retail-forever")]
    public void InvalidAliasesDoNotResolveOrFallBack(string locator)
    {
        Assert.That(GameContextRouteResolver.TryResolve(locator, out ResolvedGameContext? resolved), Is.False);
        Assert.That(resolved, Is.Null);
    }
}
