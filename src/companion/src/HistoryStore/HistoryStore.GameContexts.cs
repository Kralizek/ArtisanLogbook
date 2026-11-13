using ArtisanLogbook.History;

using Dapper;

namespace ArtisanLogbook.HistoryStore;

public sealed partial class HistoryStore
{
    public GameContextPage QueryGameContexts(int first = 20, GameContext? after = null,
        CancellationToken cancellationToken = default)
    {
        if (first is < 1 or > MaximumDimensionPageSize)
            throw new ArgumentOutOfRangeException(nameof(first));
        return ReadSnapshot((transaction, token) =>
        {
            List<GameContext> contexts = [];
            foreach ((int ProjectId, string? Track) row in transaction.Connection!.Query<(int, string?)>(
                after is null
                    ? "SELECT ProjectId, ProgressionTrack FROM GameContext ORDER BY ContextKey LIMIT $Limit"
                    : "SELECT ProjectId, ProgressionTrack FROM GameContext WHERE ContextKey > $After ORDER BY ContextKey LIMIT $Limit",
                new { Limit = first + 1, After = after is null ? null : ContextKey(after) },
                transaction, buffered: false))
            {
                token.ThrowIfCancellationRequested();
                contexts.Add(new((GameProject)row.ProjectId, row.Track));
            }
            bool hasNext = contexts.Count > first;
            if (hasNext) contexts.RemoveAt(first);
            token.ThrowIfCancellationRequested();
            return new GameContextPage(contexts, hasNext, contexts.LastOrDefault());
        }, cancellationToken);
    }

    public IReadOnlyList<GameContext> ReadGameContexts(
        IReadOnlyCollection<GameContext> contexts, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(contexts);
        if (contexts.Count > MaximumDimensionBatchSize || contexts.Any(context => context is null))
            throw new ArgumentException("The context batch is invalid or too large.", nameof(contexts));
        return ReadSnapshot((transaction, token) =>
        {
            if (contexts.Count == 0) return [];
            string[] keys = contexts.Select(ContextKey).Distinct().ToArray();
            List<GameContext> result = [];
            foreach ((int ProjectId, string? Track) row in transaction.Connection!.Query<(int, string?)>("""
                SELECT ProjectId, ProgressionTrack FROM GameContext
                WHERE ContextKey IN $keys ORDER BY ContextKey
                """, new { keys }, transaction, buffered: false))
            {
                token.ThrowIfCancellationRequested();
                result.Add(new((GameProject)row.ProjectId, row.Track));
            }
            token.ThrowIfCancellationRequested();
            return (IReadOnlyList<GameContext>)result;
        }, cancellationToken);
    }
}
