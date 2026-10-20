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

    [Test]
    public void IdenticalGameContextsMerge()
    {
        HistoryMergeResult result = HistoryReconciler.Merge([Craft(new GameContext(GameProject.Retail))], [Craft(new GameContext(GameProject.Forever))]);
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
    public void GameProjectAffectsCraftValueEquality()
    {
        Assert.That(Craft(GameProject.Retail), Is.Not.EqualTo(Craft(GameProject.Forever)));
    }
}
