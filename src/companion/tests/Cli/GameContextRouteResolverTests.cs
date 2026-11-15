using ArtisanLogbook.History;
using ArtisanLogbook.Runtime;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class GameContextRouteResolverTests
{
    [TestCase("retail", 1, "Retail")]
    [TestCase("forever", 18, "Forever")]
    public void SupportedGameAliasesResolveWithoutHistory(string alias, int project, string displayName)
    {
        GameContext context = new((GameProject)project);

        Assert.That(GameContextRouteResolver.TryResolve(alias, out ResolvedGameContext? resolved), Is.True);
        Assert.That(resolved, Is.EqualTo(new ResolvedGameContext(context, GameContextCodec.Encode(context), alias, displayName)));
    }

    [Test]
    public void CanonicalIdsAndSupportedAliasesResolveToTheSameCompleteContext()
    {
        GameContext[] contexts =
        [
            new(GameProject.Retail),
            new(GameProject.Forever),
            new(GameProject.Forever, "Hardcore"),
            new((GameProject)98765),
            new((GameProject)98765, "Track-A"),
            new((GameProject)98765, "Track A"),
            new((GameProject)98765, "track /?%#雪")
        ];

        foreach (GameContext context in contexts)
        {
            ResolvedGameContext expected = GameContextRouteResolver.Describe(context);
            string expectedAlias = context.ProgressionTrack is null && context.Project == GameProject.Retail
                ? "retail"
                : context.ProgressionTrack is null && context.Project == GameProject.Forever
                    ? "forever"
                    : expected.CanonicalId;
            Assert.That(expected.RouteAlias, Is.EqualTo(expectedAlias));
            Assert.That(GameContextRouteResolver.TryResolve(expected.RouteAlias, out ResolvedGameContext? byAlias), Is.True);
            Assert.That(GameContextRouteResolver.TryResolve(expected.CanonicalId, out ResolvedGameContext? byId), Is.True);
            Assert.That(byAlias, Is.EqualTo(expected));
            Assert.That(byId, Is.EqualTo(expected));
        }
    }

    [Test]
    public void CanonicalIdentifiersAreFallbackAliasesForUnsupportedProjectsAndTracks()
    {
        GameContext unknownProject = new((GameProject)98765);
        GameContext unsupportedProject = new((GameProject)2);
        GameContext unrecognizedTrack = new(GameProject.Forever, "Experimental");
        GameContext spacedTrack = new(GameProject.Forever, "Track A");

        ResolvedGameContext unknown = GameContextRouteResolver.Describe(unknownProject);
        ResolvedGameContext unsupported = GameContextRouteResolver.Describe(unsupportedProject);
        ResolvedGameContext experimental = GameContextRouteResolver.Describe(unrecognizedTrack);
        ResolvedGameContext spaced = GameContextRouteResolver.Describe(spacedTrack);

        Assert.Multiple(() =>
        {
            Assert.That(unknown.RouteAlias, Is.EqualTo("98765"));
            Assert.That(unknown.DisplayName, Is.EqualTo("Project 98765"));
            Assert.That(unsupported.RouteAlias, Is.EqualTo("2"));
            Assert.That(unsupported.DisplayName, Is.EqualTo("Project 2"));
            Assert.That(experimental.RouteAlias, Is.EqualTo("18-Experimental"));
            Assert.That(spaced.RouteAlias, Is.EqualTo("18-Track~0020A"));
            Assert.That(experimental.DisplayName, Is.EqualTo("Forever Experimental"));
        });
    }

    [Test]
    public void CanonicalIdentifierRemainsValidAlongsideFriendlyAlias()
    {
        Assert.That(GameContextRouteResolver.TryResolve("retail", out ResolvedGameContext? byAlias), Is.True);
        Assert.That(GameContextRouteResolver.TryResolve("1", out ResolvedGameContext? byCanonicalId), Is.True);
        Assert.That(byAlias, Is.EqualTo(byCanonicalId));
        Assert.That(byCanonicalId!.CanonicalId, Is.EqualTo("1"));
    }

    [TestCase("")]
    [TestCase("RETAIL")]
    [TestCase("status")]
    [TestCase("forever-hardcore")]
    [TestCase("project-98765")]
    [TestCase("ctx-18-t-004100")]
    [TestCase("18-")]
    [TestCase("0")]
    [TestCase("2147483648")]
    public void InvalidOrObsoleteAliasesDoNotResolve(string locator)
    {
        Assert.That(GameContextRouteResolver.TryResolve(locator, out ResolvedGameContext? resolved), Is.False);
        Assert.That(resolved, Is.Null);
    }
}
