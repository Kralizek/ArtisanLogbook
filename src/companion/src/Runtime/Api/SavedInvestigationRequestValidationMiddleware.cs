using System.Text.Json;

using Microsoft.AspNetCore.Http;

namespace ArtisanLogbook.Runtime;

internal sealed class SavedInvestigationRequestValidationMiddleware(RequestDelegate next)
{
    public async Task InvokeAsync(HttpContext context)
    {
        HttpRequest request = context.Request;
        if (!(HttpMethods.IsPost(request.Method) || HttpMethods.IsPut(request.Method)) ||
            !ApplicationStateRoutePaths.IsSavedInvestigation(request.Path))
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

internal static class ApplicationStateRoutePaths
{
    public static bool IsSavedInvestigation(PathString path)
    {
        string[] segments = path.Value?.Split('/', StringSplitOptions.RemoveEmptyEntries) ?? [];
        return segments.Length >= 3 &&
            string.Equals(segments[0], "api", StringComparison.Ordinal) &&
            string.Equals(segments[1], "v1", StringComparison.Ordinal) &&
            (string.Equals(segments[2], "saved-investigations", StringComparison.Ordinal) ||
             segments.Length == 4 &&
             string.Equals(segments[3], "saved-investigations", StringComparison.Ordinal));
    }
}
