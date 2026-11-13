using ArtisanLogbook.History;
using ArtisanLogbook.Runtime.History;

using GreenDonut;

namespace ArtisanLogbook.Runtime.GraphQL;

public sealed class CharacterCraftPageLoader(IBatchScheduler scheduler, ICraftHistoryRepository repository)
    : BatchDataLoader<CharacterCraftPageRequest, CraftPage>(scheduler, new() { MaxBatchSize = 50 })
{
    protected override Task<IReadOnlyDictionary<CharacterCraftPageRequest, CraftPage>> LoadBatchAsync(
        IReadOnlyList<CharacterCraftPageRequest> keys, CancellationToken cancellationToken) =>
        Task.FromResult(repository.CharacterPages(keys, cancellationToken));
}

public sealed class CharacterLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository)
    : BatchDataLoader<DimensionIdentity<CharacterIdentity>, CharacterDimension>(scheduler, new() { MaxBatchSize = 500 })
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<CharacterIdentity>, CharacterDimension>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<CharacterIdentity>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<CharacterIdentity>, CharacterDimension>>(
            repository.Characters(keys, cancellationToken).ToDictionary(x => new DimensionIdentity<CharacterIdentity>(x.Game, x.Identity)));
}

public sealed class RecipeLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository)
    : BatchDataLoader<DimensionIdentity<int>, RecipeDimension>(scheduler, new() { MaxBatchSize = 500 })
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<int>, RecipeDimension>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<int>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<int>, RecipeDimension>>(
            repository.Recipes(keys, cancellationToken).ToDictionary(x => new DimensionIdentity<int>(x.Game, x.Id)));
}

public sealed class ProfessionLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository)
    : BatchDataLoader<DimensionIdentity<int>, ProfessionDimension>(scheduler, new() { MaxBatchSize = 500 })
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<int>, ProfessionDimension>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<int>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<int>, ProfessionDimension>>(
            repository.Professions(keys, cancellationToken).ToDictionary(x => new DimensionIdentity<int>(x.Game, x.Id)));
}

public sealed class ItemLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository)
    : BatchDataLoader<DimensionIdentity<int>, ItemDimension>(scheduler, new() { MaxBatchSize = 500 })
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<int>, ItemDimension>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<int>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<int>, ItemDimension>>(
            repository.Items(keys, cancellationToken).ToDictionary(x => new DimensionIdentity<int>(x.Game, x.Id)));
}

public sealed class ExpansionLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository)
    : BatchDataLoader<DimensionIdentity<string>, ExpansionDimension>(scheduler, new() { MaxBatchSize = 500 })
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<string>, ExpansionDimension>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<string>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<string>, ExpansionDimension>>(
            repository.Expansions(keys, cancellationToken).ToDictionary(x => new DimensionIdentity<string>(x.Game, x.Key)));
}

public sealed class RecipeSlotLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository)
    : BatchDataLoader<DimensionIdentity<int>, IReadOnlyList<RecipeReagentSlot>>(scheduler, new() { MaxBatchSize = 500 })
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<int>, IReadOnlyList<RecipeReagentSlot>>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<int>> keys, CancellationToken cancellationToken)
    {
        Dictionary<DimensionIdentity<int>, IReadOnlyList<RecipeReagentSlot>> result = repository.RecipeSlots(keys, cancellationToken)
            .GroupBy(slot => new DimensionIdentity<int>(slot.Game, slot.RecipeId))
            .ToDictionary(group => group.Key, group => (IReadOnlyList<RecipeReagentSlot>)group.ToArray());
        foreach (DimensionIdentity<int> key in keys)
            result.TryAdd(key, []);
        return Task.FromResult<IReadOnlyDictionary<DimensionIdentity<int>, IReadOnlyList<RecipeReagentSlot>>>(result);
    }
}
