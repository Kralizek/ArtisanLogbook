using System.Text.Json;

using Microsoft.AspNetCore.Http;

namespace ArtisanLogbook.Runtime;

internal sealed class SavedInvestigationRequestValidationMiddleware(RequestDelegate next)
{
    public async Task InvokeAsync(HttpContext context)
    {
        HttpRequest request = context.Request;
        if (!(HttpMethods.IsPost(request.Method) || HttpMethods.IsPut(request.Method)) ||
            !request.Path.StartsWithSegments("/api/v1/saved-investigations"))
        {
            await next(context);
            return;
        }

        request.EnableBuffering();
        try
        {
            using JsonDocument body = await JsonDocument.ParseAsync(request.Body,
                new JsonDocumentOptions
                {
                    MaxDepth = ApplicationStateStore.MaximumInvestigationDepth + 2
                }, request.HttpContext.RequestAborted);
            if (CompanionSettingsStore.HasDuplicateProperties(body.RootElement))
            {
                await ProblemResponses.Write(context, StatusCodes.Status400BadRequest, "invalid-request",
                    "Saved-investigation requests must not contain duplicate JSON property names.");
                return;
            }
        }
        catch (JsonException)
        {
            await ProblemResponses.Write(context, StatusCodes.Status400BadRequest, "invalid-request",
                "The request body must be valid JSON within the supported nesting limit.");
            return;
        }
        finally
        {
            request.Body.Position = 0;
        }

        await next(context);
    }
}
