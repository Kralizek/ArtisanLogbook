using System.Collections;
using System.Data.Common;
using System.Diagnostics;

using ArtisanLogbook.History;

using DuckDB.NET.Data;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.HistoryStore;

[TestFixture]
public sealed class HistoryStorePerformanceTests
{
    [Test, Explicit("Manual real-DuckDB comparison; timings are not CI assertions.")]
    public async Task MeasureHistoryWorkloads()
    {
        string directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Performance", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            string path = Path.Combine(directory, "history.duckdb");
            using Store store = new(path);
            CraftObservation[] crafts = Enumerable.Range(0, 1000).Select(Observation).ToArray();
            Measure("seed 1000 crafts", () => Assert.That(
                store.WriteBatch(new(crafts, CraftDimensions.Empty)).IsSuccessful, Is.True));
            for (int i = 0; i < 10; i++) store.Read(crafts[i].Identity);
            Measure("100 single reads", () =>
            {
                for (int i = 0; i < 100; i++)
                    Assert.That(store.Read(crafts[i].Identity), Is.EqualTo(crafts[i]));
            });
            Stopwatch parallel = Stopwatch.StartNew();
            await Task.WhenAll(Enumerable.Range(0, 4).Select(worker => Task.Run(() =>
            {
                for (int i = 0; i < 100; i++)
                    Assert.That(store.Read(crafts[(i + worker) % crafts.Length].Identity),
                        Is.EqualTo(crafts[(i + worker) % crafts.Length]));
            })));
            Report("4 x 100 reads", parallel.Elapsed);
            Measure("ReadAll 1000 crafts", () => Assert.That(store.ReadAll(), Has.Count.EqualTo(1000)));

            using DuckDBConnection reused = new($"Data Source={path}");
            reused.Open();
            Measure("500 open/select/dispose", () =>
            {
                for (int i = 0; i < 500; i++)
                {
                    using DuckDBConnection connection = new($"Data Source={path}");
                    connection.Open();
                    SelectCount(connection);
                }
            });
            Measure("500 reused selects", () =>
            {
                for (int i = 0; i < 500; i++) SelectCount(reused);
            });
            Measure("batch 100 crafts", () => Assert.That(store.WriteBatch(new(
                Enumerable.Range(1000, 100).Select(Observation).ToArray(), CraftDimensions.Empty)).IsSuccessful, Is.True));

            using ManualResetEventSlim writing = new();
            using ManualResetEventSlim release = new();
            Task import = Task.Run(() => store.WriteBatch(new(
                new PausedImport([Observation(1100), Observation(1101)], () =>
                {
                    writing.Set();
                    if (!release.Wait(TimeSpan.FromSeconds(30))) throw new TimeoutException("Import not released.");
                }), CraftDimensions.Empty)));
            Assert.That(writing.Wait(TimeSpan.FromSeconds(30)), Is.True);
            using ManualResetEventSlim reading = new();
            Stopwatch during = Stopwatch.StartNew();
            Task read = Task.Run(() =>
            {
                reading.Set();
                Assert.That(store.Read(crafts[0].Identity), Is.EqualTo(crafts[0]));
            });
            try
            {
                Assert.That(reading.Wait(TimeSpan.FromSeconds(30)), Is.True);
                // This benchmark deliberately includes a known writer hold, not a concurrency correctness assertion.
                await Task.WhenAny(read, Task.Delay(250));
            }
            finally
            {
                release.Set();
            }
            await read.WaitAsync(TimeSpan.FromSeconds(30));
            Report("read during import (writer held up to 250ms)", during.Elapsed);
            await import.WaitAsync(TimeSpan.FromSeconds(30));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    internal static CraftObservation Observation(int id) => new(
        new("performance", id.ToString(System.Globalization.CultureInfo.InvariantCulture)),
        new(GameProject.Retail), DateTimeOffset.UnixEpoch.AddSeconds(id), 123,
        new("project:1:region:3:realm:1309:guid:Player-1234"),
        Reagents: [new(100, 4, 0.5m), new(101, 2, 0)],
        Outputs: [new(200, 1, 2), new(201, 2, 1)],
        Provenance: new("benchmark", GameOperationId: id));

    private static void SelectCount(DuckDBConnection connection)
    {
        using DbCommand command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM Craft";
        Assert.That(Convert.ToInt64(command.ExecuteScalar()), Is.EqualTo(1000));
    }

    private static void Measure(string name, Action action)
    {
        Stopwatch watch = Stopwatch.StartNew();
        action();
        Report(name, watch.Elapsed);
    }

    private static void Report(string name, TimeSpan elapsed) =>
        TestContext.Progress.WriteLine($"{name}: {elapsed.TotalMilliseconds:F3} ms");

    internal sealed class PausedImport(CraftObservation[] crafts, Action pause) : IReadOnlyList<CraftObservation>
    {
        private int _enumerations;
        public int Count => crafts.Length;
        public CraftObservation this[int index] => crafts[index];

        public IEnumerator<CraftObservation> GetEnumerator()
        {
            bool writing = Interlocked.Increment(ref _enumerations) == 2;
            for (int i = 0; i < crafts.Length; i++)
            {
                // Validation enumerates first; the second pass persists the batch.
                if (writing && i == 1) pause();
                yield return crafts[i];
            }
        }

        IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
    }
}
