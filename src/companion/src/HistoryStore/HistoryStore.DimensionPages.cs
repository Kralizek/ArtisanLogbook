using System.Globalization;
using System.Text;

using ArtisanLogbook.History;

using Dapper;

namespace ArtisanLogbook.HistoryStore;

public sealed partial class HistoryStore
{
    public const int MaximumDimensionPageSize = 100;

    public DimensionPage<CharacterDimension, CharacterIdentity> QueryCharacters(
        GameContext? game = null, int first = 20, DimensionIdentity<CharacterIdentity>? after = null,
        CancellationToken cancellationToken = default) =>
        QueryDimensions(game, first, after, "Character", "IdentityKey", "d.Name, d.ClassFile AS Text1", null, null,
            key => key.Key, row => new CharacterIdentity(row.Key),
            (row, context) => new CharacterDimension(context, new(row.Key), row.Name, row.Text1), cancellationToken);

    public DimensionPage<RecipeDimension, int> QueryRecipes(
        RecipeQuery query, int first = 20, DimensionIdentity<int>? after = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(query);
        if (query.ProfessionId is <= 0 ||
            (query.ExpansionKey is not null && string.IsNullOrWhiteSpace(query.ExpansionKey)) ||
            (query.Game is null && (query.ProfessionId is not null || query.ExpansionKey is not null)))
            throw new ArgumentException("Recipe criteria must be valid and scoped to a game context.", nameof(query));
        DynamicParameters filters = new();
        StringBuilder conditions = new();
        if (query.ProfessionId is int profession)
        {
            conditions.Append(" AND d.ProfessionId = $ProfessionId");
            filters.Add("ProfessionId", profession);
        }
        if (query.ExpansionKey is string expansion)
        {
            conditions.Append(" AND d.ProfessionExpansionKey = $ExpansionKey");
            filters.Add("ExpansionKey", expansion);
        }
        return QueryDimensions(query.Game, first, after, "Recipe", "RecipeId",
            "d.Name, d.ProfessionId AS Number1, d.ProfessionExpansionKey AS Text1, d.MaxQuality AS Number2",
            conditions.ToString(), filters, key => key, row => int.Parse(row.Key, CultureInfo.InvariantCulture),
            (row, context) => new RecipeDimension(context, int.Parse(row.Key, CultureInfo.InvariantCulture),
                row.Name, row.Number1, row.Text1, row.Number2), cancellationToken);
    }

    public DimensionPage<ProfessionDimension, int> QueryProfessions(
        ProfessionQuery query, int first = 20, DimensionIdentity<int>? after = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(query);
        if (query.ParentId is <= 0 || (query.ParentId is not null && query.Game is null))
            throw new ArgumentException("Profession criteria must be valid and scoped to a game context.", nameof(query));
        DynamicParameters filters = new();
        filters.Add("ParentId", query.ParentId);
        return QueryDimensions(query.Game, first, after, "Profession", "ProfessionId", "d.Name, d.ParentId AS Number1",
            query.ParentId is null ? null : " AND d.ParentId = $ParentId", filters, key => key,
            row => int.Parse(row.Key, CultureInfo.InvariantCulture),
            (row, context) => new ProfessionDimension(context, int.Parse(row.Key, CultureInfo.InvariantCulture), row.Name, row.Number1),
            cancellationToken);
    }

    public DimensionPage<ItemDimension, int> QueryItems(
        GameContext? game = null, int first = 20, DimensionIdentity<int>? after = null,
        CancellationToken cancellationToken = default) =>
        QueryDimensions(game, first, after, "Item", "ItemId", "d.Name", null, null, key => key,
            row => int.Parse(row.Key, CultureInfo.InvariantCulture),
            (row, context) => new ItemDimension(context, int.Parse(row.Key, CultureInfo.InvariantCulture), row.Name), cancellationToken);

    public DimensionPage<ExpansionDimension, string> QueryExpansions(
        GameContext? game = null, int first = 20, DimensionIdentity<string>? after = null,
        CancellationToken cancellationToken = default) =>
        QueryDimensions(game, first, after, "Expansion", "ExpansionKey", "d.Name", null, null, key => key,
            row => row.Key, (row, context) => new ExpansionDimension(context, row.Key, row.Name), cancellationToken);

    private DimensionPage<TResult, TKey> QueryDimensions<TKey, TSqlKey, TResult>(
        GameContext? game, int first, DimensionIdentity<TKey>? after, string table, string keyColumn, string columns,
        string? conditions, DynamicParameters? filters, Func<TKey, TSqlKey> sqlKey, Func<DimensionPageRow, TKey> key,
        Func<DimensionPageRow, GameContext, TResult> materialize, CancellationToken cancellationToken) where TKey : notnull
    {
        if (first is < 1 or > MaximumDimensionPageSize)
            throw new ArgumentOutOfRangeException(nameof(first));
        if (after is not null)
        {
            ValidateDimensionIdentities([after]);
            if (game is not null && game != after.Game)
                throw new ArgumentException("Continuation position belongs to another game context.", nameof(after));
        }
        return ReadSnapshot((transaction, token) =>
        {
            DynamicParameters parameters = new(filters);
            parameters.Add("Limit", first + 1);
            StringBuilder sql = new($"""
                SELECT d.ContextKey, CAST(d.{keyColumn} AS VARCHAR) AS Key, g.ProjectId, g.ProgressionTrack, {columns}
                FROM {table} d JOIN GameContext g ON g.ContextKey = d.ContextKey
                WHERE TRUE
                """);
            if (game is not null)
            {
                sql.Append(" AND d.ContextKey = $Game");
                parameters.Add("Game", ContextKey(game));
            }
            if (after is not null)
            {
                sql.Append($" AND (d.ContextKey > $AfterContext OR (d.ContextKey = $AfterContext AND d.{keyColumn} > $AfterKey))");
                parameters.Add("AfterContext", ContextKey(after.Game));
                parameters.Add("AfterKey", sqlKey(after.Key));
            }
            sql.Append(conditions);
            sql.Append($" ORDER BY d.ContextKey, d.{keyColumn} LIMIT $Limit");
            List<DimensionPageRow> rows = [];
            foreach (DimensionPageRow row in transaction.Connection!.Query<DimensionPageRow>(
                sql.ToString(), parameters, transaction, buffered: false))
            {
                token.ThrowIfCancellationRequested();
                rows.Add(row);
            }
            bool hasNext = rows.Count > first;
            if (hasNext) rows.RemoveAt(first);
            List<TResult> items = [];
            DimensionIdentity<TKey>? end = null;
            foreach (DimensionPageRow row in rows)
            {
                token.ThrowIfCancellationRequested();
                GameContext context = new((GameProject)row.ProjectId, row.ProgressionTrack);
                items.Add(materialize(row, context));
                end = new(context, key(row));
            }
            return new DimensionPage<TResult, TKey>(items, hasNext, end);
        }, cancellationToken);
    }

    private sealed class DimensionPageRow
    {
        public string Key { get; set; } = null!;
        public int ProjectId { get; set; }
        public string? ProgressionTrack { get; set; }
        public string? Name { get; set; }
        public string? Text1 { get; set; }
        public int? Number1 { get; set; }
        public int? Number2 { get; set; }
    }
}
