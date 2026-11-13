using HotChocolate;
using HotChocolate.Execution;

using Microsoft.Extensions.Logging;

namespace ArtisanLogbook.Runtime.GraphQL;

internal sealed class HistoryErrorFilter(ILogger<HistoryErrorFilter> logger) : IErrorFilter
{
    public IError OnError(IError error)
    {
        if (error.Exception is not null and not OperationCanceledException)
            logger.LogError(error.Exception, "GraphQL execution failed.");
        return error;
    }
}
