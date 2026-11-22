using ArtisanLogbook.History;
using ArtisanLogbook.Runtime.GraphQL;

using HotChocolate;

using NUnit.Framework;

namespace Tests.Cli;

public sealed class HistoryTokensTests
{
    private static readonly GameContext Retail = new(GameProject.Retail);

    [Test]
    public void DimensionIdsAreShortAndNeedNoUrlEncoding()
    {
        Assert.Multiple(() =>
        {
            Assert.That(HistoryTokens.Dimension("recipe", Retail, "1230868"), Is.EqualTo("r1-1230868"));
            Assert.That(HistoryTokens.Dimension("item", new(GameProject.Forever), "3827"), Is.EqualTo("i18-3827"));
            Assert.That(HistoryTokens.Dimension("expansion", Retail, "skillLine:2906"), Is.EqualTo("e1-skillLine.2906"));
            Assert.That(HistoryTokens.Context(Retail), Is.EqualTo("x1-"));
            Assert.That(HistoryTokens.DimensionCursor("recipe", new DimensionIdentity<int>(Retail, 42)), Is.EqualTo("nr1-42"));
            string character = HistoryTokens.Dimension("character", Retail,
                "project:1:region:3:realm:1403:guid:Player-1403-0A1B2C3D");
            Assert.That(character, Is.EqualTo("c1-project.1.region.3.realm.1403.guid.Player-1403-0A1B2C3D"));
            Assert.That(Uri.EscapeDataString(character), Is.EqualTo(character));
        });
    }

    [Test]
    public void TokensRoundTripIdentitiesTracksAndCursorInstants()
    {
        GameContext track = new(GameProject.Retail, "season:fresh-2 é");
        string unusual = "key with spaces_dots.and:colons*stars~é";
        (GameContext game, string key) = HistoryTokens.ParseDimension(HistoryTokens.Dimension("character", track, unusual), "character");
        CraftIdentity craft = new("legacy-ledger:1:project:1:guid:Player-1-2:7", "craft:42");
        DateTimeOffset recordedAt = new DateTimeOffset(2026, 11, 22, 14, 3, 7, TimeSpan.FromHours(-3)).AddTicks(1234567);
        CraftPagePosition position = HistoryTokens.ParseCraftCursor(HistoryTokens.CraftCursor(new(recordedAt, craft)));
        Assert.Multiple(() =>
        {
            Assert.That((game, key), Is.EqualTo((track, unusual)));
            Assert.That(HistoryTokens.ParseCraft(HistoryTokens.Craft(craft)), Is.EqualTo(craft));
            Assert.That(position.Identity, Is.EqualTo(craft));
            Assert.That(position.RecordedAt, Is.EqualTo(recordedAt));
            Assert.That(position.RecordedAt.Offset, Is.EqualTo(recordedAt.Offset));
            Assert.That(position.RecordedAt.Ticks, Is.EqualTo(recordedAt.Ticks));
        });
    }

    [TestCase("r1-42", "item")]
    [TestCase("r1-_34_32", "recipe")]
    [TestCase("r01-42", "recipe")]
    [TestCase("r1-", "recipe")]
    [TestCase("r-42", "recipe")]
    [TestCase("q1-42", "recipe")]
    [TestCase("r1-4%32", "recipe")]
    [TestCase("r1-_zz", "recipe")]
    [TestCase("r1.-42", "recipe")]
    [TestCase("", "recipe")]
    [TestCase("eyJub3QganNvbg", "recipe")]
    public void RejectsWrongKindsAndNonCanonicalSpellings(string token, string kind) =>
        Assert.That(() => HistoryTokens.ParseDimension(token, kind), Throws.TypeOf<GraphQLException>());

    [TestCase("k-origin")]
    [TestCase("k1-origin*craft.1")]
    [TestCase("nk-1*0*origin*craft.1")]
    public void RejectsMalformedCraftTokens(string token) =>
        Assert.That(() => HistoryTokens.ParseCraft(token), Throws.TypeOf<GraphQLException>());
}
