using System.Globalization;

using ArtisanLogbook.History;

using NUnit.Framework;

namespace Tests.History;

[TestFixture]
public class GameProjectTests
{
    private static readonly CharacterIdentity Character = new("project:1:region:3:realm:1309:guid:Player-1309-12345678");

    private static CraftObservation Craft(GameContext game) =>
        new(new CraftIdentity("origin", "craft-1"), game, DateTimeOffset.UnixEpoch, 123, Character);

    [Test]
    public void KnownValuesMatchBlizzardProjectIds()
    {
        Assert.Multiple(() =>
        {
            Assert.That((int)GameProject.Retail, Is.EqualTo(1));
            Assert.That((int)GameProject.ClassicEra, Is.EqualTo(2));
            Assert.That((int)GameProject.BurningCrusadeClassic, Is.EqualTo(5));
            Assert.That((int)GameProject.WrathClassic, Is.EqualTo(11));
            Assert.That((int)GameProject.CataclysmClassic, Is.EqualTo(14));
            Assert.That((int)GameProject.Forever, Is.EqualTo(18));
            Assert.That((int)GameProject.MistsClassic, Is.EqualTo(19));
        });
    }

    [Test]
    public void UnrecognizedProjectIdRoundTripsWithoutMappingToRetail()
    {
        GameProject future = (GameProject)12345;
        CraftObservation craft = Craft(new GameContext(future));
        Assert.That((int)craft.Game.Project, Is.EqualTo(12345));
        Assert.That(craft.Game.Project, Is.Not.EqualTo(GameProject.Retail));
    }

    [TestCase("1", 1, null)]
    [TestCase("18", 18, null)]
    [TestCase("18-Hardcore", 18, "Hardcore")]
    [TestCase("12345-future-track", 12345, "future-track")]
    [TestCase("18-a--b", 18, "a--b")]
    [TestCase("18-Track~0020~002F~003F~0025~0023~96EA", 18, "Track /?%#雪")]
    [TestCase("18-~0020spaced~0020", 18, " spaced ")]
    [TestCase("18-~007E002F", 18, "~002F")]
    public void CanonicalGameContextIdentifiersRoundTrip(string identifier, int project, string? track)
    {
        Assert.That(GameContextCodec.TryDecode(identifier, out GameContext? decoded), Is.True);
        Assert.That(decoded, Is.EqualTo(new GameContext((GameProject)project, track)));
        Assert.That(GameContextCodec.Encode(decoded!), Is.EqualTo(identifier));
    }

    [Test]
    public void CanonicalGameContextEncodingIsCultureIndependent()
    {
        CultureInfo original = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("ar-SA");
            Assert.That(GameContextCodec.Encode(new((GameProject)12345)), Is.EqualTo("12345"));
            Assert.That(GameContextCodec.Encode(new((GameProject)12345, "雪 /")), Is.EqualTo("12345-~96EA~0020~002F"));
        }
        finally
        {
            CultureInfo.CurrentCulture = original;
        }
    }

    [TestCase(null)]
    [TestCase("")]
    [TestCase("0")]
    [TestCase("-1")]
    [TestCase("+1")]
    [TestCase("01")]
    [TestCase("1-")]
    [TestCase("1-   ")]
    [TestCase("18-Track /?%#雪")]
    [TestCase("18-~")]
    [TestCase("18-~002")]
    [TestCase("18-~ZZZZ")]
    [TestCase("18-~0041")]
    [TestCase("18-~007e")]
    [TestCase("18-~0020")]
    [TestCase("1x")]
    [TestCase("2147483648")]
    [TestCase("2147483648-track")]
    public void InvalidOrNonCanonicalContextIdentifiersAreRejected(string? identifier)
    {
        Assert.That(GameContextCodec.TryDecode(identifier, out GameContext? decoded), Is.False);
        Assert.That(decoded, Is.Null);
    }

    [Test]
    public void CodecPreservesSurrogateCodeUnitsAndNeverDoubleDecodesEscapes()
    {
        string unpairedSurrogate = new('\ud800', 1);
        GameContext context = new((GameProject)18, unpairedSurrogate);
        string identifier = GameContextCodec.Encode(context);

        Assert.That(identifier, Is.EqualTo("18-~D800"));
        Assert.That(GameContextCodec.TryDecode(identifier, out GameContext? decoded), Is.True);
        Assert.That(decoded, Is.EqualTo(context));
        Assert.That(GameContextCodec.Encode(new((GameProject)18, "~002F")), Is.Not.EqualTo("18-a/b"));
    }

    [Test]
    public void DistinctCanonicalContextsHaveDistinctIdentifiers()
    {
        GameContext[] contexts =
        [
            new((GameProject)18),
            new((GameProject)18, "1"),
            new((GameProject)18, "Track-A"),
            new((GameProject)18, "Track A"),
            new((GameProject)18, "Track~0020A"),
            new((GameProject)19, "Track-A")
        ];
        string[] identifiers = contexts.Select(GameContextCodec.Encode).ToArray();

        Assert.That(identifiers, Is.Unique);
        for (int index = 0; index < contexts.Length; index++)
        {
            Assert.That(GameContextCodec.TryDecode(identifiers[index], out GameContext? decoded), Is.True);
            Assert.That(decoded, Is.EqualTo(contexts[index]));
        }
    }

    [Test]
    public void IdenticalGameContextsMerge()
    {
        HistoryMergeResult result = HistoryReconciler.Merge([Craft(new GameContext(GameProject.Retail))], [Craft(new GameContext(GameProject.Retail))]);
        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.Observations!.Single().Game.Project, Is.EqualTo(GameProject.Retail));
    }

    [Test]
    public void ContradictoryProjectsProduceConflict()
    {
        HistoryMergeResult result = HistoryReconciler.Merge([Craft(new GameContext(GameProject.Retail))], [Craft(new GameContext(GameProject.ClassicEra))]);
        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.Conflicts.Select(c => c.Field), Does.Contain(nameof(CraftObservation.Game)));
        Assert.That(result.Observations, Is.Null);
    }

    [Test]
    public void ProgressionTrackDistinguishesSameProject()
    {
        GameContext era = new(GameProject.ClassicEra, "era");
        GameContext hardcore = new(GameProject.ClassicEra, "hardcore");
        Assert.That(Craft(era), Is.Not.EqualTo(Craft(hardcore)));
        Assert.That(HistoryReconciler.Merge([Craft(era)], [Craft(hardcore)]).IsSuccessful, Is.False);
    }

    [Test]
    public void ProfessionExpansionDoesNotChangeGameContext()
    {
        CraftObservation midnight = Craft(new GameContext(GameProject.Retail)) with
        {
            ProfessionExpansionKey = "skillLine:2915"
        };
        CraftObservation dragonflight = midnight with
        {
            Identity = new CraftIdentity("origin", "craft-2"),
            ProfessionExpansionKey = "skillLine:2823"
        };
        Assert.That(midnight.Game, Is.EqualTo(dragonflight.Game));
        Assert.That(HistoryReconciler.Merge([midnight], [dragonflight]).Observations, Has.Count.EqualTo(2));
    }

    [Test]
    public void GameProjectAffectsCraftValueEquality()
    {
        Assert.That(Craft(new GameContext(GameProject.Retail)), Is.Not.EqualTo(Craft(new GameContext(GameProject.Forever))));
    }
}
