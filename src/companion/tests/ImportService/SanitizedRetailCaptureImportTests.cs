using ArtisanLogbook.History;
using ArtisanLogbook.ImportService;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.ImportService;

/// <summary>Real Retail capture shapes (identities removed) that synthetic fixtures did not exercise.</summary>
[TestFixture]
public sealed class SanitizedRetailCaptureImportTests
{
    private static readonly GameContext Retail = new(GameProject.Retail);

    [Test]
    public async Task RealCaptureShapesImportWithExpectedEvidenceAndAnalysis()
    {
        string directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.SanitizedCapture.Tests", Guid.NewGuid().ToString("N"));
        string source = File.ReadAllText(Path.Combine(TestContext.CurrentContext.TestDirectory,
            "Fixtures", "retail-69933-sanitized-sample.lua"));
        try
        {
            using Store store = new(Path.Combine(directory, "history.duckdb"));
            CompanionImportResult result = await new CompanionImportService(store).ImportSavedVariablesAsync(source);

            Assert.That(result.Outcome, Is.EqualTo(CompanionImportOutcome.Successful),
                string.Join(Environment.NewLine, result.SourceDiagnostics));
            Assert.That(result.InsertedCrafts, Is.EqualTo(12));
            Assert.That(result.CoverageWarnings.Select(d => d.Code).Distinct(),
                Is.EquivalentTo(new[] { "legacy-identity-lineage", "unknown-recipe" }));

            CraftAnalysis potion = store.Analyze(new(new(Game: Retail, RecipeId: 1230869)));
            RecipeAnalysis recipe = potion.Recipes.Nodes.Single();
            Assert.Multiple(() =>
            {
                Assert.That(potion.Attempts.Attempts, Is.EqualTo("10"));
                // Ingenuity is only possible on Concentration attempts (5 of 10).
                Assert.That(recipe.Ingenuity, Is.EqualTo(new AnalysisOutcome("5", "2", null, "0", "5")));
                Assert.That(recipe.Refund.IneligibleAttempts, Is.EqualTo("5"));
                Assert.That(recipe.Refund.Total, Is.EqualTo("304"));

                // Crafts 80 and 1031 return a quality variant that was never allocated in their requests,
                // so the return is measured while the allocation remains unknown rather than zero.
                AnalysisContribution returned = potion.Returns.Nodes.Single(x => x.Key == "236767");
                Assert.That(decimal.Parse(returned.Measure.Quantity!, System.Globalization.CultureInfo.InvariantCulture), Is.EqualTo(4m));
                AnalysisContribution allocated = potion.Inputs.Nodes.Single(x => x.Key == "236767");
                Assert.That(allocated.Measure.MeasuredAttempts, Is.EqualTo("0"));
                Assert.That(allocated.Measure.Quantity, Is.Null);
            });

            CraftAnalysis salvage = store.Analyze(new(new(Game: Retail, RecipeId: 1231127)));
            Assert.That(salvage.Outputs.Nodes.Select(x => x.Key), Is.EquivalentTo(new[] { "242606", "242788" }));
            Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(12));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }
}
