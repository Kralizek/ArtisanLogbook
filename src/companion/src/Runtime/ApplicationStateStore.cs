using System.Globalization;
using System.Text;
using System.Text.Json;

using ArtisanLogbook.History;

using Dapper;

using Microsoft.Data.Sqlite;

namespace ArtisanLogbook.Runtime;

internal enum PreferredEntityKind
{
    Recipe,
    Item
}

internal sealed record EntityPreference(
    GameContext Context, PreferredEntityKind Kind, int EntityId, bool Pinned, bool Hidden);

internal sealed record SavedInvestigation(
    string Id,
    string Name,
    GameContext Context,
    int DefinitionVersion,
    JsonElement Definition,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    long Revision);

internal sealed record SavedInvestigationSummary(
    string Id,
    string Name,
    GameContext Context,
    int DefinitionVersion,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    long Revision);

internal sealed class ApplicationStatePersistenceException(string message, Exception innerException)
    : IOException(message, innerException);

internal sealed class ApplicationStateStore : IAsyncDisposable
{
    public const int CurrentSchemaVersion = 1;
    public const int MaximumInvestigationDefinitionBytes = 256 * 1024;
    public const int MaximumInvestigationDepth = 32;
    public const int MaximumInvestigationNameLength = 120;
    public const int MaximumProgressionTrackLength = 256;

    private const int ApplicationId = 0x414C5354;
    private const string EmptyTrack = "";
    private readonly string _path;
    private readonly SemaphoreSlim _initializationGate = new(1, 1);
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private volatile bool _initialized;
    private int _disposed;

    public ApplicationStateStore(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (!Path.IsPathFullyQualified(path))
            throw new ArgumentException("The application-state database path must be absolute.", nameof(path));
        _path = path;
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        await _initializationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_initialized) return;
            string directory = Path.GetDirectoryName(_path)
                ?? throw new InvalidOperationException("The application-state database must have a parent directory.");
            Directory.CreateDirectory(directory);

            await using SqliteConnection connection = CreateConnection(readOnly: false, createIfMissing: true);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            await InitializeDatabaseAsync(connection, cancellationToken).ConfigureAwait(false);
            _initialized = true;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception exception) when (exception is SqliteException or IOException or InvalidDataException or UnauthorizedAccessException)
        {
            throw new ApplicationStatePersistenceException(
                "The application-state database could not be initialized or validated.", exception);
        }
        finally
        {
            _initializationGate.Release();
        }
    }

    public async Task<IReadOnlyList<EntityPreference>> GetEntityPreferencesAsync(
        GameContext context, CancellationToken cancellationToken = default)
    {
        ValidateContext(context);
        await EnsureInitializedAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using SqliteConnection connection = CreateConnection(readOnly: true);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            IEnumerable<PreferenceRow> rows = await connection.QueryAsync<PreferenceRow>(new CommandDefinition(
                """
                SELECT project_id AS ProjectId, progression_track AS ProgressionTrack,
                       entity_kind AS EntityKind, entity_id AS EntityId, pinned AS Pinned, hidden AS Hidden
                FROM entity_preferences
                WHERE project_id = @ProjectId AND progression_track = @ProgressionTrack
                ORDER BY entity_kind, entity_id
                """,
                new { ProjectId = (int)context.Project, ProgressionTrack = TrackKey(context) },
                cancellationToken: cancellationToken)).ConfigureAwait(false);
            return rows.Select(MapPreference).ToArray();
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) when (exception is SqliteException or IOException or UnauthorizedAccessException or
                                          ArgumentException or FormatException or OverflowException)
        {
            throw PersistenceFailure(exception);
        }
    }

    public Task<EntityPreference> SetPinnedAsync(
        GameContext context, PreferredEntityKind kind, int entityId, bool pinned,
        CancellationToken cancellationToken = default) =>
        SetEntityPreferenceAsync(context, kind, entityId, "pinned", pinned, cancellationToken);

    public Task<EntityPreference> SetHiddenAsync(
        GameContext context, PreferredEntityKind kind, int entityId, bool hidden,
        CancellationToken cancellationToken = default) =>
        SetEntityPreferenceAsync(context, kind, entityId, "hidden", hidden, cancellationToken);

    private async Task<EntityPreference> SetEntityPreferenceAsync(
        GameContext context, PreferredEntityKind kind, int entityId, string column, bool value,
        CancellationToken cancellationToken)
    {
        ValidateContext(context);
        ValidateEntity(kind, entityId);
        if (column is not ("pinned" or "hidden"))
            throw new ArgumentOutOfRangeException(nameof(column));
        await EnsureInitializedAsync(cancellationToken).ConfigureAwait(false);
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using SqliteConnection connection = CreateConnection(readOnly: false);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            await using SqliteTransaction transaction = connection.BeginTransaction(deferred: false);
            await connection.ExecuteAsync(new CommandDefinition(
                $"""
                INSERT INTO entity_preferences
                    (project_id, progression_track, entity_kind, entity_id, pinned, hidden)
                VALUES
                    (@ProjectId, @ProgressionTrack, @EntityKind, @EntityId, @Pinned, @Hidden)
                ON CONFLICT(project_id, progression_track, entity_kind, entity_id)
                DO UPDATE SET {column} = excluded.{column}
                """,
                new
                {
                    ProjectId = (int)context.Project,
                    ProgressionTrack = TrackKey(context),
                    EntityKind = kind.ToString(),
                    EntityId = entityId,
                    Pinned = column == "pinned" && value,
                    Hidden = column == "hidden" && value
                }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
            await connection.ExecuteAsync(new CommandDefinition(
                """
                DELETE FROM entity_preferences
                WHERE project_id = @ProjectId AND progression_track = @ProgressionTrack
                  AND entity_kind = @EntityKind AND entity_id = @EntityId
                  AND pinned = 0 AND hidden = 0
                """,
                new
                {
                    ProjectId = (int)context.Project,
                    ProgressionTrack = TrackKey(context),
                    EntityKind = kind.ToString(),
                    EntityId = entityId
                }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
            PreferenceRow? row = await connection.QuerySingleOrDefaultAsync<PreferenceRow>(new CommandDefinition(
                """
                SELECT project_id AS ProjectId, progression_track AS ProgressionTrack,
                       entity_kind AS EntityKind, entity_id AS EntityId, pinned AS Pinned, hidden AS Hidden
                FROM entity_preferences
                WHERE project_id = @ProjectId AND progression_track = @ProgressionTrack
                  AND entity_kind = @EntityKind AND entity_id = @EntityId
                """,
                new
                {
                    ProjectId = (int)context.Project,
                    ProgressionTrack = TrackKey(context),
                    EntityKind = kind.ToString(),
                    EntityId = entityId
                }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
            return row is null ? new(context, kind, entityId, false, false) : MapPreference(row);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) when (exception is SqliteException or IOException or UnauthorizedAccessException)
        {
            throw PersistenceFailure(exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public async Task<SavedInvestigation> CreateInvestigationAsync(
        string name, GameContext context, int definitionVersion, JsonElement definition,
        CancellationToken cancellationToken = default)
    {
        name = ValidateName(name);
        ValidateContext(context);
        ValidateDefinition(definitionVersion, definition);
        string id = Guid.NewGuid().ToString("D");
        string definitionJson = definition.GetRawText();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        string timestamp = FormatTimestamp(now);
        await EnsureInitializedAsync(cancellationToken).ConfigureAwait(false);
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using SqliteConnection connection = CreateConnection(readOnly: false);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            await using SqliteTransaction transaction = connection.BeginTransaction(deferred: false);
            await connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO saved_investigations
                    (id, name, project_id, progression_track, definition_version, definition_json,
                     created_at, updated_at, revision)
                VALUES
                    (@Id, @Name, @ProjectId, @ProgressionTrack, @DefinitionVersion, @DefinitionJson,
                     @CreatedAt, @UpdatedAt, 1)
                """,
                new
                {
                    Id = id,
                    Name = name,
                    ProjectId = (int)context.Project,
                    ProgressionTrack = TrackKey(context),
                    DefinitionVersion = definitionVersion,
                    DefinitionJson = definitionJson,
                    CreatedAt = timestamp,
                    UpdatedAt = timestamp
                }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
            return new(id, name, context, definitionVersion, definition.Clone(), now, now, 1);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) when (exception is SqliteException or IOException or UnauthorizedAccessException)
        {
            throw PersistenceFailure(exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public async Task<SavedInvestigation?> GetInvestigationAsync(
        string id, CancellationToken cancellationToken = default)
    {
        ValidateInvestigationId(id);
        await EnsureInitializedAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using SqliteConnection connection = CreateConnection(readOnly: true);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            InvestigationRow? row = await connection.QuerySingleOrDefaultAsync<InvestigationRow>(new CommandDefinition(
                SelectInvestigation + " WHERE id = @Id", new { Id = id },
                cancellationToken: cancellationToken)).ConfigureAwait(false);
            return row is null ? null : MapInvestigation(row);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) when (exception is SqliteException or IOException or UnauthorizedAccessException or
                                          ArgumentException or FormatException or OverflowException or JsonException)
        {
            throw PersistenceFailure(exception);
        }
    }

    public async Task<IReadOnlyList<SavedInvestigationSummary>> ListInvestigationsAsync(
        GameContext? context = null,
        CancellationToken cancellationToken = default)
    {
        if (context is not null)
            ValidateContext(context);
        await EnsureInitializedAsync(cancellationToken).ConfigureAwait(false);
        string filter = context is null ? "" :
            " WHERE project_id = @ProjectId AND progression_track = @ProgressionTrack";
        try
        {
            await using SqliteConnection connection = CreateConnection(readOnly: true);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            IEnumerable<InvestigationSummaryRow> rows = await connection.QueryAsync<InvestigationSummaryRow>(new CommandDefinition(
                SelectInvestigationSummary + filter + " ORDER BY created_at, id",
                new
                {
                    ProjectId = context is null ? (int?)null : (int)context.Project,
                    ProgressionTrack = context is null ? null : TrackKey(context)
                }, cancellationToken: cancellationToken)).ConfigureAwait(false);
            return rows.Select(MapInvestigationSummary).ToArray();
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) when (exception is SqliteException or IOException or UnauthorizedAccessException or
                                          ArgumentException or FormatException or OverflowException or JsonException)
        {
            throw PersistenceFailure(exception);
        }
    }

    public async Task<SavedInvestigation?> UpdateInvestigationAsync(
        string id, string name, int definitionVersion, JsonElement definition, long expectedRevision,
        CancellationToken cancellationToken = default)
    {
        ValidateInvestigationId(id);
        if (expectedRevision <= 0)
            throw new ArgumentOutOfRangeException(nameof(expectedRevision));
        name = ValidateName(name);
        ValidateDefinition(definitionVersion, definition);
        string definitionJson = definition.GetRawText();
        await EnsureInitializedAsync(cancellationToken).ConfigureAwait(false);
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using SqliteConnection connection = CreateConnection(readOnly: false);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            await using SqliteTransaction transaction = connection.BeginTransaction(deferred: false);
            int updated = await connection.ExecuteAsync(new CommandDefinition(
                """
                UPDATE saved_investigations
                SET name = @Name,
                    definition_version = @DefinitionVersion,
                    definition_json = @DefinitionJson,
                    updated_at = @UpdatedAt,
                    revision = revision + 1
                WHERE id = @Id AND revision = @ExpectedRevision
                """,
                new
                {
                    Id = id,
                    Name = name,
                    DefinitionVersion = definitionVersion,
                    DefinitionJson = definitionJson,
                    UpdatedAt = FormatTimestamp(DateTimeOffset.UtcNow),
                    ExpectedRevision = expectedRevision
                }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
            if (updated == 0)
            {
                bool exists = await connection.ExecuteScalarAsync<bool>(new CommandDefinition(
                    "SELECT EXISTS(SELECT 1 FROM saved_investigations WHERE id = @Id)",
                    new { Id = id }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
                await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
                if (!exists) return null;
                throw new SavedInvestigationRevisionConflictException();
            }
            InvestigationRow row = await connection.QuerySingleAsync<InvestigationRow>(new CommandDefinition(
                SelectInvestigation + " WHERE id = @Id", new { Id = id }, transaction,
                cancellationToken: cancellationToken)).ConfigureAwait(false);
            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
            return MapInvestigation(row);
        }
        catch (OperationCanceledException) { throw; }
        catch (SavedInvestigationRevisionConflictException) { throw; }
        catch (Exception exception) when (exception is SqliteException or IOException or UnauthorizedAccessException or
                                          ArgumentException or FormatException or OverflowException or JsonException)
        {
            throw PersistenceFailure(exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public async Task<bool> DeleteInvestigationAsync(
        string id, long expectedRevision, CancellationToken cancellationToken = default)
    {
        ValidateInvestigationId(id);
        if (expectedRevision <= 0)
            throw new ArgumentOutOfRangeException(nameof(expectedRevision));
        await EnsureInitializedAsync(cancellationToken).ConfigureAwait(false);
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using SqliteConnection connection = CreateConnection(readOnly: false);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            await using SqliteTransaction transaction = connection.BeginTransaction(deferred: false);
            int deleted = await connection.ExecuteAsync(new CommandDefinition(
                "DELETE FROM saved_investigations WHERE id = @Id AND revision = @ExpectedRevision",
                new { Id = id, ExpectedRevision = expectedRevision }, transaction,
                cancellationToken: cancellationToken)).ConfigureAwait(false);
            if (deleted == 0)
            {
                bool exists = await connection.ExecuteScalarAsync<bool>(new CommandDefinition(
                    "SELECT EXISTS(SELECT 1 FROM saved_investigations WHERE id = @Id)",
                    new { Id = id }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
                await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
                if (!exists) return false;
                throw new SavedInvestigationRevisionConflictException();
            }
            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
            return true;
        }
        catch (OperationCanceledException) { throw; }
        catch (SavedInvestigationRevisionConflictException) { throw; }
        catch (Exception exception) when (exception is SqliteException or IOException or UnauthorizedAccessException)
        {
            throw PersistenceFailure(exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public ValueTask DisposeAsync()
    {
        Interlocked.Exchange(ref _disposed, 1);
        _initialized = false;
        return ValueTask.CompletedTask;
    }

    private async Task EnsureInitializedAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        if (!_initialized)
            throw new InvalidOperationException("The application-state database has not been initialized.");
        cancellationToken.ThrowIfCancellationRequested();
        await Task.CompletedTask.ConfigureAwait(false);
    }

    private SqliteConnection CreateConnection(bool readOnly, bool createIfMissing = false) => new(new SqliteConnectionStringBuilder
    {
        DataSource = _path,
        Mode = readOnly ? SqliteOpenMode.ReadOnly :
            createIfMissing ? SqliteOpenMode.ReadWriteCreate : SqliteOpenMode.ReadWrite,
        Cache = SqliteCacheMode.Private,
        Pooling = false,
        DefaultTimeout = 5
    }.ToString());

    private static async Task InitializeDatabaseAsync(
        SqliteConnection connection, CancellationToken cancellationToken)
    {
        await using SqliteTransaction transaction = connection.BeginTransaction(deferred: false);
        string? integrity = await connection.ExecuteScalarAsync<string>(
            new CommandDefinition("PRAGMA quick_check(1)", transaction: transaction,
                cancellationToken: cancellationToken)).ConfigureAwait(false);
        if (!string.Equals(integrity, "ok", StringComparison.Ordinal))
            throw new InvalidDataException("The application-state database failed its integrity check.");

        int applicationId = await connection.ExecuteScalarAsync<int>(
            new CommandDefinition("PRAGMA application_id", transaction: transaction,
                cancellationToken: cancellationToken)).ConfigureAwait(false);
        int schemaVersion = await connection.ExecuteScalarAsync<int>(
            new CommandDefinition("PRAGMA user_version", transaction: transaction,
                cancellationToken: cancellationToken)).ConfigureAwait(false);
        long pageCount = await connection.ExecuteScalarAsync<long>(
            new CommandDefinition("PRAGMA page_count", transaction: transaction,
                cancellationToken: cancellationToken)).ConfigureAwait(false);
        long freePageCount = await connection.ExecuteScalarAsync<long>(
            new CommandDefinition("PRAGMA freelist_count", transaction: transaction,
                cancellationToken: cancellationToken)).ConfigureAwait(false);
        long applicationObjectCount = await connection.ExecuteScalarAsync<long>(
            new CommandDefinition(
                "SELECT COUNT(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'",
                transaction: transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);

        if (applicationId == 0 && schemaVersion == 0 && pageCount <= 1 && freePageCount == 0 &&
            applicationObjectCount == 0)
            await CreateInitialSchemaAsync(connection, transaction, cancellationToken).ConfigureAwait(false);
        else
            await ValidateExistingDatabaseAsync(
                connection, transaction, applicationId, schemaVersion, cancellationToken).ConfigureAwait(false);

        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);

        string? journalMode = await connection.ExecuteScalarAsync<string>(
            new CommandDefinition("PRAGMA journal_mode", cancellationToken: cancellationToken)).ConfigureAwait(false);
        if (!string.Equals(journalMode, "wal", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                journalMode = await connection.ExecuteScalarAsync<string>(
                    new CommandDefinition("PRAGMA journal_mode = WAL", cancellationToken: cancellationToken))
                    .ConfigureAwait(false);
            }
            catch (SqliteException)
            {
                journalMode = await connection.ExecuteScalarAsync<string>(
                    new CommandDefinition("PRAGMA journal_mode", cancellationToken: cancellationToken))
                    .ConfigureAwait(false);
                if (!string.Equals(journalMode, "wal", StringComparison.OrdinalIgnoreCase))
                    throw;
            }
            if (!string.Equals(journalMode, "wal", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The application-state database could not enter WAL mode.");
        }
    }

    private static async Task CreateInitialSchemaAsync(
        SqliteConnection connection, SqliteTransaction transaction, CancellationToken cancellationToken)
    {
        await connection.ExecuteAsync(new CommandDefinition(
            """
            CREATE TABLE entity_preferences (
                project_id INTEGER NOT NULL CHECK (project_id > 0),
                progression_track TEXT NOT NULL,
                entity_kind TEXT NOT NULL CHECK (entity_kind IN ('Recipe', 'Item')),
                entity_id INTEGER NOT NULL CHECK (entity_id > 0),
                pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)),
                hidden INTEGER NOT NULL CHECK (hidden IN (0, 1)),
                PRIMARY KEY (project_id, progression_track, entity_kind, entity_id)
            ) WITHOUT ROWID;

            CREATE TABLE saved_investigations (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
                project_id INTEGER NOT NULL CHECK (project_id > 0),
                progression_track TEXT NOT NULL,
                definition_version INTEGER NOT NULL CHECK (definition_version > 0),
                definition_json TEXT NOT NULL CHECK (json_valid(definition_json)),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                revision INTEGER NOT NULL CHECK (revision > 0)
            ) WITHOUT ROWID;

            CREATE INDEX saved_investigations_context_created
                ON saved_investigations(project_id, progression_track, created_at, id);
            """, transaction: transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
        await connection.ExecuteAsync(new CommandDefinition(
            $"PRAGMA application_id = {ApplicationId}; PRAGMA user_version = {CurrentSchemaVersion};",
            transaction: transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
    }

    private static async Task ValidateExistingDatabaseAsync(
        SqliteConnection connection, SqliteTransaction transaction, int applicationId, int schemaVersion,
        CancellationToken cancellationToken)
    {
        if (applicationId != ApplicationId)
            throw new InvalidDataException("The file is not an Artisan Logbook application-state database.");
        if (schemaVersion != CurrentSchemaVersion)
            throw new InvalidDataException($"Unsupported application-state schema version {schemaVersion}.");
        (string Name, string[] Columns)[] tables =
        [
            ("entity_preferences", ["project_id", "progression_track", "entity_kind", "entity_id", "pinned", "hidden"]),
            ("saved_investigations", ["id", "name", "project_id", "progression_track", "definition_version",
                "definition_json", "created_at", "updated_at", "revision"])
        ];
        foreach ((string table, string[] requiredColumns) in tables)
        {
            IEnumerable<string> columns = await connection.QueryAsync<string>(new CommandDefinition(
                "SELECT name FROM pragma_table_info(@Name)",
                new { Name = table }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
            HashSet<string> columnNames = columns.ToHashSet(StringComparer.Ordinal);
            if (requiredColumns.Any(column => !columnNames.Contains(column)))
                throw new InvalidDataException("The application-state database is missing a required table or column.");
        }
    }

    private static void ValidateContext(GameContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        if ((int)context.Project <= 0)
            throw new ArgumentOutOfRangeException(nameof(context), "A game project must be positive.");
        if (context.ProgressionTrack is { Length: > MaximumProgressionTrackLength } ||
            context.ProgressionTrack is not null && string.IsNullOrWhiteSpace(context.ProgressionTrack))
            throw new ArgumentException("The progression track is invalid.", nameof(context));
    }

    private static void ValidateEntity(PreferredEntityKind kind, int entityId)
    {
        if (!Enum.IsDefined(kind))
            throw new ArgumentOutOfRangeException(nameof(kind));
        if (entityId <= 0)
            throw new ArgumentOutOfRangeException(nameof(entityId), "An entity ID must be positive.");
    }

    private static string ValidateName(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        name = name.Trim();
        if (name.Length is < 1 or > MaximumInvestigationNameLength)
            throw new ArgumentException($"A saved investigation name must contain 1 to {MaximumInvestigationNameLength} characters.", nameof(name));
        return name;
    }

    private static void ValidateDefinition(int version, JsonElement definition)
    {
        if (version <= 0)
            throw new ArgumentOutOfRangeException(nameof(version), "A definition version must be positive.");
        if (definition.ValueKind != JsonValueKind.Object)
            throw new ArgumentException("A saved investigation definition must be a JSON object.", nameof(definition));
        string json = definition.GetRawText();
        if (Encoding.UTF8.GetByteCount(json) > MaximumInvestigationDefinitionBytes)
            throw new ArgumentException("The saved investigation definition exceeds the 256 KiB limit.", nameof(definition));
        using JsonDocument document = JsonDocument.Parse(json, new JsonDocumentOptions
        {
            MaxDepth = MaximumInvestigationDepth,
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow
        });
        if (document.RootElement.EnumerateObject()
            .Any(property => string.Equals(property.Name, "context", StringComparison.OrdinalIgnoreCase)))
            throw new ArgumentException("Game context belongs to the saved investigation envelope.", nameof(definition));
        if (CompanionSettingsStore.HasDuplicateProperties(document.RootElement))
            throw new ArgumentException("Duplicate properties are not allowed in a saved investigation definition.", nameof(definition));
    }

    private static void ValidateInvestigationId(string id)
    {
        if (id is null || id.Length != 36 || !Guid.TryParseExact(id, "D", out _))
            throw new ArgumentException("The saved investigation ID is invalid.", nameof(id));
    }

    private static string TrackKey(GameContext context) => context.ProgressionTrack ?? EmptyTrack;

    private static GameContext MapContext(long projectId, string progressionTrack) =>
        new((GameProject)checked((int)projectId), progressionTrack.Length == 0 ? null : progressionTrack);

    private static EntityPreference MapPreference(PreferenceRow row) =>
        new(MapContext(row.ProjectId, row.ProgressionTrack),
            Enum.Parse<PreferredEntityKind>(row.EntityKind, ignoreCase: false),
            checked((int)row.EntityId), row.Pinned != 0, row.Hidden != 0);

    private static SavedInvestigation MapInvestigation(InvestigationRow row)
    {
        using JsonDocument definition = JsonDocument.Parse(row.DefinitionJson, new JsonDocumentOptions
        {
            MaxDepth = MaximumInvestigationDepth
        });
        return new(row.Id, row.Name, MapContext(row.ProjectId, row.ProgressionTrack),
            checked((int)row.DefinitionVersion), definition.RootElement.Clone(),
            DateTimeOffset.Parse(row.CreatedAt, CultureInfo.InvariantCulture, DateTimeStyles.None),
            DateTimeOffset.Parse(row.UpdatedAt, CultureInfo.InvariantCulture, DateTimeStyles.None),
            row.Revision);
    }

    private static SavedInvestigationSummary MapInvestigationSummary(InvestigationSummaryRow row) =>
        new(row.Id, row.Name, MapContext(row.ProjectId, row.ProgressionTrack),
            checked((int)row.DefinitionVersion),
            DateTimeOffset.Parse(row.CreatedAt, CultureInfo.InvariantCulture, DateTimeStyles.None),
            DateTimeOffset.Parse(row.UpdatedAt, CultureInfo.InvariantCulture, DateTimeStyles.None),
            row.Revision);

    private static string FormatTimestamp(DateTimeOffset timestamp) =>
        timestamp.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);

    private static ApplicationStatePersistenceException PersistenceFailure(Exception exception) =>
        exception as ApplicationStatePersistenceException ??
        new ApplicationStatePersistenceException("The application-state database operation failed.", exception);

    private const string SelectInvestigation =
        """
        SELECT id AS Id, name AS Name, project_id AS ProjectId, progression_track AS ProgressionTrack,
               definition_version AS DefinitionVersion, definition_json AS DefinitionJson,
               created_at AS CreatedAt, updated_at AS UpdatedAt, revision AS Revision
        FROM saved_investigations
        """;

    private const string SelectInvestigationSummary =
        """
        SELECT id AS Id, name AS Name, project_id AS ProjectId, progression_track AS ProgressionTrack,
               definition_version AS DefinitionVersion, created_at AS CreatedAt,
               updated_at AS UpdatedAt, revision AS Revision
        FROM saved_investigations
        """;

    private sealed record PreferenceRow(
        long ProjectId, string ProgressionTrack, string EntityKind, long EntityId, long Pinned, long Hidden);
    private sealed record InvestigationRow(
        string Id, string Name, long ProjectId, string ProgressionTrack, long DefinitionVersion,
        string DefinitionJson, string CreatedAt, string UpdatedAt, long Revision);
    private sealed record InvestigationSummaryRow(
        string Id, string Name, long ProjectId, string ProgressionTrack, long DefinitionVersion,
        string CreatedAt, string UpdatedAt, long Revision);
}

internal sealed class SavedInvestigationRevisionConflictException()
    : InvalidOperationException("The saved investigation revision has changed.");
