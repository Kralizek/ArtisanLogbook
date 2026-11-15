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
                context.Request.Path.Value is "/" or "/history" or "/history/")
                context.Request.Path = "/index.html";
            await next(context);
        });
        app.UseStaticFiles(options);
    }
}
