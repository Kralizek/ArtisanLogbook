using System.Net;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

using ArtisanLogbook.Cli;
using ArtisanLogbook.ImportService;
using ArtisanLogbook.Runtime;

using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.Cli;

[TestFixture]
public sealed class CompanionApiTests
{
    private string _directory = null!;
    private string _root = null!;
    private ApplicationPaths _paths = null!;
    private CompanionSettingsStore _settings = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Api.Tests", Guid.NewGuid().ToString("N"));
        _root = Path.Combine(_directory, "World of Warcraft");
        Directory.CreateDirectory(_root);
        _paths = new(CompanionPlatform.Linux, _directory, _directory, null, _directory);
        _settings = new(_paths);
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [Test]
    public async Task HealthAndStatusReportEmptyDatabaseWithVersionedJson()
    {
        await using ApiHost host = await Start();
        using HttpResponseMessage health = await host.Http.GetAsync("/api/v1/health");
        JsonElement healthBody = await Json(health);
        Assert.That(health.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(health.Content.Headers.ContentType!.MediaType, Is.EqualTo("application/json"));
        Assert.That(healthBody.GetProperty("status").GetString(), Is.EqualTo("Healthy"));

        JsonElement status = await Json(await host.Http.GetAsync("/api/v1/status"));
        Assert.Multiple(() =>
        {
            Assert.That(status.GetProperty("applicationVersion").GetString(), Is.EqualTo("0.1.0"));
            Assert.That(status.GetProperty("state").GetString(), Is.EqualTo("Running"));
            Assert.That(status.GetProperty("startedAt").ValueKind, Is.EqualTo(JsonValueKind.String));
            Assert.That(status.GetProperty("database").GetProperty("available").GetBoolean(), Is.True);
            Assert.That(status.GetProperty("database").GetProperty("schemaVersion").GetInt32(), Is.Positive);
            Assert.That(status.GetProperty("history").GetProperty("craftCount").GetInt64(), Is.Zero);
            Assert.That(status.GetProperty("history").GetProperty("gameContexts").GetArrayLength(), Is.Zero);
            Assert.That(status.TryGetProperty("failure", out _), Is.False.Or.True);
            Assert.That(status.ToString(), Does.Not.Contain(_directory));
        });
    }

    [Test]
    public async Task UnknownRoutesAndMethodsReturnProblemDetails()
    {
        await using ApiHost host = await Start();
        using HttpResponseMessage missing = await host.Http.GetAsync("/api/v1/nothing");
        Assert.That(missing.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That(missing.Content.Headers.ContentType!.MediaType, Is.EqualTo("application/problem+json"));
        Assert.That((await host.Http.GetAsync("/")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        using HttpResponseMessage put = await host.Send(HttpMethod.Put, "/api/v1/imports", "{}", post: true);
        Assert.That(put.StatusCode, Is.EqualTo(HttpStatusCode.MethodNotAllowed));
    }

    [Test]
    public async Task OpenApiDocumentIsPublishedAndMatchesMappedEndpoints()
    {
        await using ApiHost host = await Start();
        using HttpResponseMessage response = await host.Http.GetAsync("/openapi/v1.yaml");
        string document = await response.Content.ReadAsStringAsync();
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(document, Does.Contain("openapi: 3.0.3").And.Contain("/api/v1"));

        string[] documented = Regex.Matches(document, @"^  (/api/v1/\S+):$", RegexOptions.Multiline)
            .Select(match => match.Groups[1].Value).Order().ToArray();
        string[] mapped = host.App.Services.GetRequiredService<EndpointDataSource>().Endpoints
            .OfType<RouteEndpoint>().Select(endpoint => endpoint.RoutePattern.RawText!)
            .Select(pattern => pattern.Replace("{id:guid}", "{id}")).Where(pattern => pattern.StartsWith("/api/v1/", StringComparison.Ordinal)).Distinct().Order().ToArray();
        Assert.That(mapped, Is.EqualTo(documented));
        Assert.That(documented, Is.EqualTo(new[]
        {
            "/api/v1/health", "/api/v1/imports", "/api/v1/imports/{id}", "/api/v1/monitoring",
            "/api/v1/monitoring/reconcile", "/api/v1/sources", "/api/v1/status"
        }));
        foreach (string operation in new[] { "getHealth", "getStatus", "listSources", "listImports", "startImport", "getImport",
            "getMonitoring", "updateMonitoring", "reconcileMonitoring" })
            Assert.That(document, Does.Contain($"operationId: {operation}"));
    }

    [Test]
    public async Task SourcesAreDiscoveredWithStableOpaqueIdentifiers()
    {
        _settings.Save(CompanionSettings.ForRoots(_root, Path.Combine(_directory, "absent")));
        string first = Ledger("_retail_", "ACCOUNT1", 1);
        Ledger("_classic_", "ACCOUNT2", 2);
        await using ApiHost host = await Start();
        string body = await host.Http.GetStringAsync("/api/v1/sources");
        JsonElement sources = JsonDocument.Parse(body).RootElement;
        JsonElement[] items = sources.GetProperty("sources").EnumerateArray().ToArray();
        Assert.Multiple(() =>
        {
            Assert.That(items, Has.Length.EqualTo(2));
            Assert.That(items.Select(item => item.GetProperty("client").GetString()), Is.EquivalentTo(new[] { "_retail_", "_classic_" }));
            Assert.That(items.Select(item => item.GetProperty("id").GetString()), Is.Unique);
            Assert.That(items.All(item => item.GetProperty("fileName").GetString() == "ArtisanLogbook_Core.lua"), Is.True);
            Assert.That(items.All(item => item.GetProperty("sizeBytes").GetInt64() > 0), Is.True);
            Assert.That(body, Does.Not.Contain(_directory).And.Not.Contain("ACCOUNT1").And.Not.Contain("ACCOUNT2"));
            Assert.That(body, Does.Not.Contain("projectId"));
            Assert.That(SourceCatalog.IdFor(first), Is.EqualTo(items.Single(item => item.GetProperty("client").GetString() == "_retail_")
                .GetProperty("id").GetString()));
        });
        Assert.That(await host.Http.GetStringAsync("/api/v1/sources"), Is.EqualTo(body));
        Assert.That(new FileInfo(first).Length, Is.Positive);
        Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.True, "serve opens the database; discovery imports nothing");
        Assert.That(host.App.Services.GetRequiredService<Store>().ReadStatus().TotalCraftCount, Is.Zero);
    }

    [Test]
    [System.Runtime.Versioning.UnsupportedOSPlatform("windows")]
    public async Task SourcesReportMissingConfigurationAndInaccessibleLocations()
    {
        await using (ApiHost none = await Start())
        {
            JsonElement empty = await Json(await none.Http.GetAsync("/api/v1/sources"));
            Assert.That(empty.GetProperty("sources").GetArrayLength(), Is.Zero);
            Assert.That(empty.GetProperty("diagnostics")[0].GetProperty("code").GetString(), Is.EqualTo("no-installation-roots"));
        }

        if (OperatingSystem.IsWindows() || Environment.UserName == "root")
            Assert.Ignore("Permission-based inaccessibility cannot be simulated for this user.");
        _settings.Save(CompanionSettings.ForRoots(_root));
        string ledger = Ledger("_retail_", "LOCKED", 1);
        string accounts = Path.Combine(_root, "_retail_", "WTF", "Account");
        File.SetUnixFileMode(accounts, UnixFileMode.None);
        try
        {
            await using ApiHost host = await Start();
            string body = await host.Http.GetStringAsync("/api/v1/sources");
            JsonElement result = JsonDocument.Parse(body).RootElement;
            Assert.That(result.GetProperty("sources").GetArrayLength(), Is.Zero);
            Assert.That(result.GetProperty("diagnostics")[0].GetProperty("severity").GetString(), Is.EqualTo("Error"));
            Assert.That(body, Does.Not.Contain(_directory));
        }
        finally
        {
            File.SetUnixFileMode(accounts, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            Assert.That(File.Exists(ledger));
        }
    }

    [Test]
    public async Task ImportIsAcceptedImmediatelyTransitionsAndUpdatesStatus()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        Ledger("_retail_", "ACCOUNT1", 1);
        await using ApiHost host = await Start(gated: true);

        using HttpResponseMessage accepted = await host.Post("/api/v1/imports", "{}");
        JsonElement operation = await Json(accepted);
        string id = operation.GetProperty("id").GetString()!;
        Assert.That(accepted.StatusCode, Is.EqualTo(HttpStatusCode.Accepted));
        Assert.That(accepted.Headers.Location!.ToString(), Is.EqualTo($"/api/v1/imports/{id}"));
        Assert.That(operation.GetProperty("status").GetString(), Is.AnyOf("Queued", "Running"));
        Assert.That(operation.GetProperty("outcome").ValueKind, Is.EqualTo(JsonValueKind.Null));

        await host.Imports!.Entered.WaitAsync(Timeout());
        JsonElement running = await Json(await host.Http.GetAsync($"/api/v1/imports/{id}"));
        Assert.That(running.GetProperty("status").GetString(), Is.EqualTo("Running"));
        Assert.That(running.GetProperty("startedAt").ValueKind, Is.EqualTo(JsonValueKind.String));
        Assert.That(running.GetProperty("completedAt").ValueKind, Is.EqualTo(JsonValueKind.Null));

        host.Imports.Gate.SetResult();
        JsonElement done = await host.WaitFor(id);
        JsonElement source = done.GetProperty("sources")[0];
        Assert.Multiple(() =>
        {
            Assert.That(done.GetProperty("status").GetString(), Is.EqualTo("Completed"));
            Assert.That(done.GetProperty("outcome").GetString(), Is.EqualTo("Successful"));
            Assert.That(source.GetProperty("outcome").GetString(), Is.EqualTo("Successful"));
            Assert.That(source.GetProperty("counts").GetProperty("inserted").GetInt32(), Is.EqualTo(1));
            Assert.That(done.ToString(), Does.Not.Contain(_directory));
        });

        JsonElement status = await Json(await host.Http.GetAsync("/api/v1/status"));
        JsonElement history = status.GetProperty("history");
        Assert.That(history.GetProperty("craftCount").GetInt64(), Is.EqualTo(1));
        JsonElement context = history.GetProperty("gameContexts").EnumerateArray().Single();
        Assert.That(context.GetProperty("project").GetInt32(), Is.EqualTo(1));
        Assert.That(context.GetProperty("projectName").GetString(), Is.EqualTo("Retail"));
        Assert.That(context.GetProperty("craftCount").GetInt64(), Is.EqualTo(1));

        JsonElement list = await Json(await host.Http.GetAsync("/api/v1/imports"));
        Assert.That(list.GetProperty("operations").EnumerateArray().Single().GetProperty("id").GetString(), Is.EqualTo(id));
    }

    [Test]
    public async Task ReimportIsIdempotentAndSingleSourceSelectionWorks()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        string ledger = Ledger("_retail_", "ACCOUNT1", 1);
        Ledger("_classic_", "ACCOUNT2", 2);
        await using ApiHost host = await Start();
        string id = SourceCatalog.IdFor(ledger);

        JsonElement first = await host.WaitFor(await Accept(host, $$"""{"sourceId":"{{id}}"}"""));
        Assert.That(first.GetProperty("requestedSourceId").GetString(), Is.EqualTo(id));
        Assert.That(first.GetProperty("sources").GetArrayLength(), Is.EqualTo(1));
        Assert.That((await Json(await host.Http.GetAsync("/api/v1/status"))).GetProperty("history")
            .GetProperty("craftCount").GetInt64(), Is.EqualTo(1));

        JsonElement all = await host.WaitFor(await Accept(host, "{}"));
        JsonElement[] sources = all.GetProperty("sources").EnumerateArray().ToArray();
        Assert.Multiple(() =>
        {
            Assert.That(sources, Has.Length.EqualTo(2));
            Assert.That(sources.Sum(source => source.GetProperty("counts").GetProperty("inserted").GetInt32()), Is.EqualTo(1));
            Assert.That(sources.Sum(source => source.GetProperty("counts").GetProperty("alreadyPresent").GetInt32()), Is.EqualTo(1));
        });
        JsonElement again = await host.WaitFor(await Accept(host, "{}"));
        Assert.That(again.GetProperty("sources").EnumerateArray()
            .Sum(source => source.GetProperty("counts").GetProperty("inserted").GetInt32()), Is.Zero);
        Assert.That(host.App.Services.GetRequiredService<Store>().ReadStatus().TotalCraftCount, Is.EqualTo(2));
    }

    [Test]
    public async Task ConcurrentImportRequestsAreAllAcceptedAndSerialized()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        string[] ids = Enumerable.Range(1, 4).Select(n => SourceCatalog.IdFor(Ledger($"_c{n}_", $"A{n}", n))).ToArray();
        await using ApiHost host = await Start();
        string[] operations = await Task.WhenAll(ids.Select(id => Accept(host, $$"""{"sourceId":"{{id}}"}""")));
        foreach (string operation in operations)
            Assert.That((await host.WaitFor(operation)).GetProperty("outcome").GetString(), Is.EqualTo("Successful"));
        Assert.That(host.App.Services.GetRequiredService<Store>().ReadStatus().Contexts, Has.Count.EqualTo(4));
    }

    [Test]
    public async Task SchedulingIsBoundedAndDuplicateSourcesAreRejected()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        string a = SourceCatalog.IdFor(Ledger("_a_", "A", 1));
        string b = SourceCatalog.IdFor(Ledger("_b_", "B", 2));
        string c = SourceCatalog.IdFor(Ledger("_c_", "C", 3));
        await using ApiHost host = await Start(gated: true, limits: new(MaxActiveOperations: 1, MaxRetainedOperations: 100));
        string first = await Accept(host, $$"""{"sourceId":"{{a}}"}""");
        await host.Imports!.Entered.WaitAsync(Timeout());
        string second = await Accept(host, $$"""{"sourceId":"{{b}}"}""");

        using HttpResponseMessage full = await host.Post("/api/v1/imports", $$"""{"sourceId":"{{c}}"}""");
        using HttpResponseMessage duplicate = await host.Post("/api/v1/imports", $$"""{"sourceId":"{{a}}"}""");
        using HttpResponseMessage overlap = await host.Post("/api/v1/imports", "{}");
        Assert.Multiple(() =>
        {
            Assert.That(full.StatusCode, Is.EqualTo((HttpStatusCode)429));
            Assert.That(duplicate.StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
            Assert.That(overlap.StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
        });
        Assert.That((await Json(full)).GetProperty("code").GetString(), Is.EqualTo("import-capacity-exceeded"));
        Assert.That((await Json(duplicate)).GetProperty("code").GetString(), Is.EqualTo("source-busy"));
        Assert.That((await Json(await host.Http.GetAsync($"/api/v1/imports/{second}"))).GetProperty("status").GetString(), Is.EqualTo("Queued"));

        host.Imports.Gate.SetResult();
        await host.WaitFor(first);
        await host.WaitFor(second);
        Assert.That((await host.Post("/api/v1/imports", $$"""{"sourceId":"{{c}}"}""")).StatusCode, Is.EqualTo(HttpStatusCode.Accepted));
    }

    [Test]
    public async Task OperationHistoryIsBoundedAndListedNewestFirst()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        Ledger("_a_", "A", 1);
        await using ApiHost host = await Start(limits: new(MaxActiveOperations: 4, MaxRetainedOperations: 3));
        List<string> ids = [];
        for (int i = 0; i < 5; i++)
        {
            string id = await Accept(host, "{}");
            await host.WaitFor(id);
            ids.Add(id);
        }
        JsonElement list = await Json(await host.Http.GetAsync("/api/v1/imports?limit=100"));
        Assert.That(list.GetProperty("operations").EnumerateArray().Select(o => o.GetProperty("id").GetString()),
            Is.EqualTo(ids.AsEnumerable().Reverse().Take(3)));
        Assert.That((await host.Http.GetAsync($"/api/v1/imports/{ids[0]}")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That((await Json(await host.Http.GetAsync("/api/v1/imports?limit=1"))).GetProperty("operations").GetArrayLength(), Is.EqualTo(1));
        Assert.That((await host.Http.GetAsync("/api/v1/imports?limit=0")).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That((await host.Http.GetAsync("/api/v1/imports?limit=101")).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [Test]
    public async Task InvalidUnknownAndArbitraryPathRequestsAreRejected()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        string ledger = Ledger("_a_", "A", 1);
        await using ApiHost host = await Start();
        string unknown = "src_" + new string('0', 24);
        (string Body, HttpStatusCode Status, string Code)[] cases =
        [
            ($$"""{"sourceId":"{{ledger.Replace("\\", "\\\\")}}"}""", HttpStatusCode.BadRequest, "invalid-source-id"),
            ("""{"sourceId":"../../etc/passwd"}""", HttpStatusCode.BadRequest, "invalid-source-id"),
            ($$"""{"sourceId":"{{unknown}}"}""", HttpStatusCode.NotFound, "unknown-source"),
            ($$"""{"path":"{{ledger.Replace("\\", "\\\\")}}"}""", HttpStatusCode.BadRequest, "invalid-request"),
            ("not json", HttpStatusCode.BadRequest, "invalid-request"),
        ];
        foreach (var (body, status, code) in cases)
        {
            using HttpResponseMessage response = await host.Post("/api/v1/imports", body);
            Assert.That(response.StatusCode, Is.EqualTo(status), body);
            Assert.That(response.Content.Headers.ContentType!.MediaType, Is.EqualTo("application/problem+json"));
            Assert.That((await Json(response)).GetProperty("code").GetString(), Is.EqualTo(code), body);
        }
        Assert.That((await host.Http.GetAsync($"/api/v1/imports/{Guid.NewGuid()}")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That((await host.Http.GetAsync("/api/v1/imports/not-a-guid")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That(host.App.Services.GetRequiredService<Store>().ReadStatus().TotalCraftCount, Is.Zero);
    }

    [Test]
    public async Task ImportWithoutDiscoveredSourcesConflicts()
    {
        await using ApiHost host = await Start();
        using HttpResponseMessage response = await host.Post("/api/v1/imports", "{}");
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
        Assert.That((await Json(response)).GetProperty("code").GetString(), Is.EqualTo("no-sources"));
    }

    [Test]
    public async Task FailedSourceBecomesAnOperationOutcomeAndServerKeepsServing()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        string bad = Ledger("_a_", "A", 1);
        File.WriteAllBytes(bad, [0xFF, 0xFE, 0xFD]);
        await using ApiHost host = await Start();
        string id = await Accept(host, "{}");
        JsonElement done = await host.WaitFor(id);
        string text = done.ToString();
        Assert.Multiple(() =>
        {
            Assert.That(done.GetProperty("status").GetString(), Is.EqualTo("Failed"));
            Assert.That(done.GetProperty("outcome").GetString(), Is.EqualTo("Failed"));
            Assert.That(done.GetProperty("sources")[0].GetProperty("outcome").GetString(), Is.EqualTo("Rejected"));
            Assert.That(done.GetProperty("sources")[0].GetProperty("diagnostics")[0].GetProperty("code").GetString(),
                Is.EqualTo("invalid-source-encoding"));
            Assert.That(text, Does.Not.Contain(_directory));
        });
        Assert.That((await host.Http.GetAsync("/api/v1/health")).StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    [Test]
    public async Task UnexpectedImporterFailureIsContainedAndReportedSafely()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        Ledger("_a_", "A", 1);
        await using ApiHost host = await Start(gated: true);
        host.Imports!.Failure = new InvalidOperationException("secret " + _directory);
        host.Imports.Gate.SetResult();
        JsonElement done = await host.WaitFor(await Accept(host, "{}"));
        Assert.That(done.GetProperty("status").GetString(), Is.EqualTo("Failed"));
        Assert.That(done.ToString(), Does.Not.Contain("secret").And.Not.Contain(_directory));
        Assert.That((await host.Http.GetAsync("/api/v1/status")).StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    [Test]
    public async Task AcceptedImportSurvivesClientDisconnect()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        Ledger("_a_", "A", 1);
        await using ApiHost host = await Start(gated: true);
        string id;
        using (HttpClient disposable = new() { BaseAddress = new(host.Url) })
        {
            using HttpRequestMessage request = host.Request(HttpMethod.Post, "/api/v1/imports", "{}");
            using CancellationTokenSource cancel = new();
            using HttpResponseMessage response = await disposable.SendAsync(request, cancel.Token);
            id = (await Json(response)).GetProperty("id").GetString()!;
            await cancel.CancelAsync();
        }
        await host.Imports!.Entered.WaitAsync(Timeout());
        host.Imports.Gate.SetResult();
        Assert.That((await host.WaitFor(id)).GetProperty("outcome").GetString(), Is.EqualTo("Successful"));
    }

    [Test]
    public async Task ShutdownDrainsRunningImportCancelsQueuedAndRejectsNewWork()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        string a = SourceCatalog.IdFor(Ledger("_a_", "A", 1));
        string b = SourceCatalog.IdFor(Ledger("_b_", "B", 2));
        ApiHost host = await Start(gated: true);
        Store store = host.App.Services.GetRequiredService<Store>();
        ImportOperations operations = host.App.Services.GetRequiredService<ImportOperations>();
        CompanionApplicationStatus status = host.App.Services.GetRequiredService<CompanionApplicationStatus>();
        string running = await Accept(host, $$"""{"sourceId":"{{a}}"}""");
        await host.Imports!.Entered.WaitAsync(Timeout());
        string queued = await Accept(host, $$"""{"sourceId":"{{b}}"}""");

        Task stop = host.App.StopAsync();
        // Stopping is observable before the active import ends and blocks new submissions.
        while (status.Read().LifecycleState != CompanionLifecycleState.Stopping) await Task.Yield();
        Assert.That(operations.Submit(null).Rejection, Is.EqualTo(ImportRejection.Stopping));
        Assert.That(stop.IsCompleted, Is.False);
        Assert.That(() => store.ReadStatus(), Throws.Nothing, "the writer stays open while an accepted import is active");

        host.Imports.Gate.SetResult();
        await stop.WaitAsync(Timeout());
        ImportOperationSnapshot runningSnapshot = operations.Get(Guid.Parse(running))!;
        ImportOperationSnapshot queuedSnapshot = operations.Get(Guid.Parse(queued))!;
        Assert.Multiple(() =>
        {
            Assert.That(runningSnapshot.Status, Is.EqualTo(ImportOperationStatus.Completed));
            Assert.That(queuedSnapshot.Status, Is.EqualTo(ImportOperationStatus.Cancelled));
            Assert.That(queuedSnapshot.Sources.Single().Diagnostics.Single().Code, Is.EqualTo("application-stopping"));
            Assert.That(status.Read().LifecycleState, Is.EqualTo(CompanionLifecycleState.Stopped));
            Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        });
        await host.DisposeAsync();
        using Store reopened = new(_paths.ResolveDatabase(null));
        Assert.That(reopened.ReadStatus().TotalCraftCount, Is.EqualTo(1), "the drained import was committed");
    }

    [Test]
    public async Task ExpiredShutdownDeadlineCancelsActiveImport()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        Ledger("_a_", "A", 1);
        await using ApiHost host = await Start(gated: true);
        string id = await Accept(host, "{}");
        await host.Imports!.Entered.WaitAsync(Timeout());
        using CancellationTokenSource deadline = new();
        Task stop = host.App.StopAsync(deadline.Token);
        await deadline.CancelAsync();
        await Task.WhenAny(stop, Task.Delay(Timeout()));
        host.Imports.Gate.SetResult();
        try { await stop.WaitAsync(Timeout()); } catch (OperationCanceledException) { }
        ImportOperationSnapshot snapshot = host.App.Services.GetRequiredService<ImportOperations>().Get(Guid.Parse(id))!;
        Assert.That(snapshot.Status, Is.AnyOf(ImportOperationStatus.Cancelled, ImportOperationStatus.Completed));
    }

    [Test]
    public async Task LoopbackHostPolicyRejectsOtherHostsAndOrigins()
    {
        await using ApiHost host = await Start();
        Uri uri = new(host.Url);
        foreach (string hostName in new[] { "evil.example", "evil.example:" + uri.Port, "192.168.1.5", "0.0.0.0" })
        {
            using HttpRequestMessage request = new(HttpMethod.Get, "/api/v1/status");
            request.Headers.Host = hostName;
            using HttpResponseMessage response = await host.Http.SendAsync(request);
            Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Forbidden), hostName);
            Assert.That((await Json(response)).GetProperty("code").GetString(), Is.EqualTo("host-not-allowed"));
        }
        foreach (string name in new[] { "localhost", "127.0.0.1" })
        {
            using HttpRequestMessage request = new(HttpMethod.Get, "/api/v1/health");
            request.Headers.Host = $"{name}:{uri.Port}";
            using HttpResponseMessage response = await host.Http.SendAsync(request);
            Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK), name);
        }

        foreach (string origin in new[] { "http://evil.example", "https://127.0.0.1:" + uri.Port, "http://localhost:" + (uri.Port + 1), "null" })
        {
            using HttpRequestMessage request = new(HttpMethod.Get, "/api/v1/status");
            request.Headers.Add("Origin", origin);
            using HttpResponseMessage response = await host.Http.SendAsync(request);
            Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Forbidden), origin);
            Assert.That(response.Headers.Contains("Access-Control-Allow-Origin"), Is.False);
        }
        using (HttpRequestMessage sameOrigin = new(HttpMethod.Get, "/api/v1/status"))
        {
            sameOrigin.Headers.Add("Origin", host.Url);
            Assert.That((await host.Http.SendAsync(sameOrigin)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        }
        using (HttpRequestMessage preflight = new(HttpMethod.Options, "/api/v1/imports"))
        {
            preflight.Headers.Add("Origin", "http://evil.example");
            preflight.Headers.Add("Access-Control-Request-Method", "POST");
            using HttpResponseMessage response = await host.Http.SendAsync(preflight);
            Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Forbidden));
            Assert.That(response.Headers.Contains("Access-Control-Allow-Origin"), Is.False);
        }
        using (HttpRequestMessage fetch = new(HttpMethod.Get, "/api/v1/status"))
        {
            fetch.Headers.Add("Sec-Fetch-Site", "cross-site");
            Assert.That((await host.Http.SendAsync(fetch)).StatusCode, Is.EqualTo(HttpStatusCode.Forbidden));
        }
    }

    [Test]
    public async Task StateChangingRequestsRequireClientHeaderJsonAndBoundedBody()
    {
        _settings.Save(CompanionSettings.ForRoots(_root));
        Ledger("_a_", "A", 1);
        await using ApiHost host = await Start();

        using HttpRequestMessage noHeader = new(HttpMethod.Post, "/api/v1/imports")
        { Content = new StringContent("{}", Encoding.UTF8, "application/json") };
        using HttpResponseMessage missing = await host.Http.SendAsync(noHeader);
        Assert.That(missing.StatusCode, Is.EqualTo(HttpStatusCode.Forbidden));
        Assert.That((await Json(missing)).GetProperty("code").GetString(), Is.EqualTo("client-header-required"));

        foreach (string type in new[] { "text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x" })
        {
            using HttpRequestMessage request = host.Request(HttpMethod.Post, "/api/v1/imports", "{}");
            request.Content = new StringContent("{}");
            request.Content.Headers.Remove("Content-Type");
            request.Content.Headers.TryAddWithoutValidation("Content-Type", type);
            using HttpResponseMessage response = await host.Http.SendAsync(request);
            Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.UnsupportedMediaType), type);
        }
        using (HttpRequestMessage noType = host.Request(HttpMethod.Post, "/api/v1/imports", "{}"))
        {
            noType.Content = new ByteArrayContent("{}"u8.ToArray());
            Assert.That((await host.Http.SendAsync(noType)).StatusCode, Is.EqualTo(HttpStatusCode.UnsupportedMediaType));
        }
        using (HttpRequestMessage large = host.Request(HttpMethod.Post, "/api/v1/imports",
            $$"""{"sourceId":"{{new string('a', 10_000)}}"}"""))
        {
            large.Headers.ConnectionClose = true;
            Assert.That((await host.Http.SendAsync(large)).StatusCode, Is.EqualTo(HttpStatusCode.RequestEntityTooLarge));
        }

        using (HttpRequestMessage crossOrigin = host.Request(HttpMethod.Post, "/api/v1/imports", "{}"))
        {
            crossOrigin.Headers.Add("Origin", "http://evil.example");
            Assert.That((await host.Http.SendAsync(crossOrigin)).StatusCode, Is.EqualTo(HttpStatusCode.Forbidden));
        }
        using (HttpRequestMessage charset = host.Request(HttpMethod.Post, "/api/v1/imports", "{}"))
        {
            charset.Content = new StringContent("{}", Encoding.UTF8, "application/json");
            Assert.That((await host.Http.SendAsync(charset)).StatusCode, Is.EqualTo(HttpStatusCode.Accepted));
        }
        Assert.That(host.App.Services.GetRequiredService<ImportOperations>().List(10), Has.Count.EqualTo(1));
    }

    [Test]
    public async Task ResponsesAreNotCacheableAndCarryNoCorsHeaders()
    {
        await using ApiHost host = await Start();
        using HttpResponseMessage response = await host.Http.GetAsync("/api/v1/health");
        Assert.That(response.Headers.CacheControl!.NoStore, Is.True);
        Assert.That(response.Headers.GetValues("X-Content-Type-Options"), Is.EqualTo(new[] { "nosniff" }));
        Assert.That(response.Headers.Select(header => header.Key), Does.Not.Contain("Access-Control-Allow-Origin"));
    }

    [Test]
    public async Task PreferredPortIsUsedAndReportedWhenAvailable()
    {
        int port = FreePort();
        await using ApiHost host = await Start(port: port);
        CompanionHttpEndpoint endpoint = host.App.Services.GetRequiredService<CompanionHttpEndpoint>();
        Assert.Multiple(() =>
        {
            Assert.That(endpoint.FallbackUsed, Is.False);
            Assert.That(endpoint.ListeningUrl, Is.EqualTo($"http://127.0.0.1:{port}"));
            Assert.That(host.Url, Is.EqualTo(endpoint.ListeningUrl));
        });
    }

    [Test]
    public async Task OccupiedPreferredPortFallsBackWithoutChangingSettings()
    {
        Directory.CreateDirectory(_paths.DataDirectory);
        _settings.Save(CompanionSettings.ForRoots(_root));
        byte[] before = await File.ReadAllBytesAsync(_settings.FilePath);
        using TcpListener occupied = new(IPAddress.Loopback, 0);
        occupied.Start();
        int port = ((IPEndPoint)occupied.LocalEndpoint).Port;
        await using ApiHost host = await Start(port: port);
        CompanionHttpEndpoint endpoint = host.App.Services.GetRequiredService<CompanionHttpEndpoint>();
        Uri url = new(endpoint.ListeningUrl!);
        Assert.Multiple(() =>
        {
            Assert.That(endpoint.FallbackUsed, Is.True);
            Assert.That(endpoint.PreferredPort, Is.EqualTo(port));
            Assert.That(url.Port, Is.Not.EqualTo(port).And.Positive);
            Assert.That(url.Host, Is.EqualTo("127.0.0.1"));
        });
        Assert.That((await host.Http.GetAsync("/api/v1/health")).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(await File.ReadAllBytesAsync(_settings.FilePath), Is.EqualTo(before));
    }

    [Test]
    public async Task ServerListensOnLoopbackOnly()
    {
        await using ApiHost host = await Start();
        var addresses = host.App.Services.GetRequiredService<Microsoft.AspNetCore.Hosting.Server.IServer>().Features
            .Get<Microsoft.AspNetCore.Hosting.Server.Features.IServerAddressesFeature>()!.Addresses;
        Assert.That(addresses.Single(), Does.StartWith("http://127.0.0.1:"));
    }

    [Test]
    public async Task WriterIsReleasedAfterApiHostStopsAndRestartIsPossible()
    {
        await using (ApiHost first = await Start())
        {
            Store store = first.App.Services.GetRequiredService<Store>();
            await first.App.StopAsync();
            Assert.That(() => store.ReadStatus(), Throws.TypeOf<ObjectDisposedException>());
        }
        await using ApiHost second = await Start();
        Assert.That((await second.Http.GetAsync("/api/v1/health")).StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    private async Task<ApiHost> Start(bool gated = false, ImportOperationLimits? limits = null, int? port = null) =>
        await ApiHost.StartAsync(_paths, _settings, gated, limits, port);

    private string Ledger(string client, string account, int project)
    {
        string directory = Path.Combine(_root, client, "WTF", "Account", account, "SavedVariables");
        Directory.CreateDirectory(directory);
        string file = Path.Combine(directory, "ArtisanLogbook_Core.lua");
        File.WriteAllText(file, CompanionCommandAppTests.Snapshot(project, null, 1));
        return file;
    }

    private static async Task<string> Accept(ApiHost host, string body)
    {
        using HttpResponseMessage response = await host.Post("/api/v1/imports", body);
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Accepted), await response.Content.ReadAsStringAsync());
        return (await Json(response)).GetProperty("id").GetString()!;
    }

    private static async Task<JsonElement> Json(HttpResponseMessage response) =>
        JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.Clone();

    private static TimeSpan Timeout() => TimeSpan.FromSeconds(30);

    private static int FreePort()
    {
        using TcpListener listener = new(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private sealed class GatedImports : CompanionRuntimeImports
    {
        private readonly CompanionWorkAdmission _admission;

        public GatedImports(CompanionWorkAdmission admission, CompanionImportService importer) : base(admission, importer) =>
            _admission = admission;

        public SemaphoreSlim Entered { get; } = new(0);
        public TaskCompletionSource Gate { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Exception? Failure { get; set; }

        public override async Task<CompanionImportResult> ImportSavedVariablesFileAsync(
            string path, CancellationToken cancellationToken = default)
        {
            // Hold a real admission lease while blocked, as an in-flight C07 import would.
            using IDisposable lease = _admission.Admit();
            if (Failure is not null)
            {
                Entered.Release();
                await Gate.Task.WaitAsync(cancellationToken);
                throw Failure;
            }
            CompanionImportResult result = await base.ImportSavedVariablesFileAsync(path, cancellationToken);
            Entered.Release();
            await Gate.Task.WaitAsync(cancellationToken);
            return result;
        }
    }

    private sealed class ApiHost : IAsyncDisposable
    {
        public required WebApplication App { get; init; }
        public required HttpClient Http { get; init; }
        public required string Url { get; init; }
        public GatedImports? Imports { get; init; }

        public static async Task<ApiHost> StartAsync(
            ApplicationPaths paths, CompanionSettingsStore settings, bool gated, ImportOperationLimits? limits, int? port)
        {
            WebApplicationBuilder builder = WebApplication.CreateEmptyBuilder(new()
            {
                Args = [],
                ApplicationName = typeof(CompanionCommandApp).Assembly.GetName().Name
            });
            CompanionRuntimeConfiguration configuration = CompanionRuntimeConfiguration.Resolve(paths, settings, port: port);
            builder.ConfigureCompanionHost(configuration);
            if (port is null) builder.WebHost.UseUrls("http://127.0.0.1:0");
            builder.Services.AddArtisanLogbookCompanion(paths, configuration);
            if (gated)
                builder.Services.Replace(ServiceDescriptor.Singleton<CompanionRuntimeImports>(provider =>
                    new GatedImports(provider.GetRequiredService<CompanionWorkAdmission>(),
                        provider.GetRequiredService<CompanionImportService>())));
            if (limits is not null) builder.Services.Replace(ServiceDescriptor.Singleton(limits));
            WebApplication app = builder.Build();
            await app.StartAsync();
            string url = app.Services.GetRequiredService<CompanionHttpEndpoint>().ListeningUrl!;
            return new()
            {
                App = app,
                Http = new() { BaseAddress = new(url) },
                Url = url,
                Imports = gated ? (GatedImports)app.Services.GetRequiredService<CompanionRuntimeImports>() : null
            };
        }

        public HttpRequestMessage Request(HttpMethod method, string path, string body)
        {
            HttpRequestMessage request = new(method, path) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
            request.Content.Headers.ContentType = new("application/json");
            request.Headers.Add("X-Artisan-Logbook-Client", "tests");
            return request;
        }

        public Task<HttpResponseMessage> Post(string path, string body) => Http.SendAsync(Request(HttpMethod.Post, path, body));

        public Task<HttpResponseMessage> Send(HttpMethod method, string path, string body, bool post) =>
            Http.SendAsync(Request(method, path, body));

        public async Task<JsonElement> WaitFor(string id)
        {
            using CancellationTokenSource timeout = new(Timeout());
            while (true)
            {
                JsonElement operation = await Json(await Http.GetAsync($"/api/v1/imports/{id}", timeout.Token));
                if (operation.GetProperty("completedAt").ValueKind != JsonValueKind.Null) return operation;
                await Task.Delay(5, timeout.Token);
            }
        }

        public async ValueTask DisposeAsync()
        {
            Http.Dispose();
            await App.StopAsync();
            await App.DisposeAsync();
        }
    }
}
