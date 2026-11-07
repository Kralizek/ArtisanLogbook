using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;

using DuckDB.NET.Data;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.HistoryStore;

[TestFixture]
public sealed class HistoricalSchematicPersistenceTests
{
    private string _directory = null!;
    private string _database = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Schematic.Tests", Guid.NewGuid().ToString("N"));
        _database = Path.Combine(_directory, "history.duckdb");
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [Test]
    public void EvidenceVariantsEnrichIdempotentlyWithoutRelaxingCanonicalConflicts()
    {
        CraftObservation original = Craft() with { RecipeSchematicEvidence = [new("source", "first snapshot")] };
        CraftObservation variant = original with { RecipeSchematicEvidence = [new("source", "different snapshot")] };
        Assert.That(original, Is.EqualTo(variant), "Supplementary evidence is not canonical fact equality.");
        using (Store store = new(_database))
        {
            Assert.That(store.Write(original).Status, Is.EqualTo(CraftWriteStatus.Inserted));
            Assert.That(store.Write(variant).Status, Is.EqualTo(CraftWriteStatus.Enriched));
            Assert.That(store.Write(variant).Status, Is.EqualTo(CraftWriteStatus.AlreadyPresent));
            Assert.That(store.Write(variant with { Outputs = [new(99, null, 2)] }).Status, Is.EqualTo(CraftWriteStatus.Conflict));
        }
        using Store reader = new(_database, readOnly: true);
        CraftObservation restored = reader.ReadAll().Single();
        Assert.That(restored.RecipeSchematicEvidence, Is.EquivalentTo(original.RecipeSchematicEvidence!.Concat(variant.RecipeSchematicEvidence!)));
        Assert.That(restored.Outputs!.Single().Quantity, Is.EqualTo(1));
    }

    [Test]
    public void SchemaOneReadOnlyStatusRemainsReadOnlyAndWriterMigratesWithoutLosingCrafts()
    {
        using (Store store = new(_database)) store.Write(Craft());
        using (DuckDBConnection connection = new($"Data Source={_database}"))
        {
            connection.Open();
            using DuckDBCommand command = connection.CreateCommand();
            command.CommandText = "ALTER TABLE Craft DROP COLUMN RecipeSchematicEvidenceJson; DELETE FROM __HistoryStoreMigration WHERE Version = 2";
            command.ExecuteNonQuery();
        }
        using (Store reader = new(_database, readOnly: true))
        {
            Assert.That(reader.ReadStatus().SchemaVersion, Is.EqualTo(1));
            Assert.That(reader.ReadStatus().TotalCraftCount, Is.EqualTo(1));
            Assert.That(reader.ReadAll().Single(), Is.EqualTo(Craft()));
        }
        using Store migrated = new(_database);
        Assert.That(migrated.SchemaVersion, Is.EqualTo(2));
        Assert.That(migrated.ReadAll().Single(), Is.EqualTo(Craft()));
        Assert.That(migrated.ReadAll().Single().RecipeSchematicEvidence, Is.Null);
        Assert.That(migrated.Write(Craft() with { RecipeSchematicEvidence = [new("source", "retained")] }).Status,
            Is.EqualTo(CraftWriteStatus.Enriched));
    }

    private static CraftObservation Craft() => new(new("source", "one"), new(GameProject.Retail),
        DateTimeOffset.UnixEpoch, 77, new("project:1:region:3:realm:1309:guid:Player-Sanitized"),
        Outputs: [new(99, null, 1)]);
}
