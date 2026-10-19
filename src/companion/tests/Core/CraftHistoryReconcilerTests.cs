using ArtisanLogbook.History;
using NUnit.Framework;

namespace Tests.History;

[TestFixture]
public class CraftHistoryReconcilerTests
{
    private static readonly CharacterIdentity Character =
        new("project:1:region:3:realm:1309:guid:Player-1309-0ABC1234");

    private static CraftObservation Craft(string origin, string id, int recipe) =>
        new(new(origin, id), DateTimeOffset.UnixEpoch, recipe, Character,
            Reagents: [new(240991, 5, null), new(236761, 8, 2)],
            Outputs: [new(241308, 2, 5)]);

    private static CraftHistory History(params CraftObservation[] crafts) =>
        new(crafts, new(
            [new(Character, "Jeany", "MAGE")],
            [new(123, "Potion One", 171)],
            [new(171, "Alchemy")],
            [new(241308, "Potion One")],
            [new(10, "Midnight")]));

    [Test]
    public void IndependentlyAddedCraftsMergeAndPreserveTypedFacts()
    {
        CraftHistory a = History(Craft("origin-a", "1", 123));
        CraftHistory b = History(Craft("origin-b", "1", 123));

        CraftHistoryMergeResult result = CraftHistoryReconciler.Merge(a, b);

        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.History!.Crafts, Has.Count.EqualTo(2));
        Assert.That(result.History.Crafts.All(c => c.Reagents![1].ReturnedQuantity == 2), Is.True);
        Assert.That(result.History.Crafts.All(c => c.Outputs![0].Quantity == 5), Is.True);
    }

    [Test]
    public void MergingSameDatasetDoesNotDuplicateDimensionsOrCrafts()
    {
        CraftHistory a = History(Craft("origin-a", "1", 123));
        CraftHistoryMergeResult result = CraftHistoryReconciler.Merge(a, a);

        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.History!.Crafts, Has.Count.EqualTo(1));
        Assert.That(result.History.Dimensions.Characters, Has.Count.EqualTo(1));
        Assert.That(result.History.Dimensions.Recipes, Has.Count.EqualTo(1));
    }

    [Test]
    public void ConflictingRecipeProfessionCannotProduceMergedDataset()
    {
        CraftHistory a = History(Craft("origin-a", "1", 123));
        CraftHistory b = a with
        {
            Dimensions = a.Dimensions with
            {
                Recipes = [new RecipeDimension(123, "Potion One", 333)]
            }
        };

        CraftHistoryMergeResult result = CraftHistoryReconciler.Merge(a, b);

        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.History, Is.Null);
        Assert.That(result.DimensionConflicts, Has.Count.EqualTo(1));
    }

    [Test]
    public void CorrectedRecipeReplacesUnknownWithoutCreatingAnotherCraft()
    {
        CraftObservation old = Craft("same-ledger", "craft-1", 123) with { RecipeId = null };
        CraftObservation repaired = old with { RecipeId = 123 };

        CraftHistoryMergeResult result = CraftHistoryReconciler.Merge(History(old), History(repaired));

        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.History!.Crafts, Has.Count.EqualTo(1));
        Assert.That(result.History.Crafts[0].RecipeId, Is.EqualTo(123));
    }

    [Test]
    public void ConflictingKnownOutputsRefuseMergedDataset()
    {
        CraftObservation a = Craft("same-ledger", "craft-1", 123);
        CraftObservation b = a with { Outputs = [new(241308, 2, 6)] };

        CraftHistoryMergeResult result = CraftHistoryReconciler.Merge(History(a), History(b));

        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.History, Is.Null);
        Assert.That(result.CraftConflicts, Is.Not.Empty);
    }

    [Test]
    public void ReagentAllocatedAndReturnedFieldsAreEnrichedIndependently()
    {
        CraftObservation a = Craft("ledger", "1", 123) with
        {
            Reagents = [new(123, 5, null)]
        };
        CraftObservation b = a with
        {
            Reagents = [new(123, null, 2)]
        };

        CraftHistoryMergeResult result = CraftHistoryReconciler.Merge(History(a), History(b));

        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.History!.Crafts[0].Reagents![0], Is.EqualTo(new CraftReagent(123, 5, 2)));
    }

    [Test]
    public void LocalIdCollisionUnderSharedOriginIsReportedInsteadOfInventingANewIdentity()
    {
        CraftObservation a = Craft("cloned-ledger", "237", 123);
        CraftObservation b = Craft("cloned-ledger", "237", 456);
        CraftHistoryMergeResult result = CraftHistoryReconciler.Merge(History(a), History(b));
        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.CraftConflicts, Is.Not.Empty);
    }

    [Test]
    public void DisjointDatasetsMergeAssociatively()
    {
        CraftHistory a = History(Craft("origin-a", "1", 123));
        CraftHistory b = History(Craft("origin-b", "1", 123));
        CraftHistory c = History(Craft("origin-c", "1", 123));
        CraftHistory first = CraftHistoryReconciler.Merge(CraftHistoryReconciler.Merge(a, b).History!, c).History!;
        CraftHistory second = CraftHistoryReconciler.Merge(a, CraftHistoryReconciler.Merge(b, c).History!).History!;
        Assert.That(first.Crafts, Is.EqualTo(second.Crafts));
    }
}
