using System.Globalization;

using Microsoft.AspNetCore.Http;

namespace ArtisanLogbook.Runtime;

/// <summary>
/// Defence for a privileged loopback API against browsers and DNS rebinding. There is no CORS and no cookie
/// authentication: cross-origin pages are refused, and state-changing requests must use JSON plus a custom
/// header, which browsers cannot send cross-site without a (never granted) preflight.
/// </summary>
internal sealed class LocalApiSecurityMiddleware(RequestDelegate next)
{
    public const string ClientHeader = "X-Artisan-Logbook-Client";
    public const int MaxRequestBodyBytes = 4096;

    private static readonly string[] LoopbackHosts = ["127.0.0.1", "localhost", "[::1]"];

    public async Task InvokeAsync(HttpContext context)
    {
        HttpResponse response = context.Response;
        response.Headers.XContentTypeOptions = "nosniff";
        response.Headers.CacheControl = "no-store";

        HttpRequest request = context.Request;
        if (!LoopbackHosts.Contains(request.Host.Host, StringComparer.OrdinalIgnoreCase))
        {
            await Reject(context, StatusCodes.Status403Forbidden, "host-not-allowed",
                "The Host header must be a loopback name (127.0.0.1, localhost or [::1]).");
            return;
        }

        if (request.Headers.TryGetValue("Sec-Fetch-Site", out var site) &&
            !(site == "same-origin" || site == "none"))
        {
            await Reject(context, StatusCodes.Status403Forbidden, "cross-origin-rejected",
                "Cross-site browser requests are not allowed.");
            return;
        }

        if (request.Headers.TryGetValue("Origin", out var origin) && !IsSameOrigin(origin.ToString(), request))
        {
            await Reject(context, StatusCodes.Status403Forbidden, "origin-not-allowed",
                "The request Origin is not this Companion; cross-origin access is not enabled.");
            return;
        }

        if (!HttpMethods.IsGet(request.Method) && !HttpMethods.IsHead(request.Method))
        {
            if (!HttpMethods.IsPost(request.Method) && !HttpMethods.IsPut(request.Method))
            {
                await Reject(context, StatusCodes.Status405MethodNotAllowed, "method-not-allowed",
                    "The method is not supported.");
                return;
            }
            if (string.IsNullOrWhiteSpace(request.Headers[ClientHeader]))
            {
                await Reject(context, StatusCodes.Status403Forbidden, "client-header-required",
                    $"State-changing requests must include the {ClientHeader} header.");
                return;
            }
            if (!IsJson(request.ContentType))
            {
                await Reject(context, StatusCodes.Status415UnsupportedMediaType, "unsupported-content-type",
                    "The request Content-Type must be application/json.");
                return;
            }
            if (request.ContentLength is null or > MaxRequestBodyBytes)
            {
                await Reject(context,
                    request.ContentLength is null ? StatusCodes.Status411LengthRequired : StatusCodes.Status413PayloadTooLarge,
                    request.ContentLength is null ? "content-length-required" : "request-too-large",
                    request.ContentLength is null
                        ? "A Content-Length header is required."
                        : $"The request body must not exceed {MaxRequestBodyBytes} bytes.");
                return;
            }
        }

        await next(context);
    }

    private static bool IsJson(string? contentType) =>
        contentType is not null &&
        System.Net.Http.Headers.MediaTypeHeaderValue.TryParse(contentType, out var parsed) &&
        string.Equals(parsed.MediaType, "application/json", StringComparison.OrdinalIgnoreCase);

    private static bool IsSameOrigin(string origin, HttpRequest request)
    {
        if (!Uri.TryCreate(origin, UriKind.Absolute, out Uri? uri) || uri.Scheme != Uri.UriSchemeHttp)
            return false;
        string host = request.Host.Host.Trim('[', ']');
        return uri.Port == (request.Host.Port ?? 80) &&
            string.Equals(uri.Host.Trim('[', ']'), host, StringComparison.OrdinalIgnoreCase);
    }

    private static Task Reject(HttpContext context, int status, string code, string detail) =>
        ProblemResponses.Write(context, status, code, detail);
}

internal static class ProblemResponses
{
    public static Task Write(HttpContext context, int status, string code, string detail)
    {
        context.Response.StatusCode = status;
        context.Response.ContentType = "application/problem+json";
        string title = Title(status);
        return context.Response.WriteAsJsonAsync(new Dictionary<string, object?>
        {
            ["type"] = FormattableString.Invariant($"https://httpstatuses.io/{status}"),
            ["title"] = title,
            ["status"] = status,
            ["detail"] = detail,
            ["code"] = code
        }, options: null, contentType: "application/problem+json");
    }

    public static string Title(int status) => status switch
    {
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        411 => "Length Required",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        429 => "Too Many Requests",
        503 => "Service Unavailable",
        500 => "Internal Server Error",
        _ => status.ToString(CultureInfo.InvariantCulture)
    };
}
