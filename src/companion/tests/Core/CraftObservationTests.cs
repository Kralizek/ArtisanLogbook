using ArtisanLogbook.History;
using NUnit.Framework;

namespace Tests.History;

[TestFixture]
public class CraftObservationTests
{
    private static readonly CraftIdentity Identity = new("capture-1", "craft-42");
    private static readonly CharacterIdentity Character = new("project:1:region:3:realm:1309:guid:Player-1309-12345678");

    [Test]
    public void ObservedCollectionsCompareByContentsRatherThanArrayIdentityOrOrder()
    {
        CraftObservation first = new(Identity, DateTimeOffset.UnixEpoch, 123, Character,
            Reagents: [new(20, 3, 0), new(10, 5, null)],
            Outputs: [new(40, 1, 2), new(30, null, 1)]);
        CraftObservation second = first with
        {
            Reagents = [new(10, 5, null), new(20, 3, 0)],
            Outputs = [new(30, null, 1), new(40, 1, 2)]
        };

        Assert.That(first, Is.EqualTo(second));
        Assert.That(first.GetHashCode(), Is.EqualTo(second.GetHashCode()));
        Assert.That(new HashSet<CraftObservation> { first, second }, Has.Count.EqualTo(1));
    }

    [Test]
    public void MissingAndExplicitlyEmptyCollectionsAreDifferent()
    {
        CraftObservation absent = new(Identity, DateTimeOffset.UnixEpoch, 123, Character);
        CraftObservation observedEmpty = absent with { Reagents = Array.Empty<CraftReagent>() };
        Assert.That(absent, Is.Not.EqualTo(observedEmpty));
    }

    [Test]
    public void FalseAndUnknownAreDifferentResourcefulnessOutcomes()
    {
        CraftObservation unknown = new(Identity, DateTimeOffset.UnixEpoch, 123, Character);
        CraftObservation negative = unknown with { HasResourcefulnessProc = false };
        Assert.That(unknown, Is.Not.EqualTo(negative));
    }

    [Test]
    public void MissingDimensionMetadataDoesNotInvalidateCrafts()
    {
        CraftObservation craft = new(Identity, DateTimeOffset.UnixEpoch, null, Character);
        CraftHistory history = new([craft], CraftDimensions.Empty);
        Assert.That(CraftHistoryValidator.Validate(history), Is.Empty);
    }

    [Test]
    public void DuplicateDimensionKeysAreRejected()
    {
        CraftHistory history = new([], new(
            [], [new(123, "First"), new(123, "Second")],
            [], [], []));
        Assert.That(CraftHistoryValidator.Validate(history).Select(e => e.Field),
            Does.Contain("RecipeDimension"));
    }

    [Test]
    public void NegativeOrDuplicateReagentMeasurementsAreInvalid()
    {
        CraftObservation craft = new(Identity, DateTimeOffset.UnixEpoch, 123, Character,
            Reagents: [new(123, -1, 0), new(123, null, null)]);
        Assert.That(HistoryValidator.Validate([craft]).Count, Is.GreaterThanOrEqualTo(2));
    }

    [Test]
    public void OneCraftCanProduceMultipleOutputsOfDistinctQualities()
    {
        CraftObservation craft = new(Identity, DateTimeOffset.UnixEpoch, 123, Character,
            Outputs: [new(10, 1, 2), new(10, 2, 3), new(11, null, 1)]);
        Assert.That(HistoryValidator.Validate([craft]), Is.Empty);
    }

    [Test]
    public void ReconciliationDoesNotDependOnInputOrderingForConflictFreeEnrichment()
    {
        CraftObservation unknown = new(Identity, DateTimeOffset.UnixEpoch, null, Character,
            Reagents: [new(10, 3, null), new(20, null, null)]);
        CraftObservation enriched = unknown with
        {
            RecipeId = 123,
            Reagents = [new(20, 8, 1), new(10, null, 0)]
        };

        HistoryMergeResult forward = HistoryReconciler.Merge([unknown], [enriched]);
        HistoryMergeResult backward = HistoryReconciler.Merge([enriched], [unknown]);

        Assert.That(forward.IsSuccessful, Is.True);
        Assert.That(backward.IsSuccessful, Is.True);
        Assert.That(forward.Observations, Is.EqualTo(backward.Observations));
        Assert.That(forward.Observations[0].Reagents![1].AllocatedQuantity, Is.EqualTo(8));
    }

    [Test]
    public void RandomizedConflictFreeMergeOrderProducesEquivalentObservations()
    {
        Random rng = new(20261020);
        for (int pass = 0; pass < 100; pass++)
        {
            CraftObservation[] crafts = Enumerable.Range(0, rng.Next(1, 60))
                .Select(i => new CraftObservation(new("ledger-" + (i % 3), "craft-" + i),
                    DateTimeOffset.UnixEpoch.AddSeconds(i), 100 + i, Character,
                    Reagents: [new(10, i + 1, null)], Outputs: [new(20, null, 1)]))
                .ToArray();
            CraftObservation[] shuffled = crafts.OrderBy(_ => rng.Next()).ToArray();
            HistoryMergeResult merged = HistoryReconciler.Merge(crafts, shuffled);
            HistoryMergeResult expected = HistoryReconciler.Merge(shuffled, crafts);
            Assert.That(merged.IsSuccessful, Is.True);
            Assert.That(merged.Observations, Is.EqualTo(expected.Observations));
            Assert.That(merged.Observations, Has.Count.EqualTo(crafts.Length));
        }
    }
}
