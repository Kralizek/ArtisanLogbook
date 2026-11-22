using ArtisanLogbook.History;
using ArtisanLogbook.Runtime.History;

using GreenDonut;

namespace ArtisanLogbook.Runtime.GraphQL;

internal static class DataLoaderBatching
{
    // Keep the request's injected options, including its shared promise cache, and only bound the batch size;
    // fresh options gave each loader no request cache, so dimensions needed at several depths were refetched.
    public static DataLoaderOptions Limit(DataLoaderOptions options, int maxBatchSize)
    {
        DataLoaderOptions limited = options.Copy();
        limited.MaxBatchSize = maxBatchSize;
        return limited;
    }
}

public sealed class CharacterCraftPageLoader(IBatchScheduler scheduler, ICraftHistoryRepository repository, DataLoaderOptions options)
    : BatchDataLoader<CharacterCraftPageRequest, CraftPage>(scheduler, DataLoaderBatching.Limit(options, 50))
{
    protected override Task<IReadOnlyDictionary<CharacterCraftPageRequest, CraftPage>> LoadBatchAsync(
        IReadOnlyList<CharacterCraftPageRequest> keys, CancellationToken cancellationToken) =>
        Task.FromResult(repository.CharacterPages(keys, cancellationToken));
}

public sealed class CharacterLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository, DataLoaderOptions options)
    : BatchDataLoader<DimensionIdentity<CharacterIdentity>, CharacterDimension>(scheduler, DataLoaderBatching.Limit(options, 500))
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<CharacterIdentity>, CharacterDimension>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<CharacterIdentity>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<CharacterIdentity>, CharacterDimension>>(
            repository.Characters(keys, cancellationToken).ToDictionary(x => new DimensionIdentity<CharacterIdentity>(x.Game, x.Identity)));
}

public sealed class RecipeLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository, DataLoaderOptions options)
    : BatchDataLoader<DimensionIdentity<int>, RecipeDimension>(scheduler, DataLoaderBatching.Limit(options, 500))
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<int>, RecipeDimension>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<int>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<int>, RecipeDimension>>(
            repository.Recipes(keys, cancellationToken).ToDictionary(x => new DimensionIdentity<int>(x.Game, x.Id)));
}

public sealed class ProfessionLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository, DataLoaderOptions options)
    : BatchDataLoader<DimensionIdentity<int>, ProfessionDimension>(scheduler, DataLoaderBatching.Limit(options, 500))
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<int>, ProfessionDimension>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<int>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<int>, ProfessionDimension>>(
            repository.Professions(keys, cancellationToken).ToDictionary(x => new DimensionIdentity<int>(x.Game, x.Id)));
}

public sealed class ItemLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository, DataLoaderOptions options)
    : BatchDataLoader<DimensionIdentity<int>, ItemDimension>(scheduler, DataLoaderBatching.Limit(options, 500))
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<int>, ItemDimension>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<int>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<int>, ItemDimension>>(
            repository.Items(keys, cancellationToken).ToDictionary(x => new DimensionIdentity<int>(x.Game, x.Id)));
}

public sealed class ExpansionLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository, DataLoaderOptions options)
    : BatchDataLoader<DimensionIdentity<string>, ExpansionDimension>(scheduler, DataLoaderBatching.Limit(options, 500))
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<string>, ExpansionDimension>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<string>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<string>, ExpansionDimension>>(
            repository.Expansions(keys, cancellationToken).ToDictionary(x => new DimensionIdentity<string>(x.Game, x.Key)));
}

public sealed class RecipeSlotLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository, DataLoaderOptions options)
    : BatchDataLoader<DimensionIdentity<int>, IReadOnlyList<RecipeReagentSlot>>(scheduler, DataLoaderBatching.Limit(options, 500))
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

public sealed class RecipeActivityLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository, DataLoaderOptions options)
    : BatchDataLoader<DimensionIdentity<int>, DimensionActivity<int>>(scheduler, DataLoaderBatching.Limit(options, 500))
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<int>, DimensionActivity<int>>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<int>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<int>, DimensionActivity<int>>>(
            repository.RecipeActivity(keys, cancellationToken).ToDictionary(x => x.Identity));
}

public sealed class ProfessionActivityLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository, DataLoaderOptions options)
    : BatchDataLoader<DimensionIdentity<int>, DimensionActivity<int>>(scheduler, DataLoaderBatching.Limit(options, 500))
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<int>, DimensionActivity<int>>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<int>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<int>, DimensionActivity<int>>>(
            repository.ProfessionActivity(keys, cancellationToken).ToDictionary(x => x.Identity));
}

public sealed class CharacterActivityLoader(IBatchScheduler scheduler, IHistoryDimensionRepository repository, DataLoaderOptions options)
    : BatchDataLoader<DimensionIdentity<CharacterIdentity>, DimensionActivity<CharacterIdentity>>(scheduler, DataLoaderBatching.Limit(options, 500))
{
    protected override Task<IReadOnlyDictionary<DimensionIdentity<CharacterIdentity>, DimensionActivity<CharacterIdentity>>> LoadBatchAsync(
        IReadOnlyList<DimensionIdentity<CharacterIdentity>> keys, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyDictionary<DimensionIdentity<CharacterIdentity>, DimensionActivity<CharacterIdentity>>>(
            repository.CharacterActivity(keys, cancellationToken).ToDictionary(x => x.Identity));
}
