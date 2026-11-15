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
        EntityPreference pinned = await first.SetPinnedAsync(context, PreferredEntityKind.Recipe, 77, true);
        EntityPreference hidden = await first.SetHiddenAsync(context, PreferredEntityKind.Recipe, 77, true);
        Assert.That(pinned.Pinned, Is.True);
        Assert.That(hidden.Hidden, Is.True);
        await first.DisposeAsync();

        ApplicationStateStore reopened = new(_database);
        await reopened.InitializeAsync();
        EntityPreference preference = (await reopened.GetEntityPreferencesAsync(context)).Single();
        Assert.That(preference, Is.EqualTo(new EntityPreference(context, PreferredEntityKind.Recipe, 77, true, true)));
        await reopened.DisposeAsync();
    }

    [Test]
    public async Task EmptyDatabaseFromInterruptedFirstInitializationCanBeRecovered()
    {
        Directory.CreateDirectory(_directory);
        await File.WriteAllBytesAsync(_database, []);

        await using ApplicationStateStore store = new(_database);
        await store.InitializeAsync();
        GameContext context = new(GameProject.Retail);
        await store.SetPinnedAsync(context, PreferredEntityKind.Recipe, 9, true);

        Assert.That((await store.GetEntityPreferencesAsync(context)).Single().Pinned, Is.True);
    }

    [Test]
    public async Task ConcurrentInitializersSerializeAndCreateOneUsableSchema()
    {
        await using ApplicationStateStore first = new(_database);
        await using ApplicationStateStore second = new(_database);
        await RunTogether(() => first.InitializeAsync(), () => second.InitializeAsync());

        GameContext context = new(GameProject.Retail);
        await first.SetPinnedAsync(context, PreferredEntityKind.Recipe, 9, true);
        Assert.That((await second.GetEntityPreferencesAsync(context)).Single().Pinned, Is.True);
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
        await using ApplicationStateStore first = new(_database);
        await using ApplicationStateStore second = new(_database);
        await first.InitializeAsync();
        await second.InitializeAsync();
        GameContext context = new(GameProject.Retail);

        await RunTogether(
            () => first.SetPinnedAsync(context, PreferredEntityKind.Recipe, 10, true),
            () => second.SetHiddenAsync(context, PreferredEntityKind.Recipe, 10, true),
            () => first.SetPinnedAsync(context, PreferredEntityKind.Item, 10, true),
            () => second.SetHiddenAsync(context, PreferredEntityKind.Recipe, 11, true));

        IReadOnlyList<EntityPreference> preferences = await first.GetEntityPreferencesAsync(context);
        Assert.That(preferences, Has.Count.EqualTo(3));
        Assert.That(preferences.Single(item => item.Kind == PreferredEntityKind.Recipe && item.EntityId == 10),
            Is.EqualTo(new EntityPreference(context, PreferredEntityKind.Recipe, 10, true, true)));
        Assert.That(preferences.Single(item => item.Kind == PreferredEntityKind.Item).Pinned, Is.True);
        Assert.That(preferences.Single(item => item.EntityId == 11).Hidden, Is.True);
    }

    private static async Task RunTogether(params Func<Task>[] operations)
    {
        using Barrier start = new(operations.Length + 1);
        Task[] tasks = operations.Select(operation => Task.Run(async () =>
        {
            if (!start.SignalAndWait(TimeSpan.FromSeconds(10)))
                throw new TimeoutException("Concurrent application-state operations did not reach the start barrier.");
            await operation();
        })).ToArray();

        if (!start.SignalAndWait(TimeSpan.FromSeconds(10)))
            throw new TimeoutException("Concurrent application-state operations did not start.");
        await Task.WhenAll(tasks).WaitAsync(TimeSpan.FromSeconds(30));
    }

    [Test]
    public async Task SavedInvestigationsRoundTripDocumentsAndRejectStaleRevisions()
    {
        GameContext retail = new(GameProject.Retail);
        GameContext retailTrackX = new(GameProject.Retail, "Track X");
        GameContext retailTrackY = new(GameProject.Retail, "Track Y");
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
            SavedInvestigation trackX = await store.CreateInvestigationAsync(
                "Track X investigation", retailTrackX, 1, document.RootElement);
            SavedInvestigation trackY = await store.CreateInvestigationAsync(
                "Track Y investigation", retailTrackY, 1, document.RootElement);
            IReadOnlyList<SavedInvestigationSummary> retailItems = await store.ListInvestigationsAsync(retail);
            IReadOnlyList<SavedInvestigationSummary> trackXItems = await store.ListInvestigationsAsync(retailTrackX);
            IReadOnlyList<SavedInvestigationSummary> trackYItems = await store.ListInvestigationsAsync(retailTrackY);
            IReadOnlyList<SavedInvestigationSummary> foreverItems = await store.ListInvestigationsAsync(forever);
            IReadOnlyList<SavedInvestigationSummary> allItems = await store.ListInvestigationsAsync();
            Assert.That(retailItems.Select(item => item.Id), Is.EqualTo(new[] { created.Id }));
            Assert.That(trackXItems.Select(item => item.Id), Is.EqualTo(new[] { trackX.Id }));
            Assert.That(trackYItems.Select(item => item.Id), Is.EqualTo(new[] { trackY.Id }));
            Assert.That(foreverItems.Select(item => item.Id), Is.EqualTo(new[] { otherContext.Id }));
            Assert.That(allItems, Has.Count.EqualTo(4));
            SavedInvestigation retrieved = (await store.GetInvestigationAsync(id))!;
            Assert.That(retrieved.Definition.GetRawText(), Is.EqualTo(created.Definition.GetRawText()));

            using JsonDocument updatedDefinition = JsonDocument.Parse("""{"period":{"kind":"absolute","from":"2025-01-01"}}""");
            SavedInvestigation updated = (await store.UpdateInvestigationAsync(
                id, "Renamed", 8, updatedDefinition.RootElement, 1))!;
            Assert.That(updated.Name, Is.EqualTo("Renamed"));
            Assert.That(updated.DefinitionVersion, Is.EqualTo(8));
            Assert.That(updated.Definition.GetRawText(), Is.EqualTo(updatedDefinition.RootElement.GetRawText()));
            Assert.That(updated.Context, Is.EqualTo(retail));
            Assert.That(updated.Revision, Is.EqualTo(2));
            Assert.That(updated.CreatedAt, Is.EqualTo(created.CreatedAt));
            Assert.That(updated.UpdatedAt, Is.GreaterThanOrEqualTo(created.UpdatedAt));
            Assert.ThrowsAsync<SavedInvestigationRevisionConflictException>(async () =>
                await store.UpdateInvestigationAsync(id, "Stale name", 9, document.RootElement, 1));
            SavedInvestigation afterStale = (await store.GetInvestigationAsync(id))!;
            Assert.That(afterStale.Name, Is.EqualTo("Renamed"));
            Assert.That(afterStale.DefinitionVersion, Is.EqualTo(8));
            Assert.That(afterStale.Definition.GetRawText(), Is.EqualTo(updated.Definition.GetRawText()));
            Assert.ThrowsAsync<SavedInvestigationRevisionConflictException>(async () =>
                await store.DeleteInvestigationAsync(id, 1));
            Assert.That(await store.DeleteInvestigationAsync(id, 2), Is.True);
            Assert.That(await store.GetInvestigationAsync(id), Is.Null);
        }

        await using ApplicationStateStore reopened = new(_database);
        await reopened.InitializeAsync();
        Assert.That(await reopened.ListInvestigationsAsync(retail), Is.Empty);
        Assert.That(await reopened.ListInvestigationsAsync(forever), Has.Count.EqualTo(1));
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
        using JsonDocument conflictingContext = JsonDocument.Parse("""{"context":{"project":18}}""");
        Assert.ThrowsAsync<ArgumentException>(async () => await store.UpdateInvestigationAsync(
            saved.Id, "Conflicting context", 2, conflictingContext.RootElement, saved.Revision));

        string oversizedJson = $$"""{"value":"{{new string('x', ApplicationStateStore.MaximumInvestigationDefinitionBytes)}}"}""";
        using JsonDocument oversized = JsonDocument.Parse(oversizedJson);
        Assert.ThrowsAsync<ArgumentException>(async () => await store.CreateInvestigationAsync(
            "Oversized", new(GameProject.Retail), 1, oversized.RootElement));

        using CancellationTokenSource cancelled = new();
        cancelled.Cancel();
        Assert.ThrowsAsync<OperationCanceledException>(async () =>
            await store.UpdateInvestigationAsync(saved.Id, "Never saved", 1, original.RootElement, 1, cancelled.Token));

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
            await store.UpdateInvestigationAsync(saved.Id, "Failed write", 2, original.RootElement, 1));
        SavedInvestigation current = (await store.GetInvestigationAsync(saved.Id))!;
        Assert.That(current.Name, Is.EqualTo(saved.Name));
        Assert.That(current.DefinitionVersion, Is.EqualTo(saved.DefinitionVersion));
        Assert.That(current.Definition.GetRawText(), Is.EqualTo(saved.Definition.GetRawText()));
        Assert.That(current.Revision, Is.EqualTo(saved.Revision));
    }

    [Test]
    public async Task ConcurrentUpdatesToIndependentInvestigationsBothSucceed()
    {
        await using ApplicationStateStore firstStore = new(_database);
        await using ApplicationStateStore secondStore = new(_database);
        await Task.WhenAll(firstStore.InitializeAsync(), secondStore.InitializeAsync());
        using JsonDocument definition = JsonDocument.Parse("""{"kind":"comparison"}""");
        SavedInvestigation first = await firstStore.CreateInvestigationAsync(
            "First", new(GameProject.Retail), 1, definition.RootElement);
        SavedInvestigation second = await firstStore.CreateInvestigationAsync(
            "Second", new(GameProject.Retail), 1, definition.RootElement);

        TaskCompletionSource start = new(TaskCreationOptions.RunContinuationsAsynchronously);
        Task<SavedInvestigation?> UpdateAsync(ApplicationStateStore store, string id, string name) =>
            Task.Run(async () =>
            {
                await start.Task;
                return await store.UpdateInvestigationAsync(id, name, 2, definition.RootElement, 1);
            });
        Task<SavedInvestigation?> firstUpdate = UpdateAsync(firstStore, first.Id, "First updated");
        Task<SavedInvestigation?> secondUpdate = UpdateAsync(secondStore, second.Id, "Second updated");
        start.SetResult();

        SavedInvestigation[] updated = (await Task.WhenAll(firstUpdate, secondUpdate)).Select(item => item!).ToArray();
        Assert.That(updated.Select(item => item.Name), Is.EquivalentTo(new[] { "First updated", "Second updated" }));
        Assert.That(updated.Select(item => item.Revision), Is.All.EqualTo(2));
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
