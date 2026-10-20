using ArtisanLogbook.History;

using NUnit.Framework;

namespace Tests.History;

[TestFixture]
public class GameProjectTests
{
    private static readonly CharacterIdentity Character = new("project:1:region:3:realm:1309:guid:Player-1309-12345678");

    private static CraftObservation Craft(GameProject? project) =>
        new(new CraftIdentity("origin", "craft-1"), DateTimeOffset.UnixEpoch, 123, Character, Project: project);

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
        CraftObservation craft = Craft(future);
        Assert.That((int)craft.Project!.Value, Is.EqualTo(12345));
        Assert.That(craft.Project, Is.Not.EqualTo(GameProject.Retail));
    }

    [Test]
    public void UnknownProjectCanBeEnrichedByKnownProject()
    {
        HistoryMergeResult result = HistoryReconciler.Merge([Craft(null)], [Craft(GameProject.Forever)]);
        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.Observations!.Single().Project, Is.EqualTo(GameProject.Forever));
    }

    [Test]
    public void ContradictoryProjectsProduceConflict()
    {
        HistoryMergeResult result = HistoryReconciler.Merge([Craft(GameProject.Retail)], [Craft(GameProject.ClassicEra)]);
        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.Conflicts.Select(c => c.Field), Does.Contain(nameof(CraftObservation.Project)));
        Assert.That(result.Observations, Is.Null);
    }

    [Test]
    public void GameProjectAffectsCraftValueEquality()
    {
        Assert.That(Craft(GameProject.Retail), Is.Not.EqualTo(Craft(GameProject.Forever)));
    }
}
