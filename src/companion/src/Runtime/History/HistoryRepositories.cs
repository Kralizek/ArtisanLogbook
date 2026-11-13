using ArtisanLogbook.History;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.Runtime.History;

public interface ICraftHistoryRepository
{
    CraftPage Query(CraftQuery query, int first = 20, CraftPagePosition? after = null,
        CancellationToken cancellationToken = default);
    IReadOnlyDictionary<CharacterCraftPageRequest, CraftPage> CharacterPages(
        IReadOnlyCollection<CharacterCraftPageRequest> requests, CancellationToken cancellationToken = default);
}

public interface IHistoryDimensionRepository
{
    DimensionPage<CharacterDimension, CharacterIdentity> Characters(GameContext? game, int first,
        DimensionIdentity<CharacterIdentity>? after, CancellationToken cancellationToken);
    DimensionPage<RecipeDimension, int> Recipes(RecipeQuery query, int first,
        DimensionIdentity<int>? after, CancellationToken cancellationToken);
    DimensionPage<ProfessionDimension, int> Professions(ProfessionQuery query, int first,
        DimensionIdentity<int>? after, CancellationToken cancellationToken);
    DimensionPage<ItemDimension, int> Items(ItemQuery query, int first,
        DimensionIdentity<int>? after, CancellationToken cancellationToken);
    DimensionPage<ExpansionDimension, string> Expansions(GameContext? game, int first,
        DimensionIdentity<string>? after, CancellationToken cancellationToken);
    GameContextPage GameContexts(int first, GameContext? after, CancellationToken cancellationToken);
    IReadOnlyList<CharacterDimension> Characters(IReadOnlyCollection<DimensionIdentity<CharacterIdentity>> identities, CancellationToken cancellationToken);
    IReadOnlyList<RecipeDimension> Recipes(IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken cancellationToken);
    IReadOnlyList<ProfessionDimension> Professions(IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken cancellationToken);
    IReadOnlyList<ItemDimension> Items(IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken cancellationToken);
    IReadOnlyList<ExpansionDimension> Expansions(IReadOnlyCollection<DimensionIdentity<string>> identities, CancellationToken cancellationToken);
    IReadOnlyList<RecipeReagentSlot> RecipeSlots(IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken cancellationToken);
    IReadOnlyList<GameContext> GameContexts(IReadOnlyCollection<GameContext> contexts, CancellationToken cancellationToken);
}

internal sealed class CraftHistoryRepository(Store store) : ICraftHistoryRepository
{
    public CraftPage Query(CraftQuery query, int first = 20, CraftPagePosition? after = null,
        CancellationToken cancellationToken = default) => store.QueryCrafts(query, first, after, cancellationToken);
    public IReadOnlyDictionary<CharacterCraftPageRequest, CraftPage> CharacterPages(
        IReadOnlyCollection<CharacterCraftPageRequest> requests, CancellationToken cancellationToken = default) =>
        store.QueryCharacterCraftPages(requests, cancellationToken);
}

internal sealed class HistoryDimensionRepository(Store store) : IHistoryDimensionRepository
{
    public DimensionPage<CharacterDimension, CharacterIdentity> Characters(GameContext? game, int first,
        DimensionIdentity<CharacterIdentity>? after, CancellationToken token) => store.QueryCharacters(game, first, after, token);
    public DimensionPage<RecipeDimension, int> Recipes(RecipeQuery query, int first,
        DimensionIdentity<int>? after, CancellationToken token) => store.QueryRecipes(query, first, after, token);
    public DimensionPage<ProfessionDimension, int> Professions(ProfessionQuery query, int first,
        DimensionIdentity<int>? after, CancellationToken token) => store.QueryProfessions(query, first, after, token);
    public DimensionPage<ItemDimension, int> Items(ItemQuery query, int first,
        DimensionIdentity<int>? after, CancellationToken token) => store.QueryItems(query, first, after, token);
    public DimensionPage<ExpansionDimension, string> Expansions(GameContext? game, int first,
        DimensionIdentity<string>? after, CancellationToken token) => store.QueryExpansions(game, first, after, token);
    public GameContextPage GameContexts(int first, GameContext? after, CancellationToken token) =>
        store.QueryGameContexts(first, after, token);
    public IReadOnlyList<CharacterDimension> Characters(IReadOnlyCollection<DimensionIdentity<CharacterIdentity>> identities, CancellationToken token) =>
        store.ReadCharacters(identities, token);
    public IReadOnlyList<RecipeDimension> Recipes(IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken token) =>
        store.ReadRecipes(identities, token);
    public IReadOnlyList<ProfessionDimension> Professions(IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken token) =>
        store.ReadProfessions(identities, token);
    public IReadOnlyList<ItemDimension> Items(IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken token) =>
        store.ReadItems(identities, token);
    public IReadOnlyList<ExpansionDimension> Expansions(IReadOnlyCollection<DimensionIdentity<string>> identities, CancellationToken token) =>
        store.ReadExpansions(identities, token);
    public IReadOnlyList<RecipeReagentSlot> RecipeSlots(IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken token) =>
        store.ReadRecipeReagentSlots(identities, token);
    public IReadOnlyList<GameContext> GameContexts(IReadOnlyCollection<GameContext> contexts, CancellationToken token) =>
        store.ReadGameContexts(contexts, token);
}
