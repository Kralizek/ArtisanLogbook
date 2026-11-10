using System.Net;
using System.Text;
using System.Text.Json;

using ArtisanLogbook.Runtime;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class MonitoringApiTests
{
    [Test]
    public async Task DisabledByDefaultAndPublicStatusDoesNotExposePathsOrAccounts()
    {
        await using MonitoringTestHost host = new();
        host.Ledger(account: "PRIVATE_ACCOUNT");
        await host.StartAsync();
        string text = await host.Http.GetStringAsync("/api/v1/monitoring");
        JsonElement state = JsonDocument.Parse(text).RootElement;
        Assert.Multiple(() =>
        {
            Assert.That(state.GetProperty("state").GetString(), Is.EqualTo("Disabled"));
            Assert.That(state.GetProperty("preferences").GetProperty("enabled").GetBoolean(), Is.False);
            Assert.That(state.GetProperty("effective").GetProperty("enabled").GetBoolean(), Is.False);
            Assert.That(state.GetProperty("effective").GetProperty("reconciliationIntervalSeconds").GetInt32(), Is.EqualTo(60));
            Assert.That(state.GetProperty("overrides").GetProperty("enabled").GetBoolean(), Is.False);
            Assert.That(state.GetProperty("lastReconciledAt").ValueKind, Is.EqualTo(JsonValueKind.Null));
            Assert.That(text, Does.Not.Contain(host.DirectoryPath).And.Not.Contain("PRIVATE_ACCOUNT").And.Not.Contain("databasePath"));
            Assert.That(host.Imports.Calls, Is.Zero);
        });
        using HttpResponseMessage disabled = await Send(host, HttpMethod.Post, "/api/v1/monitoring/reconcile", "{}");
        await Problem(disabled, HttpStatusCode.Conflict, "monitoring-disabled");
    }

    [Test]
    public async Task PutPersistsPreferencesAndPostAcceptsAnInvalidationRatherThanAnImport()
    {
        await using MonitoringTestHost host = new();
        string source = host.Ledger();
        await host.StartAsync();
        using HttpResponseMessage put = await Send(host, HttpMethod.Put, "/api/v1/monitoring",
            """{"enabled":true,"reconciliationIntervalSeconds":17}""");
        Assert.That(put.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        JsonElement body = await Json(put);
        Assert.That(body.GetProperty("effective").GetProperty("enabled").GetBoolean(), Is.True);
        Assert.That(body.GetProperty("preferences").GetProperty("reconciliationIntervalSeconds").GetInt32(), Is.EqualTo(17));
        Assert.That(host.Settings.Load().Settings!.Monitoring, Is.EqualTo(new MonitoringSettings { Enabled = true, ReconciliationIntervalSeconds = 17 }));
        Assert.That(host.Settings.Load().Settings!.InstallationRoots, Is.EqualTo(new[] { host.Root }));
        await MonitoringTestHost.Eventually(() => host.Checkpoints.Read().Document.Sources.GetValueOrDefault(SourceCatalog.IdFor(source))?.Successful is not null);
        await host.Settled();

        using HttpResponseMessage reconcile = await Send(host, HttpMethod.Post, "/api/v1/monitoring/reconcile", "{}");
        Assert.That(reconcile.StatusCode, Is.EqualTo(HttpStatusCode.Accepted));
        Assert.That(reconcile.Headers.Location!.OriginalString, Is.EqualTo("/api/v1/monitoring"));
        Assert.That((await Json(reconcile)).TryGetProperty("id", out _), Is.False);
        await host.Settled();
        Assert.That(host.Imports.Calls, Is.EqualTo(1));
    }

    [TestCase(1)]
    [TestCase(86400)]
    public async Task IntervalBoundaryValuesArePersisted(int interval)
    {
        await using MonitoringTestHost host = new();
        await host.StartAsync();
        using HttpResponseMessage response = await Send(host, HttpMethod.Put, "/api/v1/monitoring",
            $$"""{"enabled":false,"reconciliationIntervalSeconds":{{interval}}}""");
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(host.Settings.Load().Settings!.Monitoring.ReconciliationIntervalSeconds, Is.EqualTo(interval));
    }

    [Test]
    public async Task DiagnosticsAreBoundedTo50EntriesAndTruncationIsExplicit()
    {
        await using MonitoringTestHost host = new();
        for (int i = 0; i < 51; i++)
        {
            string path = host.Ledger(account: $"ACCOUNT{i}");
            host.Reader.Failures[path] = new("source-changed-during-read", "controlled incomplete write");
        }
        await host.StartAsync(enabled: true);
        await MonitoringTestHost.Eventually(() => host.Monitor.Read().LastReconciliation?.DiscoveredSources == 51);
        await host.Settled();
        JsonElement body = JsonDocument.Parse(await host.Http.GetStringAsync("/api/v1/monitoring")).RootElement;
        Assert.That(body.GetProperty("diagnostics").GetArrayLength(), Is.EqualTo(50));
        Assert.That(body.GetProperty("diagnosticsTruncated").GetBoolean(), Is.True);
        Assert.That(body.GetProperty("pendingSources").GetInt32(), Is.EqualTo(51));
        Assert.That(body.GetProperty("lastSubmittedImports").GetInt32(), Is.Zero);
        Assert.That(body.ToString(), Does.Not.Contain("ACCOUNT").And.Not.Contain(host.DirectoryPath));
    }

    [Test]
    public async Task MetadataCapacityRejectionDoesNotPretendTheImportQueueIsFull()
    {
        await using MonitoringTestHost host = new();
        host.Ledger();
        await host.StartAsync();
        string[] ids = Enumerable.Range(0, 4096).Select(i => SourceCatalog.IdFor($"/retained-{i}")).ToArray();
        Assert.That(host.Checkpoints.TryReserve(ids, host.Scheduler.Now, out _), Is.True);
        using HttpResponseMessage response = await Send(host, HttpMethod.Post, "/api/v1/imports", "{}");
        await Problem(response, HttpStatusCode.TooManyRequests, "checkpoint-capacity-exceeded");
        Assert.That(host.Operations.List(100), Is.Empty);
    }

    [TestCase(true, false)]
    [TestCase(false, true)]
    public async Task PutReportsSymmetricInvocationOverridesWithoutRestartingUnchangedEffectiveSettings(bool overridden, bool preference)
    {
        await using MonitoringTestHost host = new();
        await host.StartAsync(enabledOverride: overridden, intervalOverride: 37);
        int attempts = host.Feed.Attempts;
        using HttpResponseMessage response = await Send(host, HttpMethod.Put, "/api/v1/monitoring",
            $$"""{"enabled":{{preference.ToString().ToLowerInvariant()}},"reconciliationIntervalSeconds":15}""");
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        JsonElement body = await Json(response);
        Assert.Multiple(() =>
        {
            Assert.That(body.GetProperty("preferences").GetProperty("enabled").GetBoolean(), Is.EqualTo(preference));
            Assert.That(body.GetProperty("effective").GetProperty("enabled").GetBoolean(), Is.EqualTo(overridden));
            Assert.That(body.GetProperty("effective").GetProperty("reconciliationIntervalSeconds").GetInt32(), Is.EqualTo(37));
            Assert.That(body.GetProperty("overrides").GetProperty("enabled").GetBoolean(), Is.True);
            Assert.That(body.GetProperty("overrides").GetProperty("reconciliationIntervalSeconds").GetBoolean(), Is.True);
            Assert.That(host.Feed.Attempts, Is.EqualTo(attempts));
            Assert.That(host.Settings.Load().Settings!.Monitoring.Enabled, Is.EqualTo(preference));
        });
    }

    [TestCase("{}")]
    [TestCase("""{"enabled":true}""")]
    [TestCase("""{"reconciliationIntervalSeconds":5}""")]
    [TestCase("""{"enabled":null,"reconciliationIntervalSeconds":5}""")]
    [TestCase("""{"enabled":true,"reconciliationIntervalSeconds":0}""")]
    [TestCase("""{"enabled":true,"reconciliationIntervalSeconds":86401}""")]
    [TestCase("""{"enabled":true,"reconciliationIntervalSeconds":5,"path":"/untrusted"}""")]
    public async Task InvalidPreferencesAreProblemDetailsAndNeverSaved(string json)
    {
        await using MonitoringTestHost host = new();
        await host.StartAsync();
        byte[] before = File.ReadAllBytes(host.Settings.FilePath);
        using HttpResponseMessage response = await Send(host, HttpMethod.Put, "/api/v1/monitoring", json);
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(response.Content.Headers.ContentType!.MediaType, Is.EqualTo("application/problem+json"));
        Assert.That(File.ReadAllBytes(host.Settings.FilePath), Is.EqualTo(before));
        Assert.That(host.Monitor.Read().Phase, Is.EqualTo(MonitoringPhase.Disabled));
    }

    [Test]
    public async Task InvalidPersistedSettingsAreNotOverwrittenAndDoNotChangeRuntime()
    {
        await using MonitoringTestHost host = new();
        await host.StartAsync();
        await File.WriteAllTextAsync(host.Settings.FilePath, """{"version":99}""");
        using HttpResponseMessage response = await Send(host, HttpMethod.Put, "/api/v1/monitoring",
            """{"enabled":true,"reconciliationIntervalSeconds":5}""");
        await Problem(response, HttpStatusCode.Conflict, "settings-conflict");
        Assert.That(await File.ReadAllTextAsync(host.Settings.FilePath), Is.EqualTo("""{"version":99}"""));
        Assert.That(host.Monitor.Read().Phase, Is.EqualTo(MonitoringPhase.Disabled));
    }

    [TestCase("PUT", "/api/v1/monitoring", """{"enabled":true,"reconciliationIntervalSeconds":5}""")]
    [TestCase("POST", "/api/v1/monitoring/reconcile", "{}")]
    public async Task ControlEndpointsRetainLocalSecurityPolicy(string method, string path, string body)
    {
        await using MonitoringTestHost host = new();
        await host.StartAsync();
        using HttpResponseMessage missing = await Send(host, new(method), path, body, clientHeader: false);
        await Problem(missing, HttpStatusCode.Forbidden, "client-header-required");
        using HttpRequestMessage foreign = Request(new(method), path, body);
        foreign.Headers.Add("Origin", "http://untrusted.example");
        using HttpResponseMessage crossOrigin = await host.Http.SendAsync(foreign);
        await Problem(crossOrigin, HttpStatusCode.Forbidden, "origin-not-allowed");
        using HttpRequestMessage wrongType = Request(new(method), path, body);
        wrongType.Content = new StringContent(body, Encoding.UTF8, "text/plain");
        using HttpResponseMessage type = await host.Http.SendAsync(wrongType);
        await Problem(type, HttpStatusCode.UnsupportedMediaType, "unsupported-content-type");
        using HttpResponseMessage oversized = await Send(host, new(method), path, new string(' ', 5000) + body);
        await Problem(oversized, HttpStatusCode.RequestEntityTooLarge, "request-too-large");
    }

    [Test]
    public async Task StoppingRejectsBothPreferencesAndReconciliationWith503()
    {
        await using MonitoringTestHost host = new();
        await host.StartAsync(enabled: true);
        await host.Monitor.StoppingAsync(CancellationToken.None);
        using HttpResponseMessage update = await Send(host, HttpMethod.Put, "/api/v1/monitoring",
            """{"enabled":false,"reconciliationIntervalSeconds":5}""");
        await Problem(update, HttpStatusCode.ServiceUnavailable, "application-stopping");
        using HttpResponseMessage reconcile = await Send(host, HttpMethod.Post, "/api/v1/monitoring/reconcile", "{}");
        await Problem(reconcile, HttpStatusCode.ServiceUnavailable, "application-stopping");
    }

    private static HttpRequestMessage Request(HttpMethod method, string path, string body, bool clientHeader = true)
    {
        HttpRequestMessage request = new(method, path) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        if (clientHeader) request.Headers.Add("X-Artisan-Logbook-Client", "monitoring-tests");
        return request;
    }

    private static async Task<HttpResponseMessage> Send(
        MonitoringTestHost host, HttpMethod method, string path, string body, bool clientHeader = true)
    {
        using HttpRequestMessage request = Request(method, path, body, clientHeader);
        return await host.Http.SendAsync(request);
    }

    private static async Task<JsonElement> Json(HttpResponseMessage response) =>
        JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.Clone();

    private static async Task Problem(HttpResponseMessage response, HttpStatusCode status, string code)
    {
        Assert.That(response.StatusCode, Is.EqualTo(status));
        Assert.That(response.Content.Headers.ContentType!.MediaType, Is.EqualTo("application/problem+json"));
        Assert.That((await Json(response)).GetProperty("code").GetString(), Is.EqualTo(code));
    }
}
