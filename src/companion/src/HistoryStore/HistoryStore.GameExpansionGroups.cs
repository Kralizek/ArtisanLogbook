using System.Data.Common;
using System.Text;

using ArtisanLogbook.History;

using Dapper;

namespace ArtisanLogbook.HistoryStore;

public sealed partial class HistoryStore
{
    public const int MaximumExpansionGroupKeys = 500;

    /// <summary>Bounded context-scoped choices with recorded craft membership, not merely known dimensions.</summary>
    public (IReadOnlyList<GameExpansionGroup> Groups, bool Truncated) QueryGameExpansionGroups(
        GameContext game, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(game);
        return ReadSnapshot((transaction, token) =>
        {
            token.ThrowIfCancellationRequested();
            ExpansionGroupRow[] rows = transaction.Connection!.Query<ExpansionGroupRow>(new CommandDefinition("""
                SELECT DISTINCT c.ProfessionExpansionKey AS ExpansionKey, e.Name
                FROM Craft c LEFT JOIN Expansion e ON e.ContextKey = c.ContextKey
                    AND e.ExpansionKey = c.ProfessionExpansionKey
                WHERE c.ContextKey = $ContextKey AND c.ProfessionExpansionKey IS NOT NULL
                ORDER BY c.ProfessionExpansionKey
                LIMIT $Limit
                """, new { ContextKey = ContextKey(game), Limit = MaximumExpansionGroupKeys + 1 },
                transaction, cancellationToken: token)).ToArray();
            token.ThrowIfCancellationRequested();
            GameExpansionGroup[] groups = rows.Take(MaximumExpansionGroupKeys)
                .GroupBy(row => GameExpansionGroups.GroupKey(game, row.ExpansionKey), StringComparer.Ordinal)
                .Select(group => new GameExpansionGroup(game, group.Key,
                    group.Select(row => row.Name).FirstOrDefault(name => name is not null),
                    group.Select(row => row.ExpansionKey).ToArray()))
                .OrderBy(group => group.Key, StringComparer.Ordinal).ToArray();
            return ((IReadOnlyList<GameExpansionGroup>)groups, rows.Length > MaximumExpansionGroupKeys);
        }, cancellationToken);
    }

    private static void AppendGameExpansionGroupFilter(StringBuilder sql, DynamicParameters parameters,
        GameContext game, string? groupKey)
    {
        if (groupKey is null) return;
        IReadOnlyList<string> keys = GameExpansionGroups.MemberKeys(game, groupKey)!;
        sql.Append(" AND (");
        for (int i = 0; i < keys.Count; i++)
        {
            if (i > 0) sql.Append(" OR ");
            sql.Append($"c.ProfessionExpansionKey = $GameExpansionKey{i}");
            parameters.Add($"GameExpansionKey{i}", keys[i]);
        }
        sql.Append(')');
    }

    private sealed class ExpansionGroupRow
    {
        public string ExpansionKey { get; set; } = "";
        public string? Name { get; set; }
    }
}
