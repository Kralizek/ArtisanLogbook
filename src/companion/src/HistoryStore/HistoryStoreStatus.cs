using ArtisanLogbook.History;

namespace ArtisanLogbook.HistoryStore;

public sealed record GameContextCraftCount(GameContext Game, long CraftCount);

public sealed record HistoryStoreStatus(
    int SchemaVersion,
    long TotalCraftCount,
    DateTimeOffset? OldestCraft,
    DateTimeOffset? NewestCraft,
    IReadOnlyList<GameContextCraftCount> Contexts);
