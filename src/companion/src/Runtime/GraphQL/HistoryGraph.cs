using System.Globalization;

using ArtisanLogbook.History;
using ArtisanLogbook.Runtime.History;

using HotChocolate;
using HotChocolate.CostAnalysis.Types;
using HotChocolate.Types;

namespace ArtisanLogbook.Runtime.GraphQL;

[GraphQLName("Craft")]
public sealed class CraftGraph(CraftObservation value)
{
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string Id => HistoryTokens.Craft(value.Identity);
    public DateTimeOffset RecordedAt => value.RecordedAt;
    public GameContextGraph Game => new(value.Game);
    public int? ConcentrationSpent => value.ConcentrationSpent;
    public int? IngenuityRefund => value.IngenuityRefund;
    public int? ConcentrationCurrencyId => value.ConcentrationCurrencyId;
    public bool? HasIngenuityProc => value.HasIngenuityProc;
    public bool? HasResourcefulnessProc => value.HasResourcefulnessProc;
    public int? MulticraftBonus => value.MulticraftBonus;
    public bool? InputsComplete => value.InputsComplete;
    public bool? ResourcefulnessComplete => value.ResourcefulnessComplete;
    public bool? OutputsComplete => value.OutputsComplete;
    public IReadOnlyList<CraftReagentGraph>? Reagents => value.Reagents?.Select(x => new CraftReagentGraph(value.Game, x)).ToArray();
    public IReadOnlyList<CraftOutputGraph>? Outputs => value.Outputs?.Select(x => new CraftOutputGraph(value.Game, x)).ToArray();

    [Cost(1)]
    public async Task<CharacterGraph> GetCharacterAsync(CharacterLoader loader, CancellationToken token) =>
        new(await loader.LoadAsync(new DimensionIdentity<CharacterIdentity>(value.Game, value.Character), token) ?? new(value.Game, value.Character));

    [Cost(1)]
    public async Task<RecipeGraph?> GetRecipeAsync(RecipeLoader loader, CancellationToken token)
    {
        if (value.RecipeId is not int id) return null;
        return new(await loader.LoadAsync(new DimensionIdentity<int>(value.Game, id), token) ?? new(value.Game, id));
    }

    [Cost(1)]
    public async Task<ProfessionGraph?> GetProfessionAsync(ProfessionLoader loader, CancellationToken token)
    {
        if (value.ProfessionId is not int id) return null;
        return new(await loader.LoadAsync(new DimensionIdentity<int>(value.Game, id), token) ?? new(value.Game, id));
    }

    [Cost(1)]
    public async Task<ExpansionGraph?> GetProfessionExpansionAsync(ExpansionLoader loader, CancellationToken token)
    {
        if (value.ProfessionExpansionKey is not string key) return null;
        return new(await loader.LoadAsync(new DimensionIdentity<string>(value.Game, key), token) ?? new(value.Game, key));
    }
}

[GraphQLName("Character")]
public sealed class CharacterGraph(CharacterDimension value)
{
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string Id => HistoryTokens.Dimension("character", value.Game, value.Identity.Key);
    public string? Name => value.Name;
    public string? ClassFile => value.ClassFile;
    public GameContextGraph Game => new(value.Game);
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    [Cost(1)]
    public async Task<CraftConnection> GetCraftsAsync(CharacterCraftPageLoader loader, int first = 20, string? after = null,
        CancellationToken token = default)
    {
        HistoryConnections.ValidatePageSize(first);
        CharacterCraftPageRequest request = new(new(value.Game, value.Identity), first,
            after is null ? null : HistoryTokens.ParseCraftCursor(after));
        CraftPage page = await loader.LoadAsync(request, token)
            ?? throw new InvalidOperationException("The character craft page was not returned by the repository.");
        return HistoryConnections.Crafts(page);
    }
}

[GraphQLName("Recipe")]
public sealed class RecipeGraph(RecipeDimension value)
{
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string Id => HistoryTokens.Dimension("recipe", value.Game, value.Id.ToString(CultureInfo.InvariantCulture));
    public int BlizzardId => value.Id;
    public string? Name => value.Name;
    public int? MaxQuality => value.MaxQuality;
    public GameContextGraph Game => new(value.Game);

    [Cost(1)]
    public async Task<ProfessionGraph?> GetProfessionAsync(ProfessionLoader loader, CancellationToken token)
    {
        if (value.ProfessionId is not int id) return null;
        return new(await loader.LoadAsync(new DimensionIdentity<int>(value.Game, id), token) ?? new(value.Game, id));
    }

    [Cost(1)]
    public async Task<ExpansionGraph?> GetExpansionAsync(ExpansionLoader loader, CancellationToken token)
    {
        if (value.ProfessionExpansionKey is not string key) return null;
        return new(await loader.LoadAsync(new DimensionIdentity<string>(value.Game, key), token) ?? new(value.Game, key));
    }

    [Cost(1)]
    public async Task<IReadOnlyList<RecipeReagentSlotGraph>> GetReagentSlotsAsync(RecipeSlotLoader loader, CancellationToken token) =>
        (await loader.LoadAsync(new DimensionIdentity<int>(value.Game, value.Id), token) ?? []).Select(x => new RecipeReagentSlotGraph(x)).ToArray();

    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    [Cost(1_000)]
    public CraftConnection GetCrafts(ICraftHistoryRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) =>
        HistoryConnections.Crafts(repository, new(Game: value.Game, RecipeId: value.Id), first, after, token);
}

[GraphQLName("Profession")]
public sealed class ProfessionGraph(ProfessionDimension value)
{
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string Id => HistoryTokens.Dimension("profession", value.Game, value.Id.ToString(CultureInfo.InvariantCulture));
    public int BlizzardId => value.Id;
    public string? Name => value.Name;
    public GameContextGraph Game => new(value.Game);

    [Cost(1)]
    public async Task<ProfessionGraph?> GetParentAsync(ProfessionLoader loader, CancellationToken token)
    {
        if (value.ParentId is not int id) return null;
        return new(await loader.LoadAsync(new DimensionIdentity<int>(value.Game, id), token) ?? new(value.Game, id));
    }

    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public ProfessionConnection GetChildren(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) =>
        HistoryConnections.Professions(repository, new(value.Game, value.Id), first, after, token);
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public RecipeConnection GetRecipes(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        string? search = null, CancellationToken token = default) =>
        HistoryConnections.Recipes(repository, new(value.Game, value.Id, Search: search), first, after, token);
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public CraftConnection GetCrafts(ICraftHistoryRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) =>
        HistoryConnections.Crafts(repository, new(Game: value.Game, ProfessionId: value.Id), first, after, token);
}

[GraphQLName("Expansion")]
public sealed class ExpansionGraph(ExpansionDimension value)
{
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string Id => HistoryTokens.Dimension("expansion", value.Game, value.Key);
    public string Key => value.Key;
    public string? Name => value.Name;
    public GameContextGraph Game => new(value.Game);
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public RecipeConnection GetRecipes(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        string? search = null, CancellationToken token = default) =>
        HistoryConnections.Recipes(repository, new(value.Game, ExpansionKey: value.Key, Search: search), first, after, token);
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public CraftConnection GetCrafts(ICraftHistoryRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) =>
        HistoryConnections.Crafts(repository, new(Game: value.Game, ProfessionExpansionKey: value.Key), first, after, token);
}

[GraphQLName("Item")]
public sealed class ItemGraph(ItemDimension value)
{
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string Id => HistoryTokens.Dimension("item", value.Game, value.Id.ToString(CultureInfo.InvariantCulture));
    public int BlizzardId => value.Id;
    public string? Name => value.Name;
    public GameContextGraph Game => new(value.Game);
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public CraftConnection GetConsumingCrafts(ICraftHistoryRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) =>
        HistoryConnections.Crafts(repository, new(Game: value.Game, InputItemId: value.Id), first, after, token);
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public CraftConnection GetProducingCrafts(ICraftHistoryRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) =>
        HistoryConnections.Crafts(repository, new(Game: value.Game, OutputItemId: value.Id), first, after, token);
}

[GraphQLName("GameContext")]
public sealed class GameContextGraph(GameContext value)
{
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string Id => HistoryTokens.Context(value);
    public int Project => (int)value.Project;
    public string? ProgressionTrack => value.ProgressionTrack;
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public CharacterConnection GetCharacters(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) => HistoryConnections.Characters(repository, value, first, after, token);
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public ProfessionConnection GetProfessions(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) => HistoryConnections.Professions(repository, new(value), first, after, token);
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public RecipeConnection GetRecipes(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        string? search = null, CancellationToken token = default) =>
        HistoryConnections.Recipes(repository, new(value, Search: search), first, after, token);
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public ExpansionConnection GetExpansions(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) => HistoryConnections.Expansions(repository, value, first, after, token);
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public ItemConnection GetItems(IHistoryDimensionRepository repository, int first = 20, string? after = null,
        string? search = null, CancellationToken token = default) =>
        HistoryConnections.Items(repository, new(value, search), first, after, token);
    [Cost(1_000)]
    [ListSize(SlicingArguments = ["first"], SizedFields = ["nodes"], SlicingArgumentDefaultValue = 20, RequireOneSlicingArgument = false)]
    public CraftConnection GetCrafts(ICraftHistoryRepository repository, int first = 20, string? after = null,
        CancellationToken token = default) => HistoryConnections.Crafts(repository, new(Game: value), first, after, token);
}

[GraphQLName("CraftReagent")]
public sealed class CraftReagentGraph(GameContext game, CraftReagent value)
{
    public long? AllocatedQuantity => value.AllocatedQuantity;
    public decimal? ReturnedQuantity => value.ReturnedQuantity;
    [Cost(1)]
    public async Task<ItemGraph> GetItemAsync(ItemLoader loader, CancellationToken token) =>
        new(await loader.LoadAsync(new DimensionIdentity<int>(game, value.ItemId), token) ?? new(game, value.ItemId));
}

[GraphQLName("CraftOutput")]
public sealed class CraftOutputGraph(GameContext game, CraftOutput value)
{
    public int? Quality => value.Quality;
    public long? Quantity => value.Quantity;
    [Cost(1)]
    public async Task<ItemGraph> GetItemAsync(ItemLoader loader, CancellationToken token) =>
        new(await loader.LoadAsync(new DimensionIdentity<int>(game, value.ItemId), token) ?? new(game, value.ItemId));
}

[GraphQLName("RecipeReagentSlot")]
public sealed class RecipeReagentSlotGraph(RecipeReagentSlot value)
{
    [GraphQLType(typeof(NonNullType<IdType>))]
    public string Id => HistoryTokens.Dimension("recipe-slot", value.Game,
        FormattableString.Invariant($"{value.RecipeId}/{(value.DataSlotType is null ? "unknown" : ((int)value.DataSlotType.Value).ToString(CultureInfo.InvariantCulture))}/{value.DataSlotIndex}"));
    public RecipeReagentDataSlotType? DataSlotType => value.DataSlotType;
    public int DataSlotIndex => value.DataSlotIndex;
    public int? SlotIndex => value.SlotIndex;
    public RecipeReagentType? ReagentType => value.ReagentType;
    public bool? IsRequired => value.IsRequired;
    public int? RequiredQuantity => value.RequiredQuantity;
    [Cost(1)]
    public async Task<RecipeGraph> GetRecipeAsync(RecipeLoader loader, CancellationToken token) =>
        new(await loader.LoadAsync(new DimensionIdentity<int>(value.Game, value.RecipeId), token) ?? new(value.Game, value.RecipeId));
    [Cost(1)]
    public async Task<IReadOnlyList<ItemGraph>?> GetCandidateItemsAsync(ItemLoader loader, CancellationToken token)
    {
        if (value.CandidateItemIds is null) return null;
        Task<ItemGraph>[] items = value.CandidateItemIds.Select(async id =>
            new ItemGraph(await loader.LoadAsync(new DimensionIdentity<int>(value.Game, id), token) ?? new(value.Game, id))).ToArray();
        return await Task.WhenAll(items);
    }
}
