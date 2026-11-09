using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;

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
using Microsoft.Extensions.Hosting;

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

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Host.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _paths = new(CompanionPlatform.Linux, _directory, _directory, null, _directory);
        _settings = new(_paths);
        _database = _paths.ResolveDatabase(null);
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
                Assert.That(running.Configuration.EffectiveSettings.Monitoring.Enabled, Is.EqualTo(monitoring ?? false));
                Assert.That(running.CriticalFailure, Is.Null);
                Assert.That(app.Services.GetServices<IHostedService>().Count(), Is.EqualTo(2));
                Assert.That(app.Services.GetRequiredService<IServer>().Features
                    .Get<IServerAddressesFeature>()!.Addresses.Single(), Does.StartWith("http://127.0.0.1:"));
            });
            using HttpClient http = new();
            string address = app.Services.GetRequiredService<IServer>().Features
                .Get<IServerAddressesFeature>()!.Addresses.Single();
            Assert.That((await http.GetAsync(address + "/")).StatusCode, Is.EqualTo(System.Net.HttpStatusCode.NotFound));
            Assert.That((await http.GetAsync(address + "/api/v1/status")).StatusCode, Is.EqualTo(System.Net.HttpStatusCode.NotFound));
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
    [TestCase(true)]
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
    public async Task DrainWaitsForLeaseEvenAfterWorkersStopAndShutdownTokenIsCanceled()
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
            Assert.That(store.ReadStatus().TotalCraftCount, Is.Zero);
            Assert.ThrowsAsync<InvalidOperationException>(async () =>
                await app.Services.GetRequiredService<CompanionRuntimeImports>().ImportSavedVariablesFileAsync("unused.lua"));
            var result = await app.Services.GetRequiredService<CompanionImportService>().ImportSavedVariablesAsync(
                CompanionCommandAppTests.Snapshot(1, null, 1));
            Assert.That(result.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
        }
        finally
        {
            lease.Dispose();
        }
        await stopping;
        Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        using Store reopened = new(_database);
        Assert.That(reopened.ReadStatus().TotalCraftCount, Is.EqualTo(1));
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
        CraftHistory history = parsed with
        {
            Crafts = new EnumerationCallbackList(parsed.Crafts, () =>
            {
                if (store.ReadStatus().TotalCraftCount == 0) return;
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
    public async Task OccupiedPortFailsStartupAndDisposalReleasesDatabase()
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
            Assert.CatchAsync<IOException>(async () => await app.RunCompanionAsync());
            store = app.Services.GetRequiredService<Store>();
            Assert.That(app.Services.GetRequiredService<CompanionApplicationStatus>().Read().CriticalFailure!.Code,
                Is.EqualTo("host-failed"));
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
            while (!startup.Contains("Companion started.", StringComparison.Ordinal))
            {
                string? line = await server.StandardOutput.ReadLineAsync(timeout.Token);
                if (line is null) Assert.Fail(startup + await errors);
                startup += line + "\n";
            }
            Assert.That(startup, Does.Not.Contain("http://"));
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
            Assert.That(await remaining, Does.Contain("ownership released"));
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
