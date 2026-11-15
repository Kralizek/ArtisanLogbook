using ArtisanLogbook.WebAssets;

using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.FileProviders;

namespace ArtisanLogbook.Runtime;

internal static class FrontendHosting
{
    public static void UseEmbeddedFrontend(this IApplicationBuilder app)
    {
        IFileProvider files = EmbeddedFrontend.CreateFileProvider();
        StaticFileOptions options = new() { FileProvider = files };
        app.Use(async (context, next) =>
        {
            // Only known browser routes get the document; API and missing-asset paths stay 404.
            if ((HttpMethods.IsGet(context.Request.Method) || HttpMethods.IsHead(context.Request.Method)) &&
                BrowserRoutes.IsDocument(context.Request.Path.Value))
                context.Request.Path = "/index.html";
            await next(context);
        });
        app.UseStaticFiles(options);
    }
}

internal static class BrowserRoutes
{
    public static bool IsDocument(string? path)
    {
        if (path is "/" or "/history" or "/history/" or "/companion" or "/companion/") return true;
        string[] segments = (path ?? "").Trim('/').Split('/');
        if (segments.Length == 2 && segments[0] == "saved")
            return Guid.TryParse(segments[1], out _);
        if (segments.Length is not (2 or 3) ||
            !GameContextRouteResolver.TryResolve(segments[0], out _)) return false;
        return segments.Length == 2
            ? segments[1] is "activity" or "library" or "crafts"
            : segments[1] is "recipes" or "items" or "crafts" &&
                segments[2].Length > 0 && segments[2].All(c =>
                    char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
    }
}
