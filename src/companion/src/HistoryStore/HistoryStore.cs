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
    public bool IsSuccessful => ValidationErrors.Count == 0 &&
        CraftConflicts.Count == 0 && DimensionConflicts.Count == 0;
}

/// <summary>Persists canonical craft observations in a local DuckDB database.</summary>
public sealed class HistoryStore : IDisposable
{
    private const int CurrentSchemaVersion = 1;
    private const int EvidenceFormatVersion = 1;
    private const int UnknownDataSlotType = 0;

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
            CraftWriteResult result = WriteObservation(observation, transaction);
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

        lock (_gate)
        {
            ThrowIfDisposed();
            cancellationToken.ThrowIfCancellationRequested();

            IReadOnlyList<HistoryValidationError> validationErrors = CraftHistoryValidator.Validate(history);
            if (validationErrors.Count > 0)
                return new(0, 0, 0, 0, 0, validationErrors, [], []);

            using DbTransaction transaction = _connection.BeginTransaction();
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
            foreach (CraftObservation observation in history.Crafts)
            {
                cancellationToken.ThrowIfCancellationRequested();
                CraftWriteResult result = WriteObservation(observation, transaction);
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
                insertedDimensions, enrichedDimensions, [], [], []);
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

    public DimensionWriteResult WriteDimensions(CraftDimensions dimensions)
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            ArgumentNullException.ThrowIfNull(dimensions);

            IReadOnlyList<HistoryValidationError> validationErrors =
                CraftHistoryValidator.Validate(new CraftHistory([], dimensions));
            if (validationErrors.Count > 0)
                return new(DimensionWriteStatus.Invalid, null, validationErrors, []);

            using DbTransaction transaction = _connection.BeginTransaction();
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
            transaction.Commit();
            bool hasExisting = existing.Characters.Count + existing.Recipes.Count +
                existing.Professions.Count + existing.Items.Count + existing.Expansions.Count +
                existing.RecipeReagentSlots.Count > 0;
            return new(hasExisting ? DimensionWriteStatus.Enriched : DimensionWriteStatus.Inserted,
                persisted, [], []);
        }
    }

    public CraftDimensions ReadDimensions()
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            return ReadDimensions(transaction: null);
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
                    SELECT CraftIdentity.IdentityOrigin, CraftIdentity.IdentityObservation
                    FROM CraftIdentity
                    JOIN Craft USING (CraftKey)
                    ORDER BY CraftIdentity.IdentityOrigin, CraftIdentity.IdentityObservation
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
        ],
        _ => throw new InvalidOperationException($"No migration is defined for schema version {version}.")
    };

    private CraftObservation? Read(CraftIdentity identity, DbTransaction? transaction)
    {
        long craftKey;
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
                Craft.EvidenceFormatVersion
            FROM Craft
            JOIN CraftIdentity USING (CraftKey)
            JOIN GameContext USING (ContextKey)
            WHERE CraftIdentity.IdentityOrigin = ? AND CraftIdentity.IdentityObservation = ?
            """, transaction))
        {
            AddParameters(command, identity.Origin, identity.Observation);
            using DbDataReader reader = command.ExecuteReader();
            if (!reader.Read()) return null;

            craftKey = reader.GetInt64(0);
            projectId = reader.GetInt32(1);
            progressionTrack = NullableString(reader, 2);
            recordedAt = reader.GetString(3);
            recipeId = NullableInt32(reader, 4);
            characterKey = reader.GetString(5);
            professionId = NullableInt32(reader, 6);
            professionExpansionKey = NullableString(reader, 7);
            concentrationSpent = NullableInt32(reader, 8);
            ingenuityRefund = NullableInt32(reader, 9);
            concentrationCurrencyId = NullableInt32(reader, 10);
            hasIngenuityProc = NullableBoolean(reader, 11);
            hasResourcefulnessProc = NullableBoolean(reader, 12);
            multicraftBonus = NullableInt32(reader, 13);
            inputsComplete = NullableBoolean(reader, 14);
            resourcefulnessComplete = NullableBoolean(reader, 15);
            outputsComplete = NullableBoolean(reader, 16);
            reagentsObserved = reader.GetBoolean(17);
            outputsObserved = reader.GetBoolean(18);
            provenanceJson = NullableString(reader, 19);
            outputEvidenceJson = NullableString(reader, 20);
            configurationEvidenceJson = NullableString(reader, 21);
            evidenceFormatVersion = reader.GetInt32(22);
        }

        if (evidenceFormatVersion != EvidenceFormatVersion)
            throw new InvalidDataException(
                $"Craft evidence format {evidenceFormatVersion} is not supported; expected {EvidenceFormatVersion}.");

        IReadOnlyList<CraftReagent> reagentRows = ReadReagents(craftKey, transaction);
        IReadOnlyList<CraftOutput> outputRows = ReadOutputs(craftKey, transaction);
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
        return new(CraftWriteStatus.Enriched, reconciled, [], []);
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

    private IReadOnlyList<CraftReagent> ReadReagents(long craftKey, DbTransaction? transaction)
    {
        List<CraftReagent> reagents = [];
        using DuckDBCommand command = CreateCommand("""
            SELECT ItemId, AllocatedQuantity, ReturnedQuantity
            FROM CraftReagent
            WHERE CraftKey = ?
            ORDER BY ItemId
            """, transaction);
        AddParameters(command, craftKey);
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

    private IReadOnlyList<CraftOutput> ReadOutputs(long craftKey, DbTransaction? transaction)
    {
        List<CraftOutput> outputs = [];
        using DuckDBCommand command = CreateCommand("""
            SELECT ItemId, Quality, Quantity
            FROM CraftOutput
            WHERE CraftKey = ?
            ORDER BY ItemId, QualityKey
            """, transaction);
        AddParameters(command, craftKey);
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
            ExecuteNonQuery(
                "DELETE FROM CraftReagent WHERE CraftKey = ?", transaction, craftKey);
            ExecuteNonQuery(
                "DELETE FROM CraftOutput WHERE CraftKey = ?", transaction, craftKey);
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
                WHERE CraftKey = ?
                """,
                transaction,
                CraftValues(observation).Concat([
                    craftKey
                ]).ToArray());
        }
        else
        {
            craftKey = Convert.ToInt64(
                ExecuteScalar("SELECT nextval('CraftKeySequence')", transaction),
                CultureInfo.InvariantCulture);
            ExecuteNonQuery("""
                INSERT INTO CraftIdentity (IdentityOrigin, IdentityObservation, CraftKey)
                VALUES (?, ?, ?)
                """, transaction, observation.Identity.Origin, observation.Identity.Observation, craftKey);
            ExecuteNonQuery("""
                INSERT INTO Craft (
                    CraftKey, ContextKey, CharacterKey, RecordedAt,
                    RecipeId, ProfessionId, ProfessionExpansionKey, ConcentrationSpent, IngenuityRefund,
                    ConcentrationCurrencyId, HasIngenuityProc, HasResourcefulnessProc, MulticraftBonus,
                    InputsComplete, ResourcefulnessComplete, OutputsComplete, ReagentsObserved, OutputsObserved,
                    ProvenanceJson, OutputEvidenceJson, ConfigurationEvidenceJson, EvidenceFormatVersion
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                transaction,
                new object?[]
                {
                    craftKey
                }.Concat(CraftValues(observation)).ToArray());
        }

        foreach (CraftReagent reagent in observation.Reagents ?? [])
            ExecuteNonQuery("""
                INSERT INTO CraftReagent (
                    CraftKey, ItemId, AllocatedQuantity, ReturnedQuantity
                ) VALUES (?, ?, ?, ?)
                """,
                transaction,
                craftKey,
                reagent.ItemId,
                reagent.AllocatedQuantity,
                reagent.ReturnedQuantity?.ToString(CultureInfo.InvariantCulture));

        foreach (CraftOutput output in observation.Outputs ?? [])
            ExecuteNonQuery("""
                INSERT INTO CraftOutput (
                    CraftKey, ItemId, QualityKey, Quality, Quantity
                ) VALUES (?, ?, ?, ?, ?)
                """,
                transaction,
                craftKey,
                output.ItemId,
                output.Quality ?? -1,
                output.Quality,
                output.Quantity);
    }

    private CraftDimensions ReadDimensions(DbTransaction? transaction)
    {
        Dictionary<string, GameContext> contexts = [];
        using (DuckDBCommand command = CreateCommand("""
            SELECT ContextKey, ProjectId, ProgressionTrack FROM GameContext
            """, transaction))
        {
            using DbDataReader reader = command.ExecuteReader();
            while (reader.Read())
                contexts.Add(reader.GetString(0),
                    new GameContext((GameProject)reader.GetInt32(1), NullableString(reader, 2)));
        }

        GameContext Game(DbDataReader reader, int ordinal) =>
            contexts.TryGetValue(reader.GetString(ordinal), out GameContext? game)
                ? game
                : throw new InvalidDataException("A dimension references an unknown game context.");

        List<CharacterDimension> characters = [];
        using (DuckDBCommand command = CreateCommand("""
            SELECT ContextKey, IdentityKey, Name, ClassFile FROM Character
            ORDER BY ContextKey, IdentityKey
            """, transaction))
        {
            using DbDataReader reader = command.ExecuteReader();
            while (reader.Read())
                characters.Add(new(Game(reader, 0), new CharacterIdentity(reader.GetString(1)),
                    NullableString(reader, 2), NullableString(reader, 3)));
        }

        List<RecipeDimension> recipes = [];
        using (DuckDBCommand command = CreateCommand("""
            SELECT ContextKey, RecipeId, Name, ProfessionId, ProfessionExpansionKey, MaxQuality FROM Recipe
            ORDER BY ContextKey, RecipeId
            """, transaction))
        {
            using DbDataReader reader = command.ExecuteReader();
            while (reader.Read())
                recipes.Add(new(Game(reader, 0), reader.GetInt32(1), NullableString(reader, 2),
                    NullableInt32(reader, 3), NullableString(reader, 4), NullableInt32(reader, 5)));
        }

        List<ProfessionDimension> professions = [];
        using (DuckDBCommand command = CreateCommand("""
            SELECT ContextKey, ProfessionId, Name, ParentId FROM Profession
            ORDER BY ContextKey, ProfessionId
            """, transaction))
        {
            using DbDataReader reader = command.ExecuteReader();
            while (reader.Read())
                professions.Add(new(Game(reader, 0), reader.GetInt32(1), NullableString(reader, 2),
                    NullableInt32(reader, 3)));
        }

        List<ItemDimension> items = [];
        using (DuckDBCommand command = CreateCommand("""
            SELECT ContextKey, ItemId, Name FROM Item
            ORDER BY ContextKey, ItemId
            """, transaction))
        {
            using DbDataReader reader = command.ExecuteReader();
            while (reader.Read())
                items.Add(new(Game(reader, 0), reader.GetInt32(1), NullableString(reader, 2)));
        }

        List<ExpansionDimension> expansions = [];
        using (DuckDBCommand command = CreateCommand("""
            SELECT ContextKey, ExpansionKey, Name FROM Expansion
            ORDER BY ContextKey, ExpansionKey
            """, transaction))
        {
            using DbDataReader reader = command.ExecuteReader();
            while (reader.Read())
                expansions.Add(new(Game(reader, 0), reader.GetString(1), NullableString(reader, 2)));
        }

        List<RecipeReagentSlot> slots = [];
        using (DuckDBCommand command = CreateCommand("""
            SELECT ContextKey, RecipeId, DataSlotTypeKey, DataSlotIndex, SlotIndex,
                ReagentType, IsRequired, RequiredQuantity, CandidateItemIdsJson
            FROM RecipeReagent
            ORDER BY ContextKey, RecipeId, DataSlotTypeKey, DataSlotIndex
            """, transaction))
        {
            using DbDataReader reader = command.ExecuteReader();
            while (reader.Read())
            {
                int dataSlotTypeKey = Convert.ToInt32(reader.GetValue(2), CultureInfo.InvariantCulture);
                RecipeReagentDataSlotType? dataSlotType = dataSlotTypeKey == UnknownDataSlotType
                    ? null
                    : EnumValue<RecipeReagentDataSlotType>(dataSlotTypeKey - 1, "data-slot type");
                string? candidateIdsJson = NullableString(reader, 8);
                slots.Add(new(Game(reader, 0), reader.GetInt32(1), dataSlotType, reader.GetInt32(3),
                    NullableInt32(reader, 4),
                    NullableEnum<RecipeReagentType>(reader, 5),
                    NullableBoolean(reader, 6),
                    NullableInt32(reader, 7),
                    candidateIdsJson is null
                        ? null
                        : JsonSerializer.Deserialize<int[]>(candidateIdsJson, JsonOptions) ??
                          throw new InvalidDataException("Recipe reagent candidate IDs are invalid JSON.")));
            }
        }

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
            ExecuteNonQuery("""
                INSERT INTO Character (ContextKey, IdentityKey, Name, ClassFile) VALUES (?, ?, ?, ?)
                ON CONFLICT (ContextKey, IdentityKey) DO UPDATE SET
                    Name = COALESCE(excluded.Name, Character.Name),
                    ClassFile = COALESCE(excluded.ClassFile, Character.ClassFile)
                """, transaction, ContextKey(character.Game), character.Identity.Key,
                character.Name, character.ClassFile);

        foreach (RecipeDimension recipe in dimensions.Recipes)
            ExecuteNonQuery("""
                INSERT INTO Recipe (
                    ContextKey, RecipeId, Name, ProfessionId, ProfessionExpansionKey, MaxQuality
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (ContextKey, RecipeId) DO UPDATE SET
                    Name = COALESCE(excluded.Name, Recipe.Name),
                    ProfessionId = COALESCE(excluded.ProfessionId, Recipe.ProfessionId),
                    ProfessionExpansionKey = COALESCE(excluded.ProfessionExpansionKey, Recipe.ProfessionExpansionKey),
                    MaxQuality = COALESCE(excluded.MaxQuality, Recipe.MaxQuality)
                """, transaction, ContextKey(recipe.Game), recipe.Id, recipe.Name, recipe.ProfessionId,
                recipe.ProfessionExpansionKey, recipe.MaxQuality);
        foreach (RecipeDimension recipe in dimensions.Recipes)
        {
            if (recipe.ProfessionId is int professionId)
                EnsureProfession(recipe.Game, professionId, transaction);
            if (recipe.ProfessionExpansionKey is string expansionKey)
                EnsureExpansion(recipe.Game, expansionKey, transaction);
        }

        foreach (ProfessionDimension profession in dimensions.Professions)
        {
            ExecuteNonQuery("""
                INSERT INTO Profession (ContextKey, ProfessionId, Name, ParentId) VALUES (?, ?, ?, ?)
                ON CONFLICT (ContextKey, ProfessionId) DO UPDATE SET
                    Name = COALESCE(excluded.Name, Profession.Name),
                    ParentId = COALESCE(excluded.ParentId, Profession.ParentId)
                """, transaction, ContextKey(profession.Game), profession.Id, profession.Name, profession.ParentId);
            if (profession.ParentId is int parentId)
                EnsureProfession(profession.Game, parentId, transaction);
        }

        foreach (ItemDimension item in dimensions.Items)
            ExecuteNonQuery("""
                INSERT INTO Item (ContextKey, ItemId, Name) VALUES (?, ?, ?)
                ON CONFLICT (ContextKey, ItemId) DO UPDATE SET
                    Name = COALESCE(excluded.Name, Item.Name)
                """, transaction, ContextKey(item.Game), item.Id, item.Name);

        foreach (ExpansionDimension expansion in dimensions.Expansions)
            ExecuteNonQuery("""
                INSERT INTO Expansion (ContextKey, ExpansionKey, Name) VALUES (?, ?, ?)
                ON CONFLICT (ContextKey, ExpansionKey) DO UPDATE SET
                    Name = COALESCE(excluded.Name, Expansion.Name)
                """, transaction, ContextKey(expansion.Game), expansion.Key, expansion.Name);

        foreach (RecipeReagentSlot slot in dimensions.RecipeReagentSlots)
        {
            EnsureRecipe(slot.Game, slot.RecipeId, transaction);
            foreach (int candidateItemId in slot.CandidateItemIds ?? [])
                EnsureItem(slot.Game, candidateItemId, transaction);
            ExecuteNonQuery("""
                INSERT INTO RecipeReagent (
                    ContextKey, RecipeId, DataSlotTypeKey, DataSlotIndex, SlotIndex, ReagentType,
                    IsRequired, RequiredQuantity, CandidateItemIdsJson
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (ContextKey, RecipeId, DataSlotTypeKey, DataSlotIndex) DO UPDATE SET
                    SlotIndex = COALESCE(excluded.SlotIndex, RecipeReagent.SlotIndex),
                    ReagentType = COALESCE(excluded.ReagentType, RecipeReagent.ReagentType),
                    IsRequired = COALESCE(excluded.IsRequired, RecipeReagent.IsRequired),
                    RequiredQuantity = COALESCE(excluded.RequiredQuantity, RecipeReagent.RequiredQuantity),
                    CandidateItemIdsJson = COALESCE(excluded.CandidateItemIdsJson, RecipeReagent.CandidateItemIdsJson)
                """, transaction, ContextKey(slot.Game), slot.RecipeId,
                slot.DataSlotType is null ? UnknownDataSlotType : (int)slot.DataSlotType.Value + 1,
                slot.DataSlotIndex, slot.SlotIndex,
                slot.ReagentType is null ? null : (int)slot.ReagentType.Value,
                slot.IsRequired, slot.RequiredQuantity,
                slot.CandidateItemIds is null ? null : JsonSerializer.Serialize(
                    slot.CandidateItemIds.Order().ToArray(), JsonOptions));
        }
    }

    private long? ReadCraftKey(CraftIdentity identity, DbTransaction transaction)
    {
        object? value = ExecuteScalar("""
            SELECT CraftKey FROM CraftIdentity
            WHERE IdentityOrigin = ? AND IdentityObservation = ?
            """, transaction, identity.Origin, identity.Observation);
        return value is null or DBNull ? null : Convert.ToInt64(value, CultureInfo.InvariantCulture);
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

    private void EnsureProfession(GameContext game, int professionId, DbTransaction transaction)
    {
        ExecuteNonQuery("""
            INSERT INTO Profession (ContextKey, ProfessionId)
            VALUES (?, ?)
            ON CONFLICT DO NOTHING
            """, transaction, ContextKey(game), professionId);
    }

    private void EnsureItem(GameContext game, int itemId, DbTransaction transaction)
    {
        ExecuteNonQuery("""
            INSERT INTO Item (ContextKey, ItemId)
            VALUES (?, ?)
            ON CONFLICT DO NOTHING
            """, transaction, ContextKey(game), itemId);
    }

    private void EnsureExpansion(GameContext game, string expansionKey, DbTransaction transaction)
    {
        ExecuteNonQuery("""
            INSERT INTO Expansion (ContextKey, ExpansionKey)
            VALUES (?, ?)
            ON CONFLICT DO NOTHING
            """, transaction, ContextKey(game), expansionKey);
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

    private object? ExecuteScalar(string sql)
    {
        using DuckDBCommand command = _connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar();
    }

    private object? ExecuteScalar(string sql, DbTransaction transaction, params object?[] values)
    {
        using DuckDBCommand command = CreateCommand(sql, transaction);
        AddParameters(command, values);
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

    private static T? NullableEnum<T>(DbDataReader reader, int ordinal) where T : struct, Enum =>
        reader.IsDBNull(ordinal) ? null : EnumValue<T>(
            Convert.ToInt32(reader.GetValue(ordinal), CultureInfo.InvariantCulture), typeof(T).Name);

    private static T EnumValue<T>(int value, string field) where T : struct, Enum
    {
        T enumValue = (T)Enum.ToObject(typeof(T), value);
        return Enum.IsDefined(enumValue)
            ? enumValue
            : throw new InvalidDataException($"Stored recipe reagent {field} '{value}' is not supported.");
    }

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(_disposed, this);

    private sealed record ContextIdentity(int ProjectId, string? ProgressionTrack);
}
