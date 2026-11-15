using System.Text.Json;

using ArtisanLogbook.History;
using ArtisanLogbook.Runtime;

using Microsoft.Data.Sqlite;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class ApplicationStateStoreTests
{
    private string _directory = null!;
    private string _database = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.ApplicationState.Tests", Guid.NewGuid().ToString("N"));
        _database = Path.Combine(_directory, "application-state.sqlite3");
    }

    [TearDown]
    public void TearDown()
    {
        if (Directory.Exists(_directory))
            Directory.Delete(_directory, recursive: true);
    }

    [Test]
    public async Task MissingDatabaseInitializesAndStateSurvivesReopening()
    {
        ApplicationStateStore first = new(_database);
        await first.InitializeAsync();
        Assert.That(File.Exists(_database), Is.True);

        GameContext context = new(GameProject.Forever, "Hardcore");
        await first.SetLastSelectedContextAsync(context);
        EntityPreference pinned = await first.SetPinnedAsync(context, PreferredEntityKind.Recipe, 77, true);
        EntityPreference hidden = await first.SetHiddenAsync(context, PreferredEntityKind.Recipe, 77, true);
        Assert.That(pinned.Pinned, Is.True);
        Assert.That(hidden.Hidden, Is.True);
        await first.DisposeAsync();

        ApplicationStateStore reopened = new(_database);
        await reopened.InitializeAsync();
        Assert.That(await reopened.GetLastSelectedContextAsync(), Is.EqualTo(context));
        EntityPreference preference = (await reopened.GetEntityPreferencesAsync(context)).Single();
        Assert.That(preference, Is.EqualTo(new EntityPreference(context, PreferredEntityKind.Recipe, 77, true, true)));
        await reopened.DisposeAsync();
    }

    [Test]
    public async Task PreferencesAreDesiredStateAndIsolatedByContextAndEntityKind()
    {
        await using ApplicationStateStore store = new(_database);
        await store.InitializeAsync();
        GameContext retail = new(GameProject.Retail);
        GameContext forever = new(GameProject.Forever);
        GameContext retailTrack = new(GameProject.Retail, "Classic");

        await store.SetPinnedAsync(retail, PreferredEntityKind.Recipe, 123, true);
        await store.SetHiddenAsync(retail, PreferredEntityKind.Recipe, 123, true);
        await store.SetPinnedAsync(retail, PreferredEntityKind.Recipe, 123, true);
        await store.SetPinnedAsync(retail, PreferredEntityKind.Item, 123, true);
        await store.SetHiddenAsync(forever, PreferredEntityKind.Recipe, 123, true);
        await store.SetPinnedAsync(retailTrack, PreferredEntityKind.Recipe, 123, true);

        EntityPreference[] retailPreferences = (await store.GetEntityPreferencesAsync(retail)).ToArray();
        Assert.That(retailPreferences, Has.Length.EqualTo(2));
        Assert.That(retailPreferences.Single(preference => preference.Kind == PreferredEntityKind.Recipe),
            Is.EqualTo(new EntityPreference(retail, PreferredEntityKind.Recipe, 123, true, true)));
        Assert.That(retailPreferences.Single(preference => preference.Kind == PreferredEntityKind.Item).Pinned, Is.True);
        Assert.That(await store.GetEntityPreferencesAsync(forever),
            Is.EqualTo(new[] { new EntityPreference(forever, PreferredEntityKind.Recipe, 123, false, true) }));

        using CancellationTokenSource cancelled = new();
        cancelled.Cancel();
        Assert.ThrowsAsync<OperationCanceledException>(async () =>
            await store.SetPinnedAsync(retail, PreferredEntityKind.Recipe, 123, false, cancelled.Token));
        Assert.That((await store.GetEntityPreferencesAsync(retail))
            .Single(preference => preference.Kind == PreferredEntityKind.Recipe).Hidden, Is.True);

        await store.SetPinnedAsync(retail, PreferredEntityKind.Recipe, 123, false);
        await store.SetHiddenAsync(retail, PreferredEntityKind.Recipe, 123, false);
        Assert.That((await store.GetEntityPreferencesAsync(retail))
            .Any(preference => preference.Kind == PreferredEntityKind.Recipe), Is.False);
    }

    [Test]
    public async Task ConcurrentEntityMutationsPreserveIndependentAndUnrelatedState()
    {
        await using ApplicationStateStore store = new(_database);
        await store.InitializeAsync();
        GameContext context = new(GameProject.Retail);

        await Task.WhenAll(
            store.SetPinnedAsync(context, PreferredEntityKind.Recipe, 10, true),
            store.SetHiddenAsync(context, PreferredEntityKind.Recipe, 10, true),
            store.SetPinnedAsync(context, PreferredEntityKind.Item, 10, true),
            store.SetHiddenAsync(context, PreferredEntityKind.Recipe, 11, true));

        IReadOnlyList<EntityPreference> preferences = await store.GetEntityPreferencesAsync(context);
        Assert.That(preferences, Has.Count.EqualTo(3));
        Assert.That(preferences.Single(item => item.Kind == PreferredEntityKind.Recipe && item.EntityId == 10),
            Is.EqualTo(new EntityPreference(context, PreferredEntityKind.Recipe, 10, true, true)));
        Assert.That(preferences.Single(item => item.Kind == PreferredEntityKind.Item).Pinned, Is.True);
        Assert.That(preferences.Single(item => item.EntityId == 11).Hidden, Is.True);
    }

    [Test]
    public async Task SavedInvestigationsRoundTripDocumentsAndRejectStaleRevisions()
    {
        GameContext retail = new(GameProject.Retail);
        GameContext forever = new(GameProject.Forever);
        string source = """
            {
              "filter": { "recipeId": 99, "futureField": { "enabled": true } },
              "period": { "kind": "relative", "days": 90 },
              "comparison": { "left": { "from": "2025-01-01" }, "right": { "to": "2025-02-01" } }
            }
            """;
        using JsonDocument document = JsonDocument.Parse(source);
        string id;
        await using (ApplicationStateStore store = new(_database))
        {
            await store.InitializeAsync();
            SavedInvestigation created = await store.CreateInvestigationAsync("  Production review  ", retail, 7, document.RootElement);
            id = created.Id;
            Assert.That(created.Name, Is.EqualTo("Production review"));
            Assert.That(created.Definition.GetProperty("filter").GetProperty("futureField").GetProperty("enabled").GetBoolean(), Is.True);
            Assert.That(created.Definition.GetProperty("period").GetProperty("kind").GetString(), Is.EqualTo("relative"));

            SavedInvestigation otherContext = await store.CreateInvestigationAsync(
                "Forever investigation", forever, 2, document.RootElement);
            IReadOnlyList<SavedInvestigation> retailItems =
                await store.ListInvestigationsAsync((int)GameProject.Retail);
            IReadOnlyList<SavedInvestigation> foreverItems =
                await store.ListInvestigationsAsync((int)GameProject.Forever);
            Assert.That(retailItems.Select(item => item.Id), Is.EqualTo(new[] { created.Id }));
            Assert.That(foreverItems.Select(item => item.Id), Is.EqualTo(new[] { otherContext.Id }));
            SavedInvestigation retrieved = (await store.GetInvestigationAsync(id))!;
            Assert.That(retrieved.Definition.GetRawText(), Is.EqualTo(created.Definition.GetRawText()));

            SavedInvestigation renamed = (await store.RenameInvestigationAsync(id, "Renamed", 1))!;
            Assert.That(renamed.Revision, Is.EqualTo(2));
            Assert.That(renamed.CreatedAt, Is.EqualTo(created.CreatedAt));
            Assert.That(renamed.UpdatedAt, Is.GreaterThanOrEqualTo(created.UpdatedAt));
            Assert.ThrowsAsync<SavedInvestigationRevisionConflictException>(async () =>
                await store.ReplaceInvestigationDefinitionAsync(id, 8, document.RootElement, 1));

            SavedInvestigation replaced = (await store.ReplaceInvestigationDefinitionAsync(id, 8, document.RootElement, 2))!;
            Assert.That(replaced.Revision, Is.EqualTo(3));
            Assert.That(replaced.DefinitionVersion, Is.EqualTo(8));
            Assert.ThrowsAsync<SavedInvestigationRevisionConflictException>(async () =>
                await store.DeleteInvestigationAsync(id, 2));
            Assert.That(await store.DeleteInvestigationAsync(id, 3), Is.True);
            Assert.That(await store.GetInvestigationAsync(id), Is.Null);
        }

        await using ApplicationStateStore reopened = new(_database);
        await reopened.InitializeAsync();
        Assert.That(await reopened.ListInvestigationsAsync((int)GameProject.Retail), Is.Empty);
        Assert.That(await reopened.ListInvestigationsAsync((int)GameProject.Forever), Has.Count.EqualTo(1));
    }

    [Test]
    public async Task InvalidAndOversizedDefinitionsAreRejectedWithoutChangingStoredState()
    {
        await using ApplicationStateStore store = new(_database);
        await store.InitializeAsync();
        using JsonDocument original = JsonDocument.Parse("""{"period":{"kind":"relative","days":30}}""");
        SavedInvestigation saved = await store.CreateInvestigationAsync(
            "Investigation", new(GameProject.Retail), 1, original.RootElement);

        using JsonDocument duplicate = JsonDocument.Parse("""{"x":1,"x":2}""");
        Assert.ThrowsAsync<ArgumentException>(async () => await store.CreateInvestigationAsync(
            "Invalid", new(GameProject.Retail), 1, duplicate.RootElement));

        string oversizedJson = $$"""{"value":"{{new string('x', ApplicationStateStore.MaximumInvestigationDefinitionBytes)}}"}""";
        using JsonDocument oversized = JsonDocument.Parse(oversizedJson);
        Assert.ThrowsAsync<ArgumentException>(async () => await store.CreateInvestigationAsync(
            "Oversized", new(GameProject.Retail), 1, oversized.RootElement));

        using CancellationTokenSource cancelled = new();
        cancelled.Cancel();
        Assert.ThrowsAsync<OperationCanceledException>(async () =>
            await store.RenameInvestigationAsync(saved.Id, "Never saved", 1, cancelled.Token));

        using (SqliteConnection connection = new(new SqliteConnectionStringBuilder
        {
            DataSource = _database,
            Pooling = false
        }.ToString()))
        {
            connection.Open();
            using SqliteCommand command = connection.CreateCommand();
            command.CommandText = """
                CREATE TRIGGER reject_investigation_update
                BEFORE UPDATE ON saved_investigations
                BEGIN
                    SELECT RAISE(ABORT, 'forced write failure');
                END
                """;
            command.ExecuteNonQuery();
        }
        Assert.ThrowsAsync<ApplicationStatePersistenceException>(async () =>
            await store.RenameInvestigationAsync(saved.Id, "Failed write", 1));
        SavedInvestigation current = (await store.GetInvestigationAsync(saved.Id))!;
        Assert.That(current.Name, Is.EqualTo(saved.Name));
        Assert.That(current.Revision, Is.EqualTo(saved.Revision));
    }

    [Test]
    public async Task UnsupportedOrInvalidDatabaseIsRejectedWithoutReplacingItsContents()
    {
        Directory.CreateDirectory(_directory);
        byte[] invalid = "not a sqlite database"u8.ToArray();
        await File.WriteAllBytesAsync(_database, invalid);

        ApplicationStateStore invalidStore = new(_database);
        Assert.ThrowsAsync<ApplicationStatePersistenceException>(async () => await invalidStore.InitializeAsync());
        Assert.That(await File.ReadAllBytesAsync(_database), Is.EqualTo(invalid));
        await invalidStore.DisposeAsync();

        string unsupportedPath = Path.Combine(_directory, "unsupported.sqlite3");
        await using ApplicationStateStore initial = new(unsupportedPath);
        await initial.InitializeAsync();
        await initial.DisposeAsync();
        using (SqliteConnection connection = new(new SqliteConnectionStringBuilder
        {
            DataSource = unsupportedPath,
            Pooling = false
        }.ToString()))
        {
            connection.Open();
            using SqliteCommand command = connection.CreateCommand();
            command.CommandText = "PRAGMA user_version = 99";
            command.ExecuteNonQuery();
        }
        ApplicationStateStore unsupported = new(unsupportedPath);
        Assert.ThrowsAsync<ApplicationStatePersistenceException>(async () => await unsupported.InitializeAsync());
        await unsupported.DisposeAsync();
        using SqliteConnection verify = new(new SqliteConnectionStringBuilder
        {
            DataSource = unsupportedPath,
            Pooling = false
        }.ToString());
        verify.Open();
        using SqliteCommand version = verify.CreateCommand();
        version.CommandText = "PRAGMA user_version";
        Assert.That(version.ExecuteScalar(), Is.EqualTo(99L));

        string malformedPath = Path.Combine(_directory, "malformed.sqlite3");
        await using (ApplicationStateStore malformedInitial = new(malformedPath))
            await malformedInitial.InitializeAsync();
        using (SqliteConnection connection = new(new SqliteConnectionStringBuilder
        {
            DataSource = malformedPath,
            Pooling = false
        }.ToString()))
        {
            connection.Open();
            using SqliteCommand command = connection.CreateCommand();
            command.CommandText = "DROP TABLE saved_investigations; CREATE TABLE saved_investigations (id TEXT)";
            command.ExecuteNonQuery();
        }
        ApplicationStateStore malformed = new(malformedPath);
        Assert.ThrowsAsync<ApplicationStatePersistenceException>(async () => await malformed.InitializeAsync());
        await malformed.DisposeAsync();
        Assert.That(File.Exists(malformedPath), Is.True);
    }
}
