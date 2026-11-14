using Aspire.Hosting.ApplicationModel;

using Microsoft.Extensions.Configuration;

var builder = DistributedApplication.CreateBuilder(args);
string dataDirectory = Path.GetFullPath(builder.Configuration["Development:DataDirectory"] ??
    Path.Combine(builder.AppHostDirectory, "../../.artifacts/development"));

var companion = builder.AddProject<Projects.Cli>("companion", options => options.ExcludeLaunchProfile = true)
    .WithHttpEndpoint(port: builder.Configuration.GetValue<int?>("Development:CompanionPort"), name: "http", isProxied: false)
    .WithEnvironment("ARTISAN_LOGBOOK_DATA_DIRECTORY", dataDirectory)
    .WithHttpHealthCheck("/api/v1/health");

companion.WithArgs(context =>
{
    context.Args.Add("serve");
    context.Args.Add("--monitoring");
    context.Args.Add("false");
    context.Args.Add("--require-port");
    context.Args.Add("--port");
    context.Args.Add(companion.GetEndpoint("http").Property(EndpointProperty.Port));
});

builder.AddViteApp("web", "../../web")
    .WithNpm(install: builder.Configuration.GetValue("Development:InstallFrontend", true),
        installCommand: "ci", installArgs: ["--no-audit", "--no-fund"])
    .WithEndpoint("http", endpoint =>
    {
        endpoint.IsProxied = false;
        endpoint.Port = builder.Configuration.GetValue<int?>("Development:WebPort");
    })
    .WithEnvironment("COMPANION_URL", ReferenceExpression.Create(
        $"http://127.0.0.1:{companion.GetEndpoint("http").Property(EndpointProperty.Port)}"))
    .WithEnvironment("NODE_ENV", "development")
    .WithEnvironment("VITE_USE_POLLING", "true")
    .WaitFor(companion);

builder.Build().Run();
