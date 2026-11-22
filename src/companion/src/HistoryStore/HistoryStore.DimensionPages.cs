using System.Globalization;
using System.Text;

using ArtisanLogbook.History;

using Dapper;

namespace ArtisanLogbook.HistoryStore;

public sealed partial class HistoryStore
{
    public const int MaximumDimensionPageSize = 100;

    // A literal, case-insensitive name substring; a whole number (optionally "#"-prefixed) also matches that ID.
    private static string SearchCondition(string keyColumn, string search, DynamicParameters filters)
    {
        filters.Add("Search", search);
        string number = search.Trim().TrimStart('#');
        if (number.Length == 0 || !number.All(char.IsAsciiDigit) ||
            !int.TryParse(number, NumberStyles.None, CultureInfo.InvariantCulture, out int id))
            return " AND contains(lower(d.Name), lower($Search))";
        filters.Add("SearchId", id);
        return $" AND (contains(lower(d.Name), lower($Search)) OR d.{keyColumn} = $SearchId)";
    }

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
        if (!string.IsNullOrEmpty(query.Search))
            conditions.Append(SearchCondition("RecipeId", query.Search, filters));
        if (query.CraftedOnly)
            conditions.Append(" AND EXISTS (SELECT 1 FROM Craft c WHERE c.ContextKey = d.ContextKey AND c.RecipeId = d.RecipeId)");
        return QueryDimensions(query.Game, first, after, "Recipe", "RecipeId",
            "d.Name, d.ProfessionId AS Number1, d.ProfessionExpansionKey AS Text1, d.MaxQuality AS Number2",
            conditions.ToString(), filters, key => key, row => int.Parse(row.Key, CultureInfo.InvariantCulture),
            (row, context) => new RecipeDimension(context, int.Parse(row.Key, CultureInfo.InvariantCulture),
                row.Name, row.Number1, row.Text1, row.Number2), cancellationToken,
            RecipeOrder(query.Order), query.Descending);
    }

    // Sort values for a recipe row with the given alias; null orders by recipe ID alone.
    private static Func<string, string>? RecipeOrder(CatalogueOrder order) => order switch
    {
        CatalogueOrder.Name => NameOrder,
        CatalogueOrder.Number => null,
        CatalogueOrder.Profession => alias => $"""
            COALESCE((SELECT {NameOrder("p")} FROM Profession p
                WHERE p.ContextKey = {alias}.ContextKey AND p.ProfessionId = {alias}.ProfessionId), '2')
            """,
        CatalogueOrder.Crafts => alias =>
            $"(SELECT COUNT(*) FROM Craft c WHERE c.ContextKey = {alias}.ContextKey AND c.RecipeId = {alias}.RecipeId)",
        CatalogueOrder.LastCrafted => alias => $"""
            COALESCE((SELECT MAX(CAST(c.RecordedAt AS TIMESTAMPTZ)) FROM Craft c
                WHERE c.ContextKey = {alias}.ContextKey AND c.RecipeId = {alias}.RecipeId), TIMESTAMPTZ '0001-01-01 00:00:00+00')
            """,
        _ => throw new ArgumentOutOfRangeException(nameof(order))
    };

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
        ItemQuery query, int first = 20, DimensionIdentity<int>? after = null,
        CancellationToken cancellationToken = default) =>
        QueryItemsCore(query, first, after, cancellationToken);

    private DimensionPage<ItemDimension, int> QueryItemsCore(
        ItemQuery query, int first, DimensionIdentity<int>? after, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        DynamicParameters? filters = null;
        string? conditions = null;
        if (!string.IsNullOrEmpty(query.Search))
        {
            filters = new();
            conditions = SearchCondition("ItemId", query.Search, filters);
        }
        return QueryDimensions(query.Game, first, after, "Item", "ItemId", "d.Name, d.Quality AS Number1", conditions, filters,
            key => key, row => int.Parse(row.Key, CultureInfo.InvariantCulture),
            (row, context) => new ItemDimension(context, int.Parse(row.Key, CultureInfo.InvariantCulture), row.Name, row.Number1),
            cancellationToken, query.Order switch
            {
                CatalogueOrder.Name => NameOrder,
                CatalogueOrder.Number => null,
                _ => throw new ArgumentException("Items can be ordered by name or number only.", nameof(query))
            }, query.Descending);
    }

    public DimensionPage<ExpansionDimension, string> QueryExpansions(
        GameContext? game = null, int first = 20, DimensionIdentity<string>? after = null,
        CancellationToken cancellationToken = default) =>
        QueryDimensions(game, first, after, "Expansion", "ExpansionKey", "d.Name", null, null, key => key,
            row => row.Key, (row, context) => new ExpansionDimension(context, row.Key, row.Name), cancellationToken);

    private DimensionPage<TResult, TKey> QueryDimensions<TKey, TSqlKey, TResult>(
        GameContext? game, int first, DimensionIdentity<TKey>? after, string table, string keyColumn, string columns,
        string? conditions, DynamicParameters? filters, Func<TKey, TSqlKey> sqlKey, Func<DimensionPageRow, TKey> key,
        Func<DimensionPageRow, GameContext, TResult> materialize, CancellationToken cancellationToken,
        Func<string, string>? sortValue = null, bool descending = false)
        where TKey : notnull
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
            // Rows are ordered by context, then the sort value, then the key, with the sort value and key in the
            // requested direction. A continuation resumes after the position the last row currently sorts to, so the
            // cursor stays the row's key; if that row no longer exists, the page ends.
            string op = descending ? "<" : ">", direction = descending ? "DESC" : "ASC";
            if (after is not null)
            {
                string tie = $"d.{keyColumn} {op} $AfterKey";
                string within = tie;
                if (sortValue is not null)
                {
                    string afterValue =
                        $"(SELECT {sortValue("a")} FROM {table} a WHERE a.ContextKey = $AfterContext AND a.{keyColumn} = $AfterKey)";
                    within = $"({sortValue("d")} {op} {afterValue} OR ({sortValue("d")} = {afterValue} AND {tie}))";
                }
                sql.Append($" AND (d.ContextKey > $AfterContext OR (d.ContextKey = $AfterContext AND {within}))");
                parameters.Add("AfterContext", ContextKey(after.Game));
                parameters.Add("AfterKey", sqlKey(after.Key));
            }
            sql.Append(conditions);
            sql.Append(sortValue is null
                ? $" ORDER BY d.ContextKey, d.{keyColumn} {direction} LIMIT $Limit"
                : $" ORDER BY d.ContextKey, {sortValue("d")} {direction}, d.{keyColumn} {direction} LIMIT $Limit");
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

    // A sortable name key: named rows first by lower-cased name, unnamed rows ("1") after them.
    private static string NameOrder(string alias) =>
        $"(CASE WHEN {alias}.Name IS NULL THEN '1' ELSE '0' || lower({alias}.Name) END)";

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
