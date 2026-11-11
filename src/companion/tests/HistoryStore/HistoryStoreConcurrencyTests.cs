using System.Data.Common;

using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;

using DuckDB.NET.Data;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.HistoryStore;

[TestFixture]
public sealed class HistoryStoreConcurrencyTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);
    private string _directory = null!;
    private string _path = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Concurrency", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _path = Path.Combine(_directory, "history.duckdb");
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [Test]
    public async Task SameAndDifferentCraftsHaveSimultaneousIndependentReaders()
    {
        using CountdownEvent entered = new(4);
        using ManualResetEventSlim release = new();
        using Store store = new(_path)
        {
            ReadCheckpoint = checkpoint =>
            {
                if (checkpoint != "Craft") return;
                entered.Signal();
                Wait(release);
            }
        };
        CraftObservation[] crafts = [Observation(0), Observation(1)];
        Assert.That(store.WriteBatch(new(crafts, CraftDimensions.Empty)).IsSuccessful, Is.True);
        Task<CraftObservation?>[] reads = Enumerable.Range(0, 4)
            .Select(i => Task.Run(() => store.Read(crafts[i % 2].Identity))).ToArray();
        try
        {
            Assert.That(entered.Wait(Timeout), Is.True, "All readers must enter before any is released.");
        }
        finally
        {
            release.Set();
            await Task.WhenAll(reads).WaitAsync(Timeout);
        }
        for (int i = 0; i < reads.Length; i++)
            Assert.That(reads[i].Result, Is.EqualTo(crafts[i % 2]));
    }

    [TestCase("commit")]
    [TestCase("conflict")]
    [TestCase("cancel")]
    [TestCase("failure")]
    [TestCase("database")]
    public async Task ReadsCompleteDuringUncommittedBatchAndOnlySeeCommittedData(string outcome)
    {
        using Store store = new(_path);
        CraftObservation committed = Observation(0);
        CraftObservation pending = outcome == "database"
            ? Observation(1) with { Outputs = [new(200, 1, 12), new(201, 2, 11)] }
            : Observation(1);
        Assert.That(store.Write(committed).IsSuccessful, Is.True);
        if (outcome == "database")
        {
            using DuckDBConnection connection = Open(readOnly: false);
            using DbCommand command = connection.CreateCommand();
            command.CommandText = "CREATE UNIQUE INDEX FailBatch ON CraftOutput(ItemId, Quantity)";
            command.ExecuteNonQuery();
        }
        using CancellationTokenSource cancellation = new();
        using ManualResetEventSlim writing = new();
        using ManualResetEventSlim release = new();
        CraftObservation last = outcome == "conflict"
            ? committed with { RecipeId = 999 }
            : Observation(2);
        Task<CraftHistoryBatchWriteResult> import = Task.Run(() => store.WriteBatch(new(
            new HistoryStorePerformanceTests.PausedImport([pending, last], () =>
            {
                writing.Set();
                Wait(release);
                if (outcome == "cancel") cancellation.Cancel();
                if (outcome == "failure") throw new IOException("Controlled import failure.");
            }), CraftDimensions.Empty), cancellation.Token));
        try
        {
            Wait(writing);
            await Task.WhenAll(
                Task.Run(() => Assert.That(store.Read(committed.Identity), Is.EqualTo(committed))),
                Task.Run(() => Assert.That(store.Read(pending.Identity), Is.Null)),
                Task.Run(() => Assert.That(store.ReadAll(), Is.EqualTo(new[] { committed }))),
                Task.Run(() => Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(1))),
                Task.Run(() => Assert.That(store.ReadDimensions().Items, Has.Count.EqualTo(4))))
                .WaitAsync(Timeout);
            Assert.That(import.IsCompleted, Is.False, "Reads must not require the writer to finish.");
        }
        finally
        {
            release.Set();
            if (outcome == "cancel")
                Assert.ThrowsAsync<OperationCanceledException>(async () => await import.WaitAsync(Timeout));
            else if (outcome == "failure")
                Assert.ThrowsAsync<IOException>(async () => await import.WaitAsync(Timeout));
            else if (outcome == "database")
                Assert.ThrowsAsync<DuckDBException>(async () => await import.WaitAsync(Timeout));
            else
                await import.WaitAsync(Timeout);
        }

        if (outcome == "commit")
        {
            Assert.That(import.Result.IsSuccessful, Is.True);
            Assert.That(store.Read(pending.Identity), Is.EqualTo(pending));
            Assert.That(store.ReadAll(), Has.Count.EqualTo(3));
        }
        else
        {
            Assert.That(store.Read(pending.Identity), Is.Null);
            Assert.That(store.ReadAll(), Is.EqualTo(new[] { committed }));
        }
        Assert.That(store.Write(Observation(3) with { Outputs = null }).IsSuccessful, Is.True,
            "Writer must remain usable.");
    }

    [Test]
    public Task CraftMaterializationRetainsSnapshotAcrossConcurrentEnrichment() =>
        AcrossCommit("Craft", store => store.Read(Observation(0).Identity),
            result => Assert.That(result, Is.EqualTo(Partial())));

    [Test]
    public Task ReadAllUsesOneSnapshotForIdentitiesAndEveryCraft() =>
        AcrossCommit("Identities", store => store.ReadAll(),
            result => Assert.That(result, Is.EqualTo(new[] { Partial() })));

    [Test]
    public Task DimensionsUseOneSnapshotForContextsAndRelatedRows() =>
        AcrossCommit("Contexts", store => store.ReadDimensions(), result =>
        {
            Assert.That(result.Characters.Select(x => x.Game), Is.EqualTo(new[] { Partial().Game }));
            Assert.That(result.Items.Select(x => x.Id), Is.EquivalentTo(new[] { 100, 101, 200, 201 }));
        });

    [Test]
    public Task StatusCountsAndContextCountsShareOneSnapshot() =>
        AcrossCommit("Counts", store => store.ReadStatus(), result =>
        {
            Assert.That(result.TotalCraftCount, Is.EqualTo(1));
            Assert.That(result.Contexts.Sum(x => x.CraftCount), Is.EqualTo(result.TotalCraftCount));
        });

    [Test]
    public async Task DisposeDrainsActiveReadRejectsNewWorkAndReleasesFile()
    {
        using ManualResetEventSlim entered = new();
        using ManualResetEventSlim release = new();
        Store store = new(_path)
        {
            ReadCheckpoint = checkpoint =>
            {
                if (checkpoint != "Craft") return;
                entered.Set();
                Wait(release);
            }
        };
        Assert.That(store.Write(Observation(0)).IsSuccessful, Is.True);
        Task<CraftObservation?> read = Task.Run(() => store.Read(Observation(0).Identity));
        Task? dispose = null;
        try
        {
            Wait(entered);
            dispose = Task.Run(store.Dispose);
            Assert.That(SpinWait.SpinUntil(() =>
            {
                try { _ = store.SchemaVersion; return false; }
                catch (ObjectDisposedException) { return true; }
            }, Timeout), Is.True);
            Assert.That(dispose.IsCompleted, Is.False);
            Assert.Throws<ObjectDisposedException>(() => store.Write(Observation(1)));
        }
        finally
        {
            release.Set();
            await read.WaitAsync(Timeout);
            if (dispose is not null) await dispose.WaitAsync(Timeout);
            store.Dispose();
        }
        Assert.That(read.Result, Is.EqualTo(Observation(0)));
        AssertReleased();
        using Store reopened = new(_path);
        Assert.That(reopened.ReadAll(), Has.Count.EqualTo(1));
    }

    [Test]
    public async Task DisposeWaitsForActiveWriterWithoutInterruptingItsTransaction()
    {
        Store store = new(_path);
        using ManualResetEventSlim writing = new();
        using ManualResetEventSlim release = new();
        using ManualResetEventSlim disposing = new();
        Task<CraftHistoryBatchWriteResult> import = Task.Run(() => store.WriteBatch(new(
            new HistoryStorePerformanceTests.PausedImport([Observation(0), Observation(1)], () =>
            {
                writing.Set();
                Wait(release);
            }), CraftDimensions.Empty)));
        Task? dispose = null;
        try
        {
            Wait(writing);
            dispose = Task.Run(() =>
            {
                disposing.Set();
                store.Dispose();
            });
            Wait(disposing);
            Assert.That(store.ReadAll(), Is.Empty);
            Assert.That(dispose.IsCompleted, Is.False);
        }
        finally
        {
            release.Set();
            await import.WaitAsync(Timeout);
            if (dispose is not null) await dispose.WaitAsync(Timeout);
            store.Dispose();
        }
        using Store reopened = new(_path);
        Assert.That(reopened.ReadAll(), Has.Count.EqualTo(2));
    }

    [Test]
    public void FailedReadRollsBackReleasesAdmissionAndAllowsShutdown()
    {
        using Store store = new(_path)
        {
            ReadCheckpoint = checkpoint =>
            {
                if (checkpoint == "Craft") throw new IOException("Controlled materialization failure.");
            }
        };
        Assert.That(store.Write(Observation(0)).IsSuccessful, Is.True);
        Assert.Throws<IOException>(() => store.Read(Observation(0).Identity));
        Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(1));
        Assert.That(store.Write(Observation(1)).IsSuccessful, Is.True);
        store.Dispose();
        Assert.Throws<ObjectDisposedException>(() => store.ReadAll());
        Assert.Throws<ObjectDisposedException>(() => store.ReadDimensions());
        Assert.Throws<ObjectDisposedException>(() => store.ReadStatus());
        Assert.Throws<ObjectDisposedException>(() => _ = store.SchemaVersion);
        Assert.Throws<ObjectDisposedException>(() => store.WriteBatch(new([], CraftDimensions.Empty)));
        Assert.Throws<ObjectDisposedException>(() => store.WriteDimensions(CraftDimensions.Empty));
        AssertReleased();
    }

    [Test]
    public async Task BoundedReadersAndSerializedWritersPreserveCanonicalHistory()
    {
        using Store store = new(_path);
        CraftObservation[] crafts = Enumerable.Range(0, 40).Select(Observation).ToArray();
        Assert.That(store.WriteBatch(new(crafts[..10], CraftDimensions.Empty)).IsSuccessful, Is.True);
        using Barrier start = new(6);
        Task[] writers = Enumerable.Range(0, 2).Select(_ => Task.Run(() =>
        {
            Assert.That(start.SignalAndWait(Timeout), Is.True);
            foreach (CraftObservation[] batch in crafts.Chunk(5))
                Assert.That(store.WriteBatch(new(batch, CraftDimensions.Empty)).IsSuccessful, Is.True);
        })).ToArray();
        Task[] readers = Enumerable.Range(0, 4).Select(worker => Task.Run(() =>
        {
            Assert.That(start.SignalAndWait(Timeout), Is.True);
            for (int i = 0; i < 15; i++)
            {
                CraftObservation expected = crafts[(worker + i) % 10];
                Assert.That(store.Read(expected.Identity), Is.EqualTo(expected));
                IReadOnlyList<CraftObservation> snapshot = store.ReadAll();
                Assert.That(snapshot.Select(x => x.Identity).Distinct().Count(), Is.EqualTo(snapshot.Count));
                foreach (CraftObservation observation in snapshot)
                    Assert.That(observation, Is.EqualTo(crafts.Single(x => x.Identity == observation.Identity)));
                HistoryStoreStatus status = store.ReadStatus();
                Assert.That(status.Contexts.Sum(x => x.CraftCount), Is.EqualTo(status.TotalCraftCount));
            }
        })).ToArray();
        await Task.WhenAll(writers.Concat(readers)).WaitAsync(TimeSpan.FromSeconds(90));
        Assert.That(store.ReadAll(), Is.EquivalentTo(crafts));
        store.Dispose();
        AssertReleased();
        using Store reopened = new(_path);
        Assert.That(reopened.ReadAll(), Is.EquivalentTo(crafts));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void ProviderCachesDatabaseAccessModeFromFirstOpener(bool readOnlyFirst)
    {
        using (Store initialized = new(_path))
            Assert.That(initialized.Write(Observation(0)).IsSuccessful, Is.True);
        using DuckDBConnection first = Open(readOnlyFirst);
        using DuckDBConnection second = Open(!readOnlyFirst);
        using DbCommand command = second.CreateCommand();
        command.CommandText = "SELECT current_setting('access_mode')";
        Assert.That(command.ExecuteScalar(), Is.EqualTo(readOnlyFirst ? "read_only" : "automatic"));
        command.CommandText = "CREATE TABLE AccessModeProbe (Id INTEGER)";
        if (readOnlyFirst)
            Assert.Throws<DuckDBException>(() => command.ExecuteNonQuery());
        else
            Assert.DoesNotThrow(() => command.ExecuteNonQuery());
    }

    [Test]
    public void ReadOnlyStoreRejectsWritesEvenWhenProviderSharesReadWriteDatabase()
    {
        using Store writer = new(_path);
        Assert.That(writer.Write(Observation(0)).IsSuccessful, Is.True);
        using Store reader = new(_path, readOnly: true);
        Assert.That(reader.ReadAll(), Has.Count.EqualTo(1));
        Assert.Throws<InvalidOperationException>(() => reader.Write(Observation(1)));
        Assert.Throws<InvalidOperationException>(() => reader.WriteBatch(new([Observation(1)], CraftDimensions.Empty)));
        Assert.Throws<InvalidOperationException>(() => reader.WriteDimensions(CraftDimensions.Empty));
    }

    [Test]
    public void FailedConnectionOpenIsReportedAndSamePathCanBeOpenedAfterRepair()
    {
        Directory.CreateDirectory(_path);
        Assert.Throws<DuckDBException>(() => new Store(_path));
        Directory.Delete(_path);
        using Store store = new(_path);
        Assert.That(store.Write(Observation(0)).IsSuccessful, Is.True);
        Assert.That(store.Read(Observation(0).Identity), Is.EqualTo(Observation(0)));
    }

    private async Task AcrossCommit<T>(string checkpoint, Func<Store, T> read, Action<T> verify)
    {
        using ManualResetEventSlim entered = new();
        using ManualResetEventSlim release = new();
        int paused = 0;
        using Store store = new(_path)
        {
            ReadCheckpoint = name =>
            {
                if (name != checkpoint || Interlocked.Exchange(ref paused, 1) != 0) return;
                entered.Set();
                Wait(release);
            }
        };
        Assert.That(store.Write(Partial()).IsSuccessful, Is.True);
        Task<T> snapshot = Task.Run(() => read(store));
        try
        {
            Wait(entered);
            CraftObservation additional = Observation(1) with { Game = new(GameProject.Forever, "progression") };
            CraftHistoryBatchWriteResult result = await Task.Run(() => store.WriteBatch(
                new([Observation(0), additional], CraftDimensions.Empty))).WaitAsync(Timeout);
            Assert.That(result.IsSuccessful, Is.True,
                string.Join("; ", result.ValidationErrors.Cast<object>().Concat(result.CraftConflicts)
                    .Concat(result.DimensionConflicts)));
        }
        finally
        {
            release.Set();
            await snapshot.WaitAsync(Timeout);
        }
        verify(snapshot.Result);
        Assert.That(store.Read(Observation(0).Identity), Is.EqualTo(Observation(0)));
        Assert.That(store.ReadAll(), Has.Count.EqualTo(2));
        Assert.That(store.ReadDimensions().Characters, Has.Count.EqualTo(2));
    }

    private DuckDBConnection Open(bool readOnly)
    {
        DbConnectionStringBuilder builder = new() { ["Data Source"] = _path };
        if (readOnly) builder["access_mode"] = "READ_ONLY";
        DuckDBConnection connection = new(builder.ConnectionString);
        try
        {
            connection.Open();
            return connection;
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    private void AssertReleased()
    {
        // A leaked connection would keep the provider's original read-write database handle cached.
        using DuckDBConnection connection = Open(readOnly: true);
        using DbCommand command = connection.CreateCommand();
        command.CommandText = "SELECT current_setting('access_mode')";
        Assert.That(command.ExecuteScalar(), Is.EqualTo("read_only"));
    }

    private static CraftObservation Observation(int id) => HistoryStorePerformanceTests.Observation(id);

    private static CraftObservation Partial() => Observation(0) with
    {
        Reagents = [new(100, 4, null), new(101, 2, null)],
        Outputs = [new(200, 1, null), new(201, 2, null)]
    };

    private static void Wait(ManualResetEventSlim signal)
    {
        if (!signal.Wait(Timeout)) throw new TimeoutException("Concurrency checkpoint was not released.");
    }
}
