using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Reflection;

using ArtisanLogbook.Cli;
using ArtisanLogbook.History;
using ArtisanLogbook.ImportService;
using ArtisanLogbook.Runtime;
using ArtisanLogbook.SavedVariables;

using DuckDB.NET.Data;

using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.Cli;

[TestFixture]
public sealed class CompanionHostingTests
{
    private string _directory = null!;
    private ApplicationPaths _paths = null!;
    private CompanionSettingsStore _settings = null!;
    private string _database = null!;
    private List<string> _runtimeLogs = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Host.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _paths = new(CompanionPlatform.Linux, _directory, _directory, null, _directory);
        _settings = new(_paths);
        _database = _paths.ResolveDatabase(null);
        _runtimeLogs = [];
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [TestCase(null)]
    [TestCase(false)]
    [TestCase(true)]
    public async Task EmptyHistoryStartsWithoutAvailableSourcesOrAutomaticImports(bool? monitoring)
    {
        Directory.CreateDirectory(_paths.DataDirectory);
        string preference = monitoring is null ? "" : $$""","monitoring":{"enabled":{{monitoring.Value.ToString().ToLowerInvariant()}}}""";
        await File.WriteAllTextAsync(_settings.FilePath,
            $$"""{"version":1,"installationRoots":["{{Path.Combine(_directory, "offline").Replace("\\", "\\\\")}}"]{{preference}}}""");
        byte[] before = await File.ReadAllBytesAsync(_settings.FilePath);
        Store store;
        CompanionApplicationStatus status;
        await using (WebApplication app = Build())
        {
            status = app.Services.GetRequiredService<CompanionApplicationStatus>();
            Assert.That(status.Read().LifecycleState, Is.EqualTo(CompanionLifecycleState.Created));
            Assert.That(File.Exists(_database), Is.False);
            await app.StartAsync();
            store = app.Services.GetRequiredService<Store>();
            CompanionStatus running = status.Read();
            Assert.Multiple(() =>
            {
                Assert.That(running.ApplicationVersion, Is.EqualTo("0.1.0"));
                Assert.That(running.StartupTime, Is.Not.Null);
                Assert.That(running.LifecycleState, Is.EqualTo(CompanionLifecycleState.Running));
                Assert.That(running.DatabaseAvailable, Is.True);
                Assert.That(running.DatabaseSchemaVersion, Is.EqualTo(store.SchemaVersion));
                Assert.That(running.CanonicalCraftCount, Is.Zero);
                Assert.That(running.Configuration.EffectiveSettings.Monitoring.Enabled, Is.EqualTo(monitoring ?? true));
                Assert.That(running.CriticalFailure, Is.Null);
                Assert.That(_runtimeLogs, Does.Contain("Artisan Logbook Companion started."));
                Assert.That(_runtimeLogs, Does.Contain($"Game directory: {Path.Combine(_directory, "offline")}"));
                Assert.That(_runtimeLogs, Does.Contain("ArtisanLogbook Core installed flavors: (none detected)"));
                Assert.That(_runtimeLogs, Does.Contain(monitoring is not false
                    ? "SavedVariables monitoring: on"
                    : "SavedVariables monitoring: off"));
                Assert.That(_runtimeLogs, Does.Contain("Reconciliation interval: 60 seconds."));
                Assert.That(_runtimeLogs, Has.Some.Matches<string>(line =>
                    line.StartsWith("HTTP API listening on http://127.0.0.1:", StringComparison.Ordinal) && line.EndsWith("(preferred port 48721).", StringComparison.Ordinal)));
                Assert.That(_runtimeLogs, Does.Not.Contain("Artisan Logbook Companion started. Monitoring preference: False."));
                Assert.That(app.Services.GetServices<IHostedService>().Count(), Is.EqualTo(4));
                Assert.That(app.Services.GetRequiredService<IServer>().Features
                    .Get<IServerAddressesFeature>()!.Addresses.Single(), Does.StartWith("http://127.0.0.1:"));
            });
            using HttpClient http = new();
            string address = app.Services.GetRequiredService<IServer>().Features
                .Get<IServerAddressesFeature>()!.Addresses.Single();
            Assert.That((await http.GetAsync(address + "/")).StatusCode, Is.EqualTo(System.Net.HttpStatusCode.NotFound));
            Assert.That((await http.GetAsync(address + "/api/v1/status")).StatusCode, Is.EqualTo(System.Net.HttpStatusCode.OK));
            await app.StopAsync();
            Assert.That(status.Read().LifecycleState, Is.EqualTo(CompanionLifecycleState.Stopped));
            Assert.That(status.Read().DatabaseAvailable, Is.False);
            Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        }
        Assert.That(status.Read().LifecycleState, Is.EqualTo(CompanionLifecycleState.Stopped));
        using Store reopened = new(_database);
        Assert.That(reopened.ReadStatus().TotalCraftCount, Is.Zero);
        Assert.That(await File.ReadAllBytesAsync(_settings.FilePath), Is.EqualTo(before));
    }

    [Test]
    public async Task StartupShowsConfiguredGameDirectoryAndDetectedFlavorsWithoutSavedVariables()
    {
        string root = Path.Combine(_directory, "World of Warcraft");
        string classic = Path.Combine(root, "_classic_");
        string retail = Path.Combine(root, "_retail_");
        Directory.CreateDirectory(Path.Combine(classic, "WTF", "Account"));
        Directory.CreateDirectory(Path.Combine(retail, "WTF", "Account"));
        Directory.CreateDirectory(Path.Combine(classic, "Interface", "AddOns", "UnrelatedAddon"));
        string coreAddon = Path.Combine(retail, "Interface", "AddOns", "ArtisanLogbook_Core");
        Directory.CreateDirectory(coreAddon);
        File.WriteAllText(Path.Combine(coreAddon, "ArtisanLogbook_Core.toc"), "## Title: Artisan Logbook Core");
        _settings.Save(CompanionSettings.ForRoots(root));
        Assert.That(new InstallationDiscovery().DiscoverSavedVariables([root]).Paths, Is.Empty);

        await using WebApplication app = Build();
        await app.StartAsync();
        Assert.Multiple(() =>
        {
            Assert.That(_runtimeLogs, Does.Contain($"Game directory: {root}"));
            Assert.That(_runtimeLogs, Does.Contain("ArtisanLogbook Core installed flavors: _retail_"));
            Assert.That(app.Services.GetRequiredService<Store>().ReadStatus().TotalCraftCount, Is.Zero);
        });
        await app.StopAsync();
    }

    [Test]
    public async Task SharedImporterAndStatusUseAuthoritativeHistoryWithoutStartupChanges()
    {
        string source = Path.Combine(_directory, "snapshot.lua");
        await File.WriteAllTextAsync(source, CompanionCommandAppTests.Snapshot(1, null, 1));
        byte[] sourceBytes = await File.ReadAllBytesAsync(source);
        await using (WebApplication app = Build())
        {
            await app.StartAsync();
            Store store = app.Services.GetRequiredService<Store>();
            Assert.That(app.Services.GetRequiredService<Store>(), Is.SameAs(store));
            CompanionRuntimeImports importer = app.Services.GetRequiredService<CompanionRuntimeImports>();
            Assert.That((await importer.ImportSavedVariablesFileAsync(source)).Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
            Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(1));
            Assert.That(app.Services.GetRequiredService<CompanionApplicationStatus>().Read().CanonicalCraftCount, Is.EqualTo(1));
            await app.StopAsync();
        }
        byte[] databaseBytes = await File.ReadAllBytesAsync(_database);
        await using (WebApplication app = Build())
        {
            await app.StartAsync();
            Assert.That(app.Services.GetRequiredService<CompanionApplicationStatus>().Read().CanonicalCraftCount, Is.EqualTo(1));
            await app.StopAsync();
        }
        using Store reopened = new(_database, readOnly: true);
        Assert.That(reopened.ReadStatus().TotalCraftCount, Is.EqualTo(1));
        Assert.That(await File.ReadAllBytesAsync(_database), Is.EqualTo(databaseBytes));
        Assert.That(await File.ReadAllBytesAsync(source), Is.EqualTo(sourceBytes));
    }

    [Test]
    public async Task CancellationStopsHostAndDisposesWriter()
    {
        await using WebApplication app = Build();
        await app.StartAsync();
        Store store = app.Services.GetRequiredService<Store>();
        using CancellationTokenSource cancellation = new();
        Task wait = app.WaitForShutdownAsync(cancellation.Token);
        cancellation.Cancel();
        await wait.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.That(app.Services.GetRequiredService<CompanionApplicationStatus>().Read().LifecycleState,
            Is.EqualTo(CompanionLifecycleState.Stopped));
        Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        using Store reopened = new(_database);
    }

    [TestCase(null)]
    [TestCase(false)]
    public async Task StartupWithDiscoverableSnapshotNeverImportsOrModifiesSource(bool? monitoring)
    {
        string root = Path.Combine(_directory, "WoW");
        string source = Path.Combine(root, "_retail_", "WTF", "Account", "Sanitized", "SavedVariables", "ArtisanLogbook_Core.lua");
        Directory.CreateDirectory(Path.GetDirectoryName(source)!);
        await File.WriteAllTextAsync(source, CompanionCommandAppTests.Snapshot(1, null, 1));
        _settings.Save(CompanionSettings.ForRoots(root) with
        {
            Monitoring = new() { Enabled = monitoring ?? false }
        });
        if (monitoring is null)
        {
            await File.WriteAllTextAsync(_settings.FilePath,
                $$"""{"version":1,"installationRoots":["{{root.Replace("\\", "\\\\")}}"]}""");
        }
        byte[] sourceBytes = await File.ReadAllBytesAsync(source);
        byte[] settingsBytes = await File.ReadAllBytesAsync(_settings.FilePath);
        Assert.That(new InstallationDiscovery().DiscoverSavedVariables([root]).Paths, Is.EqualTo(new[] { source }));
        await using (WebApplication app = Build())
        {
            await app.StartAsync();
            Assert.That(app.Services.GetRequiredService<Store>().ReadStatus().TotalCraftCount, Is.Zero);
            await app.StopAsync();
        }
        using Store reopened = new(_database);
        Assert.That(reopened.ReadStatus().TotalCraftCount, Is.Zero);
        Assert.That(await File.ReadAllBytesAsync(source), Is.EqualTo(sourceBytes));
        Assert.That(await File.ReadAllBytesAsync(_settings.FilePath), Is.EqualTo(settingsBytes));
    }

    [Test]
    public async Task WorkersCanDrainTransactionalWorkBeforeDatabaseDisposal()
    {
        WebApplicationBuilder builder = Builder();
        builder.Services.AddHostedService<DrainOnStopWorker>();
        await using (WebApplication app = builder.Build())
        {
            await app.StartAsync();
            await app.StopAsync();
        }
        using Store reopened = new(_database);
        Assert.That(reopened.ReadStatus().TotalCraftCount, Is.EqualTo(1));
    }

    [Test]
    public void OperationalStatusIsNotAnExportedApiContract()
    {
        Assert.That(typeof(CompanionStatus).IsVisible, Is.False);
        Assert.That(typeof(CompanionApplicationStatus).IsVisible, Is.False);
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task ShutdownRejectsNewWorkWhileAdmittedWorkerCompletesOrCancels(bool cancel)
    {
        WebApplicationBuilder builder = Builder();
        builder.Services.AddSingleton<ControlledDrainWorker>();
        builder.Services.AddHostedService(provider => provider.GetRequiredService<ControlledDrainWorker>());
        await using (WebApplication app = builder.Build())
        {
            CompanionWorkAdmission admission = app.Services.GetRequiredService<CompanionWorkAdmission>();
            Assert.That(() => admission.Admit(), Throws.InvalidOperationException);
            Assert.ThrowsAsync<InvalidOperationException>(async () =>
                await app.Services.GetRequiredService<CompanionRuntimeImports>().ImportSavedVariablesAsync(
                    CompanionCommandAppTests.Snapshot(1, null, 1)));
            await app.StartAsync();
            Store store = app.Services.GetRequiredService<Store>();
            ControlledDrainWorker worker = app.Services.GetRequiredService<ControlledDrainWorker>();
            using CancellationTokenSource shutdown = new();
            Task stopping = app.StopAsync(shutdown.Token);
            await worker.Stopping.Task;
            Assert.That(stopping.IsCompleted, Is.False);
            Assert.That(() => admission.Admit(), Throws.InvalidOperationException);
            Assert.That(store.ReadStatus().TotalCraftCount, Is.Zero, "The admitted worker still owns an open store.");
            Assert.ThrowsAsync<InvalidOperationException>(async () =>
                await app.Services.GetRequiredService<CompanionRuntimeImports>().ImportSavedVariablesAsync(
                    CompanionCommandAppTests.Snapshot(1, null, 1)));
            if (cancel) shutdown.Cancel();
            worker.Finish.SetResult();
            await stopping;
            Assert.That(worker.Canceled, Is.EqualTo(cancel));
            Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        }
        using Store reopened = new(_database);
        Assert.That(reopened.ReadStatus().TotalCraftCount, Is.EqualTo(cancel ? 0 : 1));
    }

    [Test]
    public async Task ShutdownFailureStillDrainsAndReleasesWriter()
    {
        WebApplicationBuilder builder = Builder();
        builder.Services.AddHostedService<FailingStopWorker>();
        await using (WebApplication app = builder.Build())
        {
            await app.StartAsync();
            Assert.ThrowsAsync<InvalidOperationException>(async () => await app.StopAsync());
            Assert.That(() => app.Services.GetRequiredService<Store>().ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
            Assert.That(() => app.Services.GetRequiredService<CompanionWorkAdmission>().Admit(), Throws.InvalidOperationException);
        }
        using Store reopened = new(_database);
        Assert.That(reopened.ReadStatus().TotalCraftCount, Is.Zero);
    }

    [Test]
    public async Task CanceledStartupDrainsAlreadyAdmittedWorkBeforeCleanup()
    {
        await using WebApplication app = Build();
        CompanionRuntimeLifecycle lifecycle = app.Services.GetServices<IHostedService>()
            .OfType<CompanionRuntimeLifecycle>().Single();
        CompanionWorkAdmission admission = app.Services.GetRequiredService<CompanionWorkAdmission>();

        // Model the interleaving in which startup cancellation is observed after
        // admission opened and another operation already acquired a lease.
        admission.Open();
        IDisposable lease = admission.Admit();
        using CancellationTokenSource cancellation = new();
        cancellation.Cancel();
        Task starting = lifecycle.StartAsync(cancellation.Token);
        try
        {
            Assert.That(starting.IsCompleted, Is.False,
                "Startup cleanup must wait for the admitted operation.");
            Assert.That(() => admission.Admit(), Throws.InvalidOperationException);
        }
        finally
        {
            lease.Dispose();
        }
        Assert.ThrowsAsync<OperationCanceledException>(async () => await starting);
        Assert.That(() => admission.Admit(), Throws.InvalidOperationException);
    }

    [Test]
    public async Task FailedStartupWaitsForAdmittedWorkBeforeHostDisposal()
    {
        WebApplicationBuilder builder = Builder();
        builder.Services.AddSingleton<AdmittingStartupFailure>();
        builder.Services.AddHostedService(provider => provider.GetRequiredService<AdmittingStartupFailure>());
        Store store;
        await using (WebApplication app = builder.Build())
        {
            AdmittingStartupFailure worker = app.Services.GetRequiredService<AdmittingStartupFailure>();
            Task running = app.RunCompanionAsync();
            await worker.Admitted.Task;
            store = app.Services.GetRequiredService<Store>();
            try
            {
                Assert.That(running.IsCompleted, Is.False, "Failure cleanup must drain before DI disposes the writer.");
                Assert.That(store.ReadStatus().TotalCraftCount, Is.Zero);
                Assert.That(() => app.Services.GetRequiredService<CompanionWorkAdmission>().Admit(), Throws.InvalidOperationException);
            }
            finally
            {
                worker.Lease!.Dispose();
            }
            Assert.ThrowsAsync<InvalidOperationException>(async () => await running);
        }
        Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        using Store reopened = new(_database);
    }

    [Test]
    public async Task DrainWaitsForLeaseButDatabaseRejectsNewOperationsAfterWorkersStop()
    {
        await using WebApplication app = Build();
        await app.StartAsync();
        Store store = app.Services.GetRequiredService<Store>();
        CompanionWorkAdmission admission = app.Services.GetRequiredService<CompanionWorkAdmission>();
        IDisposable lease = admission.Admit();
        using CancellationTokenSource cancellation = new();
        Task stopping = app.StopAsync(cancellation.Token);
        try
        {
            Assert.That(stopping.IsCompleted, Is.False);
            cancellation.Cancel();
            Assert.That(stopping.IsCompleted, Is.False);
            Assert.That(SpinWait.SpinUntil(() =>
            {
                try { _ = store.ShutdownCompletion; return true; }
                catch (InvalidOperationException) { return false; }
            }, TimeSpan.FromSeconds(10)), Is.True);
            Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
            Assert.ThrowsAsync<InvalidOperationException>(async () =>
                await app.Services.GetRequiredService<CompanionRuntimeImports>().ImportSavedVariablesFileAsync("unused.lua"));
            var result = await app.Services.GetRequiredService<CompanionImportService>().ImportSavedVariablesAsync(
                CompanionCommandAppTests.Snapshot(1, null, 1));
            Assert.That(result.Outcome, Is.EqualTo(CompanionImportOutcome.Failed));
        }
        finally
        {
            lease.Dispose();
        }
        await stopping;
        Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        using Store reopened = new(_database);
        Assert.That(reopened.ReadStatus().TotalCraftCount, Is.Zero);
    }

    [Test]
    public async Task HostReportsDatabaseShutdownTimeoutAndLateRollbackRetainsSafeOwnership()
    {
        WebApplicationBuilder builder = Builder();
        builder.Services.Replace(ServiceDescriptor.Singleton<Store>(_ =>
            new(_database, shutdownGracePeriod: TimeSpan.FromMilliseconds(100))));
        await using WebApplication app = builder.Build();
        await app.StartAsync();
        Store store = app.Services.GetRequiredService<Store>();
        CompanionWorkAdmission admission = app.Services.GetRequiredService<CompanionWorkAdmission>();
        CraftHistory parsed = SavedVariablesReader.Parse(CompanionCommandAppTests.Snapshot(1, null, 1)).History!;
        using ManualResetEventSlim written = new();
        using ManualResetEventSlim release = new();
        int passes = 0;
        Task transaction = Task.Run(() =>
        {
            using IDisposable lease = admission.Admit();
            store.WriteBatch(parsed with
            {
                Crafts = new EnumerationCallbackList(parsed.Crafts, () =>
                {
                    if (Interlocked.Increment(ref passes) != 2) return;
                    written.Set();
                    if (!release.Wait(TimeSpan.FromSeconds(20))) throw new TimeoutException("Test writer was not released.");
                })
            });
        });
        try
        {
            Assert.That(written.Wait(TimeSpan.FromSeconds(20)), Is.True);
            Assert.ThrowsAsync<TimeoutException>(async () => await app.StopAsync().WaitAsync(TimeSpan.FromSeconds(10)));
            Assert.That(store.ShutdownCompletion.IsCompleted, Is.False);
            Assert.That(transaction.IsCompleted, Is.False);
            CompanionStatus status = app.Services.GetRequiredService<CompanionApplicationStatus>().Read();
            Assert.That(status.LifecycleState, Is.EqualTo(CompanionLifecycleState.Failed));
            Assert.That(status.CriticalFailure!.Code, Is.EqualTo("database-shutdown-timeout"));
            Assert.That(_runtimeLogs, Has.None.Contains("database ownership released"));
        }
        finally
        {
            release.Set();
            Assert.ThrowsAsync<OperationCanceledException>(async () => await transaction.WaitAsync(TimeSpan.FromSeconds(20)));
            await store.ShutdownCompletion.WaitAsync(TimeSpan.FromSeconds(20));
        }
        using Store reopened = new(_database);
        Assert.That(reopened.ReadAll(), Is.Empty);
    }

    [Test]
    public async Task StoppedThenConcurrentRuntimeDisposalsShareCompletedDatabaseCleanup()
    {
        await using WebApplication app = Build();
        await app.StartAsync();
        Store store = app.Services.GetRequiredService<Store>();
        CompanionApplicationStatus status = app.Services.GetRequiredService<CompanionApplicationStatus>();
        CompanionRuntimeLifecycle lifecycle = app.Services.GetServices<IHostedService>()
            .OfType<CompanionRuntimeLifecycle>().Single();
        await app.StopAsync();
        Task completion = store.ShutdownCompletion;
        await Task.WhenAll(lifecycle.DisposeAsync().AsTask(), lifecycle.DisposeAsync().AsTask(), Task.Run(lifecycle.Dispose));
        Assert.That(store.ShutdownCompletion, Is.SameAs(completion));
        Assert.That(completion.IsCompletedSuccessfully, Is.True);
        Assert.That(status.Read().DatabaseAvailable, Is.False);
        Assert.That(status.Read().LifecycleState, Is.EqualTo(CompanionLifecycleState.Stopped));
        AssertDatabaseReleased();
    }

    [Test]
    public async Task HostWithoutNormalStopUsesAsyncDiDisposalAndReleasesDatabase()
    {
        WebApplicationBuilder builder = Builder();
        builder.Services.AddSingleton<AsyncDisposalProbe>();
        WebApplication app = builder.Build();
        await app.StartAsync();
        AsyncDisposalProbe probe = app.Services.GetRequiredService<AsyncDisposalProbe>();
        Store store = app.Services.GetRequiredService<Store>();
        CompanionApplicationStatus status = app.Services.GetRequiredService<CompanionApplicationStatus>();
        await app.DisposeAsync();
        Assert.That(probe.AsyncDisposed, Is.True);
        Assert.That(store.ShutdownCompletion.IsCompletedSuccessfully, Is.True);
        Assert.That(status.Read().DatabaseAvailable, Is.False);
        Assert.That(status.Read().LifecycleState, Is.EqualTo(CompanionLifecycleState.Stopped));
        AssertDatabaseReleased();
    }

    [Test]
    public async Task CleanupFailureRemainsObservableThroughRuntimeAndHostDisposal()
    {
        WebApplication app = Build();
        await app.StartAsync();
        Store store = app.Services.GetRequiredService<Store>();
        CompanionApplicationStatus status = app.Services.GetRequiredService<CompanionApplicationStatus>();
        CompanionRuntimeLifecycle lifecycle = app.Services.GetServices<IHostedService>()
            .OfType<CompanionRuntimeLifecycle>().Single();
        CancellationTokenSource shutdown = (CancellationTokenSource)typeof(Store)
            .GetField("_shutdown", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(store)!;
        using CancellationTokenRegistration registration = shutdown.Token.Register(() =>
            throw new IOException("Controlled cleanup callback failure."));
        Assert.ThrowsAsync<AggregateException>(async () => await lifecycle.StoppedAsync(CancellationToken.None));
        Assert.That(store.ShutdownCompletion.IsFaulted, Is.True);
        Assert.That(status.Read().LifecycleState, Is.EqualTo(CompanionLifecycleState.Failed));
        Assert.That(status.Read().CriticalFailure!.Code, Is.EqualTo("database-shutdown-failed"));
        Assert.That(_runtimeLogs, Has.None.Contains("database ownership released"));
        Assert.ThrowsAsync<AggregateException>(async () => await lifecycle.DisposeAsync());
        Assert.ThrowsAsync<AggregateException>(async () => await app.DisposeAsync());
        AssertDatabaseReleased();
    }

    [Test]
    public async Task HostStartupAndFinalDrainFailuresAreBothPreserved()
    {
        WebApplicationBuilder builder = Builder();
        builder.Services.AddSingleton<AdmittingStartupFailure>();
        builder.Services.AddHostedService(provider => provider.GetRequiredService<AdmittingStartupFailure>());
        await using WebApplication app = builder.Build();
        AdmittingStartupFailure worker = app.Services.GetRequiredService<AdmittingStartupFailure>();
        try
        {
            AggregateException? failure = Assert.ThrowsAsync<AggregateException>(async () =>
                await app.RunCompanionAsync().WaitAsync(TimeSpan.FromSeconds(15)));
            Assert.That(failure!.InnerExceptions[0], Is.TypeOf<InvalidOperationException>());
            Assert.That(failure.InnerExceptions[0].Message, Does.Contain("Startup failed"));
            Assert.That(failure.InnerExceptions[1], Is.TypeOf<TimeoutException>());
            Assert.That(_runtimeLogs, Has.Some.Contains("Companion final work drain failed"));
        }
        finally
        {
            worker.Lease?.Dispose();
        }
    }

    [TestCase(false, false)]
    [TestCase(false, true)]
    [TestCase(true, false)]
    [TestCase(true, true)]
    public async Task AsyncRuntimeOrHostDisposalRetainsActiveNativeReadUntilEventualCleanup(
        bool stoppedFirst, bool disposeHost)
    {
        WebApplicationBuilder builder = Builder();
        builder.Services.Replace(ServiceDescriptor.Singleton<Store>(_ =>
            new(_database, shutdownGracePeriod: TimeSpan.FromMilliseconds(100))));
        WebApplication app = builder.Build();
        await app.StartAsync();
        Store store = app.Services.GetRequiredService<Store>();
        CompanionApplicationStatus status = app.Services.GetRequiredService<CompanionApplicationStatus>();
        CompanionRuntimeLifecycle lifecycle = app.Services.GetServices<IHostedService>()
            .OfType<CompanionRuntimeLifecycle>().Single();
        CraftHistory parsed = SavedVariablesReader.Parse(CompanionCommandAppTests.Snapshot(1, null, 1)).History!;
        store.WriteBatch(parsed);
        using ManualResetEventSlim executing = new();
        using ManualResetEventSlim release = new();
        using (DuckDBConnection setup = new($"Data Source={_database}"))
        {
            setup.Open();
            setup.RegisterScalarFunction<long, bool>("hold_runtime_read", (long _) =>
            {
                executing.Set();
                if (!release.Wait(TimeSpan.FromSeconds(20))) throw new TimeoutException("Test read was not released.");
                return true;
            });
            using var command = setup.CreateCommand();
            command.CommandText = """
                ALTER TABLE Craft RENAME TO StoredCraft;
                CREATE VIEW Craft AS SELECT c.* FROM StoredCraft c WHERE hold_runtime_read(c.CraftKey)
                """;
            command.ExecuteNonQuery();
        }
        Task read = Task.Run(() => store.ReadStatus());
        try
        {
            Assert.That(executing.Wait(TimeSpan.FromSeconds(20)), Is.True);
            if (stoppedFirst)
                Assert.ThrowsAsync<TimeoutException>(async () => await app.StopAsync());
            Task disposing = disposeHost ? app.DisposeAsync().AsTask() : lifecycle.DisposeAsync().AsTask();
            Assert.That(disposing.IsCompleted, Is.False, "Async disposal must return while the native read still owns its connection.");
            Assert.ThrowsAsync<TimeoutException>(async () => await disposing);
            Assert.That(store.ShutdownCompletion.IsCompleted, Is.False);
            Assert.That(read.IsCompleted, Is.False);
            Assert.That(_runtimeLogs, Has.None.Contains("database ownership released"));
            if (!disposeHost)
            {
                Assert.That(status.Read().CriticalFailure!.Code, Is.EqualTo("database-shutdown-timeout"));
                Assert.ThrowsAsync<TimeoutException>(async () => await lifecycle.DisposeAsync());
            }
            using DuckDBConnection probe = new($"Data Source={_database};access_mode=READ_ONLY");
            probe.Open();
            using var command = probe.CreateCommand();
            command.CommandText = "SELECT current_setting('access_mode')";
            Assert.That(command.ExecuteScalar(), Is.EqualTo("automatic"), "The original database handle must remain owned.");
        }
        finally
        {
            release.Set();
            Assert.ThrowsAsync<OperationCanceledException>(async () => await read.WaitAsync(TimeSpan.FromSeconds(20)));
            await store.ShutdownCompletion.WaitAsync(TimeSpan.FromSeconds(20));
            await lifecycle.DisposeAsync();
            await app.DisposeAsync();
        }
        Assert.That(status.Read().DatabaseAvailable, Is.False);
        Assert.That(store.ShutdownCompletion.IsCompletedSuccessfully, Is.True);
        await lifecycle.StoppedAsync(CancellationToken.None);
        Assert.That(status.Read().LifecycleState, Is.EqualTo(CompanionLifecycleState.Failed));
        Assert.That(status.Read().CriticalFailure!.Code, Is.EqualTo("database-shutdown-timeout"));
        Assert.That(_runtimeLogs, Has.None.Contains("database ownership released"));
        AssertDatabaseReleased();
    }

    [Test]
    public async Task FailedStartupPreservesOriginalErrorWhenCleanupAlsoTimesOut()
    {
        WebApplicationBuilder builder = Builder();
        builder.Services.Replace(ServiceDescriptor.Singleton<Store>(_ =>
            new(_database, shutdownGracePeriod: TimeSpan.FromMilliseconds(100))));
        builder.Services.AddSingleton<ILogger<CompanionRuntimeLifecycle>>(new FailingStartupLogger());
        await using WebApplication app = builder.Build();
        CompanionRuntimeLifecycle lifecycle = app.Services.GetServices<IHostedService>()
            .OfType<CompanionRuntimeLifecycle>().Single();
        CompanionWorkAdmission admission = app.Services.GetRequiredService<CompanionWorkAdmission>();
        CompanionApplicationStatus status = app.Services.GetRequiredService<CompanionApplicationStatus>();
        admission.Open();
        IDisposable lease = admission.Admit();
        try
        {
            AggregateException? failure = Assert.ThrowsAsync<AggregateException>(async () =>
                await lifecycle.StartAsync(CancellationToken.None));
            Assert.That(failure!.InnerExceptions[0], Is.TypeOf<IOException>());
            Assert.That(failure.InnerExceptions[1], Is.TypeOf<TimeoutException>());
            Assert.That(status.Read().CriticalFailure!.Code, Is.EqualTo("database-startup-failed"));
            Assert.That(status.Read().DatabaseAvailable, Is.False);
            AssertDatabaseReleased();
            Assert.That(_runtimeLogs, Has.None.Contains("database ownership released"));
        }
        finally
        {
            lease.Dispose();
            await lifecycle.DisposeAsync();
        }
        Assert.That(status.Read().CriticalFailure!.Code, Is.EqualTo("database-startup-failed"));
    }

    [Test]
    public async Task ShutdownCancellationRollsBackAnAdmittedTransactionBeforeReleasingOwnership()
    {
        await using WebApplication app = Build();
        await app.StartAsync();
        Store store = app.Services.GetRequiredService<Store>();
        CompanionWorkAdmission admission = app.Services.GetRequiredService<CompanionWorkAdmission>();
        CraftHistory parsed = SavedVariablesReader.Parse(CompanionCommandAppTests.Snapshot(1, null, 1)).History!;
        TaskCompletionSource written = new(TaskCreationOptions.RunContinuationsAsynchronously);
        TaskCompletionSource continueTransaction = new(TaskCreationOptions.RunContinuationsAsynchronously);
        using CancellationTokenSource cancellation = new();
        int completedPasses = 0;
        CraftHistory history = parsed with
        {
            Crafts = new EnumerationCallbackList(parsed.Crafts, () =>
            {
                // Validation completes first; the second pass has persisted the uncommitted batch.
                if (Interlocked.Increment(ref completedPasses) != 2) return;
                Assert.That(store.ReadStatus().TotalCraftCount, Is.Zero);
                written.TrySetResult();
                continueTransaction.Task.GetAwaiter().GetResult();
            })
        };
        Task transaction = Task.Run(() =>
        {
            using IDisposable lease = admission.Admit();
            store.WriteBatch(history, cancellation.Token);
        });
        Task stopping = Task.CompletedTask;
        try
        {
            await written.Task.WaitAsync(TimeSpan.FromSeconds(10));
            stopping = app.StopAsync(cancellation.Token);
            Assert.That(stopping.IsCompleted, Is.False);
            Assert.That(() => admission.Admit(), Throws.InvalidOperationException);
            cancellation.Cancel();
        }
        finally
        {
            continueTransaction.TrySetResult();
        }
        Assert.ThrowsAsync<OperationCanceledException>(async () => await transaction);
        await stopping;
        Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        using Store reopened = new(_database);
        Assert.That(reopened.ReadStatus().TotalCraftCount, Is.Zero);
        CraftDimensions dimensions = reopened.ReadDimensions();
        Assert.Multiple(() =>
        {
            Assert.That(dimensions.Characters, Is.Empty);
            Assert.That(dimensions.Recipes, Is.Empty);
            Assert.That(dimensions.Professions, Is.Empty);
            Assert.That(dimensions.Items, Is.Empty);
            Assert.That(dimensions.Expansions, Is.Empty);
            Assert.That(dimensions.RecipeReagentSlots, Is.Empty);
        });
    }

    [Test]
    public async Task UnavailableDatabaseReportsCriticalRuntimeFailureInsteadOfStaleCounts()
    {
        await using WebApplication app = Build();
        await app.StartAsync();
        app.Services.GetRequiredService<Store>().Dispose();
        CompanionStatus failed = app.Services.GetRequiredService<CompanionApplicationStatus>().Read();
        Assert.Multiple(() =>
        {
            Assert.That(failed.LifecycleState, Is.EqualTo(CompanionLifecycleState.Failed));
            Assert.That(failed.DatabaseAvailable, Is.False);
            Assert.That(failed.DatabaseSchemaVersion, Is.Null);
            Assert.That(failed.CanonicalCraftCount, Is.Null);
            Assert.That(failed.CriticalFailure!.Code, Is.EqualTo("database-status-failed"));
        });
        await app.StopAsync();
    }

    [Test]
    public async Task FailureAfterDatabaseStartupReleasesOwnershipOnDisposal()
    {
        WebApplicationBuilder builder = Builder();
        builder.Services.AddHostedService<FailingWorker>();
        Store store;
        await using (WebApplication app = builder.Build())
        {
            Assert.ThrowsAsync<InvalidOperationException>(async () => await app.RunCompanionAsync());
            Assert.That(app.Services.GetRequiredService<CompanionApplicationStatus>().Read().CriticalFailure!.Code,
                Is.EqualTo("host-failed"));
            store = app.Services.GetRequiredService<Store>();
        }
        Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        await using WebApplication next = Build();
        await next.StartAsync();
        await next.StopAsync();
    }

    [TestCase("corrupt")]
    [TestCase("unsupported")]
    public async Task InvalidDatabaseFailsWithoutChangingFileOrLeavingLocks(string kind)
    {
        Directory.CreateDirectory(_paths.DataDirectory);
        if (kind == "corrupt")
            await File.WriteAllTextAsync(_database, "not a DuckDB database");
        else
        {
            using (Store store = new(_database)) { }
            using DuckDBConnection connection = new($"Data Source={_database}");
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = "UPDATE __HistoryStoreMigration SET Version = 999";
            command.ExecuteNonQuery();
        }
        byte[] before = await File.ReadAllBytesAsync(_database);
        await using (WebApplication app = Build())
        {
            Assert.CatchAsync<Exception>(async () => await app.StartAsync());
            CompanionStatus failed = app.Services.GetRequiredService<CompanionApplicationStatus>().Read();
            Assert.That(failed.LifecycleState, Is.EqualTo(CompanionLifecycleState.Failed));
            Assert.That(failed.DatabaseAvailable, Is.False);
            Assert.That(failed.CriticalFailure!.Code, Is.EqualTo("database-startup-failed"));
        }
        Assert.That(await File.ReadAllBytesAsync(_database), Is.EqualTo(before));
        using FileStream exclusive = new(_database, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
    }

    [Test]
    public void InvalidSettingsFailBeforeDatabaseAcquisition()
    {
        Directory.CreateDirectory(_paths.DataDirectory);
        File.WriteAllText(_settings.FilePath, """{"version":2}""");
        Assert.That(() => Build(), Throws.TypeOf<CompanionSettingsException>());
        Assert.That(File.Exists(_database), Is.False);
    }

    [Test]
    public void DuplicateCompositionCannotRegisterIndependentStores()
    {
        WebApplicationBuilder builder = Builder();
        Assert.That(() => builder.Services.AddArtisanLogbookCompanion(
            _paths, CompanionRuntimeConfiguration.Resolve(_paths, _settings)), Throws.InvalidOperationException);
        Assert.That(builder.Services.Count(service => service.ServiceType == typeof(Store)), Is.EqualTo(1));
    }

    [Test]
    public async Task OccupiedPortFallsBackToLoopbackPortAndDisposalReleasesDatabase()
    {
        using TcpListener occupied = new(IPAddress.Loopback, 0);
        occupied.Start();
        int port = ((IPEndPoint)occupied.LocalEndpoint).Port;
        CompanionRuntimeConfiguration configuration = CompanionRuntimeConfiguration.Resolve(_paths, _settings, port: port);
        WebApplicationBuilder builder = WebApplication.CreateEmptyBuilder(new()
        {
            ApplicationName = typeof(CompanionCommandApp).Assembly.GetName().Name
        });
        builder.ConfigureCompanionHost(configuration);
        builder.Services.AddArtisanLogbookCompanion(_paths, configuration);
        Store store;
        await using (WebApplication app = builder.Build())
        {
            await app.StartAsync();
            store = app.Services.GetRequiredService<Store>();
            string address = app.Services.GetRequiredService<IServer>().Features
                .Get<IServerAddressesFeature>()!.Addresses.Single();
            Assert.That(address, Does.StartWith("http://127.0.0.1:").And.Not.EndWith(":" + port));
            Assert.That(app.Services.GetRequiredService<ArtisanLogbook.Runtime.CompanionHttpEndpoint>().FallbackUsed, Is.True);
            await app.StopAsync();
        }
        Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        await using WebApplication retry = Build();
        await retry.StartAsync();
        await retry.StopAsync();
    }

    [Test]
    public async Task ServeProcessOwnsDatabaseUntilTerminationAndReleasesIt()
    {
        if (OperatingSystem.IsWindows())
            Assert.Ignore("POSIX SIGTERM test; controlled host cancellation is tested on every platform.");
        using Process server = StartCli("serve", "--database", _database);
        using CancellationTokenSource timeout = new(TimeSpan.FromSeconds(30));
        Task<string> errors = server.StandardError.ReadToEndAsync();
        try
        {
            string startup = "";
            while (!startup.Contains("Server ready", StringComparison.Ordinal))
            {
                string? line = await server.StandardOutput.ReadLineAsync(timeout.Token);
                if (line is null) Assert.Fail(startup + await errors);
                startup += line + "\n";
            }
            while (!startup.Contains("http://127.0.0.1:", StringComparison.Ordinal))
            {
                string? line = await server.StandardOutput.ReadLineAsync(timeout.Token);
                if (line is null) Assert.Fail(startup + await errors);
                startup += line + "\n";
            }
            Assert.That(startup, Does.Contain("ARTISAN LOGBOOK")
                .And.Contain("Monitoring active")
                .And.Contain("Every 60s")
                .And.Contain("Server ready")
                .And.Contain("http://127.0.0.1:")
                .And.Not.Contain("category=")
                .And.Not.Contain("event="));
            foreach (string command in new[] { "serve", "status", "import" })
            {
                string[] arguments = command == "import"
                    ? [command, Path.Combine(_directory, "unused.lua"), "--database", _database]
                    : [command, "--database", _database];
                using Process contender = StartCli(arguments);
                Task<string> output = contender.StandardOutput.ReadToEndAsync();
                Task<string> error = contender.StandardError.ReadToEndAsync();
                try
                {
                    await contender.WaitForExitAsync(timeout.Token);
                }
                finally
                {
                    if (!contender.HasExited)
                    {
                        contender.Kill(entireProcessTree: true);
                        await contender.WaitForExitAsync();
                    }
                }
                Assert.That(contender.ExitCode, Is.EqualTo(ExitCodes.Failed), await output + await error);
                Assert.That(await output, Does.Contain("locked").And.Contain("retry").And.Contain("Do not delete"));
            }
            using Process signal = Process.Start(new ProcessStartInfo("kill")
            {
                ArgumentList = { "-TERM", server.Id.ToString(CultureInfo.InvariantCulture) },
                UseShellExecute = false
            })!;
            await signal.WaitForExitAsync(timeout.Token);
            Assert.That(signal.ExitCode, Is.Zero);
            Task<string> remaining = server.StandardOutput.ReadToEndAsync();
            await server.WaitForExitAsync(timeout.Token);
            Assert.That(server.ExitCode, Is.EqualTo(ExitCodes.Success), await errors);
            Assert.That(await remaining, Does.Contain("Stopping Companion").And.Contain("Companion stopped"));
            using Store reopened = new(_database);
            Assert.That(reopened.ReadStatus().TotalCraftCount, Is.Zero);
            Assert.That(File.Exists(_settings.FilePath), Is.False);
        }
        finally
        {
            if (!server.HasExited)
            {
                server.Kill(entireProcessTree: true);
                await server.WaitForExitAsync();
            }
        }
    }

    private static Process StartCli(params string[] arguments)
    {
        ProcessStartInfo start = new("dotnet")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };
        start.ArgumentList.Add(typeof(CompanionCommandApp).Assembly.Location);
        foreach (string argument in arguments) start.ArgumentList.Add(argument);
        return Process.Start(start)!;
    }

    private WebApplication Build() => Builder().Build();

    private void AssertDatabaseReleased()
    {
        using DuckDBConnection connection = new($"Data Source={_database};access_mode=READ_ONLY");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT current_setting('access_mode')";
        Assert.That(command.ExecuteScalar(), Is.EqualTo("read_only"));
    }

    private WebApplicationBuilder Builder()
    {
        WebApplicationBuilder builder = WebApplication.CreateEmptyBuilder(new()
        {
            Args = [],
            ApplicationName = typeof(ArtisanLogbook.Cli.CompanionCommandApp).Assembly.GetName().Name
        });
        CompanionRuntimeConfiguration configuration = CompanionRuntimeConfiguration.Resolve(_paths, _settings);
        builder.ConfigureCompanionHost(configuration);
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        builder.Logging.AddProvider(new CapturingLoggerProvider(_runtimeLogs));
        builder.Services.AddArtisanLogbookCompanion(
            _paths, configuration);
        return builder;
    }

    private sealed class FailingWorker : IHostedService
    {
        public Task StartAsync(CancellationToken cancellationToken) =>
            throw new InvalidOperationException("Controlled startup failure.");
        public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class CapturingLoggerProvider(List<string> messages) : ILoggerProvider
    {
        public ILogger CreateLogger(string categoryName) => new CapturingLogger(messages);
        public void Dispose() { }
    }

    private sealed class CapturingLogger(List<string> messages) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;
        public void Log<TState>(
            LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (IsEnabled(logLevel)) lock (messages) messages.Add(formatter(state, exception));
        }
    }

    private sealed class FailingStartupLogger : ILogger<CompanionRuntimeLifecycle>
    {
        private int _failed;
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(
            LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (Interlocked.Exchange(ref _failed, 1) == 0)
                throw new IOException("Controlled startup reporting failure after database acquisition.");
        }
    }

    private sealed class AsyncDisposalProbe : IDisposable, IAsyncDisposable
    {
        public bool AsyncDisposed { get; private set; }
        public void Dispose() => throw new InvalidOperationException("The asynchronous host must not select synchronous DI disposal.");
        public ValueTask DisposeAsync()
        {
            AsyncDisposed = true;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class DrainOnStopWorker(
        CompanionImportService importer, CompanionApplicationStatus status, CompanionWorkAdmission admission) : IHostedService
    {
        private IDisposable? _lease;
        public Task StartAsync(CancellationToken cancellationToken)
        {
            _lease = admission.Admit();
            return Task.CompletedTask;
        }
        public async Task StopAsync(CancellationToken cancellationToken)
        {
            using IDisposable lease = _lease!;
            Assert.That(status.Read().LifecycleState, Is.EqualTo(CompanionLifecycleState.Stopping));
            var result = await importer.ImportSavedVariablesAsync(
                CompanionCommandAppTests.Snapshot(1, null, 1), cancellationToken: cancellationToken);
            Assert.That(result.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
        }
    }

    private sealed class ControlledDrainWorker(CompanionWorkAdmission admission, CompanionImportService importer) : IHostedService
    {
        public TaskCompletionSource Stopping { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Finish { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Canceled { get; private set; }
        private IDisposable? _lease;

        public Task StartAsync(CancellationToken cancellationToken)
        {
            _lease = admission.Admit();
            return Task.CompletedTask;
        }

        public async Task StopAsync(CancellationToken cancellationToken)
        {
            using IDisposable lease = _lease!;
            Stopping.SetResult();
            await Finish.Task;
            try
            {
                var result = await importer.ImportSavedVariablesAsync(
                    CompanionCommandAppTests.Snapshot(1, null, 1), cancellationToken: cancellationToken);
                Assert.That(result.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                Canceled = true;
            }
        }
    }

    private sealed class FailingStopWorker : IHostedService
    {
        public Task StartAsync(CancellationToken cancellationToken) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken) => throw new InvalidOperationException("Controlled shutdown failure.");
    }

    private sealed class AdmittingStartupFailure(CompanionWorkAdmission admission) : IHostedService
    {
        public TaskCompletionSource Admitted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public IDisposable? Lease { get; private set; }
        public Task StartAsync(CancellationToken cancellationToken)
        {
            Lease = admission.Admit();
            Admitted.SetResult();
            throw new InvalidOperationException("Startup failed with admitted work still unwinding.");
        }
        public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class EnumerationCallbackList(IReadOnlyList<CraftObservation> crafts, Action completed) : IReadOnlyList<CraftObservation>
    {
        public int Count => crafts.Count;
        public CraftObservation this[int index] => crafts[index];
        public IEnumerator<CraftObservation> GetEnumerator()
        {
            foreach (CraftObservation craft in crafts) yield return craft;
            completed();
        }
        System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
    }
}
