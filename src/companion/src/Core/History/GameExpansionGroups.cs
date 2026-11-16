namespace ArtisanLogbook.History;

/// <summary>
/// Known Retail profession skill lines grouped by their game expansion. These are explicit
/// skill-line identities, not numeric ranges or localized expansion-name matches.
/// </summary>
public static class GameExpansionGroups
{
    private static readonly IReadOnlyDictionary<string, string[]> RetailGroups = new Dictionary<string, string[]>
    {
        ["game:midnight"] = Keys(2906, 2907, 2908, 2909, 2910, 2911, 2912, 2913, 2914, 2915, 2916, 2917, 2918),
        ["game:war-within"] = Keys(2871, 2872, 2873, 2874, 2875, 2876, 2877, 2878, 2879, 2880, 2881, 2882, 2883),
        ["game:dragonflight"] = Keys(2823, 2822, 2824, 2825, 2827, 2826, 2832, 2828, 2829, 2830, 2833, 2834, 2831),
        ["game:shadowlands"] = Keys(2750, 2751, 2752, 2753, 2755, 2754, 2760, 2756, 2757, 2758, 2761, 2762, 2759),
        ["game:battle-for-azeroth"] = Keys(2478, 2437, 2541, 2486, 2499, 2585, 2549, 2507, 2517, 2525, 2565, 2557, 2533),
        ["game:legion"] = Keys(2479, 2454, 2542, 2487, 2500, 2586, 2550, 2508, 2518, 2526, 2566, 2558, 2534),
        ["game:warlords"] = Keys(2480, 2472, 2543, 2488, 2501, 2587, 2551, 2509, 2519, 2527, 2567, 2559, 2535),
        ["game:pandaria"] = Keys(2481, 2473, 2544, 2489, 2502, 2588, 2552, 2510, 2520, 2528, 2568, 2560, 2536),
        ["game:cataclysm"] = Keys(2482, 2474, 2545, 2491, 2503, 2589, 2553, 2511, 2521, 2529, 2569, 2561, 2537),
        ["game:wrath"] = Keys(2483, 2475, 2546, 2492, 2504, 2590, 2554, 2512, 2522, 2530, 2570, 2562, 2538),
        ["game:burning-crusade"] = Keys(2484, 2476, 2547, 2493, 2505, 2591, 2555, 2513, 2523, 2531, 2571, 2563, 2539),
        ["game:classic"] = Keys(2485, 2477, 2548, 2494, 2506, 2592, 2556, 2514, 2524, 2532, 2572, 2564, 2540)
    };

    private static readonly IReadOnlyDictionary<string, string> RetailKeyToGroup =
        RetailGroups.SelectMany(group => group.Value.Select(key => (key, group.Key)))
            .ToDictionary(pair => pair.key, pair => pair.Key, StringComparer.Ordinal);

    public static string GroupKey(GameContext game, string professionExpansionKey) =>
        game.Project == GameProject.Retail &&
        RetailKeyToGroup.TryGetValue(professionExpansionKey, out string? group)
            ? group : professionExpansionKey;

    /// <summary>Unknown source keys remain separate singleton groups; unknown group IDs are rejected.</summary>
    public static IReadOnlyList<string>? MemberKeys(GameContext game, string groupKey)
    {
        if (game.Project == GameProject.Retail && RetailGroups.TryGetValue(groupKey, out string[]? keys))
            return keys;
        return string.IsNullOrWhiteSpace(groupKey) || groupKey.StartsWith("game:", StringComparison.Ordinal)
            ? null : [groupKey];
    }

    private static string[] Keys(params int[] ids) => ids.Select(id => $"skillLine:{id}").ToArray();
}

/// <summary>Available, recorded profession-expansion identities in one game-expansion choice.</summary>
public sealed record GameExpansionGroup(GameContext Game, string Key, string? Name,
    IReadOnlyList<string> ProfessionExpansionKeys);
