using ArtisanLogbook.History;
using NUnit.Framework;

namespace Tests.History;

[TestFixture]
public class HistoryReconcilerTests
{
    private static readonly CharacterIdentity Character = new("Pozzo dell'Eternità", "Jeany", "Retail");

    private static CraftObservation Craft(string origin, string observation, int? recipe = 123) =>
        new(new CraftIdentity(origin, observation), DateTimeOffset.UnixEpoch, recipe, Character);

    [Test]
    public void IdenticalHistoryIsIdempotent()
    {
        CraftObservation craft = Craft("ledger-a", "1");
        HistoryMergeResult result = HistoryReconciler.Merge([craft], [craft]);
        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.Observations, Is.EqualTo(new[] { craft }));
    }

    [Test]
    public void IndependentCraftsWithIdenticalLocalNumbersSurvive()
    {
        HistoryMergeResult result = HistoryReconciler.Merge(
            [Craft("ledger-a", "1")], [Craft("ledger-b", "1")]);
        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.Observations, Has.Count.EqualTo(2));
    }

    [Test]
    public void KnownRecipeConflictIsReported()
    {
        HistoryMergeResult result = HistoryReconciler.Merge(
            [Craft("ledger-a", "1")], [Craft("ledger-a", "1", 789)]);
        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.Conflicts.Select(c => c.Field), Does.Contain("RecipeId"));
    }

    [Test]
    public void RepairedUnknownRecipeEnrichesPriorObservation()
    {
        CraftObservation unknown = Craft("ledger-a", "1", null);
        CraftObservation repaired = Craft("ledger-a", "1", 789);
        HistoryMergeResult result = HistoryReconciler.Merge([unknown], [repaired]);
        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.Observations.Single().RecipeId, Is.EqualTo(789));
    }

    [Test]
    public void UnknownResourcefulnessIsNotAFalseOutcome()
    {
        CraftObservation partial = Craft("ledger", "1") with { HasResourcefulnessProc = null };
        CraftObservation complete = Craft("ledger", "1") with { HasResourcefulnessProc = false };
        HistoryMergeResult result = HistoryReconciler.Merge([partial], [complete]);
        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.Observations.Single().HasResourcefulnessProc, Is.False);
    }

    [Test]
    public void IndependentlyObservedOutputSetsCannotBeUnionedSilently()
    {
        CraftObservation a = Craft("ledger", "1") with { Outputs = [new(123, 1, 2)] };
        CraftObservation b = a with { Outputs = [new(123, 1, 2), new(456, null, 1)] };
        HistoryMergeResult result = HistoryReconciler.Merge([a], [b]);
        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.Conflicts.Select(c => c.Field), Does.Contain("Outputs"));
    }

    [Test]
    public void ConflictingTimestampIsNotOverwrittenSilently()
    {
        CraftObservation a = Craft("ledger", "1");
        CraftObservation b = a with { RecordedAt = a.RecordedAt.AddSeconds(1) };
        Assert.That(HistoryReconciler.Merge([a], [b]).IsSuccessful, Is.False);
    }

    [Test]
    public void IndependentObservationsAreCommutative()
    {
        CraftObservation a = Craft("ledger-a", "1");
        CraftObservation b = Craft("ledger-b", "2");
        Assert.That(HistoryReconciler.Merge([a], [b]).Observations,
            Is.EqualTo(HistoryReconciler.Merge([b], [a]).Observations));
    }

    [Test]
    public void ConflictingObservationsDoNotPassValidation()
    {
        CraftObservation a = Craft("ledger", "1") with
        {
            Reagents = [new(123, 1, null), new(123, null, 2)]
        };
        Assert.That(HistoryValidator.Validate([a]).Select(e => e.Field), Does.Contain("Reagents"));
    }

    [Test]
    public void AZeroKnownReturnIsDistinctFromAnUnknownReturn()
    {
        CraftObservation a = Craft("ledger", "1") with { Reagents = [new(123, 3, 0)] };
        CraftObservation b = Craft("ledger", "2") with { Reagents = [new(123, 3, null)] };
        Assert.That(a.Reagents![0].ReturnedQuantity, Is.EqualTo(0));
        Assert.That(b.Reagents![0].ReturnedQuantity, Is.Null);
    }

    [Test]
    public void IdentityRejectsMissingOrigin()
    {
        Assert.Throws<ArgumentException>(() => new CraftIdentity(" ", "123"));
    }

    [Test]
    public void InvalidMeasurementsAreRejected()
    {
        CraftObservation a = Craft("ledger", "1") with
        {
            ConcentrationSpent = -1,
            Outputs = [new(123, null, 0)]
        };
        Assert.That(HistoryValidator.Validate([a]), Has.Count.GreaterThanOrEqualTo(2));
    }

    [Test]
    public void RandomDisjointMergesPreserveAllCrafts()
    {
        Random random = new(912);
        for (int pass = 0; pass < 100; pass++)
        {
            CraftObservation[] all = Enumerable.Range(0, random.Next(1, 80))
                .Select(i => Craft($"ledger-{i % 4}", i.ToString())).ToArray();
            int cut = random.Next(all.Length + 1);
            HistoryMergeResult merged = HistoryReconciler.Merge(all.Take(cut), all.Skip(cut));
            Assert.That(merged.IsSuccessful, Is.True);
            Assert.That(merged.Observations, Has.Count.EqualTo(all.Length));
        }
    }
}
