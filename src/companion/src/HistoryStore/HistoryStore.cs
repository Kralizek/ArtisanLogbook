using System.Data.Common;
using System.Globalization;
using System.Text.Json;

using ArtisanLogbook.History;

using Dapper;

using DuckDB.NET.Data;

namespace ArtisanLogbook.HistoryStore;

public enum CraftWriteStatus
{
    Inserted,
    AlreadyPresent,
    Enriched,
    Conflict,
    Invalid
}

public sealed record CraftWriteResult(
    CraftWriteStatus Status,
    CraftObservation? Observation,
    IReadOnlyList<HistoryValidationError> ValidationErrors,
    IReadOnlyList<HistoryConflict> Conflicts)
{
    public CraftObservation? PreviousObservation { get; init; }

    public bool IsSuccessful => Status is CraftWriteStatus.Inserted
        or CraftWriteStatus.AlreadyPresent
        or CraftWriteStatus.Enriched;
}

public enum DimensionWriteStatus
{
    Inserted,
    AlreadyPresent,
    Enriched,
    Conflict,
    Invalid
}

public sealed record DimensionWriteResult(
    DimensionWriteStatus Status,
    CraftDimensions? Dimensions,
    IReadOnlyList<HistoryValidationError> ValidationErrors,
    IReadOnlyList<DimensionConflict> Conflicts)
{
    public bool IsSuccessful => Status is DimensionWriteStatus.Inserted
        or DimensionWriteStatus.AlreadyPresent
        or DimensionWriteStatus.Enriched;
}

public sealed record CraftHistoryBatchWriteResult(
    int InsertedCrafts,
    int AlreadyPresentCrafts,
    int EnrichedCrafts,
    int InsertedDimensions,
    int EnrichedDimensions,
    IReadOnlyList<HistoryValidationError> ValidationErrors,
    IReadOnlyList<HistoryConflict> CraftConflicts,
    IReadOnlyList<DimensionConflict> DimensionConflicts)
{
    /// <summary>Per-observation reconciliation facts, exposed only after the batch commits.</summary>
    public IReadOnlyList<CraftWriteResult> Observations { get; init; } = [];

    public bool IsSuccessful => ValidationErrors.Count == 0 &&
        CraftConflicts.Count == 0 && DimensionConflicts.Count == 0;
}

/// <summary>Persists canonical craft observations in a local DuckDB database.</summary>
public sealed class HistoryStore : IDisposable, IAsyncDisposable
{
    private const int CurrentSchemaVersion = 2;
    private const int EvidenceFormatVersion = 1;
    private const int UnknownDataSlotType = 0;
    private static readonly IReadOnlyDictionary<string, string[]> RequiredColumns =
        new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
        {
            ["Character"] = ["ContextKey", "IdentityKey", "Name", "ClassFile"],
            ["Craft"] =
            [
                "CraftKey", "ContextKey", "CharacterKey", "RecordedAt", "RecipeId",
                "ProfessionId", "ProfessionExpansionKey", "ConcentrationSpent", "IngenuityRefund",
                "ConcentrationCurrencyId", "HasIngenuityProc", "HasResourcefulnessProc", "MulticraftBonus",
                "InputsComplete", "ResourcefulnessComplete", "OutputsComplete", "ReagentsObserved",
                "OutputsObserved", "ProvenanceJson", "OutputEvidenceJson", "ConfigurationEvidenceJson",
                "RecipeSchematicEvidenceJson", "EvidenceFormatVersion"
            ],
            ["CraftIdentity"] = ["IdentityOrigin", "IdentityObservation", "CraftKey"],
            ["CraftOutput"] = ["CraftKey", "ItemId", "QualityKey", "Quality", "Quantity"],
            ["CraftReagent"] = ["CraftKey", "ItemId", "AllocatedQuantity", "ReturnedQuantity"],
            ["Expansion"] = ["ContextKey", "ExpansionKey", "Name"],
            ["GameContext"] = ["ContextKey", "ProjectId", "ProgressionTrack"],
            ["Item"] = ["ContextKey", "ItemId", "Name"],
            ["Profession"] = ["ContextKey", "ProfessionId", "Name", "ParentId"],
            ["Recipe"] = ["ContextKey", "RecipeId", "Name", "ProfessionId", "ProfessionExpansionKey", "MaxQuality"],
            ["RecipeReagent"] =
            [
                "ContextKey", "RecipeId", "DataSlotTypeKey", "DataSlotIndex", "SlotIndex",
                "ReagentType", "IsRequired", "RequiredQuantity", "CandidateItemIdsJson"
            ],
            ["__HistoryStoreMigration"] = ["Version", "AppliedAt"]
        };

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly Lock _gate = new();
    private readonly Lock _lifecycleGate = new();
    private readonly DuckDBConnection _writerConnection;
    private readonly string _connectionString;
    private readonly bool _readOnly;
    private readonly CancellationTokenSource _shutdown = new();
    private readonly TaskCompletionSource _operationsDrained = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int _activeOperations;
    private Task? _cleanup;

    // Test synchronization at materialization boundaries, without exposing connections.
    internal Action<string>? ReadCheckpoint { get; init; }

    public string DatabasePath { get; }
    public static TimeSpan DefaultShutdownGracePeriod => TimeSpan.FromSeconds(5);
    public TimeSpan ShutdownGracePeriod { get; }

    public int SchemaVersion => GetSchemaVersion();

    public int GetSchemaVersion(CancellationToken cancellationToken = default) =>
        ReadSnapshot(ReadStoredSchemaVersion, cancellationToken);

    private static int ReadStoredSchemaVersion(DbTransaction transaction, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        int version = transaction.Connection!.ExecuteScalar<int>(
            "SELECT COALESCE(MAX(Version), 0) FROM __HistoryStoreMigration", transaction: transaction);
        cancellationToken.ThrowIfCancellationRequested();
        return version;
    }

    public HistoryStore(string databasePath, bool readOnly = false, TimeSpan? shutdownGracePeriod = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);
        ShutdownGracePeriod = shutdownGracePeriod ?? DefaultShutdownGracePeriod;
        if (ShutdownGracePeriod <= TimeSpan.Zero || ShutdownGracePeriod.TotalMilliseconds > int.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(shutdownGracePeriod), "Shutdown grace must be positive and finite.");
        _readOnly = readOnly;
        DatabasePath = Path.GetFullPath(databasePath);
        if (readOnly)
        {
            if (!File.Exists(DatabasePath))
                throw new FileNotFoundException("The history database does not exist.", DatabasePath);
        }
        else
        {
            Directory.CreateDirectory(Path.GetDirectoryName(DatabasePath)!);
        }

        bool initializeIfEmpty = false;
        if (!readOnly)
        {
            initializeIfEmpty = !File.Exists(DatabasePath) || new FileInfo(DatabasePath).Length == 0;
            if (!initializeIfEmpty)
                initializeIfEmpty = InspectExistingDatabase(DatabasePath);
        }

        DbConnectionStringBuilder connectionString = new()
        {
            ["Data Source"] = DatabasePath
        };
        if (readOnly)
            connectionString["access_mode"] = "READ_ONLY";
        _connectionString = connectionString.ConnectionString;
        _writerConnection = new DuckDBConnection(_connectionString);
        try
        {
            _writerConnection.Open();
            if (!readOnly)
                InitializeSchema(initializeIfEmpty);
        }
        catch
        {
            _writerConnection.Dispose();
            throw;
        }
    }

    public CraftWriteResult Write(CraftObservation observation)
    {
        using Operation operation = AdmitOperation();
        lock (_gate)
        {
            operation.Token.ThrowIfCancellationRequested();
            ThrowIfReadOnly();
            ArgumentNullException.ThrowIfNull(observation);

            IReadOnlyList<HistoryValidationError> validationErrors = HistoryValidator.Validate([observation]);
            if (validationErrors.Count > 0)
                return new(CraftWriteStatus.Invalid, null, validationErrors, []);

            using DbTransaction transaction = _writerConnection.BeginTransaction();
            CraftWriteResult result = WriteObservation(observation, transaction);
            operation.Token.ThrowIfCancellationRequested();
            transaction.Commit();
            return result;
        }
    }

    /// <summary>
    /// Validates and reconciles a complete imported history in one DuckDB transaction.
    /// Any conflict leaves both dimensions and crafts unchanged.
    /// </summary>
    public CraftHistoryBatchWriteResult WriteBatch(
        CraftHistory history,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(history);
        cancellationToken.ThrowIfCancellationRequested();
        using Operation operation = AdmitOperation(cancellationToken);
        cancellationToken = operation.Token;

        lock (_gate)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ThrowIfReadOnly();
            cancellationToken.ThrowIfCancellationRequested();

            IReadOnlyList<HistoryValidationError> validationErrors = CraftHistoryValidator.Validate(history);
            if (validationErrors.Count > 0)
                return new(0, 0, 0, 0, 0, validationErrors, [], []);

            using DbTransaction transaction = _writerConnection.BeginTransaction();
            CraftDimensions existingDimensions = ReadDimensions(transaction);
            CraftHistoryMergeResult dimensionMerge = CraftHistoryReconciler.Merge(
                new CraftHistory([], existingDimensions),
                new CraftHistory([], history.Dimensions));
            if (!dimensionMerge.IsSuccessful)
            {
                transaction.Rollback();
                return new(0, 0, 0, 0, 0, dimensionMerge.ValidationErrors ?? [],
                    dimensionMerge.CraftConflicts, dimensionMerge.DimensionConflicts);
            }

            CraftDimensions reconciledDimensions = dimensionMerge.History!.Dimensions;
            bool dimensionsChanged = !SerializeDimensions(existingDimensions)
                .Equals(SerializeDimensions(reconciledDimensions), StringComparison.Ordinal);
            (int insertedDimensions, int enrichedDimensions) = CountDimensionChanges(
                existingDimensions, reconciledDimensions);
            if (dimensionsChanged)
                StoreDimensions(reconciledDimensions, transaction);

            int insertedCrafts = 0;
            int alreadyPresentCrafts = 0;
            int enrichedCrafts = 0;
            List<HistoryConflict> craftConflicts = [];
            List<CraftWriteResult> observations = [];
            foreach (CraftObservation observation in history.Crafts)
            {
                cancellationToken.ThrowIfCancellationRequested();
                CraftWriteResult result = WriteObservation(observation, transaction);
                observations.Add(result);
                switch (result.Status)
                {
                    case CraftWriteStatus.Inserted:
                        insertedCrafts++;
                        break;
                    case CraftWriteStatus.AlreadyPresent:
                        alreadyPresentCrafts++;
                        break;
                    case CraftWriteStatus.Enriched:
                        enrichedCrafts++;
                        break;
                    case CraftWriteStatus.Conflict:
                        craftConflicts.AddRange(result.Conflicts);
                        break;
                    case CraftWriteStatus.Invalid:
                        transaction.Rollback();
                        return new(0, 0, 0, 0, 0, result.ValidationErrors, [], []);
                    default:
                        throw new InvalidOperationException($"Unexpected craft write status: {result.Status}.");
                }
            }

            if (craftConflicts.Count > 0)
            {
                transaction.Rollback();
                return new(0, 0, 0, 0, 0, [], craftConflicts, []);
            }

            cancellationToken.ThrowIfCancellationRequested();
            transaction.Commit();
            return new(insertedCrafts, alreadyPresentCrafts, enrichedCrafts,
                insertedDimensions, enrichedDimensions, [], [], [])
            { Observations = observations };
        }
    }

    public CraftObservation? Read(CraftIdentity identity, CancellationToken cancellationToken = default)
    {
        return ReadSnapshot((transaction, token) =>
        {
            ArgumentNullException.ThrowIfNull(identity);
            return Read(identity, transaction, token);
        }, cancellationToken);
    }

    public DimensionWriteResult WriteDimensions(CraftDimensions dimensions)
    {
        using Operation operation = AdmitOperation();
        lock (_gate)
        {
            operation.Token.ThrowIfCancellationRequested();
            ThrowIfReadOnly();
            ArgumentNullException.ThrowIfNull(dimensions);

            IReadOnlyList<HistoryValidationError> validationErrors =
                CraftHistoryValidator.Validate(new CraftHistory([], dimensions));
            if (validationErrors.Count > 0)
                return new(DimensionWriteStatus.Invalid, null, validationErrors, []);

            using DbTransaction transaction = _writerConnection.BeginTransaction();
            CraftDimensions existing = ReadDimensions(transaction);
            CraftHistoryMergeResult merge = CraftHistoryReconciler.Merge(
                new CraftHistory([], existing),
                new CraftHistory([], dimensions));
            if (!merge.IsSuccessful)
            {
                transaction.Commit();
                return new(DimensionWriteStatus.Conflict, null, [], merge.DimensionConflicts);
            }

            CraftDimensions reconciled = merge.History!.Dimensions;
            bool changed = !SerializeDimensions(existing)
                .Equals(SerializeDimensions(reconciled), StringComparison.Ordinal);
            if (!changed)
            {
                transaction.Commit();
                return new(DimensionWriteStatus.AlreadyPresent, existing, [], []);
            }

            StoreDimensions(reconciled, transaction);
            CraftDimensions persisted = ReadDimensions(transaction);
            operation.Token.ThrowIfCancellationRequested();
            transaction.Commit();
            bool hasExisting = existing.Characters.Count + existing.Recipes.Count +
                existing.Professions.Count + existing.Items.Count + existing.Expansions.Count +
                existing.RecipeReagentSlots.Count > 0;
            return new(hasExisting ? DimensionWriteStatus.Enriched : DimensionWriteStatus.Inserted,
                persisted, [], []);
        }
    }

    public CraftDimensions ReadDimensions(CancellationToken cancellationToken = default) =>
        ReadSnapshot(ReadDimensions, cancellationToken);

    public IReadOnlyList<CraftObservation> ReadAll(CancellationToken cancellationToken = default)
    {
        return ReadSnapshot<IReadOnlyList<CraftObservation>>((transaction, token) =>
        {
            List<CraftIdentity> identities = [];
            token.ThrowIfCancellationRequested();
            foreach ((string Origin, string Observation) row in transaction.Connection!.Query<(string, string)>("""
                    SELECT CraftIdentity.IdentityOrigin, CraftIdentity.IdentityObservation
                    FROM CraftIdentity
                    JOIN Craft USING (CraftKey)
                    ORDER BY CraftIdentity.IdentityOrigin, CraftIdentity.IdentityObservation
                    """, transaction: transaction, buffered: false))
            {
                token.ThrowIfCancellationRequested();
                identities.Add(new CraftIdentity(row.Origin, row.Observation));
                token.ThrowIfCancellationRequested();
            }

            OnReadCheckpoint("Identities", transaction, token);
            List<CraftObservation> observations = new(identities.Count);
            foreach (CraftIdentity identity in identities)
                observations.Add(Read(identity, transaction, token) ??
                    throw new InvalidDataException($"Craft '{identity.Origin}/{identity.Observation}' disappeared during a read."));
            return observations;
        }, cancellationToken);
    }

    /// <summary>Returns operational counts without loading craft payloads or migrating the database.</summary>
    public HistoryStoreStatus ReadStatus(CancellationToken cancellationToken = default)
    {
        return ReadSnapshot((transaction, token) =>
        {
            token.ThrowIfCancellationRequested();
            bool hasMigration = transaction.Connection!.ExecuteScalar<long>("""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE table_schema = 'main' AND table_name = '__HistoryStoreMigration'
                """, transaction: transaction) > 0;
            token.ThrowIfCancellationRequested();
            int? version = hasMigration ? ReadStoredSchemaVersion(transaction, token) : null;
            if (version != CurrentSchemaVersion)
                throw new InvalidOperationException(
                    $"History schema version {version?.ToString(CultureInfo.InvariantCulture) ?? "unavailable"} " +
                    $"cannot be read by this Companion (supported: {CurrentSchemaVersion}).");

            (long Total, string? Oldest, string? Newest) counts = transaction.Connection!.QuerySingle<(long, string?, string?)>("""
                    SELECT COUNT(*),
                        strftime(MIN(CAST(RecordedAt AS TIMESTAMPTZ)) AT TIME ZONE 'UTC', '%Y-%m-%dT%H:%M:%S.%fZ'),
                        strftime(MAX(CAST(RecordedAt AS TIMESTAMPTZ)) AT TIME ZONE 'UTC', '%Y-%m-%dT%H:%M:%S.%fZ')
                    FROM Craft
                    """, transaction: transaction);

            OnReadCheckpoint("Counts", transaction, token);
            List<GameContextCraftCount> contexts = [];
            foreach ((int ProjectId, string? ProgressionTrack, long Count) row in
                transaction.Connection!.Query<(int, string?, long)>("""
                    SELECT g.ProjectId, g.ProgressionTrack, COUNT(*)
                    FROM Craft c JOIN GameContext g ON c.ContextKey = g.ContextKey
                    GROUP BY g.ProjectId, g.ProgressionTrack
                    ORDER BY g.ProjectId, g.ProgressionTrack NULLS FIRST
                    """, transaction: transaction, buffered: false))
            {
                token.ThrowIfCancellationRequested();
                contexts.Add(new(new GameContext((GameProject)row.ProjectId, row.ProgressionTrack), row.Count));
                token.ThrowIfCancellationRequested();
            }
            token.ThrowIfCancellationRequested();
            return new HistoryStoreStatus(version.Value, counts.Total, ReadTimestamp(counts.Oldest),
                ReadTimestamp(counts.Newest), contexts);
        }, cancellationToken);
    }

    private static DateTimeOffset? ReadTimestamp(string? value) =>
        value is null ? null : DateTimeOffset.Parse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);

    public async ValueTask DisposeAsync()
    {
        Task cleanup;
        lock (_lifecycleGate)
        {
            if (_cleanup is null)
            {
                Task cancellation = _shutdown.CancelAsync();
                if (_activeOperations == 0) _operationsDrained.TrySetResult();
                _cleanup = Task.Run(async () =>
                {
                    try
                    {
                        await cancellation.ConfigureAwait(false);
                    }
                    finally
                    {
                        await _operationsDrained.Task.ConfigureAwait(false);
                        try
                        {
                            _writerConnection.Dispose();
                        }
                        finally
                        {
                            _shutdown.Dispose();
                        }
                    }
                });
            }
            cleanup = _cleanup;
        }
        await cleanup.WaitAsync(ShutdownGracePeriod).ConfigureAwait(false);
    }

    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult();

    private Operation AdmitOperation(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (_lifecycleGate)
        {
            ObjectDisposedException.ThrowIf(_cleanup is not null, this);
            cancellationToken.ThrowIfCancellationRequested();
            Operation operation = new(this, cancellationToken, _shutdown.Token);
            _activeOperations++;
            return operation;
        }
    }

    private sealed class Operation(
        HistoryStore owner, CancellationToken callerToken, CancellationToken shutdownToken) : IDisposable
    {
        private readonly CancellationTokenSource? _cancellation = callerToken.CanBeCanceled
            ? CancellationTokenSource.CreateLinkedTokenSource(callerToken, shutdownToken) : null;
        public CancellationToken Token => _cancellation?.Token ?? shutdownToken;

        public void Dispose()
        {
            _cancellation?.Dispose();
            lock (owner._lifecycleGate)
            {
                if (--owner._activeOperations == 0 && owner._cleanup is not null)
                    owner._operationsDrained.TrySetResult();
            }
        }
    }

    private T ReadSnapshot<T>(Func<DbTransaction, CancellationToken, T> read, CancellationToken cancellationToken)
    {
        using Operation operation = AdmitOperation(cancellationToken);
        CancellationToken token = operation.Token;
        using DuckDBConnection connection = new(_connectionString);
        ReadCheckpoint?.Invoke("Admission");
        token.ThrowIfCancellationRequested();
        connection.Open();
        token.ThrowIfCancellationRequested();
        using DbTransaction transaction = connection.BeginTransaction();
        try
        {
            T result;
            // Stop/join interrupt callbacks before COMMIT or rollback/disconnection.
            using (new ReadInterruption(connection, token))
            {
                token.ThrowIfCancellationRequested();
                result = read(transaction, token);
                token.ThrowIfCancellationRequested();
            }
            transaction.Commit();
            return result;
        }
        catch (OperationCanceledException exception) when (token.IsCancellationRequested)
        {
            throw new OperationCanceledException("History read was interrupted.", exception,
                cancellationToken.IsCancellationRequested ? cancellationToken : token);
        }
    }

    private void OnReadCheckpoint(string checkpoint, DbTransaction transaction, CancellationToken cancellationToken = default)
    {
        if (!ReferenceEquals(transaction.Connection, _writerConnection))
            ReadCheckpoint?.Invoke(checkpoint);
        cancellationToken.ThrowIfCancellationRequested();
    }

    private static bool InspectExistingDatabase(string databasePath)
    {
        DbConnectionStringBuilder connectionString = new()
        {
            ["Data Source"] = databasePath,
            ["access_mode"] = "READ_ONLY"
        };
        using DuckDBConnection connection = new(connectionString.ConnectionString);
        connection.Open();

        if (UserObjectCount(connection) == 0)
            return true;

        ValidateInitializedSchema(connection);
        return false;
    }

    private static void ValidateInitializedSchema(DbConnection connection)
    {
        HashSet<string> tables = [];
        using (DbCommand command = connection.CreateCommand())
        {
            command.CommandText = """
                SELECT table_name FROM information_schema.tables
                WHERE table_schema = 'main' AND table_type = 'BASE TABLE'
                """;
            using DbDataReader reader = command.ExecuteReader();
            while (reader.Read())
                tables.Add(reader.GetString(0));
        }
        if (!RequiredColumns.Keys.All(tables.Contains))
            throw new InvalidOperationException(
                "The existing DuckDB file is not an initialized Artisan Logbook history database. " +
                "Use a new database path and reimport SavedVariables. Old development databases are not migrated.");

        int version;
        long versionRows;
        using (DbCommand command = connection.CreateCommand())
        {
            command.CommandText = """
                SELECT COUNT(*), COALESCE(MAX(Version), 0)
                FROM __HistoryStoreMigration
                """;
            using DbDataReader reader = command.ExecuteReader();
            reader.Read();
            versionRows = reader.GetInt64(0);
            version = reader.GetInt32(1);
        }
        if (versionRows != 1 || version != CurrentSchemaVersion)
            throw new InvalidOperationException(
                $"Database schema version {version} is unsupported; expected {CurrentSchemaVersion}. " +
                "Use a new database path and reimport SavedVariables. Old development databases are not migrated.");

        Dictionary<string, HashSet<string>> columns = new(StringComparer.OrdinalIgnoreCase);
        using (DbCommand command = connection.CreateCommand())
        {
            command.CommandText = """
                SELECT table_name, column_name FROM information_schema.columns
                WHERE table_schema = 'main'
                """;
            using DbDataReader reader = command.ExecuteReader();
            while (reader.Read())
            {
                string table = reader.GetString(0);
                if (!columns.TryGetValue(table, out HashSet<string>? names))
                    columns.Add(table, names = new(StringComparer.OrdinalIgnoreCase));
                names.Add(reader.GetString(1));
            }
        }
        if (RequiredColumns.Any(pair => !columns.TryGetValue(pair.Key, out HashSet<string>? names) ||
            pair.Value.Any(column => !names.Contains(column))))
            throw new InvalidOperationException(
                "The existing DuckDB file does not contain the complete supported Artisan Logbook schema.");

        bool hasSequence;
        using (DbCommand command = connection.CreateCommand())
        {
            command.CommandText = """
                SELECT COUNT(*) FROM duckdb_sequences()
                WHERE schema_name = 'main' AND sequence_name = 'CraftKeySequence'
                """;
            hasSequence = Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) == 1;
        }
        if (!hasSequence)
            throw new InvalidOperationException(
                "The existing DuckDB file does not contain the complete supported Artisan Logbook schema.");
    }

    private void InitializeSchema(bool initializeIfEmpty)
    {
        long objectCount = UserObjectCount(_writerConnection);
        if (objectCount == 0)
        {
            if (!initializeIfEmpty)
                throw new InvalidOperationException(
                    "The database became empty while it was being opened; refusing to initialize an existing file.");
            using DbTransaction transaction = _writerConnection.BeginTransaction();
            foreach (string statement in SchemaStatements())
                ExecuteNonQuery(statement, transaction);
            ExecuteNonQuery(
                "INSERT INTO __HistoryStoreMigration (Version, AppliedAt) VALUES (?, ?)",
                transaction,
                CurrentSchemaVersion,
                DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture));
            transaction.Commit();
            return;
        }

        ValidateInitializedSchema(_writerConnection);
    }

    private static long UserObjectCount(DbConnection connection)
    {
        using DuckDBCommand command = (DuckDBCommand)connection.CreateCommand();
        command.CommandText = """
            SELECT
                (SELECT COUNT(*) FROM information_schema.tables
                 WHERE table_schema NOT IN ('information_schema', 'pg_catalog')) +
                (SELECT COUNT(*) FROM duckdb_sequences()
                 WHERE schema_name NOT IN ('information_schema', 'pg_catalog')) +
                (SELECT COUNT(*) FROM information_schema.schemata
                 WHERE schema_name NOT IN ('main', 'information_schema', 'pg_catalog'))
            """;
        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private static IReadOnlyList<string> SchemaStatements() =>
        [
            """
            CREATE TABLE __HistoryStoreMigration (
                Version INTEGER PRIMARY KEY,
                AppliedAt VARCHAR NOT NULL
            )
            """,
            """
            CREATE TABLE GameContext (
                ContextKey VARCHAR PRIMARY KEY,
                ProjectId INTEGER NOT NULL,
                ProgressionTrack VARCHAR
            )
            """,
            """
            CREATE TABLE Character (
                ContextKey VARCHAR NOT NULL,
                IdentityKey VARCHAR NOT NULL,
                Name VARCHAR,
                ClassFile VARCHAR,
                PRIMARY KEY (ContextKey, IdentityKey),
                FOREIGN KEY (ContextKey) REFERENCES GameContext(ContextKey)
            )
            """,
            """
            CREATE TABLE Recipe (
                ContextKey VARCHAR NOT NULL,
                RecipeId INTEGER NOT NULL,
                Name VARCHAR,
                ProfessionId INTEGER,
                ProfessionExpansionKey VARCHAR,
                MaxQuality INTEGER,
                PRIMARY KEY (ContextKey, RecipeId),
                FOREIGN KEY (ContextKey) REFERENCES GameContext(ContextKey)
            )
            """,
            """
            CREATE TABLE Profession (
                ContextKey VARCHAR NOT NULL,
                ProfessionId INTEGER NOT NULL,
                Name VARCHAR,
                ParentId INTEGER,
                PRIMARY KEY (ContextKey, ProfessionId),
                FOREIGN KEY (ContextKey) REFERENCES GameContext(ContextKey)
            )
            """,
            """
            CREATE TABLE Item (
                ContextKey VARCHAR NOT NULL,
                ItemId INTEGER NOT NULL,
                Name VARCHAR,
                PRIMARY KEY (ContextKey, ItemId),
                FOREIGN KEY (ContextKey) REFERENCES GameContext(ContextKey)
            )
            """,
            """
            CREATE TABLE Expansion (
                ContextKey VARCHAR NOT NULL,
                ExpansionKey VARCHAR NOT NULL,
                Name VARCHAR,
                PRIMARY KEY (ContextKey, ExpansionKey),
                FOREIGN KEY (ContextKey) REFERENCES GameContext(ContextKey)
            )
            """,
            """
            CREATE TABLE RecipeReagent (
                ContextKey VARCHAR NOT NULL,
                RecipeId INTEGER NOT NULL,
                DataSlotTypeKey SMALLINT NOT NULL,
                DataSlotIndex INTEGER NOT NULL,
                SlotIndex INTEGER,
                ReagentType SMALLINT,
                IsRequired BOOLEAN,
                RequiredQuantity INTEGER,
                CandidateItemIdsJson VARCHAR,
                PRIMARY KEY (ContextKey, RecipeId, DataSlotTypeKey, DataSlotIndex),
                FOREIGN KEY (ContextKey) REFERENCES GameContext(ContextKey)
            )
            """,
            "CREATE SEQUENCE CraftKeySequence START 1",
            """
            CREATE TABLE CraftIdentity (
                IdentityOrigin VARCHAR NOT NULL,
                IdentityObservation VARCHAR NOT NULL,
                CraftKey BIGINT NOT NULL UNIQUE,
                PRIMARY KEY (IdentityOrigin, IdentityObservation)
            )
            """,
            """
            CREATE TABLE Craft (
                CraftKey BIGINT PRIMARY KEY,
                ContextKey VARCHAR NOT NULL,
                CharacterKey VARCHAR NOT NULL,
                RecordedAt VARCHAR NOT NULL,
                RecipeId INTEGER,
                ProfessionId INTEGER,
                ProfessionExpansionKey VARCHAR,
                ConcentrationSpent INTEGER,
                IngenuityRefund INTEGER,
                ConcentrationCurrencyId INTEGER,
                HasIngenuityProc BOOLEAN,
                HasResourcefulnessProc BOOLEAN,
                MulticraftBonus INTEGER,
                InputsComplete BOOLEAN,
                ResourcefulnessComplete BOOLEAN,
                OutputsComplete BOOLEAN,
                ReagentsObserved BOOLEAN NOT NULL,
                OutputsObserved BOOLEAN NOT NULL,
                ProvenanceJson VARCHAR,
                OutputEvidenceJson VARCHAR,
                ConfigurationEvidenceJson VARCHAR,
                RecipeSchematicEvidenceJson VARCHAR,
                EvidenceFormatVersion INTEGER NOT NULL,
                FOREIGN KEY (CraftKey) REFERENCES CraftIdentity(CraftKey),
                FOREIGN KEY (ContextKey) REFERENCES GameContext(ContextKey)
            )
            """,
            """
            CREATE TABLE CraftReagent (
                CraftKey BIGINT NOT NULL,
                ItemId INTEGER NOT NULL,
                AllocatedQuantity BIGINT,
                ReturnedQuantity VARCHAR,
                PRIMARY KEY (CraftKey, ItemId),
                FOREIGN KEY (CraftKey) REFERENCES CraftIdentity(CraftKey)
            )
            """,
            """
            CREATE TABLE CraftOutput (
                CraftKey BIGINT NOT NULL,
                ItemId INTEGER NOT NULL,
                QualityKey INTEGER NOT NULL,
                Quality INTEGER,
                Quantity BIGINT,
                PRIMARY KEY (CraftKey, ItemId, QualityKey),
                FOREIGN KEY (CraftKey) REFERENCES CraftIdentity(CraftKey),
                CHECK (QualityKey = COALESCE(Quality, -1))
            )
            """
        ];

    private CraftObservation? Read(CraftIdentity identity, DbTransaction transaction, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        CraftRow? row = transaction.Connection!.QuerySingleOrDefault<CraftRow>("""
            SELECT
                Craft.CraftKey,
                GameContext.ProjectId,
                GameContext.ProgressionTrack,
                Craft.RecordedAt,
                Craft.RecipeId,
                Craft.CharacterKey,
                Craft.ProfessionId,
                Craft.ProfessionExpansionKey,
                Craft.ConcentrationSpent,
                Craft.IngenuityRefund,
                Craft.ConcentrationCurrencyId,
                Craft.HasIngenuityProc,
                Craft.HasResourcefulnessProc,
                Craft.MulticraftBonus,
                Craft.InputsComplete,
                Craft.ResourcefulnessComplete,
                Craft.OutputsComplete,
                Craft.ReagentsObserved,
                Craft.OutputsObserved,
                Craft.ProvenanceJson,
                Craft.OutputEvidenceJson,
                Craft.ConfigurationEvidenceJson,
                Craft.EvidenceFormatVersion,
                Craft.RecipeSchematicEvidenceJson
            FROM Craft
            JOIN CraftIdentity USING (CraftKey)
            JOIN GameContext USING (ContextKey)
            WHERE CraftIdentity.IdentityOrigin = $Origin AND CraftIdentity.IdentityObservation = $Observation
            """, new { identity.Origin, identity.Observation }, transaction);
        cancellationToken.ThrowIfCancellationRequested();
        if (row is null) return null;

        OnReadCheckpoint("Craft", transaction, cancellationToken);
        if (row.EvidenceFormatVersion != EvidenceFormatVersion)
            throw new InvalidDataException(
                $"Craft evidence format {row.EvidenceFormatVersion} is not supported; expected {EvidenceFormatVersion}.");

        IReadOnlyList<CraftReagent> reagentRows = ReadReagents(row.CraftKey, transaction, cancellationToken);
        IReadOnlyList<CraftOutput> outputRows = ReadOutputs(row.CraftKey, transaction, cancellationToken);
        if ((!row.ReagentsObserved && reagentRows.Count != 0) || (!row.OutputsObserved && outputRows.Count != 0))
            throw new InvalidDataException(
                $"Craft '{identity.Origin}/{identity.Observation}' has child rows for an unobserved collection.");

        return new CraftObservation(
            identity,
            new GameContext((GameProject)row.ProjectId, row.ProgressionTrack),
            DateTimeOffset.ParseExact(row.RecordedAt, "O", CultureInfo.InvariantCulture, DateTimeStyles.None),
            row.RecipeId,
            new CharacterIdentity(row.CharacterKey),
            row.ProfessionId,
            row.ProfessionExpansionKey,
            row.ConcentrationSpent,
            row.IngenuityRefund,
            row.ConcentrationCurrencyId,
            row.HasIngenuityProc,
            row.HasResourcefulnessProc,
            row.MulticraftBonus,
            row.ReagentsObserved ? reagentRows : null,
            row.OutputsObserved ? outputRows : null,
            Deserialize<CraftProvenance>(row.ProvenanceJson),
            row.InputsComplete,
            row.ResourcefulnessComplete,
            row.OutputsComplete,
            Deserialize<IReadOnlyList<CraftOutputEvidence>>(row.OutputEvidenceJson),
            Deserialize<IReadOnlyList<CraftConfigurationEvidence>>(row.ConfigurationEvidenceJson),
            Deserialize<IReadOnlyList<CraftRecipeSchematicEvidence>>(row.RecipeSchematicEvidenceJson));
    }

    private CraftWriteResult WriteObservation(CraftObservation observation, DbTransaction transaction)
    {
        CraftObservation? existing = Read(observation.Identity, transaction);
        if (existing is null)
        {
            StoreObservation(observation, transaction, isUpdate: false);
            return new(CraftWriteStatus.Inserted, observation, [], []);
        }

        HistoryMergeResult merge = HistoryReconciler.Merge([existing], [observation]);
        if (!merge.IsSuccessful)
            return new(CraftWriteStatus.Conflict, null, [], merge.Conflicts);

        CraftObservation reconciled = merge.Observations!.Single();
        if (EquivalentIncludingEvidence(existing, reconciled))
            return new(CraftWriteStatus.AlreadyPresent, existing, [], []);

        StoreObservation(reconciled, transaction, isUpdate: true);
        return new(CraftWriteStatus.Enriched, reconciled, [], []) { PreviousObservation = existing };
    }

    private static (int Inserted, int Enriched) CountDimensionChanges(
        CraftDimensions existing,
        CraftDimensions reconciled)
    {
        int inserted = 0;
        int enriched = 0;

        void Count<T, TKey>(IEnumerable<T> before, IEnumerable<T> after, Func<T, TKey> key)
            where TKey : notnull
        {
            Dictionary<TKey, T> previous = before.ToDictionary(key);
            foreach (T item in after)
            {
                if (!previous.TryGetValue(key(item), out T? prior))
                    inserted++;
                else if (!JsonSerializer.Serialize(prior, JsonOptions)
                    .Equals(JsonSerializer.Serialize(item, JsonOptions), StringComparison.Ordinal))
                    enriched++;
            }
        }

        Count(existing.Characters, reconciled.Characters, x => (x.Game, x.Identity.Key));
        Count(existing.Recipes, reconciled.Recipes, x => (x.Game, x.Id));
        Count(existing.Professions, reconciled.Professions, x => (x.Game, x.Id));
        Count(existing.Items, reconciled.Items, x => (x.Game, x.Id));
        Count(existing.Expansions, reconciled.Expansions, x => (x.Game, x.Key));
        Count(existing.RecipeReagentSlots, reconciled.RecipeReagentSlots,
            x => (x.Game, x.RecipeId, x.DataSlotType, x.DataSlotIndex));
        return (inserted, enriched);
    }

    private IReadOnlyList<CraftReagent> ReadReagents(long craftKey, DbTransaction transaction, CancellationToken cancellationToken)
    {
        List<CraftReagent> reagents = [];
        cancellationToken.ThrowIfCancellationRequested();
        foreach ((int ItemId, long? Allocated, string? Returned) row in transaction.Connection!.Query<(int, long?, string?)>("""
            SELECT ItemId, AllocatedQuantity, ReturnedQuantity
            FROM CraftReagent
            WHERE CraftKey = $craftKey
            ORDER BY ItemId
            """, new { craftKey }, transaction, buffered: false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            reagents.Add(new CraftReagent(
                row.ItemId,
                row.Allocated,
                row.Returned is null
                    ? null
                    : decimal.Parse(row.Returned, NumberStyles.Number, CultureInfo.InvariantCulture)));
            cancellationToken.ThrowIfCancellationRequested();
        }
        cancellationToken.ThrowIfCancellationRequested();
        return reagents;
    }

    private IReadOnlyList<CraftOutput> ReadOutputs(long craftKey, DbTransaction transaction, CancellationToken cancellationToken)
    {
        List<CraftOutput> outputs = [];
        cancellationToken.ThrowIfCancellationRequested();
        foreach ((int ItemId, int? Quality, long? Quantity) row in transaction.Connection!.Query<(int, int?, long?)>("""
            SELECT ItemId, Quality, Quantity
            FROM CraftOutput
            WHERE CraftKey = $craftKey
            ORDER BY ItemId, QualityKey
            """, new { craftKey }, transaction, buffered: false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            outputs.Add(new CraftOutput(row.ItemId, row.Quality, row.Quantity));
            cancellationToken.ThrowIfCancellationRequested();
        }
        cancellationToken.ThrowIfCancellationRequested();
        return outputs;
    }

    private void StoreObservation(CraftObservation observation, DbTransaction transaction, bool isUpdate)
    {
        EnsureContext(observation.Game, transaction);
        EnsureCharacter(observation.Game, observation.Character, transaction);
        if (observation.RecipeId is int recipeId)
            EnsureRecipe(observation.Game, recipeId, transaction);
        if (observation.ProfessionId is int professionId)
            EnsureProfession(observation.Game, professionId, transaction);
        if (observation.ProfessionExpansionKey is string expansionKey)
            EnsureExpansion(observation.Game, expansionKey, transaction);
        EnsureObservationItems(observation, transaction);

        long craftKey;

        if (isUpdate)
        {
            craftKey = ReadCraftKey(observation.Identity, transaction) ??
                throw new InvalidDataException("A craft disappeared during reconciliation.");
            transaction.Connection!.Execute("DELETE FROM CraftReagent WHERE CraftKey = $craftKey",
                new { craftKey }, transaction);
            transaction.Connection!.Execute("DELETE FROM CraftOutput WHERE CraftKey = $craftKey",
                new { craftKey }, transaction);
            transaction.Connection!.Execute("""
                UPDATE Craft SET
                    ContextKey = $ContextKey, CharacterKey = $CharacterKey, RecordedAt = $RecordedAt,
                    RecipeId = $RecipeId, ProfessionId = $ProfessionId, ProfessionExpansionKey = $ProfessionExpansionKey,
                    ConcentrationSpent = $ConcentrationSpent, IngenuityRefund = $IngenuityRefund,
                    ConcentrationCurrencyId = $ConcentrationCurrencyId, HasIngenuityProc = $HasIngenuityProc,
                    HasResourcefulnessProc = $HasResourcefulnessProc, MulticraftBonus = $MulticraftBonus,
                    InputsComplete = $InputsComplete, ResourcefulnessComplete = $ResourcefulnessComplete,
                    OutputsComplete = $OutputsComplete, ReagentsObserved = $ReagentsObserved,
                    OutputsObserved = $OutputsObserved, ProvenanceJson = $ProvenanceJson,
                    OutputEvidenceJson = $OutputEvidenceJson, ConfigurationEvidenceJson = $ConfigurationEvidenceJson,
                    EvidenceFormatVersion = $EvidenceFormatVersion, RecipeSchematicEvidenceJson = $RecipeSchematicEvidenceJson
                WHERE CraftKey = $CraftKey
                """, CraftValues(observation, craftKey), transaction);
        }
        else
        {
            craftKey = transaction.Connection!.ExecuteScalar<long>("SELECT nextval('CraftKeySequence')", transaction: transaction);
            transaction.Connection!.Execute("""
                INSERT INTO CraftIdentity (IdentityOrigin, IdentityObservation, CraftKey)
                VALUES ($Origin, $Observation, $CraftKey)
                """, new { observation.Identity.Origin, observation.Identity.Observation, CraftKey = craftKey }, transaction);
            transaction.Connection!.Execute("""
                INSERT INTO Craft (
                    CraftKey, ContextKey, CharacterKey, RecordedAt,
                    RecipeId, ProfessionId, ProfessionExpansionKey, ConcentrationSpent, IngenuityRefund,
                    ConcentrationCurrencyId, HasIngenuityProc, HasResourcefulnessProc, MulticraftBonus,
                    InputsComplete, ResourcefulnessComplete, OutputsComplete, ReagentsObserved, OutputsObserved,
                    ProvenanceJson, OutputEvidenceJson, ConfigurationEvidenceJson, EvidenceFormatVersion,
                    RecipeSchematicEvidenceJson
                ) VALUES ($CraftKey, $ContextKey, $CharacterKey, $RecordedAt, $RecipeId, $ProfessionId,
                    $ProfessionExpansionKey, $ConcentrationSpent, $IngenuityRefund, $ConcentrationCurrencyId,
                    $HasIngenuityProc, $HasResourcefulnessProc, $MulticraftBonus, $InputsComplete,
                    $ResourcefulnessComplete, $OutputsComplete, $ReagentsObserved, $OutputsObserved,
                    $ProvenanceJson, $OutputEvidenceJson, $ConfigurationEvidenceJson, $EvidenceFormatVersion,
                    $RecipeSchematicEvidenceJson)
                """, CraftValues(observation, craftKey), transaction);
        }

        foreach (CraftReagent reagent in observation.Reagents ?? [])
            transaction.Connection!.Execute("""
                INSERT INTO CraftReagent (
                    CraftKey, ItemId, AllocatedQuantity, ReturnedQuantity
                ) VALUES ($craftKey, $ItemId, $AllocatedQuantity, $ReturnedQuantity)
                """, new
            {
                craftKey,
                reagent.ItemId,
                reagent.AllocatedQuantity,
                ReturnedQuantity = reagent.ReturnedQuantity?.ToString(CultureInfo.InvariantCulture)
            }, transaction);

        foreach (CraftOutput output in observation.Outputs ?? [])
            transaction.Connection!.Execute("""
                INSERT INTO CraftOutput (
                    CraftKey, ItemId, QualityKey, Quality, Quantity
                ) VALUES ($craftKey, $ItemId, $QualityKey, $Quality, $Quantity)
                """, new
            {
                craftKey,
                output.ItemId,
                QualityKey = output.Quality ?? -1,
                output.Quality,
                output.Quantity
            }, transaction);
    }

    private CraftDimensions ReadDimensions(DbTransaction transaction, CancellationToken cancellationToken = default)
    {
        Dictionary<string, GameContext> contexts = [];
        cancellationToken.ThrowIfCancellationRequested();
        foreach ((string Key, int ProjectId, string? Track) row in transaction.Connection!.Query<(string, int, string?)>("""
            SELECT ContextKey, ProjectId, ProgressionTrack FROM GameContext
            """, transaction: transaction, buffered: false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            contexts.Add(row.Key, new GameContext((GameProject)row.ProjectId, row.Track));
            cancellationToken.ThrowIfCancellationRequested();
        }

        OnReadCheckpoint("Contexts", transaction, cancellationToken);
        GameContext Game(string key) =>
            contexts.TryGetValue(key, out GameContext? game)
                ? game
                : throw new InvalidDataException("A dimension references an unknown game context.");

        List<CharacterDimension> characters = [];
        foreach ((string Context, string Identity, string? Name, string? ClassFile) row in
            transaction.Connection!.Query<(string, string, string?, string?)>("""
            SELECT ContextKey, IdentityKey, Name, ClassFile FROM Character
            ORDER BY ContextKey, IdentityKey
            """, transaction: transaction, buffered: false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            characters.Add(new(Game(row.Context), new CharacterIdentity(row.Identity), row.Name, row.ClassFile));
            if (!ReferenceEquals(transaction.Connection, _writerConnection))
                ReadCheckpoint?.Invoke("CharacterRow");
            cancellationToken.ThrowIfCancellationRequested();
        }

        cancellationToken.ThrowIfCancellationRequested();
        List<RecipeDimension> recipes = [];
        foreach ((string Context, int Id, string? Name, int? Profession, string? Expansion, int? Quality) row in
            transaction.Connection!.Query<(string, int, string?, int?, string?, int?)>("""
            SELECT ContextKey, RecipeId, Name, ProfessionId, ProfessionExpansionKey, MaxQuality FROM Recipe
            ORDER BY ContextKey, RecipeId
            """, transaction: transaction, buffered: false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            recipes.Add(new(Game(row.Context), row.Id, row.Name, row.Profession, row.Expansion, row.Quality));
            cancellationToken.ThrowIfCancellationRequested();
        }

        cancellationToken.ThrowIfCancellationRequested();
        List<ProfessionDimension> professions = [];
        foreach ((string Context, int Id, string? Name, int? Parent) row in
            transaction.Connection!.Query<(string, int, string?, int?)>("""
            SELECT ContextKey, ProfessionId, Name, ParentId FROM Profession
            ORDER BY ContextKey, ProfessionId
            """, transaction: transaction, buffered: false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            professions.Add(new(Game(row.Context), row.Id, row.Name, row.Parent));
            cancellationToken.ThrowIfCancellationRequested();
        }

        cancellationToken.ThrowIfCancellationRequested();
        List<ItemDimension> items = [];
        foreach ((string Context, int Id, string? Name) row in transaction.Connection!.Query<(string, int, string?)>("""
            SELECT ContextKey, ItemId, Name FROM Item
            ORDER BY ContextKey, ItemId
            """, transaction: transaction, buffered: false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            items.Add(new(Game(row.Context), row.Id, row.Name));
            cancellationToken.ThrowIfCancellationRequested();
        }

        cancellationToken.ThrowIfCancellationRequested();
        List<ExpansionDimension> expansions = [];
        foreach ((string Context, string Key, string? Name) row in transaction.Connection!.Query<(string, string, string?)>("""
            SELECT ContextKey, ExpansionKey, Name FROM Expansion
            ORDER BY ContextKey, ExpansionKey
            """, transaction: transaction, buffered: false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            expansions.Add(new(Game(row.Context), row.Key, row.Name));
            cancellationToken.ThrowIfCancellationRequested();
        }

        cancellationToken.ThrowIfCancellationRequested();
        List<RecipeReagentSlot> slots = [];
        foreach (RecipeSlotRow row in transaction.Connection!.Query<RecipeSlotRow>("""
            SELECT ContextKey, RecipeId, DataSlotTypeKey, DataSlotIndex, SlotIndex,
                ReagentType, IsRequired, RequiredQuantity, CandidateItemIdsJson
            FROM RecipeReagent
            ORDER BY ContextKey, RecipeId, DataSlotTypeKey, DataSlotIndex
            """, transaction: transaction, buffered: false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            RecipeReagentDataSlotType? dataSlotType = row.DataSlotTypeKey == UnknownDataSlotType
                ? null
                : EnumValue<RecipeReagentDataSlotType>(row.DataSlotTypeKey - 1, "data-slot type");
            slots.Add(new(Game(row.ContextKey), row.RecipeId, dataSlotType, row.DataSlotIndex,
                row.SlotIndex,
                row.ReagentType is short type ? EnumValue<RecipeReagentType>(type, nameof(RecipeReagentType)) : null,
                row.IsRequired,
                row.RequiredQuantity,
                row.CandidateItemIdsJson is null
                    ? null
                    : JsonSerializer.Deserialize<int[]>(row.CandidateItemIdsJson, JsonOptions) ??
                      throw new InvalidDataException("Recipe reagent candidate IDs are invalid JSON.")));
            cancellationToken.ThrowIfCancellationRequested();
        }

        cancellationToken.ThrowIfCancellationRequested();
        return new CraftDimensions(characters, recipes, professions, items, expansions)
        {
            RecipeReagentSlots = slots
        };
    }

    private void StoreDimensions(CraftDimensions dimensions, DbTransaction transaction)
    {
        foreach (GameContext game in dimensions.Characters.Select(x => x.Game)
            .Concat(dimensions.Recipes.Select(x => x.Game))
            .Concat(dimensions.Professions.Select(x => x.Game))
            .Concat(dimensions.Items.Select(x => x.Game))
            .Concat(dimensions.Expansions.Select(x => x.Game))
            .Concat(dimensions.RecipeReagentSlots.Select(x => x.Game))
            .Distinct())
            EnsureContext(game, transaction);

        foreach (CharacterDimension character in dimensions.Characters)
            transaction.Connection!.Execute("""
                INSERT INTO Character (ContextKey, IdentityKey, Name, ClassFile) VALUES ($ContextKey, $IdentityKey, $Name, $ClassFile)
                ON CONFLICT (ContextKey, IdentityKey) DO UPDATE SET
                    Name = COALESCE(excluded.Name, Character.Name),
                    ClassFile = COALESCE(excluded.ClassFile, Character.ClassFile)
                """, new
            {
                ContextKey = ContextKey(character.Game),
                IdentityKey = character.Identity.Key,
                character.Name,
                character.ClassFile
            }, transaction);

        foreach (RecipeDimension recipe in dimensions.Recipes)
            transaction.Connection!.Execute("""
                INSERT INTO Recipe (
                    ContextKey, RecipeId, Name, ProfessionId, ProfessionExpansionKey, MaxQuality
                ) VALUES ($ContextKey, $RecipeId, $Name, $ProfessionId, $ProfessionExpansionKey, $MaxQuality)
                ON CONFLICT (ContextKey, RecipeId) DO UPDATE SET
                    Name = COALESCE(excluded.Name, Recipe.Name),
                    ProfessionId = COALESCE(excluded.ProfessionId, Recipe.ProfessionId),
                    ProfessionExpansionKey = COALESCE(excluded.ProfessionExpansionKey, Recipe.ProfessionExpansionKey),
                    MaxQuality = COALESCE(excluded.MaxQuality, Recipe.MaxQuality)
                """, new
            {
                ContextKey = ContextKey(recipe.Game),
                RecipeId = recipe.Id,
                recipe.Name,
                recipe.ProfessionId,
                recipe.ProfessionExpansionKey,
                recipe.MaxQuality
            }, transaction);
        foreach (RecipeDimension recipe in dimensions.Recipes)
        {
            if (recipe.ProfessionId is int professionId)
                EnsureProfession(recipe.Game, professionId, transaction);
            if (recipe.ProfessionExpansionKey is string expansionKey)
                EnsureExpansion(recipe.Game, expansionKey, transaction);
        }

        foreach (ProfessionDimension profession in dimensions.Professions)
        {
            transaction.Connection!.Execute("""
                INSERT INTO Profession (ContextKey, ProfessionId, Name, ParentId) VALUES ($ContextKey, $ProfessionId, $Name, $ParentId)
                ON CONFLICT (ContextKey, ProfessionId) DO UPDATE SET
                    Name = COALESCE(excluded.Name, Profession.Name),
                    ParentId = COALESCE(excluded.ParentId, Profession.ParentId)
                """, new
            {
                ContextKey = ContextKey(profession.Game),
                ProfessionId = profession.Id,
                profession.Name,
                profession.ParentId
            }, transaction);
            if (profession.ParentId is int parentId)
                EnsureProfession(profession.Game, parentId, transaction);
        }

        foreach (ItemDimension item in dimensions.Items)
            transaction.Connection!.Execute("""
                INSERT INTO Item (ContextKey, ItemId, Name) VALUES ($ContextKey, $ItemId, $Name)
                ON CONFLICT (ContextKey, ItemId) DO UPDATE SET
                    Name = COALESCE(excluded.Name, Item.Name)
                """, new { ContextKey = ContextKey(item.Game), ItemId = item.Id, item.Name }, transaction);

        foreach (ExpansionDimension expansion in dimensions.Expansions)
            transaction.Connection!.Execute("""
                INSERT INTO Expansion (ContextKey, ExpansionKey, Name) VALUES ($ContextKey, $ExpansionKey, $Name)
                ON CONFLICT (ContextKey, ExpansionKey) DO UPDATE SET
                    Name = COALESCE(excluded.Name, Expansion.Name)
                """, new { ContextKey = ContextKey(expansion.Game), ExpansionKey = expansion.Key, expansion.Name }, transaction);

        foreach (RecipeReagentSlot slot in dimensions.RecipeReagentSlots)
        {
            EnsureRecipe(slot.Game, slot.RecipeId, transaction);
            foreach (int candidateItemId in slot.CandidateItemIds ?? [])
                EnsureItem(slot.Game, candidateItemId, transaction);
            transaction.Connection!.Execute("""
                INSERT INTO RecipeReagent (
                    ContextKey, RecipeId, DataSlotTypeKey, DataSlotIndex, SlotIndex, ReagentType,
                    IsRequired, RequiredQuantity, CandidateItemIdsJson
                ) VALUES ($ContextKey, $RecipeId, $DataSlotTypeKey, $DataSlotIndex, $SlotIndex, $ReagentType,
                    $IsRequired, $RequiredQuantity, $CandidateItemIdsJson)
                ON CONFLICT (ContextKey, RecipeId, DataSlotTypeKey, DataSlotIndex) DO UPDATE SET
                    SlotIndex = COALESCE(excluded.SlotIndex, RecipeReagent.SlotIndex),
                    ReagentType = COALESCE(excluded.ReagentType, RecipeReagent.ReagentType),
                    IsRequired = COALESCE(excluded.IsRequired, RecipeReagent.IsRequired),
                    RequiredQuantity = COALESCE(excluded.RequiredQuantity, RecipeReagent.RequiredQuantity),
                    CandidateItemIdsJson = COALESCE(excluded.CandidateItemIdsJson, RecipeReagent.CandidateItemIdsJson)
                """, new
            {
                ContextKey = ContextKey(slot.Game),
                slot.RecipeId,
                DataSlotTypeKey = slot.DataSlotType is null ? UnknownDataSlotType : (int)slot.DataSlotType.Value + 1,
                slot.DataSlotIndex,
                slot.SlotIndex,
                ReagentType = slot.ReagentType is null ? (int?)null : (int)slot.ReagentType.Value,
                slot.IsRequired,
                slot.RequiredQuantity,
                CandidateItemIdsJson = slot.CandidateItemIds is null ? null :
                        JsonSerializer.Serialize(slot.CandidateItemIds.Order().ToArray(), JsonOptions)
            }, transaction);
        }
    }

    private long? ReadCraftKey(CraftIdentity identity, DbTransaction transaction)
    {
        return transaction.Connection!.QuerySingleOrDefault<long?>("""
            SELECT CraftKey FROM CraftIdentity
            WHERE IdentityOrigin = $Origin AND IdentityObservation = $Observation
            """, new { identity.Origin, identity.Observation }, transaction);
    }

    private void EnsureObservationItems(CraftObservation observation, DbTransaction transaction)
    {
        foreach (CraftReagent reagent in observation.Reagents ?? [])
            EnsureItem(observation.Game, reagent.ItemId, transaction);
        foreach (CraftOutput output in observation.Outputs ?? [])
            EnsureItem(observation.Game, output.ItemId, transaction);
        foreach (CraftOutputEvidence evidence in observation.OutputEvidence ?? [])
            foreach (CraftOutputObservation callback in evidence.Callbacks)
            {
                EnsureItem(observation.Game, callback.Output.ItemId, transaction);
                foreach (CraftReagent returned in callback.Returns)
                    EnsureItem(observation.Game, returned.ItemId, transaction);
            }
    }

    private void EnsureContext(GameContext game, DbTransaction transaction)
    {
        transaction.Connection!.Execute("""
            INSERT INTO GameContext (ContextKey, ProjectId, ProgressionTrack)
            VALUES ($ContextKey, $ProjectId, $ProgressionTrack)
            ON CONFLICT DO NOTHING
            """, new { ContextKey = ContextKey(game), ProjectId = (int)game.Project, game.ProgressionTrack }, transaction);
    }

    private void EnsureCharacter(GameContext game, CharacterIdentity character, DbTransaction transaction)
    {
        transaction.Connection!.Execute("""
            INSERT INTO Character (ContextKey, IdentityKey)
            VALUES ($ContextKey, $IdentityKey)
            ON CONFLICT DO NOTHING
            """, new { ContextKey = ContextKey(game), IdentityKey = character.Key }, transaction);
    }

    private void EnsureRecipe(GameContext game, int recipeId, DbTransaction transaction)
    {
        transaction.Connection!.Execute("""
            INSERT INTO Recipe (ContextKey, RecipeId)
            VALUES ($ContextKey, $recipeId)
            ON CONFLICT DO NOTHING
            """, new { ContextKey = ContextKey(game), recipeId }, transaction);
    }

    private void EnsureProfession(GameContext game, int professionId, DbTransaction transaction)
    {
        transaction.Connection!.Execute("""
            INSERT INTO Profession (ContextKey, ProfessionId)
            VALUES ($ContextKey, $professionId)
            ON CONFLICT DO NOTHING
            """, new { ContextKey = ContextKey(game), professionId }, transaction);
    }

    private void EnsureItem(GameContext game, int itemId, DbTransaction transaction)
    {
        transaction.Connection!.Execute("""
            INSERT INTO Item (ContextKey, ItemId)
            VALUES ($ContextKey, $itemId)
            ON CONFLICT DO NOTHING
            """, new { ContextKey = ContextKey(game), itemId }, transaction);
    }

    private void EnsureExpansion(GameContext game, string expansionKey, DbTransaction transaction)
    {
        transaction.Connection!.Execute("""
            INSERT INTO Expansion (ContextKey, ExpansionKey)
            VALUES ($ContextKey, $expansionKey)
            ON CONFLICT DO NOTHING
            """, new { ContextKey = ContextKey(game), expansionKey }, transaction);
    }

    private static object CraftValues(CraftObservation observation, long craftKey) => new
    {
        CraftKey = craftKey,
        ContextKey = ContextKey(observation.Game),
        CharacterKey = observation.Character.Key,
        RecordedAt = observation.RecordedAt.ToString("O", CultureInfo.InvariantCulture),
        observation.RecipeId,
        observation.ProfessionId,
        observation.ProfessionExpansionKey,
        observation.ConcentrationSpent,
        observation.IngenuityRefund,
        observation.ConcentrationCurrencyId,
        observation.HasIngenuityProc,
        observation.HasResourcefulnessProc,
        observation.MulticraftBonus,
        observation.InputsComplete,
        observation.ResourcefulnessComplete,
        observation.OutputsComplete,
        ReagentsObserved = observation.Reagents is not null,
        OutputsObserved = observation.Outputs is not null,
        ProvenanceJson = Serialize(observation.Provenance),
        OutputEvidenceJson = Serialize(observation.OutputEvidence),
        ConfigurationEvidenceJson = Serialize(observation.ConfigurationEvidence),
        EvidenceFormatVersion,
        RecipeSchematicEvidenceJson = Serialize(observation.RecipeSchematicEvidence)
    };

    private static string ContextKey(GameContext game) =>
        "v1:" + JsonSerializer.Serialize(
            new ContextIdentity((int)game.Project, game.ProgressionTrack),
            JsonOptions);

    private static bool EquivalentIncludingEvidence(CraftObservation first, CraftObservation second) =>
        first == second
        && SequenceEqual(first.OutputEvidence, second.OutputEvidence)
        && SequenceEqual(first.ConfigurationEvidence, second.ConfigurationEvidence)
        && SequenceEqual(first.RecipeSchematicEvidence, second.RecipeSchematicEvidence);

    private static bool SequenceEqual<T>(IReadOnlyList<T>? first, IReadOnlyList<T>? second) =>
        first is null ? second is null : second is not null && first.SequenceEqual(second);

    private static string? Serialize<T>(T? value) =>
        value is null ? null : JsonSerializer.Serialize(value, JsonOptions);

    private static string SerializeDimensions(CraftDimensions dimensions) =>
        JsonSerializer.Serialize(new
        {
            Characters = dimensions.Characters
                .OrderBy(x => ContextKey(x.Game), StringComparer.Ordinal)
                .ThenBy(x => x.Identity.Key, StringComparer.Ordinal),
            Recipes = dimensions.Recipes
                .OrderBy(x => ContextKey(x.Game), StringComparer.Ordinal)
                .ThenBy(x => x.Id),
            Professions = dimensions.Professions
                .OrderBy(x => ContextKey(x.Game), StringComparer.Ordinal)
                .ThenBy(x => x.Id),
            Items = dimensions.Items
                .OrderBy(x => ContextKey(x.Game), StringComparer.Ordinal)
                .ThenBy(x => x.Id),
            Expansions = dimensions.Expansions
                .OrderBy(x => ContextKey(x.Game), StringComparer.Ordinal)
                .ThenBy(x => x.Key, StringComparer.Ordinal),
            RecipeReagentSlots = dimensions.RecipeReagentSlots
                .OrderBy(x => ContextKey(x.Game), StringComparer.Ordinal)
                .ThenBy(x => x.RecipeId)
                .ThenBy(x => x.DataSlotType)
                .ThenBy(x => x.DataSlotIndex)
                .Select(x => x with { CandidateItemIds = x.CandidateItemIds?.Order().ToArray() })
        }, JsonOptions);

    private static T? Deserialize<T>(string? value)
    {
        if (value is null) return default;
        return JsonSerializer.Deserialize<T>(value, JsonOptions) ??
            throw new InvalidDataException($"A stored {typeof(T).Name} JSON value was null.");
    }

    private static int ExecuteNonQuery(string sql, DbTransaction transaction, params object?[] values)
    {
        using DuckDBCommand command = CreateCommand(sql, transaction);
        AddParameters(command, values);
        return command.ExecuteNonQuery();
    }

    private static DuckDBCommand CreateCommand(string sql, DbTransaction transaction)
    {
        DuckDBCommand command = (DuckDBCommand)(transaction.Connection ??
            throw new InvalidOperationException("The history transaction has no connection.")).CreateCommand();
        command.CommandText = sql;
        command.Transaction = transaction;
        return command;
    }

    private static void AddParameters(DuckDBCommand command, params object?[] values)
    {
        foreach (object? value in values)
        {
            DbParameter parameter = command.CreateParameter();
            parameter.Value = value ?? DBNull.Value;
            command.Parameters.Add(parameter);
        }
    }

    private static T EnumValue<T>(int value, string field) where T : struct, Enum
    {
        T enumValue = (T)Enum.ToObject(typeof(T), value);
        return Enum.IsDefined(enumValue)
            ? enumValue
            : throw new InvalidDataException($"Stored recipe reagent {field} '{value}' is not supported.");
    }

    private void ThrowIfReadOnly()
    {
        if (_readOnly)
            throw new InvalidOperationException("The history store was opened read-only.");
    }

    private sealed class RecipeSlotRow
    {
        public string ContextKey { get; set; } = null!;
        public int RecipeId { get; set; }
        public short DataSlotTypeKey { get; set; }
        public int DataSlotIndex { get; set; }
        public int? SlotIndex { get; set; }
        public short? ReagentType { get; set; }
        public bool? IsRequired { get; set; }
        public int? RequiredQuantity { get; set; }
        public string? CandidateItemIdsJson { get; set; }
    }

    private sealed class CraftRow
    {
        public long CraftKey { get; set; }
        public int ProjectId { get; set; }
        public string? ProgressionTrack { get; set; }
        public string RecordedAt { get; set; } = null!;
        public int? RecipeId { get; set; }
        public string CharacterKey { get; set; } = null!;
        public int? ProfessionId { get; set; }
        public string? ProfessionExpansionKey { get; set; }
        public int? ConcentrationSpent { get; set; }
        public int? IngenuityRefund { get; set; }
        public int? ConcentrationCurrencyId { get; set; }
        public bool? HasIngenuityProc { get; set; }
        public bool? HasResourcefulnessProc { get; set; }
        public int? MulticraftBonus { get; set; }
        public bool? InputsComplete { get; set; }
        public bool? ResourcefulnessComplete { get; set; }
        public bool? OutputsComplete { get; set; }
        public bool ReagentsObserved { get; set; }
        public bool OutputsObserved { get; set; }
        public string? ProvenanceJson { get; set; }
        public string? OutputEvidenceJson { get; set; }
        public string? ConfigurationEvidenceJson { get; set; }
        public string? RecipeSchematicEvidenceJson { get; set; }
        public int EvidenceFormatVersion { get; set; }
    }

    private sealed record ContextIdentity(int ProjectId, string? ProgressionTrack);
}
