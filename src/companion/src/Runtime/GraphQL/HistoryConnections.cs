using System.Globalization;

using ArtisanLogbook.History;
using ArtisanLogbook.Runtime.History;

using HotChocolate;

namespace ArtisanLogbook.Runtime.GraphQL;

public sealed record HistoryPageInfo(bool HasNextPage, string? EndCursor);
public sealed record CraftConnection(IReadOnlyList<CraftGraph> Nodes, HistoryPageInfo PageInfo);
public sealed record CharacterConnection(IReadOnlyList<CharacterGraph> Nodes, HistoryPageInfo PageInfo);
public sealed record RecipeConnection(IReadOnlyList<RecipeGraph> Nodes, HistoryPageInfo PageInfo);
public sealed record ProfessionConnection(IReadOnlyList<ProfessionGraph> Nodes, HistoryPageInfo PageInfo);
public sealed record ExpansionConnection(IReadOnlyList<ExpansionGraph> Nodes, HistoryPageInfo PageInfo);
public sealed record ItemConnection(IReadOnlyList<ItemGraph> Nodes, HistoryPageInfo PageInfo);
public sealed record GameContextConnection(IReadOnlyList<GameContextGraph> Nodes, HistoryPageInfo PageInfo);

internal static class HistoryConnections
{
    public static CraftConnection Crafts(ICraftHistoryRepository repository, CraftQuery query, int first, string? after, CancellationToken token)
    {
        ValidatePageSize(first);
        CraftPage page = repository.Query(query, first, after is null ? null : HistoryTokens.ParseCraftCursor(after), token);
        return Crafts(page);
    }

    public static CraftConnection Crafts(CraftPage page)
    {
        return new(page.Crafts.Select(craft => new CraftGraph(craft)).ToArray(),
            new(page.HasNextPage, page.EndPosition is null ? null : HistoryTokens.CraftCursor(page.EndPosition)));
    }

    public static CharacterConnection Characters(IHistoryDimensionRepository repository, GameContext? game, int first, string? after, CancellationToken token)
    {
        ValidatePageSize(first);
        DimensionIdentity<CharacterIdentity>? position = null;
        if (after is not null)
        {
            (GameContext context, string key) = HistoryTokens.ParseDimension(after, "cursor:character");
            position = new(context, new(key));
            ValidateContext(game, context);
        }
        DimensionPage<CharacterDimension, CharacterIdentity> page = repository.Characters(game, first, position, token);
        return new(page.Items.Select(x => new CharacterGraph(x)).ToArray(),
            new(page.HasNextPage, page.EndPosition is null ? null : HistoryTokens.CharacterCursor(page.EndPosition)));
    }

    public static RecipeConnection Recipes(IHistoryDimensionRepository repository, RecipeQuery query, int first, string? after, CancellationToken token)
    {
        ValidatePageSize(first);
        DimensionIdentity<int>? position = IntegerCursor(after, "recipe", query.Game);
        DimensionPage<RecipeDimension, int> page = repository.Recipes(query, first, position, token);
        return new(page.Items.Select(x => new RecipeGraph(x)).ToArray(),
            new(page.HasNextPage, page.EndPosition is null ? null : HistoryTokens.DimensionCursor("recipe", page.EndPosition)));
    }

    public static ProfessionConnection Professions(IHistoryDimensionRepository repository, ProfessionQuery query, int first, string? after, CancellationToken token)
    {
        ValidatePageSize(first);
        DimensionIdentity<int>? position = IntegerCursor(after, "profession", query.Game);
        DimensionPage<ProfessionDimension, int> page = repository.Professions(query, first, position, token);
        return new(page.Items.Select(x => new ProfessionGraph(x)).ToArray(),
            new(page.HasNextPage, page.EndPosition is null ? null : HistoryTokens.DimensionCursor("profession", page.EndPosition)));
    }

    public static ItemConnection Items(IHistoryDimensionRepository repository, GameContext? game, int first, string? after, CancellationToken token)
    {
        ValidatePageSize(first);
        DimensionIdentity<int>? position = IntegerCursor(after, "item", game);
        DimensionPage<ItemDimension, int> page = repository.Items(game, first, position, token);
        return new(page.Items.Select(x => new ItemGraph(x)).ToArray(),
            new(page.HasNextPage, page.EndPosition is null ? null : HistoryTokens.DimensionCursor("item", page.EndPosition)));
    }

    public static ExpansionConnection Expansions(IHistoryDimensionRepository repository, GameContext? game, int first, string? after, CancellationToken token)
    {
        ValidatePageSize(first);
        DimensionIdentity<string>? position = null;
        if (after is not null)
        {
            (GameContext context, string key) = HistoryTokens.ParseDimension(after, "cursor:expansion");
            ValidateContext(game, context);
            position = new(context, key);
        }
        DimensionPage<ExpansionDimension, string> page = repository.Expansions(game, first, position, token);
        return new(page.Items.Select(x => new ExpansionGraph(x)).ToArray(),
            new(page.HasNextPage, page.EndPosition is null ? null : HistoryTokens.DimensionCursor("expansion", page.EndPosition)));
    }

    public static GameContextConnection GameContexts(IHistoryDimensionRepository repository, int first, string? after, CancellationToken token)
    {
        ValidatePageSize(first);
        GameContextPage page = repository.GameContexts(first,
            after is null ? null : HistoryTokens.ParseDimension(after, "cursor:context").Game, token);
        return new(page.Items.Select(x => new GameContextGraph(x)).ToArray(),
            new(page.HasNextPage, page.EndPosition is null ? null : HistoryTokens.Dimension("cursor:context", page.EndPosition, "")));
    }

    private static DimensionIdentity<int>? IntegerCursor(string? cursor, string kind, GameContext? game)
    {
        if (cursor is null) return null;
        DimensionIdentity<int> position = HistoryTokens.ParseIntegerDimension(cursor, "cursor:" + kind);
        ValidateContext(game, position.Game);
        return position;
    }

    private static void ValidateContext(GameContext? expected, GameContext actual)
    {
        if (expected is not null && expected != actual)
            throw new GraphQLException(ErrorBuilder.New().SetMessage("The cursor belongs to a different game context.")
                .SetCode("INVALID_CURSOR").Build());
    }

    public static void ValidatePageSize(int first)
    {
        if (first is < 1 or > 100)
            throw new GraphQLException(ErrorBuilder.New().SetMessage("The page size must be between 1 and 100.")
                .SetCode("INVALID_PAGE_SIZE").Build());
    }
}
