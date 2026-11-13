using ArtisanLogbook.History;
using ArtisanLogbook.Runtime.History;

using HotChocolate;
using HotChocolate.CostAnalysis.Types;
using HotChocolate.Types;

namespace ArtisanLogbook.Runtime.GraphQL;

public sealed record CraftFilter(
    [property: GraphQLType(typeof(IdType))] string? GameId = null,
    [property: GraphQLType(typeof(IdType))] string? CharacterId = null,
    [property: GraphQLType(typeof(IdType))] string? RecipeId = null,
    [property: GraphQLType(typeof(IdType))] string? ProfessionId = null,
    [property: GraphQLType(typeof(IdType))] string? ExpansionId = null,
    DateTimeOffset? From = null,
    DateTimeOffset? To = null,
    [property: GraphQLType(typeof(IdType))] string? InputItemId = null,
    [property: GraphQLType(typeof(IdType))] string? OutputItemId = null);

[GraphQLName("Query")]
public sealed class HistoryQuery
{
    public CraftGraph? GetCraft([GraphQLType(typeof(NonNullType<IdType>))] string id,
        ICraftHistoryRepository repository, CancellationToken token)
    {
        CraftPage page = repository.Query(new(Identity: HistoryTokens.ParseCraft(id)), 1, cancellationToken: token);
        return page.Crafts.Count == 0 ? null : new(page.Crafts[0].Facts);
    }

    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public CraftConnection GetCrafts(ICraftHistoryRepository repository, int first = 20, string? after = null,
        CraftFilter? filter = null, CancellationToken token = default) =>
        HistoryConnections.Crafts(repository, ToQuery(filter), first, after, token);

    public async Task<CharacterGraph?> GetCharacterAsync([GraphQLType(typeof(NonNullType<IdType>))] string id,
        CharacterLoader loader, CancellationToken token)
    {
        (GameContext game, string key) = HistoryTokens.ParseDimension(id, "character");
        CharacterDimension? result = await loader.LoadAsync(new DimensionIdentity<CharacterIdentity>(game, new(key)), token);
        return result is null ? null : new(result);
    }

    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public CharacterConnection GetCharacters(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) => HistoryConnections.Characters(repository, null, first, after, token);

    public async Task<RecipeGraph?> GetRecipeAsync([GraphQLType(typeof(NonNullType<IdType>))] string id,
        RecipeLoader loader, CancellationToken token)
    {
        RecipeDimension? result = await loader.LoadAsync(HistoryTokens.ParseIntegerDimension(id, "recipe"), token);
        return result is null ? null : new(result);
    }

    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public RecipeConnection GetRecipes(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        string? search = null, CancellationToken token = default) =>
        HistoryConnections.Recipes(repository, new(Search: search), first, after, token);

    public async Task<ProfessionGraph?> GetProfessionAsync([GraphQLType(typeof(NonNullType<IdType>))] string id,
        ProfessionLoader loader, CancellationToken token)
    {
        ProfessionDimension? result = await loader.LoadAsync(HistoryTokens.ParseIntegerDimension(id, "profession"), token);
        return result is null ? null : new(result);
    }

    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public ProfessionConnection GetProfessions(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) => HistoryConnections.Professions(repository, new(), first, after, token);

    public async Task<ItemGraph?> GetItemAsync([GraphQLType(typeof(NonNullType<IdType>))] string id,
        ItemLoader loader, CancellationToken token)
    {
        ItemDimension? result = await loader.LoadAsync(HistoryTokens.ParseIntegerDimension(id, "item"), token);
        return result is null ? null : new(result);
    }

    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public ItemConnection GetItems(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        string? search = null, CancellationToken token = default) =>
        HistoryConnections.Items(repository, new(Search: search), first, after, token);

    public async Task<ExpansionGraph?> GetExpansionAsync([GraphQLType(typeof(NonNullType<IdType>))] string id,
        ExpansionLoader loader, CancellationToken token)
    {
        (GameContext game, string key) = HistoryTokens.ParseDimension(id, "expansion");
        ExpansionDimension? result = await loader.LoadAsync(new DimensionIdentity<string>(game, key), token);
        return result is null ? null : new(result);
    }

    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public ExpansionConnection GetExpansions(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) => HistoryConnections.Expansions(repository, null, first, after, token);

    public GameContextGraph? GetGameContext([GraphQLType(typeof(NonNullType<IdType>))] string id,
        IHistoryDimensionRepository repository, CancellationToken token)
    {
        GameContext game = HistoryTokens.ParseContext(id);
        return repository.GameContexts([game], token).Count == 0 ? null : new(game);
    }

    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public GameContextConnection GetGameContexts(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) => HistoryConnections.GameContexts(repository, first, after, token);

    private static CraftQuery ToQuery(CraftFilter? filter)
    {
        if (filter is null) return new();
        GameContext? game = filter.GameId is null ? null : HistoryTokens.ParseContext(filter.GameId);
        CharacterIdentity? character = null;
        int? recipe = null;
        int? profession = null;
        string? expansion = null;
        int? input = null;
        int? output = null;
        if (filter.CharacterId is not null)
        {
            (GameContext context, string key) = HistoryTokens.ParseDimension(filter.CharacterId, "character");
            MergeContext(context);
            character = new(key);
        }
        if (filter.RecipeId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(filter.RecipeId, "recipe");
            MergeContext(id.Game);
            recipe = id.Key;
        }
        if (filter.ProfessionId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(filter.ProfessionId, "profession");
            MergeContext(id.Game);
            profession = id.Key;
        }
        if (filter.ExpansionId is not null)
        {
            (GameContext context, string key) = HistoryTokens.ParseDimension(filter.ExpansionId, "expansion");
            MergeContext(context);
            expansion = key;
        }
        if (filter.InputItemId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(filter.InputItemId, "item");
            MergeContext(id.Game);
            input = id.Key;
        }
        if (filter.OutputItemId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(filter.OutputItemId, "item");
            MergeContext(id.Game);
            output = id.Key;
        }
        if (filter.From > filter.To)
            throw InvalidFilter();
        return new(game, character, recipe, profession, expansion, filter.From, filter.To, input, output);

        void MergeContext(GameContext context)
        {
            if (game is not null && game != context) throw InvalidFilter();
            game = context;
        }
    }

    private static GraphQLException InvalidFilter() =>
        new(ErrorBuilder.New().SetMessage("The craft filter is invalid or contains identities from different game contexts.")
            .SetCode("INVALID_FILTER").Build());
}
