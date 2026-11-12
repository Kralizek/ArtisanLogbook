using System.Data.Common;
using System.Diagnostics;

using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;

using DuckDB.NET.Data;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.HistoryStore;

[TestFixture]
public sealed class HistoryStoreCancellationTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(20);
    private string _directory = null!;
    private string _path = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Cancellation", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _path = Path.Combine(_directory, "history.duckdb");
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [Test]
    public void PreCancelledReadsNeverEnterConnectionAdmission()
    {
        using CancellationTokenSource cancellation = new();
        cancellation.Cancel();
        using Store store = new(_path)
        {
            ReadCheckpoint = _ => Assert.Fail("Cancelled operation must not be admitted.")
        };
        Assert.Throws<OperationCanceledException>(() => store.Read(Observation.Identity, cancellation.Token));
        Assert.Throws<OperationCanceledException>(() => store.ReadAll(cancellation.Token));
        Assert.Throws<OperationCanceledException>(() => store.ReadDimensions(cancellation.Token));
        Assert.Throws<OperationCanceledException>(() => store.ReadStatus(cancellation.Token));
        Assert.Throws<OperationCanceledException>(() => store.GetSchemaVersion(cancellation.Token));
    }

    [Test]
    public async Task CompletedReadRemovesRegistrationsBeforeConnectionAndStoreDisposal()
    {
        using CancellationTokenSource cancellation = new();
        Store store = new(_path);
        Assert.That(store.Write(Observation).IsSuccessful, Is.True);
        Assert.That(store.Read(Observation.Identity, cancellation.Token), Is.EqualTo(Observation));
        store.Dispose();
        await cancellation.CancelAsync();
        AssertReleased();
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task UsingAndAwaitUsingReleaseTheDatabaseAndAllowRepeatedDisposal(bool asynchronous)
    {
        Store store;
        if (asynchronous)
        {
            await using (store = new(_path))
                Assert.That(store.Write(Observation).IsSuccessful, Is.True);
        }
        else
        {
            using (store = new(_path))
                Assert.That(store.Write(Observation).IsSuccessful, Is.True);
        }
        AssertReleased();
        await using Store reopened = new(_path);
        await store.DisposeAsync();
        store.Dispose();
        Assert.That(reopened.Read(Observation.Identity), Is.EqualTo(Observation));
    }

    [Test]
    public async Task ConcurrentMixedDisposalsWaitWithoutBlockingAndReleaseTheDatabase()
    {
        using ManualResetEventSlim entered = new();
        using ManualResetEventSlim release = new();
        Store store = new(_path)
        {
            ReadCheckpoint = boundary =>
            {
                if (boundary != "Craft") return;
                entered.Set();
                Wait(release);
            }
        };
        Assert.That(store.Write(Observation).IsSuccessful, Is.True);
        Task read = Task.Run(() => store.Read(Observation.Identity));
        Task[] disposing = [];
        try
        {
            Wait(entered);
            disposing = [store.DisposeAsync().AsTask(), store.DisposeAsync().AsTask(), Task.Run(store.Dispose)];
            Assert.That(disposing, Has.All.Property(nameof(Task.IsCompleted)).False);
            Assert.Throws<ObjectDisposedException>(() => store.ReadStatus());
            Assert.Throws<ObjectDisposedException>(() => store.Write(Observation));
        }
        finally
        {
            release.Set();
            Assert.ThrowsAsync<OperationCanceledException>(async () => await read.WaitAsync(Timeout));
            await Task.WhenAll(disposing).WaitAsync(Timeout);
            await store.DisposeAsync();
        }
        AssertReleased();
    }

    [TestCase("Admission")]
    [TestCase("Craft")]
    [TestCase("Identities")]
    [TestCase("Contexts")]
    [TestCase("Counts")]
    public async Task CancellationAtReadBoundariesReleasesResourcesAndAllowsRecovery(string boundary)
    {
        using CancellationTokenSource cancellation = new();
        using ManualResetEventSlim entered = new();
        using ManualResetEventSlim release = new();
        int paused = 0;
        using Store store = new(_path)
        {
            ReadCheckpoint = name =>
            {
                if (name != boundary || Interlocked.Exchange(ref paused, 1) != 0) return;
                entered.Set();
                Wait(release);
            }
        };
        Assert.That(store.Write(Observation).IsSuccessful, Is.True);
        Task read = Task.Run(() =>
        {
            switch (boundary)
            {
                case "Admission": _ = store.GetSchemaVersion(cancellation.Token); break;
                case "Craft": _ = store.Read(Observation.Identity, cancellation.Token); break;
                case "Identities": _ = store.ReadAll(cancellation.Token); break;
                case "Contexts": _ = store.ReadDimensions(cancellation.Token); break;
                case "Counts": _ = store.ReadStatus(cancellation.Token); break;
            }
        });
        try
        {
            Wait(entered);
            await cancellation.CancelAsync();
            Assert.That(store.Read(Observation.Identity), Is.EqualTo(Observation));
            Assert.That(store.Write(HistoryStorePerformanceTests.Observation(1)).IsSuccessful, Is.True);
        }
        finally
        {
            release.Set();
        }
        Assert.ThrowsAsync<OperationCanceledException>(async () => await read.WaitAsync(Timeout));
        Assert.That(store.Read(Observation.Identity), Is.EqualTo(Observation));
        store.Dispose();
        AssertReleased();
    }

    [Test]
    public void CancellationDuringDimensionMaterializationStopsTheRead()
    {
        using CancellationTokenSource cancellation = new();
        using Store store = new(_path)
        {
            ReadCheckpoint = boundary =>
            {
                if (boundary == "CharacterRow") cancellation.Cancel();
            }
        };
        Assert.That(store.Write(Observation).IsSuccessful, Is.True);
        Assert.Throws<OperationCanceledException>(() => store.ReadDimensions(cancellation.Token));
        Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(1));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task ProviderCancelInterruptsExecutingSqlAndConnectionCanBeReused(bool streaming)
    {
        using Store store = new(_path);
        Assert.That(store.Write(Observation).IsSuccessful, Is.True);
        using DuckDBConnection connection = Open();
        using ManualResetEventSlim executing = new();
        connection.RegisterScalarFunction<long, long>("execution_signal", value =>
        {
            executing.Set();
            return value;
        });
        using DbTransaction transaction = connection.BeginTransaction();
        using DuckDBCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.UseStreamingMode = streaming;
        command.CommandText = streaming
            ? "SELECT execution_signal(i) FROM range(1000000000000) t(i)"
            : "SELECT SUM(sin(execution_signal(i))) FROM range(1000000000000) t(i)";
        Task query = Task.Run(() =>
        {
            using DbDataReader reader = command.ExecuteReader();
            while (reader.Read()) _ = reader.GetValue(0);
        });
        try
        {
            Wait(executing); // Signaled inside the actual SQL function, not by a task about to execute.
            Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(1));
        }
        finally
        {
            command.Cancel();
            Assert.ThrowsAsync<OperationCanceledException>(async () => await query.WaitAsync(Timeout));
        }
        transaction.Rollback();
        using DbCommand recovered = connection.CreateCommand();
        recovered.CommandText = "SELECT COUNT(*) FROM Craft";
        Assert.That(Convert.ToInt64(recovered.ExecuteScalar()), Is.EqualTo(1));
        TestContext.Progress.WriteLine($"Native version: {connection.ServerVersion}; interrupted streaming={streaming}");
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task PublicReadInterruptsNativeSqlWithoutCancellingAnotherReaderOrWriter(bool shutdown)
    {
        using Store store = new(_path);
        Assert.That(store.Write(Observation).IsSuccessful, Is.True);
        using DuckDBConnection setup = Open();
        using ManualResetEventSlim executing = new();
        setup.RegisterScalarFunction<long, long>("execution_signal", value =>
        {
            executing.Set();
            return value;
        });
        Execute(setup, """
            ALTER TABLE Craft RENAME TO StoredCraft;
            CREATE VIEW Craft AS
            SELECT c.* FROM StoredCraft c
            CROSS JOIN (
                SELECT SUM(sin(execution_signal(i))) AS total FROM range(1000000000000) t(i)
            ) slow WHERE slow.total IS NOT NULL
            """);
        using CancellationTokenSource cancellation = new();
        Task read = Task.Run(() => store.ReadStatus(cancellation.Token));
        Task? stopping = null;
        try
        {
            Wait(executing);
            if (shutdown)
                stopping = store.DisposeAsync().AsTask();
            else
            {
                // These operations do not touch the deliberately slow test view.
                Assert.That(store.ReadDimensions().Characters, Has.Count.EqualTo(1));
                Assert.That(store.WriteDimensions(CraftDimensions.Empty).IsSuccessful, Is.True);
            }
        }
        finally
        {
            await cancellation.CancelAsync();
            Assert.ThrowsAsync<OperationCanceledException>(async () => await read.WaitAsync(Timeout));
            if (stopping is not null) await stopping.WaitAsync(Timeout);
            Execute(setup, "DROP VIEW Craft; ALTER TABLE StoredCraft RENAME TO Craft");
        }
        if (!shutdown)
        {
            Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(1));
            Assert.That(store.Write(HistoryStorePerformanceTests.Observation(1)).IsSuccessful, Is.True);
        }
    }

    [Test]
    public async Task InterruptRetryCoversCancellationImmediatelyBeforeQueryStartup()
    {
        using Store store = new(_path);
        using DuckDBConnection connection = Open();
        using CancellationTokenSource cancellation = new();
        cancellation.Cancel();
        using ReadInterruption interruption = new(connection, cancellation.Token);
        using DbCommand command = connection.CreateCommand();
        command.CommandText = "SELECT SUM(sin(i)) FROM range(1000000000000) t(i)";
        Task query = Task.Run(() => command.ExecuteScalar());
        Assert.ThrowsAsync<OperationCanceledException>(async () => await query.WaitAsync(Timeout));
    }

    [Test]
    public async Task NonCooperativeNativeCallbackCannotBeForceDisposedAtShutdownDeadline()
    {
        using ManualResetEventSlim executing = new();
        using ManualResetEventSlim release = new();
        Store store = new(_path, shutdownGracePeriod: TimeSpan.FromMilliseconds(100));
        Assert.That(store.Write(Observation).IsSuccessful, Is.True);
        using DuckDBConnection setup = Open();
        setup.RegisterScalarFunction<long, bool>("hold_native", (long _) =>
        {
            executing.Set();
            Wait(release);
            return true;
        });
        Execute(setup, """
            ALTER TABLE Craft RENAME TO StoredCraft;
            CREATE VIEW Craft AS SELECT c.* FROM StoredCraft c WHERE hold_native(c.CraftKey)
            """);
        Task read = Task.Run(() => store.ReadStatus());
        try
        {
            Wait(executing);
            Assert.ThrowsAsync<TimeoutException>(async () => await store.DisposeAsync());
            Assert.That(read.IsCompleted, Is.False, "Interrupt must not be mistaken for forced callback termination.");
            Assert.Throws<ObjectDisposedException>(() => store.ReadAll());
        }
        finally
        {
            release.Set();
            Assert.ThrowsAsync<OperationCanceledException>(async () => await read.WaitAsync(Timeout));
            await store.DisposeAsync();
            Execute(setup, "DROP VIEW Craft; ALTER TABLE StoredCraft RENAME TO Craft");
        }
        setup.Dispose();
        AssertReleased();
    }

    [Test]
    public async Task OnlyTheCancelledConcurrentReaderIsInterrupted()
    {
        using CountdownEvent entered = new(2);
        using ManualResetEventSlim release = new();
        using CancellationTokenSource cancellation = new();
        using Store store = new(_path)
        {
            ReadCheckpoint = boundary =>
            {
                if (boundary != "Craft") return;
                entered.Signal();
                Wait(release);
            }
        };
        Assert.That(store.Write(Observation).IsSuccessful, Is.True);
        Task<CraftObservation?> cancelled = Task.Run(() => store.Read(Observation.Identity, cancellation.Token));
        Task<CraftObservation?> other = Task.Run(() => store.Read(Observation.Identity));
        try
        {
            Assert.That(entered.Wait(Timeout), Is.True);
            await cancellation.CancelAsync();
            Assert.That(store.Write(HistoryStorePerformanceTests.Observation(1)).IsSuccessful, Is.True);
        }
        finally
        {
            release.Set();
        }
        Assert.ThrowsAsync<OperationCanceledException>(async () => await cancelled.WaitAsync(Timeout));
        Assert.That(await other.WaitAsync(Timeout), Is.EqualTo(Observation));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task NonresponsiveOperationTimesOutButRemainsOwnedUntilItUnwinds(bool writer)
    {
        using ManualResetEventSlim entered = new();
        using ManualResetEventSlim release = new();
        Store store = new(_path, shutdownGracePeriod: TimeSpan.FromMilliseconds(100))
        {
            ReadCheckpoint = boundary =>
            {
                if (boundary != "Craft") return;
                entered.Set();
                Wait(release);
            }
        };
        Assert.That(store.Write(Observation).IsSuccessful, Is.True);
        Task operation = writer
            ? Task.Run(() => store.WriteBatch(new(
                new HistoryStorePerformanceTests.PausedImport(
                    [HistoryStorePerformanceTests.Observation(1), HistoryStorePerformanceTests.Observation(2)],
                    () => { entered.Set(); Wait(release); }), CraftDimensions.Empty)))
            : Task.Run(() => store.Read(Observation.Identity));
        try
        {
            Wait(entered);
            Stopwatch elapsed = Stopwatch.StartNew();
            Assert.ThrowsAsync<TimeoutException>(async () => await store.DisposeAsync());
            Assert.That(elapsed.Elapsed, Is.LessThan(store.ShutdownGracePeriod + TimeSpan.FromSeconds(5)));
            Assert.That(elapsed.Elapsed, Is.GreaterThanOrEqualTo(store.ShutdownGracePeriod * 0.75));
            Assert.That(operation.IsCompleted, Is.False);
            Assert.Throws<ObjectDisposedException>(() => store.ReadStatus());
            Assert.Throws<ObjectDisposedException>(() => store.Write(Observation));
            using DuckDBConnection probe = Open(readOnly: true);
            using DbCommand command = probe.CreateCommand();
            command.CommandText = "SELECT current_setting('access_mode')";
            Assert.That(command.ExecuteScalar(), Is.EqualTo("automatic"), "Writer handle is still owned.");
        }
        finally
        {
            release.Set();
            Assert.ThrowsAsync<OperationCanceledException>(async () => await operation.WaitAsync(Timeout));
            Assert.That(SpinWait.SpinUntil(() =>
            {
                using DuckDBConnection probe = Open(readOnly: true);
                using DbCommand command = probe.CreateCommand();
                command.CommandText = "SELECT current_setting('access_mode')";
                return Equals(command.ExecuteScalar(), "read_only");
            }, Timeout), Is.True, "Cleanup must release the writer without another disposal trigger.");
            await store.DisposeAsync();
            store.Dispose();
        }
        AssertReleased();
        using Store reopened = new(_path);
        Assert.That(reopened.ReadAll(), Is.EqualTo(new[] { Observation }));
    }

    private DuckDBConnection Open(bool readOnly = false)
    {
        DbConnectionStringBuilder builder = new() { ["Data Source"] = _path };
        if (readOnly) builder["access_mode"] = "READ_ONLY";
        DuckDBConnection connection = new(builder.ConnectionString);
        connection.Open();
        return connection;
    }

    private void AssertReleased()
    {
        using DuckDBConnection connection = Open(readOnly: true);
        using DbCommand command = connection.CreateCommand();
        command.CommandText = "SELECT current_setting('access_mode')";
        Assert.That(command.ExecuteScalar(), Is.EqualTo("read_only"));
    }

    private static void Execute(DuckDBConnection connection, string sql)
    {
        using DbCommand command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private static CraftObservation Observation => HistoryStorePerformanceTests.Observation(0);

    private static void Wait(ManualResetEventSlim signal)
    {
        if (!signal.Wait(Timeout)) throw new TimeoutException("Test operation was not released.");
    }
}
