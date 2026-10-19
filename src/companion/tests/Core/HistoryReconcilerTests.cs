using ArtisanLogbook.History;

namespace Tests.History;

[TestFixture]
public class HistoryReconcilerTests
{
    private static CraftObservation Craft(string origin, string observation, int recipe = 123) =>
        new(new CraftIdentity(origin, observation), DateTimeOffset.UnixEpoch, recipe, 42);

    [Test]
    public void MergeOfIdenticalHistoryIsIdempotent()
    {
        CraftObservation craft = Craft("ledger-a", "1");
        HistoryMergeResult result = HistoryReconciler.Merge([craft], [craft]);

        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.Observations, Is.EqualTo(new[] { craft }));
    }

    [Test]
    public void UniqueCraftsFromDifferentOriginsSurvive()
    {
        CraftObservation first = Craft("ledger-a", "1");
        CraftObservation second = Craft("ledger-b", "1");

        HistoryMergeResult result = HistoryReconciler.Merge([first], [second]);

        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.Observations, Has.Count.EqualTo(2));
    }

    [Test]
    public void ConflictingObservationsNeverSilentlyOverwrite()
    {
        CraftObservation original = Craft("ledger-a", "1");
        CraftObservation changed = Craft("ledger-a", "1", recipe: 789);

        HistoryMergeResult result = HistoryReconciler.Merge([original], [changed]);

        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.Conflicts, Has.Count.EqualTo(1));
    }

    [Test]
    public void ConflictFreeMergeIsOrderIndependent()
    {
        CraftObservation a = Craft("ledger-a", "1");
        CraftObservation b = Craft("ledger-b", "2");

        HistoryMergeResult forward = HistoryReconciler.Merge([a], [b]);
        HistoryMergeResult reversed = HistoryReconciler.Merge([b], [a]);

        Assert.That(forward.Observations, Is.EqualTo(reversed.Observations));
    }

    [Test]
    public void IdentityRejectsMissingOrigin()
    {
        Assert.Throws<ArgumentException>(() => new CraftIdentity(" ", "123"));
    }
}
