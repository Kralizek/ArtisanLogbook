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
    [property: GraphQLType(typeof(IdType))] string? OutputItemId = null,
    [property: GraphQLType(typeof(IdType))] string? ReturnedItemId = null,
    [property: GraphQLType(typeof(IdType))] string? ItemId = null,
    [property: GraphQLType(typeof(IdType))] string? ConfigurationId = null,
    int? BuffSpellId = null,
    [property: GraphQLType(typeof(IdType))] string? FinishingItemId = null,
    int? AbsentBuffSpellId = null,
    [property: GraphQLType(typeof(IdType))] string? AbsentFinishingItemId = null,
    [property: GraphQLType(typeof(IdType))] string? AbsentInputItemId = null,
    [property: GraphQLType(typeof(IdType))] string? GameExpansionId = null);

[GraphQLName("Query")]
public sealed class HistoryQuery
{
    public GameContextGraph GetGame(string context)
    {
        if (!GameContextCodec.TryDecode(context, out GameContext? game))
            throw InvalidFilter();
        return new(game!);
    }

    public AnalysisGraph GetAnalysis(string context, IHistoryAnalysisRepository repository,
        CraftFilter? filter = null, AnalysisGranularity granularity = AnalysisGranularity.Day,
        [GraphQLType(typeof(IdType))] string? returnItemId = null,
        CancellationToken token = default)
    {
        CraftQuery query = ScopedQuery(context, filter);
        int? item = null;
        if (returnItemId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(returnItemId, "item");
            if (id.Game != query.Game || query.Game!.Project != GameProject.Retail) throw InvalidFilter();
            item = id.Key;
        }
        return new(query.Game!, repository.Analyze(new(query, granularity, item), token));
    }

    public string GetAnalysisSignature(string context, IHistoryAnalysisRepository repository,
        CraftFilter? filter = null, CancellationToken token = default) =>
        repository.Signature(ScopedQuery(context, filter), token);

    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public CraftConnection GetContextCrafts(string context, ICraftHistoryRepository repository,
        CraftFilter? filter = null, int first = 20, string? after = null, CancellationToken token = default) =>
        HistoryConnections.Crafts(repository, ScopedQuery(context, filter), first, after, token);

    public CraftGraph? GetContextCraft(string context, [GraphQLType(typeof(NonNullType<IdType>))] string id,
        ICraftHistoryRepository repository, CancellationToken token)
    {
        CraftQuery query = ScopedQuery(context, null) with { Identity = HistoryTokens.ParseCraft(id) };
        CraftPage page = repository.Query(query, 1, cancellationToken: token);
        return page.Crafts.Count == 0 ? null : new(page.Crafts[0].Facts);
    }

    public RecipeGraph? GetContextRecipe(string context, [GraphQLType(typeof(NonNullType<IdType>))] string id,
        IHistoryDimensionRepository repository, CancellationToken token)
    {
        GameContext game = ScopedQuery(context, null).Game!;
        DimensionIdentity<int> recipe = HistoryTokens.ParseIntegerDimension(id, "recipe");
        if (recipe.Game != game) throw InvalidFilter();
        return repository.Recipes([recipe], token).Select(row => new RecipeGraph(row)).SingleOrDefault();
    }

    public ItemGraph? GetContextItem(string context, [GraphQLType(typeof(NonNullType<IdType>))] string id,
        IHistoryDimensionRepository repository, CancellationToken token)
    {
        GameContext game = ScopedQuery(context, null).Game!;
        DimensionIdentity<int> item = HistoryTokens.ParseIntegerDimension(id, "item");
        if (item.Game != game) throw InvalidFilter();
        return repository.Items([item], token).Select(row => new ItemGraph(row)).SingleOrDefault();
    }

    private static CraftQuery ScopedQuery(string context, CraftFilter? filter)
    {
        if (!GameContextCodec.TryDecode(context, out GameContext? game)) throw InvalidFilter();
        CraftQuery query = ToQuery(filter);
        if (query.Game is not null && query.Game != game) throw InvalidFilter();
        return query with { Game = game };
    }

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

    internal static CraftQuery ToQuery(CraftFilter? filter)
    {
        if (filter is null) return new();
        GameContext? game = filter.GameId is null ? null : HistoryTokens.ParseContext(filter.GameId);
        CharacterIdentity? character = null;
        int? recipe = null;
        int? profession = null;
        string? expansion = null;
        string? gameExpansion = null;
        int? input = null;
        int? output = null;
        int? returned = null;
        int? item = null;
        int? finishing = null;
        int? absentFinishing = null;
        int? absentInput = null;
        string? configuration = null;
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
        if (filter.GameExpansionId is not null)
        {
            (GameContext context, string key) = HistoryTokens.ParseDimension(filter.GameExpansionId, "game-expansion");
            MergeContext(context);
            if (GameExpansionGroups.MemberKeys(context, key) is null) throw InvalidFilter();
            gameExpansion = key;
        }
        if (filter.InputItemId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(filter.InputItemId, "item");
            MergeContext(id.Game);
            input = id.Key;
        }
        if (filter.AbsentInputItemId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(filter.AbsentInputItemId, "item");
            MergeContext(id.Game);
            absentInput = id.Key;
        }
        if (filter.OutputItemId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(filter.OutputItemId, "item");
            MergeContext(id.Game);
            output = id.Key;
        }
        if (filter.ReturnedItemId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(filter.ReturnedItemId, "item");
            MergeContext(id.Game);
            returned = id.Key;
        }
        if (filter.ItemId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(filter.ItemId, "item");
            MergeContext(id.Game);
            item = id.Key;
        }
        if (filter.FinishingItemId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(filter.FinishingItemId, "item");
            MergeContext(id.Game);
            finishing = id.Key;
        }
        if (filter.AbsentFinishingItemId is not null)
        {
            DimensionIdentity<int> id = HistoryTokens.ParseIntegerDimension(filter.AbsentFinishingItemId, "item");
            MergeContext(id.Game);
            absentFinishing = id.Key;
        }
        if (filter.BuffSpellId is <= 0 || filter.AbsentBuffSpellId is <= 0) throw InvalidFilter();
        if (filter.ConfigurationId is not null)
        {
            (GameContext context, string signature) = HistoryTokens.ParseDimension(filter.ConfigurationId, "configuration");
            MergeContext(context);
            if (signature.Length != 64 || signature.Any(c => c is not (>= '0' and <= '9' or >= 'a' and <= 'f')))
                throw InvalidFilter();
            configuration = signature;
        }
        if (filter.From > filter.To)
            throw InvalidFilter();
        return new(game, character, recipe, profession, expansion, filter.From, filter.To,
            input, output, ReturnedItemId: returned, ItemId: item, ConfigurationSignature: configuration,
            BuffSpellId: filter.BuffSpellId, FinishingItemId: finishing,
            AbsentBuffSpellId: filter.AbsentBuffSpellId, AbsentFinishingItemId: absentFinishing,
            AbsentInputItemId: absentInput, GameExpansionGroupKey: gameExpansion);

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
