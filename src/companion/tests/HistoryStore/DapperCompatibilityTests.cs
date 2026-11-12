using System.Data.Common;

using ArtisanLogbook.HistoryStore;

using Dapper;

using DuckDB.NET.Data;

using NUnit.Framework;

namespace Tests.HistoryStore;

[TestFixture]
public sealed class DapperCompatibilityTests
{
    [Test]
    public void NamedParametersAndTypedRowsRoundTripDuckDbValues()
    {
        using DuckDBConnection connection = new("Data Source=:memory:");
        connection.Open();
        using DbTransaction transaction = connection.BeginTransaction();
        var parameters = new
        {
            Id = 5_000_000_000L,
            Quantity = 123456789.123456m,
            Missing = (string?)null,
            Json = """{"evidence":[1,2]}""",
            Timestamp = new DateTime(2024, 3, 5, 6, 7, 8, DateTimeKind.Unspecified),
            Kind = SampleKind.Second
        };
        Row row = connection.QuerySingle<Row>("""
            SELECT CAST($Id AS BIGINT) AS Id, CAST($Quantity AS DECIMAL(20,6)) AS Quantity,
                CAST($Missing AS VARCHAR) AS Missing, $Json AS Json,
                CAST($Timestamp AS TIMESTAMP) AS Timestamp, CAST($Kind AS INTEGER) AS Kind
            """, parameters, transaction);
        Assert.Multiple(() =>
        {
            Assert.That(row.Id, Is.EqualTo(parameters.Id));
            Assert.That(row.Quantity, Is.EqualTo(parameters.Quantity));
            Assert.That(row.Missing, Is.Null);
            Assert.That(row.Json, Is.EqualTo(parameters.Json));
            Assert.That(row.Timestamp, Is.EqualTo(parameters.Timestamp));
            Assert.That(row.Kind, Is.EqualTo(parameters.Kind));
        });

        DynamicParameters dynamicParameters = new();
        dynamicParameters.Add("value", (long?)null);
        Assert.That(connection.QuerySingle<long?>("SELECT CAST($value AS BIGINT)", dynamicParameters, transaction), Is.Null);
    }

    [Test]
    public void DapperCommandsParticipateInExplicitTransactionsAndListLookup()
    {
        using DuckDBConnection connection = new("Data Source=:memory:");
        connection.Open();
        connection.Execute("CREATE TABLE sample (id BIGINT)");
        using (DbTransaction transaction = connection.BeginTransaction())
        {
            connection.Execute("INSERT INTO sample VALUES ($id)", new { id = 5_000_000_000L }, transaction);
            Assert.That(connection.Query<long>("SELECT id FROM sample WHERE id IN $ids",
                new { ids = new long[] { 1, 5_000_000_000L } }, transaction), Is.EqualTo(new[] { 5_000_000_000L }));
            transaction.Rollback();
        }
        Assert.That(connection.ExecuteScalar<long>("SELECT COUNT(*) FROM sample"), Is.Zero);
    }

    [Test]
    public async Task NativeInterruptionCancelsAnExecutingDapperQuery()
    {
        using DuckDBConnection connection = new("Data Source=:memory:");
        connection.Open();
        using ManualResetEventSlim executing = new();
        using CancellationTokenSource cancellation = new();
        connection.RegisterScalarFunction<long, long>("execution_signal", value =>
        {
            executing.Set();
            return value;
        });
        using DbTransaction transaction = connection.BeginTransaction();
        using (new ReadInterruption(connection, cancellation.Token))
        {
            Task query = Task.Run(() => connection.QuerySingle<double>(
                "SELECT SUM(sin(execution_signal(i))) FROM range(1000000000000) t(i)",
                transaction: transaction));
            try
            {
                Assert.That(executing.Wait(TimeSpan.FromSeconds(20)), Is.True);
            }
            finally
            {
                await cancellation.CancelAsync();
            }
            Assert.ThrowsAsync<OperationCanceledException>(async () => await query.WaitAsync(TimeSpan.FromSeconds(20)));
        }
        transaction.Rollback();
        Assert.That(connection.ExecuteScalar<int>("SELECT 1"), Is.EqualTo(1));
    }

    private enum SampleKind { First, Second }

    private sealed class Row
    {
        public long Id { get; set; }
        public decimal Quantity { get; set; }
        public string? Missing { get; set; }
        public string Json { get; set; } = "";
        public DateTime Timestamp { get; set; }
        public SampleKind Kind { get; set; }
    }
}
