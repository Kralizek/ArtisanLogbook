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
    public void OldDevelopmentDatabaseIsRejectedWithoutMigrationOrOverwrite()
    {
        using (Store store = new(_database)) store.Write(Craft());
        using (DuckDBConnection connection = new($"Data Source={_database}"))
        {
            connection.Open();
            using DuckDBCommand command = connection.CreateCommand();
            command.CommandText = "ALTER TABLE Craft DROP COLUMN RecipeSchematicEvidenceJson; UPDATE __HistoryStoreMigration SET Version = 1";
            command.ExecuteNonQuery();
        }
        byte[] before = File.ReadAllBytes(_database);
        using (Store reader = new(_database, readOnly: true))
        {
            Assert.That(() => reader.ReadStatus(), Throws.InvalidOperationException.With.Message.Contains("cannot be read"));
        }
        Assert.That(() => new Store(_database), Throws.InvalidOperationException.With.Message.Contains("not migrated"));
        Assert.That(File.ReadAllBytes(_database), Is.EqualTo(before));
    }

    private static CraftObservation Craft() => new(new("source", "one"), new(GameProject.Retail),
        DateTimeOffset.UnixEpoch, 77, new("project:1:region:3:realm:1309:guid:Player-Sanitized"),
        Outputs: [new(99, null, 1)]);
}
