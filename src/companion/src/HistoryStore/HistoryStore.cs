using System.Data.Common;
using System.Globalization;
using System.Text.Json;

using ArtisanLogbook.History;

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
    public bool IsSuccessful => Status is CraftWriteStatus.Inserted
        or CraftWriteStatus.AlreadyPresent
        or CraftWriteStatus.Enriched;
}

/// <summary>Persists canonical craft observations in a local DuckDB database.</summary>
public sealed class HistoryStore : IDisposable
{
    private const int CurrentSchemaVersion = 1;
    private const int EvidenceFormatVersion = 1;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly object _gate = new();
    private readonly DuckDBConnection _connection;
    private bool _disposed;

    public string DatabasePath { get; }

    public int SchemaVersion
    {
        get
        {
            lock (_gate)
            {
                ThrowIfDisposed();
                return Convert.ToInt32(ExecuteScalar("SELECT COALESCE(MAX(Version), 0) FROM __HistoryStoreMigration"));
            }
        }
    }

    public HistoryStore(string databasePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);
        DatabasePath = Path.GetFullPath(databasePath);
        Directory.CreateDirectory(Path.GetDirectoryName(DatabasePath)!);

        DbConnectionStringBuilder connectionString = new()
        {
            ["Data Source"] = DatabasePath
        };
        _connection = new DuckDBConnection(connectionString.ConnectionString);
        try
        {
            _connection.Open();
            InitializeSchema();
        }
        catch
        {
            _connection.Dispose();
            throw;
        }
    }

    public CraftWriteResult Write(CraftObservation observation)
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            ArgumentNullException.ThrowIfNull(observation);

            IReadOnlyList<HistoryValidationError> validationErrors = HistoryValidator.Validate([observation]);
            if (validationErrors.Count > 0)
                return new(CraftWriteStatus.Invalid, null, validationErrors, []);

            using DbTransaction transaction = _connection.BeginTransaction();
            CraftObservation? existing = Read(observation.Identity, transaction);
            if (existing is null)
            {
                StoreObservation(observation, transaction, isUpdate: false);
                transaction.Commit();
                return new(CraftWriteStatus.Inserted, observation, [], []);
            }

            HistoryMergeResult merge = HistoryReconciler.Merge([existing], [observation]);
            if (!merge.IsSuccessful)
            {
                transaction.Commit();
                return new(CraftWriteStatus.Conflict, null, [], merge.Conflicts);
            }

            CraftObservation reconciled = merge.Observations!.Single();
            if (EquivalentIncludingEvidence(existing, reconciled))
            {
                transaction.Commit();
                return new(CraftWriteStatus.AlreadyPresent, existing, [], []);
            }

            StoreObservation(reconciled, transaction, isUpdate: true);
            transaction.Commit();
            return new(CraftWriteStatus.Enriched, reconciled, [], []);
        }
    }

    public CraftObservation? Read(CraftIdentity identity)
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            ArgumentNullException.ThrowIfNull(identity);
            return Read(identity, transaction: null);
        }
    }

    public IReadOnlyList<CraftObservation> ReadAll()
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            List<CraftIdentity> identities = [];
            using (DuckDBCommand command = _connection.CreateCommand())
            {
                command.CommandText = """
                    SELECT IdentityOrigin, IdentityObservation
                    FROM Craft
                    ORDER BY IdentityOrigin, IdentityObservation
                    """;
                using DbDataReader reader = command.ExecuteReader();
                while (reader.Read())
                    identities.Add(new CraftIdentity(reader.GetString(0), reader.GetString(1)));
            }

            List<CraftObservation> observations = new(identities.Count);
            foreach (CraftIdentity identity in identities)
                observations.Add(Read(identity) ??
                    throw new InvalidDataException($"Craft '{identity.Origin}/{identity.Observation}' disappeared during a read."));
            return observations;
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _connection.Dispose();
            _disposed = true;
        }
    }

    private void InitializeSchema()
    {
        ExecuteNonQuery("""
            CREATE TABLE IF NOT EXISTS __HistoryStoreMigration (
                Version INTEGER PRIMARY KEY,
                AppliedAt VARCHAR NOT NULL
            )
            """);

        int version = SchemaVersion;
        if (version > CurrentSchemaVersion)
            throw new InvalidOperationException(
                $"Database schema version {version} is newer than supported version {CurrentSchemaVersion}.");

        while (version < CurrentSchemaVersion)
        {
            int nextVersion = version + 1;
            using DbTransaction transaction = _connection.BeginTransaction();
            foreach (string statement in MigrationStatements(nextVersion))
                ExecuteNonQuery(statement, transaction);
            ExecuteNonQuery(
                "INSERT INTO __HistoryStoreMigration (Version, AppliedAt) VALUES (?, ?)",
                transaction,
                nextVersion,
                DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture));
            transaction.Commit();
            version = nextVersion;
        }
    }

    private static IReadOnlyList<string> MigrationStatements(int version) => version switch
    {
        1 =>
        [
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
            CREATE TABLE RecipeReagent (
                ContextKey VARCHAR NOT NULL,
                RecipeId INTEGER NOT NULL,
                ItemId INTEGER NOT NULL,
                RequiredQuantity VARCHAR NOT NULL,
                PRIMARY KEY (ContextKey, RecipeId, ItemId),
                FOREIGN KEY (ContextKey, RecipeId) REFERENCES Recipe(ContextKey, RecipeId)
            )
            """,
            """
            CREATE TABLE Craft (
                IdentityOrigin VARCHAR NOT NULL,
                IdentityObservation VARCHAR NOT NULL,
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
                EvidenceFormatVersion INTEGER NOT NULL,
                PRIMARY KEY (IdentityOrigin, IdentityObservation),
                FOREIGN KEY (ContextKey, CharacterKey) REFERENCES Character(ContextKey, IdentityKey),
                FOREIGN KEY (ContextKey, RecipeId) REFERENCES Recipe(ContextKey, RecipeId)
            )
            """,
            """
            CREATE TABLE CraftReagent (
                IdentityOrigin VARCHAR NOT NULL,
                IdentityObservation VARCHAR NOT NULL,
                ItemId INTEGER NOT NULL,
                AllocatedQuantity BIGINT,
                ReturnedQuantity VARCHAR,
                PRIMARY KEY (IdentityOrigin, IdentityObservation, ItemId)
            )
            """,
            """
            CREATE TABLE CraftOutput (
                IdentityOrigin VARCHAR NOT NULL,
                IdentityObservation VARCHAR NOT NULL,
                ItemId INTEGER NOT NULL,
                QualityKey INTEGER NOT NULL,
                Quality INTEGER,
                Quantity BIGINT,
                PRIMARY KEY (IdentityOrigin, IdentityObservation, ItemId, QualityKey),
                CHECK (QualityKey = COALESCE(Quality, -1))
            )
            """
        ],
        _ => throw new InvalidOperationException($"No migration is defined for schema version {version}.")
    };

    private CraftObservation? Read(CraftIdentity identity, DbTransaction? transaction)
    {
        int projectId;
        string? progressionTrack;
        string recordedAt;
        int? recipeId;
        string characterKey;
        int? professionId;
        string? professionExpansionKey;
        int? concentrationSpent;
        int? ingenuityRefund;
        int? concentrationCurrencyId;
        bool? hasIngenuityProc;
        bool? hasResourcefulnessProc;
        int? multicraftBonus;
        bool? inputsComplete;
        bool? resourcefulnessComplete;
        bool? outputsComplete;
        bool reagentsObserved;
        bool outputsObserved;
        string? provenanceJson;
        string? outputEvidenceJson;
        string? configurationEvidenceJson;
        int evidenceFormatVersion;

        using (DuckDBCommand command = CreateCommand("""
            SELECT
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
                Craft.EvidenceFormatVersion
            FROM Craft
            JOIN GameContext USING (ContextKey)
            WHERE Craft.IdentityOrigin = ? AND Craft.IdentityObservation = ?
            """, transaction))
        {
            AddParameters(command, identity.Origin, identity.Observation);
            using DbDataReader reader = command.ExecuteReader();
            if (!reader.Read()) return null;

            projectId = reader.GetInt32(0);
            progressionTrack = NullableString(reader, 1);
            recordedAt = reader.GetString(2);
            recipeId = NullableInt32(reader, 3);
            characterKey = reader.GetString(4);
            professionId = NullableInt32(reader, 5);
            professionExpansionKey = NullableString(reader, 6);
            concentrationSpent = NullableInt32(reader, 7);
            ingenuityRefund = NullableInt32(reader, 8);
            concentrationCurrencyId = NullableInt32(reader, 9);
            hasIngenuityProc = NullableBoolean(reader, 10);
            hasResourcefulnessProc = NullableBoolean(reader, 11);
            multicraftBonus = NullableInt32(reader, 12);
            inputsComplete = NullableBoolean(reader, 13);
            resourcefulnessComplete = NullableBoolean(reader, 14);
            outputsComplete = NullableBoolean(reader, 15);
            reagentsObserved = reader.GetBoolean(16);
            outputsObserved = reader.GetBoolean(17);
            provenanceJson = NullableString(reader, 18);
            outputEvidenceJson = NullableString(reader, 19);
            configurationEvidenceJson = NullableString(reader, 20);
            evidenceFormatVersion = reader.GetInt32(21);
        }

        if (evidenceFormatVersion != EvidenceFormatVersion)
            throw new InvalidDataException(
                $"Craft evidence format {evidenceFormatVersion} is not supported; expected {EvidenceFormatVersion}.");

        IReadOnlyList<CraftReagent> reagentRows = ReadReagents(identity, transaction);
        IReadOnlyList<CraftOutput> outputRows = ReadOutputs(identity, transaction);
        if ((!reagentsObserved && reagentRows.Count != 0) || (!outputsObserved && outputRows.Count != 0))
            throw new InvalidDataException(
                $"Craft '{identity.Origin}/{identity.Observation}' has child rows for an unobserved collection.");

        return new CraftObservation(
            identity,
            new GameContext((GameProject)projectId, progressionTrack),
            DateTimeOffset.ParseExact(recordedAt, "O", CultureInfo.InvariantCulture, DateTimeStyles.None),
            recipeId,
            new CharacterIdentity(characterKey),
            professionId,
            professionExpansionKey,
            concentrationSpent,
            ingenuityRefund,
            concentrationCurrencyId,
            hasIngenuityProc,
            hasResourcefulnessProc,
            multicraftBonus,
            reagentsObserved ? reagentRows : null,
            outputsObserved ? outputRows : null,
            Deserialize<CraftProvenance>(provenanceJson),
            inputsComplete,
            resourcefulnessComplete,
            outputsComplete,
            Deserialize<IReadOnlyList<CraftOutputEvidence>>(outputEvidenceJson),
            Deserialize<IReadOnlyList<CraftConfigurationEvidence>>(configurationEvidenceJson));
    }

    private IReadOnlyList<CraftReagent> ReadReagents(CraftIdentity identity, DbTransaction? transaction)
    {
        List<CraftReagent> reagents = [];
        using DuckDBCommand command = CreateCommand("""
            SELECT ItemId, AllocatedQuantity, ReturnedQuantity
            FROM CraftReagent
            WHERE IdentityOrigin = ? AND IdentityObservation = ?
            ORDER BY ItemId
            """, transaction);
        AddParameters(command, identity.Origin, identity.Observation);
        using DbDataReader reader = command.ExecuteReader();
        while (reader.Read())
        {
            string? returnedQuantity = NullableString(reader, 2);
            reagents.Add(new CraftReagent(
                reader.GetInt32(0),
                NullableInt64(reader, 1),
                returnedQuantity is null
                    ? null
                    : decimal.Parse(returnedQuantity, NumberStyles.Number, CultureInfo.InvariantCulture)));
        }
        return reagents;
    }

    private IReadOnlyList<CraftOutput> ReadOutputs(CraftIdentity identity, DbTransaction? transaction)
    {
        List<CraftOutput> outputs = [];
        using DuckDBCommand command = CreateCommand("""
            SELECT ItemId, Quality, Quantity
            FROM CraftOutput
            WHERE IdentityOrigin = ? AND IdentityObservation = ?
            ORDER BY ItemId, QualityKey
            """, transaction);
        AddParameters(command, identity.Origin, identity.Observation);
        using DbDataReader reader = command.ExecuteReader();
        while (reader.Read())
            outputs.Add(new CraftOutput(
                reader.GetInt32(0),
                NullableInt32(reader, 1),
                NullableInt64(reader, 2)));
        return outputs;
    }

    private void StoreObservation(CraftObservation observation, DbTransaction transaction, bool isUpdate)
    {
        EnsureContext(observation.Game, transaction);
        EnsureCharacter(observation.Game, observation.Character, transaction);
        if (observation.RecipeId is int recipeId)
            EnsureRecipe(observation.Game, recipeId, transaction);

        if (isUpdate)
        {
            ExecuteNonQuery(
                "DELETE FROM CraftReagent WHERE IdentityOrigin = ? AND IdentityObservation = ?",
                transaction,
                observation.Identity.Origin,
                observation.Identity.Observation);
            ExecuteNonQuery(
                "DELETE FROM CraftOutput WHERE IdentityOrigin = ? AND IdentityObservation = ?",
                transaction,
                observation.Identity.Origin,
                observation.Identity.Observation);
            ExecuteNonQuery("""
                UPDATE Craft SET
                    ContextKey = ?,
                    CharacterKey = ?,
                    RecordedAt = ?,
                    RecipeId = ?,
                    ProfessionId = ?,
                    ProfessionExpansionKey = ?,
                    ConcentrationSpent = ?,
                    IngenuityRefund = ?,
                    ConcentrationCurrencyId = ?,
                    HasIngenuityProc = ?,
                    HasResourcefulnessProc = ?,
                    MulticraftBonus = ?,
                    InputsComplete = ?,
                    ResourcefulnessComplete = ?,
                    OutputsComplete = ?,
                    ReagentsObserved = ?,
                    OutputsObserved = ?,
                    ProvenanceJson = ?,
                    OutputEvidenceJson = ?,
                    ConfigurationEvidenceJson = ?,
                    EvidenceFormatVersion = ?
                WHERE IdentityOrigin = ? AND IdentityObservation = ?
                """,
                transaction,
                CraftValues(observation).Concat([
                    observation.Identity.Origin,
                    observation.Identity.Observation
                ]).ToArray());
        }
        else
        {
            ExecuteNonQuery("""
                INSERT INTO Craft (
                    IdentityOrigin, IdentityObservation, ContextKey, CharacterKey, RecordedAt,
                    RecipeId, ProfessionId, ProfessionExpansionKey, ConcentrationSpent, IngenuityRefund,
                    ConcentrationCurrencyId, HasIngenuityProc, HasResourcefulnessProc, MulticraftBonus,
                    InputsComplete, ResourcefulnessComplete, OutputsComplete, ReagentsObserved, OutputsObserved,
                    ProvenanceJson, OutputEvidenceJson, ConfigurationEvidenceJson, EvidenceFormatVersion
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                transaction,
                new object?[]
                {
                    observation.Identity.Origin,
                    observation.Identity.Observation
                }.Concat(CraftValues(observation)).ToArray());
        }

        foreach (CraftReagent reagent in observation.Reagents ?? [])
            ExecuteNonQuery("""
                INSERT INTO CraftReagent (
                    IdentityOrigin, IdentityObservation, ItemId, AllocatedQuantity, ReturnedQuantity
                ) VALUES (?, ?, ?, ?, ?)
                """,
                transaction,
                observation.Identity.Origin,
                observation.Identity.Observation,
                reagent.ItemId,
                reagent.AllocatedQuantity,
                reagent.ReturnedQuantity?.ToString(CultureInfo.InvariantCulture));

        foreach (CraftOutput output in observation.Outputs ?? [])
            ExecuteNonQuery("""
                INSERT INTO CraftOutput (
                    IdentityOrigin, IdentityObservation, ItemId, QualityKey, Quality, Quantity
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                transaction,
                observation.Identity.Origin,
                observation.Identity.Observation,
                output.ItemId,
                output.Quality ?? -1,
                output.Quality,
                output.Quantity);
    }

    private void EnsureContext(GameContext game, DbTransaction transaction)
    {
        ExecuteNonQuery("""
            INSERT INTO GameContext (ContextKey, ProjectId, ProgressionTrack)
            VALUES (?, ?, ?)
            ON CONFLICT DO NOTHING
            """,
            transaction,
            ContextKey(game),
            (int)game.Project,
            game.ProgressionTrack);
    }

    private void EnsureCharacter(GameContext game, CharacterIdentity character, DbTransaction transaction)
    {
        ExecuteNonQuery("""
            INSERT INTO Character (ContextKey, IdentityKey)
            VALUES (?, ?)
            ON CONFLICT DO NOTHING
            """,
            transaction,
            ContextKey(game),
            character.Key);
    }

    private void EnsureRecipe(GameContext game, int recipeId, DbTransaction transaction)
    {
        ExecuteNonQuery("""
            INSERT INTO Recipe (ContextKey, RecipeId)
            VALUES (?, ?)
            ON CONFLICT DO NOTHING
            """,
            transaction,
            ContextKey(game),
            recipeId);
    }

    private static object?[] CraftValues(CraftObservation observation) =>
    [
        ContextKey(observation.Game),
        observation.Character.Key,
        observation.RecordedAt.ToString("O", CultureInfo.InvariantCulture),
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
        observation.Reagents is not null,
        observation.Outputs is not null,
        Serialize(observation.Provenance),
        Serialize(observation.OutputEvidence),
        Serialize(observation.ConfigurationEvidence),
        EvidenceFormatVersion
    ];

    private static string ContextKey(GameContext game) =>
        "v1:" + JsonSerializer.Serialize(
            new ContextIdentity((int)game.Project, game.ProgressionTrack),
            JsonOptions);

    private static bool EquivalentIncludingEvidence(CraftObservation first, CraftObservation second) =>
        first == second
        && SequenceEqual(first.OutputEvidence, second.OutputEvidence)
        && SequenceEqual(first.ConfigurationEvidence, second.ConfigurationEvidence);

    private static bool SequenceEqual<T>(IReadOnlyList<T>? first, IReadOnlyList<T>? second) =>
        first is null ? second is null : second is not null && first.SequenceEqual(second);

    private static string? Serialize<T>(T? value) =>
        value is null ? null : JsonSerializer.Serialize(value, JsonOptions);

    private static T? Deserialize<T>(string? value)
    {
        if (value is null) return default;
        return JsonSerializer.Deserialize<T>(value, JsonOptions) ??
            throw new InvalidDataException($"A stored {typeof(T).Name} JSON value was null.");
    }

    private object? ExecuteScalar(string sql)
    {
        using DuckDBCommand command = _connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar();
    }

    private int ExecuteNonQuery(string sql, DbTransaction? transaction = null, params object?[] values)
    {
        using DuckDBCommand command = CreateCommand(sql, transaction);
        AddParameters(command, values);
        return command.ExecuteNonQuery();
    }

    private DuckDBCommand CreateCommand(string sql, DbTransaction? transaction)
    {
        DuckDBCommand command = _connection.CreateCommand();
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

    private static string? NullableString(DbDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);

    private static int? NullableInt32(DbDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : reader.GetInt32(ordinal);

    private static long? NullableInt64(DbDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : reader.GetInt64(ordinal);

    private static bool? NullableBoolean(DbDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : reader.GetBoolean(ordinal);

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(_disposed, this);

    private sealed record ContextIdentity(int ProjectId, string? ProgressionTrack);
}
