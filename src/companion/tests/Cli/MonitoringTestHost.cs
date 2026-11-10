using System.Collections.Concurrent;
using System.Diagnostics;
using System.Reactive.Concurrency;

using ArtisanLogbook.Cli;
using ArtisanLogbook.ImportService;
using ArtisanLogbook.Runtime;

using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;
using Microsoft.Reactive.Testing;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.Cli;

internal sealed class MonitoringTestHost : IAsyncDisposable
{
    public MonitoringTestHost()
    {
        DirectoryPath = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Monitoring.Tests", Guid.NewGuid().ToString("N"));
        Root = Path.Combine(DirectoryPath, "WoW");
        Directory.CreateDirectory(Root);
        Paths = new(CompanionPlatform.Linux, DirectoryPath, DirectoryPath, null, DirectoryPath);
        Settings = new(Paths);
        Feed = new(Scheduler, Logs.CreateLogger<SourceChangeFeed>());
    }

    public string DirectoryPath { get; }
    public string Root { get; }
    public ApplicationPaths Paths { get; }
    public CompanionSettingsStore Settings { get; }
    public TestScheduler Scheduler { get; } = new();
    public CapturingLoggerProvider Logs { get; } = new();
    public ReactiveMonitoringTests.ControlledFeed Feed { get; }
    public ControlledSnapshotReader Reader { get; } = new();
    public WebApplication App { get; private set; } = null!;
    public HttpClient Http { get; private set; } = null!;
    public SourceMonitor Monitor => App.Services.GetRequiredService<SourceMonitor>();
    public MonitoringCheckpoints Checkpoints => App.Services.GetRequiredService<MonitoringCheckpoints>();
    public ImportOperations Operations => App.Services.GetRequiredService<ImportOperations>();
    public ControlledRuntimeImports Imports => (ControlledRuntimeImports)App.Services.GetRequiredService<CompanionRuntimeImports>();
    public Store History => App.Services.GetRequiredService<Store>();

    public string Ledger(string flavor = "_retail_", string account = "A", int project = 1, string? content = null)
    {
        string path = Path.Combine(Root, flavor, "WTF", "Account", account, "SavedVariables", "ArtisanLogbook_Core.lua");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content ?? CompanionCommandAppTests.Snapshot(project, null, 1));
        return path;
    }

    public async Task StartAsync(
        bool enabled = false, int interval = 60, bool? enabledOverride = null, int? intervalOverride = null,
        MonitoringCheckpointTests.MemoryStore? checkpointStore = null, bool realWatchers = false,
        ImportOperationLimits? limits = null, bool legacySettings = false)
    {
        Settings.Save(CompanionSettings.ForRoots(Root) with
        {
            Monitoring = new() { Enabled = enabled, ReconciliationIntervalSeconds = interval }
        });
        if (legacySettings)
            File.WriteAllText(Settings.FilePath, System.Text.Json.JsonSerializer.Serialize(new
            {
                version = 1,
                installationRoots = new[] { Root }
            }));
        CompanionRuntimeConfiguration configuration = CompanionRuntimeConfiguration.Resolve(
            Paths, Settings, monitoring: enabledOverride, reconciliationIntervalSeconds: intervalOverride);
        WebApplicationBuilder builder = WebApplication.CreateEmptyBuilder(new()
        {
            Args = [],
            ApplicationName = typeof(CompanionCommandApp).Assembly.GetName().Name
        });
        builder.ConfigureCompanionHost(configuration);
        builder.Logging.SetMinimumLevel(LogLevel.Debug).AddProvider(Logs);
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        builder.Services.AddArtisanLogbookCompanion(Paths, configuration);
        builder.Services.Replace(ServiceDescriptor.Singleton<SavedVariablesSnapshotReader>(Reader));
        builder.Services.Replace(ServiceDescriptor.Singleton<CompanionRuntimeImports>(provider =>
            new ControlledRuntimeImports(provider.GetRequiredService<CompanionWorkAdmission>(),
                provider.GetRequiredService<CompanionImportService>())));
        if (!realWatchers)
        {
            builder.Services.Replace(ServiceDescriptor.Singleton<IScheduler>(Scheduler));
            builder.Services.Replace(ServiceDescriptor.Singleton<SourceChangeFeed>(Feed));
        }
        if (checkpointStore is not null)
            builder.Services.Replace(ServiceDescriptor.Singleton<MonitoringCheckpointStore>(checkpointStore));
        if (limits is not null) builder.Services.Replace(ServiceDescriptor.Singleton(limits));
        App = builder.Build();
        await App.StartAsync();
        Http = new() { BaseAddress = new(App.Services.GetRequiredService<CompanionHttpEndpoint>().ListeningUrl!) };
    }

    public void Preferences(bool enabled, int interval = 60) =>
        Monitor.UpdatePreferences(new() { Enabled = enabled, ReconciliationIntervalSeconds = interval }, CancellationToken.None);

    public Task Settled() => Eventually(() => !Checkpoints.Read().IsDirty &&
        Monitor.Read().Phase is MonitoringPhase.Active or MonitoringPhase.Degraded or MonitoringPhase.Disabled,
        "monitor did not settle");

    public static async Task Eventually(Func<bool> condition, string message = "condition was not reached")
    {
        Stopwatch timeout = Stopwatch.StartNew();
        while (!condition())
        {
            if (timeout.Elapsed > TimeSpan.FromSeconds(15)) throw new TimeoutException(message);
            await Task.Delay(5);
        }
    }

    public async ValueTask DisposeAsync()
    {
        Reader.ReleaseAll();
        if (App is not null)
        {
            Imports.ReleaseAll();
            try { await App.StopAsync(); }
            finally
            {
                Http?.Dispose();
                await App.DisposeAsync();
            }
        }
        Feed.Events.Dispose();
        Directory.Delete(DirectoryPath, recursive: true);
    }
}

internal sealed class TestGate<T>
{
    public TaskCompletionSource<T> Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
}

internal sealed class ControlledSnapshotReader() : SavedVariablesSnapshotReader(quietPeriod: TimeSpan.Zero)
{
    private TestGate<SavedVariablesSnapshot>? _next;
    private readonly ConcurrentBag<TestGate<SavedVariablesSnapshot>> _gates = [];
    public ConcurrentDictionary<string, int> Reads { get; } = new();
    public ConcurrentDictionary<string, SourceSnapshotException> Failures { get; } = new();
    public Exception? UnexpectedFailure { get; set; }

    public TestGate<SavedVariablesSnapshot> BlockNext()
    {
        TestGate<SavedVariablesSnapshot> gate = new();
        _gates.Add(gate);
        Interlocked.Exchange(ref _next, gate);
        return gate;
    }

    public override async Task<SavedVariablesSnapshot> ReadAsync(string path, CancellationToken cancellationToken = default)
    {
        Reads.AddOrUpdate(path, 1, (_, value) => value + 1);
        if (UnexpectedFailure is not null) throw UnexpectedFailure;
        if (Failures.TryGetValue(path, out SourceSnapshotException? failure)) throw failure;
        TestGate<SavedVariablesSnapshot>? gate = Interlocked.Exchange(ref _next, null);
        SavedVariablesSnapshot snapshot = await base.ReadAsync(path, cancellationToken);
        if (gate is not null)
        {
            gate.Entered.TrySetResult(snapshot);
            // Deliberately uncooperative: tests must prove obsolete results are rejected, not merely request cancellation.
            await gate.Release.Task;
        }
        return snapshot;
    }

    public void ReleaseAll()
    {
        foreach (var gate in _gates) gate.Release.TrySetResult();
    }
}

internal sealed class ControlledRuntimeImports : CompanionRuntimeImports
{
    private readonly CompanionWorkAdmission _admission;
    private TestGate<CompanionImportResult>? _next;
    private readonly ConcurrentBag<TestGate<CompanionImportResult>> _gates = [];
    private int _calls;
    private int _active;
    private int _nullFingerprintForNext;
    private int _nullFingerprintOnCall;
    private readonly ConcurrentBag<int> _concurrency = [];
    public int Calls => Volatile.Read(ref _calls);
    public int MaximumActive => _concurrency.DefaultIfEmpty().Max();

    public ControlledRuntimeImports(CompanionWorkAdmission admission, CompanionImportService importer) : base(admission, importer) =>
        _admission = admission;

    public TestGate<CompanionImportResult> BlockNext()
    {
        TestGate<CompanionImportResult> gate = new();
        _gates.Add(gate);
        Interlocked.Exchange(ref _next, gate);
        return gate;
    }

    public void ReturnNullFingerprintForNext() => Interlocked.Exchange(ref _nullFingerprintForNext, 1);
    public void ReturnNullFingerprintOnCall(int call) => Interlocked.Exchange(ref _nullFingerprintOnCall, call);

    public override async Task<CompanionImportResult> ImportSavedVariablesFileAsync(string path, CancellationToken cancellationToken = default)
    {
        using IDisposable lease = _admission.Admit();
        int call = Interlocked.Increment(ref _calls);
        int active = Interlocked.Increment(ref _active);
        _concurrency.Add(active);
        try
        {
            TestGate<CompanionImportResult>? gate = Interlocked.Exchange(ref _next, null);
            CompanionImportResult result = await base.ImportSavedVariablesFileAsync(path, cancellationToken);
            if (gate is not null)
            {
                gate.Entered.TrySetResult(result);
                await gate.Release.Task.WaitAsync(cancellationToken);
            }
            if (Interlocked.Exchange(ref _nullFingerprintForNext, 0) != 0 ||
                Interlocked.CompareExchange(ref _nullFingerprintOnCall, 0, call) == call)
                result = result with { SourceFingerprint = null };
            return result;
        }
        finally { Interlocked.Decrement(ref _active); }
    }

    public void ReleaseAll()
    {
        foreach (var gate in _gates) gate.Release.TrySetResult();
    }
}
