using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.HistoryStore;

[TestFixture]
public sealed class DimensionBatchTests
{
    [Test]
    public void BatchedDimensionsUseExactContextAndKeyPairsAndPreserveSchematicFacts()
    {
        string directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.DimensionBatch", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            GameContext retail = new(GameProject.Retail);
            GameContext forever = new(GameProject.Forever, "progression");
            CharacterIdentity character = new("guid");
            using Store store = new(Path.Combine(directory, "history.duckdb"));
            CraftDimensions dimensions = new(
                [new(retail, character, "Name", "MAGE")],
                [new(retail, 1, "First", 12, "expansion", 5), new(retail, 2, "Unrequested"),
                    new(retail, 3, "Wild%_Recipe"), new(forever, 1, "Wrong"), new(forever, 2, null)],
                [new(retail, 12, "Alchemy", 11)],
                [new(retail, 10, "Reagent"), new(retail, 12, "Wild%_Item"), new(forever, 10, "Different")],
                [new(retail, "expansion", "Expansion")])
            {
                RecipeReagentSlots =
                [
                    new(retail, 1, RecipeReagentDataSlotType.Reagent, 1, 2, RecipeReagentType.Basic, true, 3, [10, 11]),
                    new(forever, 2, null, 2, CandidateItemIds: null)
                ]
            };
            Assert.That(store.WriteDimensions(dimensions).IsSuccessful, Is.True);

            DimensionIdentity<int>[] keys = [new(retail, 1), new(forever, 2), new(retail, 1), new(retail, 99)];
            IReadOnlyList<RecipeDimension> recipes = store.ReadRecipes(keys);
            Assert.Multiple(() =>
            {
                Assert.That(recipes, Has.Count.EqualTo(2));
                Assert.That(recipes, Does.Contain(dimensions.Recipes[0]).And.Contain(dimensions.Recipes[4]));
                Assert.That(store.ReadCharacters([new(retail, character)]), Is.EqualTo(dimensions.Characters));
                Assert.That(store.ReadProfessions([new(retail, 12)]), Is.EqualTo(dimensions.Professions));
                Assert.That(store.ReadItems([new(retail, 10)]), Is.EqualTo(new[] { dimensions.Items[0] }));
                Assert.That(store.ReadExpansions([new(retail, "expansion")]), Is.EqualTo(dimensions.Expansions));
                IReadOnlyList<RecipeReagentSlot> slots = store.ReadRecipeReagentSlots(keys);
                Assert.That(slots, Has.Count.EqualTo(2));
                Assert.That(slots.Single(slot => slot.Game == retail).CandidateItemIds, Is.EqualTo(new[] { 10, 11 }));
                Assert.That(slots.Single(slot => slot.Game == forever).CandidateItemIds, Is.Null);
                Assert.That(store.ReadRecipes([]), Is.Empty);
            });

            DimensionPage<RecipeDimension, int> first = store.QueryRecipes(new(), 1);
            List<RecipeDimension> paged = [.. first.Items];
            DimensionPage<RecipeDimension, int> next = first;
            while (next.HasNextPage)
            {
                next = store.QueryRecipes(new(), 1, next.EndPosition);
                paged.AddRange(next.Items);
            }
            Assert.Multiple(() =>
            {
                Assert.That(paged, Is.EquivalentTo(dimensions.Recipes));
                Assert.That(store.QueryRecipes(new(retail, 12, "expansion")).Items,
                    Is.EqualTo(new[] { dimensions.Recipes[0] }));
                Assert.That(store.QueryRecipes(new(retail, 12, "expansion", "iRsT")).Items,
                    Is.EqualTo(new[] { dimensions.Recipes[0] }));
                Assert.That(store.QueryRecipes(new(retail, Search: "%_")).Items,
                    Is.EqualTo(new[] { dimensions.Recipes[2] }));
                Assert.That(store.QueryCharacters(retail).Items, Is.EqualTo(dimensions.Characters));
                Assert.That(store.QueryProfessions(new(retail, 11)).Items, Is.EqualTo(dimensions.Professions));
                Assert.That(store.QueryItems(new(retail)).Items,
                    Is.EqualTo(new[] { dimensions.Items[0], new ItemDimension(retail, 11), dimensions.Items[1] }));
                Assert.That(store.QueryItems(new(retail, Search: "rEaG")).Items,
                    Is.EqualTo(new[] { dimensions.Items[0] }));
                Assert.That(store.QueryItems(new(retail, Search: "%_")).Items,
                    Is.EqualTo(new[] { dimensions.Items[1] }));
                Assert.That(store.QueryExpansions(retail).Items, Is.EqualTo(dimensions.Expansions));
                Assert.That(store.ReadGameContexts([retail, forever, new(GameProject.MistsClassic)]),
                    Is.EquivalentTo(new[] { retail, forever }));
                GameContextPage contexts = store.QueryGameContexts(1);
                Assert.That(contexts.HasNextPage, Is.True);
                Assert.That(contexts.Items.Concat(store.QueryGameContexts(1, contexts.EndPosition).Items),
                    Is.EquivalentTo(new[] { retail, forever }));
                Assert.Throws<ArgumentException>(() => store.QueryRecipes(new(ProfessionId: 12)));
                Assert.Throws<ArgumentException>(() => store.QueryRecipes(new(retail), after: new(forever, 1)));
            });
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Test]
    public void InvalidAndCancelledBatchesAreRejected()
    {
        string directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.DimensionBatch", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            using Store store = new(Path.Combine(directory, "history.duckdb"));
            using CancellationTokenSource cancellation = new();
            cancellation.Cancel();
            Assert.Throws<ArgumentException>(() => store.ReadItems([new(new(GameProject.Retail), 0)]));
            Assert.Throws<OperationCanceledException>(() => store.ReadItems([], cancellation.Token));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
