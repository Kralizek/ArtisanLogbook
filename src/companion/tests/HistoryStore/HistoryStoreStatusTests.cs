using System.Data.Common;

using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;

using DuckDB.NET.Data;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.HistoryStore;

[TestFixture]
public sealed class HistoryStoreStatusTests
{
    private string _directory = null!;
    private string _database = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Status.Tests", Guid.NewGuid().ToString("N"));
        _database = Path.Combine(_directory, "history.duckdb");
    }

    [TearDown]
    public void TearDown()
    {
        if (Directory.Exists(_directory))
            Directory.Delete(_directory, recursive: true);
    }

    [Test]
    public void MissingReadOnlyDatabaseDoesNotCreateDirectories()
    {
        Assert.That(() => new Store(_database, readOnly: true), Throws.TypeOf<FileNotFoundException>());
        Assert.That(Directory.Exists(_directory), Is.False);
    }

    [Test]
    public void EmptyStoreHasNoInventedTimestampOrCrafts()
    {
        using Store store = new(_database);
        HistoryStoreStatus status = store.ReadStatus();
        Assert.Multiple(() =>
        {
            Assert.That(status.SchemaVersion, Is.EqualTo(2));
            Assert.That(status.TotalCraftCount, Is.Zero);
            Assert.That(status.OldestCraft, Is.Null);
            Assert.That(status.NewestCraft, Is.Null);
            Assert.That(status.Contexts, Is.Empty);
        });
    }

    [Test]
    public void StatusAggregatesContextsAndOrdersTimestampsByInstantNotOffsetText()
    {
        GameContext retail = new(GameProject.Retail);
        GameContext hardcore = new(GameProject.ClassicEra, "hardcore");
        DateTimeOffset older = new(2026, 11, 7, 13, 0, 0, TimeSpan.FromHours(2));
        DateTimeOffset newer = new(2026, 11, 7, 12, 0, 0, TimeSpan.Zero);
        CraftObservation[] crafts =
        [
            Craft("a", retail, older),
            Craft("b", retail, newer),
            Craft("c", hardcore, newer)
        ];
        using (Store store = new(_database))
        {
            foreach (CraftObservation craft in crafts)
                Assert.That(store.Write(craft).IsSuccessful, Is.True);
        }
        byte[] before = File.ReadAllBytes(_database);
        using (Store reader = new(_database, readOnly: true))
        {
            HistoryStoreStatus status = reader.ReadStatus();
            Assert.Multiple(() =>
            {
                Assert.That(status.TotalCraftCount, Is.EqualTo(3));
                Assert.That(status.OldestCraft, Is.EqualTo(older));
                Assert.That(status.NewestCraft, Is.EqualTo(newer));
                Assert.That(status.Contexts, Is.EqualTo(new[]
                {
                    new GameContextCraftCount(retail, 2),
                    new GameContextCraftCount(hardcore, 1)
                }));
            });
            Assert.That(() => reader.Write(Craft("d", retail, newer)), Throws.InvalidOperationException);
        }
        Assert.That(File.ReadAllBytes(_database), Is.EqualTo(before));
    }

    [Test]
    public void ReadOnlyOpenDoesNotInitializeAnUnrecognizedDatabase()
    {
        Directory.CreateDirectory(_directory);
        using (DuckDBConnection connection = new($"Data Source={_database}"))
        {
            connection.Open();
        }
        using Store reader = new(_database, readOnly: true);
        Assert.That(() => reader.ReadStatus(), Throws.InvalidOperationException.With.Message.Contains("unavailable"));
    }

    [Test]
    public void WriterInitializesOnlyAnExistingEmptyDuckDbFile()
    {
        Directory.CreateDirectory(_directory);
        using (DuckDBConnection connection = new($"Data Source={_database}"))
        {
            connection.Open();
        }

        using Store store = new(_database);
        Assert.That(store.ReadStatus().SchemaVersion, Is.EqualTo(2));
    }

    [Test]
    public void WriterRejectsForeignDuckDbWithoutChangingIt()
    {
        Directory.CreateDirectory(_directory);
        using (DuckDBConnection connection = new($"Data Source={_database}"))
        {
            connection.Open();
            using DuckDBCommand command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE Unrelated (Value INTEGER)";
            command.ExecuteNonQuery();
        }
        byte[] before = File.ReadAllBytes(_database);

        Assert.That(() => new Store(_database),
            Throws.InvalidOperationException.With.Message.Contains("not an initialized"));
        Assert.That(File.ReadAllBytes(_database), Is.EqualTo(before));
    }

    [Test]
    public void WriterRejectsNonDuckDbFileWithoutChangingIt()
    {
        Directory.CreateDirectory(_directory);
        byte[] before = [0x41, 0x4c, 0x42, 0x21, 0x00, 0xFF];
        File.WriteAllBytes(_database, before);

        Assert.That(() => new Store(_database), Throws.Exception);
        Assert.That(File.ReadAllBytes(_database), Is.EqualTo(before));
    }

    private static CraftObservation Craft(string id, GameContext game, DateTimeOffset timestamp) =>
        new(new("status-tests", id), game, timestamp, 77,
            new($"project:{(int)game.Project}:region:3:realm:1309:guid:Player-Sanitized"));
}
