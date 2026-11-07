using System.Data.Common;
using System.Globalization;

using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;

using DuckDB.NET.Data;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.HistoryStore;

[TestFixture]
public sealed class HistoryStoreIntegrationTests
{
    private string _directory = null!;
    private string _databasePath = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.HistoryStore.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _databasePath = Path.Combine(_directory, "history.duckdb");
    }

    [TearDown]
    public void TearDown()
    {
        if (Directory.Exists(_directory))
            Directory.Delete(_directory, recursive: true);
    }

    [Test]
    public void ObservationsSurviveCloseAndReopenWithCanonicalValuesAndEvidenceIntact()
    {
        GameContext retail = new(GameProject.Retail);
        GameContext forever = new(GameProject.Forever, "progression-A");
        CharacterIdentity character = new("project:1:region:3:realm:1309:guid:Player-1234");
        CharacterIdentity otherCharacter = new("project:18:region:3:realm:1309:guid:Player-5678");
        DateTimeOffset recordedAt = new DateTimeOffset(2026, 11, 7, 12, 30, 45, TimeSpan.FromMinutes(90)).AddTicks(1234);
        decimal returned = 123456789.123456789012345678m;

        CraftOutputObservation callbackOne = new(
            new CraftOutput(700, 1, 2),
            recordedAt.AddSeconds(1),
            new CraftResultMeasurements(ConcentrationSpent: 0, HasIngenuityProc: false),
            [new CraftReagent(100, null, 0.125m)],
            ItemLevel: 42);
        CraftOutputObservation callbackTwo = new(
            new CraftOutput(701, null, 1),
            recordedAt.AddSeconds(2),
            new CraftResultMeasurements(MulticraftBonus: 0),
            [],
            QuantityAmbiguous: true,
            LegacyCraftId: 7);

        CraftObservation unknown = new(
            new CraftIdentity("capture-a", "one"),
            retail,
            recordedAt,
            RecipeId: 123,
            character,
            HasIngenuityProc: null,
            HasResourcefulnessProc: null,
            Reagents: null,
            Outputs: null,
            Provenance: new CraftProvenance("source-a", 11, 12, 13, "session-a", "partial"),
            InputsComplete: null,
            ResourcefulnessComplete: null,
            OutputsComplete: null);
        CraftObservation knownEmpty = new(
            new CraftIdentity("capture-a", "two"),
            forever,
            recordedAt,
            RecipeId: 123,
            otherCharacter,
            ConcentrationSpent: 0,
            HasIngenuityProc: false,
            HasResourcefulnessProc: false,
            Reagents: [],
            Outputs: [],
            InputsComplete: true,
            ResourcefulnessComplete: true,
            OutputsComplete: true);
        CraftObservation measured = new(
            new CraftIdentity("capture-b", "three"),
            retail,
            recordedAt,
            RecipeId: 123,
            character,
            ProfessionId: 171,
            ProfessionExpansionKey: "skillLine:2915",
            IngenuityRefund: 0,
            ConcentrationCurrencyId: 0,
            MulticraftBonus: 0,
            Reagents: [new CraftReagent(100, 4, returned), new CraftReagent(101, null, 0)],
            Outputs: [new CraftOutput(700, null, 2), new CraftOutput(700, 1, null)],
            Provenance: new CraftProvenance("source-b", GameOperationId: 14),
            InputsComplete: false,
            ResourcefulnessComplete: false,
            OutputsComplete: false,
            OutputEvidence: [new CraftOutputEvidence("recorder-b", [callbackOne, callbackTwo], Complete: false)],
            ConfigurationEvidence: [new CraftConfigurationEvidence("recorder-b", 9, "{\"quality\":2}")]
        );
        CraftObservation[] expected = [unknown, knownEmpty, measured];

        using (Store store = new(_databasePath))
        {
            Assert.That(store.SchemaVersion, Is.EqualTo(1));
            foreach (CraftObservation observation in expected)
                Assert.That(store.Write(observation).Status, Is.EqualTo(CraftWriteStatus.Inserted));
        }

        using (Store reopened = new(_databasePath))
        {
            IReadOnlyList<CraftObservation> actual = reopened.ReadAll();
            Assert.That(actual, Has.Count.EqualTo(expected.Length));
            foreach (CraftObservation original in expected)
            {
                CraftObservation restored = actual.Single(x => x.Identity == original.Identity);
                Assert.That(restored, Is.EqualTo(original));
                Assert.That(restored.Provenance, Is.EqualTo(original.Provenance));
                Assert.That(restored.OutputEvidence, Is.EqualTo(original.OutputEvidence));
                Assert.That(restored.ConfigurationEvidence, Is.EqualTo(original.ConfigurationEvidence));
                Assert.That(restored.RecordedAt, Is.EqualTo(original.RecordedAt));
            }

            CraftObservation restoredUnknown = actual.Single(x => x.Identity == unknown.Identity);
            CraftObservation restoredEmpty = actual.Single(x => x.Identity == knownEmpty.Identity);
            CraftObservation restoredMeasured = actual.Single(x => x.Identity == measured.Identity);
            Assert.Multiple(() =>
            {
                Assert.That(restoredUnknown.Reagents, Is.Null);
                Assert.That(restoredUnknown.Outputs, Is.Null);
                Assert.That(restoredUnknown.HasResourcefulnessProc, Is.Null);
                Assert.That(restoredEmpty.Reagents, Is.Empty);
                Assert.That(restoredEmpty.Outputs, Is.Empty);
                Assert.That(restoredEmpty.HasIngenuityProc, Is.False);
                Assert.That(restoredEmpty.ConcentrationSpent, Is.Zero);
                Assert.That(restoredMeasured.Reagents![0].ReturnedQuantity, Is.EqualTo(returned));
                Assert.That(
                    restoredMeasured.Reagents[0].ReturnedQuantity!.Value.ToString(CultureInfo.InvariantCulture),
                    Is.EqualTo(returned.ToString(CultureInfo.InvariantCulture)));
                Assert.That(restoredMeasured.OutputEvidence![0].Callbacks, Has.Count.EqualTo(2));
            });
        }

        using DuckDBConnection connection = new($"Data Source={_databasePath}");
        connection.Open();
        using DuckDBCommand command = connection.CreateCommand();
        command.CommandText = """
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = 'main'
            """;
        using DbDataReader reader = command.ExecuteReader();
        HashSet<string> tableNames = [];
        while (reader.Read()) tableNames.Add(reader.GetString(0));
        Assert.That(tableNames, Does.Contain("GameContext"));
        Assert.That(tableNames, Does.Contain("Character"));
        Assert.That(tableNames, Does.Contain("Recipe"));
        Assert.That(tableNames, Does.Contain("RecipeReagent"));
        Assert.That(tableNames, Does.Contain("Craft"));
        Assert.That(tableNames, Does.Contain("CraftReagent"));
        Assert.That(tableNames, Does.Contain("CraftOutput"));
        Assert.That(tableNames, Does.Contain("__HistoryStoreMigration"));

        command.CommandText = "SELECT COUNT(*) FROM Recipe WHERE RecipeId = 123";
        Assert.That(Convert.ToInt64(command.ExecuteScalar()), Is.EqualTo(2));
        command.CommandText = "SELECT COUNT(*) FROM Character";
        Assert.That(Convert.ToInt64(command.ExecuteScalar()), Is.EqualTo(2));
        command.CommandText = """
            SELECT COUNT(*)
            FROM Recipe
            WHERE Name IS NOT NULL OR ProfessionId IS NOT NULL
                OR ProfessionExpansionKey IS NOT NULL OR MaxQuality IS NOT NULL
            """;
        Assert.That(Convert.ToInt64(command.ExecuteScalar()), Is.Zero);
        command.CommandText = "SELECT COUNT(*) FROM RecipeReagent";
        Assert.That(Convert.ToInt64(command.ExecuteScalar()), Is.Zero);
    }

    [Test]
    public void ReplayEnrichesThroughCoreRulesAndConflictsNeverOverwrite()
    {
        GameContext game = new(GameProject.Retail);
        CharacterIdentity character = new("project:1:region:3:realm:1309:guid:Player-5678");
        CraftIdentity identity = new("capture", "craft-1");
        DateTimeOffset recordedAt = DateTimeOffset.UnixEpoch;
        CraftObservation partial = new(
            identity,
            game,
            recordedAt,
            RecipeId: null,
            character,
            Reagents: [new CraftReagent(100, 4, null)],
            Outputs: [new CraftOutput(200, 1, null)],
            InputsComplete: null,
            OutputsComplete: null);
        CraftOutputObservation callback = new(
            new CraftOutput(200, 1, 2),
            recordedAt.AddSeconds(1),
            new CraftResultMeasurements(),
            []);
        CraftObservation enriched = partial with
        {
            RecipeId = 123,
            Reagents = [new CraftReagent(100, 4, 0.5m)],
            Outputs = [new CraftOutput(200, 1, 2)],
            InputsComplete = true,
            OutputsComplete = true,
            OutputEvidence = [new CraftOutputEvidence("recorder", [callback])]
        };

        using Store store = new(_databasePath);
        Assert.That(store.Write(partial).Status, Is.EqualTo(CraftWriteStatus.Inserted));
        Assert.That(store.Write(enriched).Status, Is.EqualTo(CraftWriteStatus.Enriched));
        Assert.That(store.Write(enriched).Status, Is.EqualTo(CraftWriteStatus.AlreadyPresent));

        CraftObservation evidenceOnlyEnrichment = enriched with
        {
            OutputEvidence = enriched.OutputEvidence!.Append(
                new CraftOutputEvidence("second-recorder", [callback with { ObservedAt = recordedAt.AddSeconds(2) }]))
                .ToArray()
        };
        CraftWriteResult evidenceResult = store.Write(evidenceOnlyEnrichment);
        Assert.That(evidenceResult.Status, Is.EqualTo(CraftWriteStatus.Enriched));
        Assert.That(evidenceResult.Observation, Is.EqualTo(enriched));
        Assert.That(evidenceResult.Observation!.OutputEvidence, Has.Count.EqualTo(2));
        Assert.That(store.Write(evidenceOnlyEnrichment).Status, Is.EqualTo(CraftWriteStatus.AlreadyPresent));

        CraftObservation conflict = evidenceOnlyEnrichment with { Outputs = [new CraftOutput(200, 1, 3)] };
        CraftWriteResult conflictResult = store.Write(conflict);

        Assert.Multiple(() =>
        {
            Assert.That(conflictResult.Status, Is.EqualTo(CraftWriteStatus.Conflict));
            Assert.That(conflictResult.Conflicts, Is.Not.Empty);
            Assert.That(store.ReadAll(), Has.Count.EqualTo(1));
            Assert.That(store.Read(identity)!.Outputs, Is.EqualTo(evidenceOnlyEnrichment.Outputs));
            Assert.That(store.Read(identity)!.OutputEvidence, Is.EqualTo(evidenceOnlyEnrichment.OutputEvidence));
        });
    }

    [Test]
    public void InvalidCanonicalObservationIsNotPersisted()
    {
        CraftObservation invalid = new(
            new CraftIdentity("capture", "invalid"),
            new GameContext(GameProject.Retail),
            DateTimeOffset.UnixEpoch,
            RecipeId: 0,
            new CharacterIdentity("character"));

        using Store store = new(_databasePath);
        CraftWriteResult result = store.Write(invalid);

        Assert.Multiple(() =>
        {
            Assert.That(result.Status, Is.EqualTo(CraftWriteStatus.Invalid));
            Assert.That(result.ValidationErrors, Is.Not.Empty);
            Assert.That(store.ReadAll(), Is.Empty);
        });
    }
}
