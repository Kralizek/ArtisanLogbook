using System.Globalization;
using System.Text;
using System.Text.Json;

using ArtisanLogbook.History;

using Dapper;

namespace ArtisanLogbook.HistoryStore;

public sealed partial class HistoryStore
{
    private const int MaximumDimensionBatchSize = 500;

    public IReadOnlyList<CharacterDimension> ReadCharacters(
        IReadOnlyCollection<DimensionIdentity<CharacterIdentity>> identities, CancellationToken cancellationToken = default) =>
        ReadDimensionBatch(identities, "Character", "IdentityKey", "d.Name, d.ClassFile AS Text1",
            identity => identity.Key.Key,
            (row, game) => new CharacterDimension(game, new CharacterIdentity(row.Key), row.Name, row.Text1),
            cancellationToken);

    public IReadOnlyList<RecipeDimension> ReadRecipes(
        IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken cancellationToken = default) =>
        ReadDimensionBatch(identities, "Recipe", "RecipeId", "d.Name, d.ProfessionId AS Number1, d.ProfessionExpansionKey AS Text1, d.MaxQuality AS Number2",
            identity => identity.Key,
            (row, game) => new RecipeDimension(game, int.Parse(row.Key, CultureInfo.InvariantCulture), row.Name, row.Number1, row.Text1, row.Number2),
            cancellationToken);

    public IReadOnlyList<ProfessionDimension> ReadProfessions(
        IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken cancellationToken = default) =>
        ReadDimensionBatch(identities, "Profession", "ProfessionId", "d.Name, d.ParentId AS Number1",
            identity => identity.Key,
            (row, game) => new ProfessionDimension(game, int.Parse(row.Key, CultureInfo.InvariantCulture), row.Name, row.Number1),
            cancellationToken);

    public IReadOnlyList<ItemDimension> ReadItems(
        IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken cancellationToken = default) =>
        ReadDimensionBatch(identities, "Item", "ItemId", "d.Name",
            identity => identity.Key,
            (row, game) => new ItemDimension(game, int.Parse(row.Key, CultureInfo.InvariantCulture), row.Name),
            cancellationToken);

    public IReadOnlyList<ExpansionDimension> ReadExpansions(
        IReadOnlyCollection<DimensionIdentity<string>> identities, CancellationToken cancellationToken = default) =>
        ReadDimensionBatch(identities, "Expansion", "ExpansionKey", "d.Name",
            identity => identity.Key,
            (row, game) => new ExpansionDimension(game, row.Key, row.Name),
            cancellationToken);

    public IReadOnlyList<RecipeReagentSlot> ReadRecipeReagentSlots(
        IReadOnlyCollection<DimensionIdentity<int>> identities, CancellationToken cancellationToken = default)
    {
        ValidateDimensionIdentities(identities);
        return ReadSnapshot((transaction, token) =>
        {
            if (identities.Count == 0) return [];
            (string values, DynamicParameters parameters, Dictionary<string, GameContext> games) =
                DimensionValues(identities, identity => identity.Key);
            List<RecipeReagentSlot> slots = [];
            foreach (RecipeSlotRow row in transaction.Connection!.Query<RecipeSlotRow>($"""
                SELECT d.ContextKey, d.RecipeId, d.DataSlotTypeKey, d.DataSlotIndex, d.SlotIndex,
                    d.ReagentType, d.IsRequired, d.RequiredQuantity, d.CandidateItemIdsJson
                FROM RecipeReagent d
                JOIN (VALUES {values}) AS requested(ContextKey, EntityKey)
                  ON d.ContextKey = requested.ContextKey AND d.RecipeId = requested.EntityKey
                ORDER BY d.ContextKey, d.RecipeId, d.DataSlotTypeKey, d.DataSlotIndex
                """, parameters, transaction, buffered: false))
            {
                token.ThrowIfCancellationRequested();
                RecipeReagentDataSlotType? slotType = row.DataSlotTypeKey == UnknownDataSlotType
                    ? null : EnumValue<RecipeReagentDataSlotType>(row.DataSlotTypeKey - 1, "data-slot type");
                slots.Add(new(games[row.ContextKey], row.RecipeId, slotType, row.DataSlotIndex, row.SlotIndex,
                    row.ReagentType is short type ? EnumValue<RecipeReagentType>(type, nameof(RecipeReagentType)) : null,
                    row.IsRequired, row.RequiredQuantity,
                    row.CandidateItemIdsJson is null ? null :
                        JsonSerializer.Deserialize<int[]>(row.CandidateItemIdsJson, JsonOptions) ??
                        throw new InvalidDataException("Recipe reagent candidate IDs are invalid JSON.")));
            }
            token.ThrowIfCancellationRequested();
            return (IReadOnlyList<RecipeReagentSlot>)slots;
        }, cancellationToken);
    }

    private IReadOnlyList<TResult> ReadDimensionBatch<TKey, TSqlKey, TResult>(
        IReadOnlyCollection<DimensionIdentity<TKey>> identities, string table, string keyColumn, string columns,
        Func<DimensionIdentity<TKey>, TSqlKey> sqlKey, Func<DimensionRow, GameContext, TResult> materialize,
        CancellationToken cancellationToken) where TKey : notnull
    {
        ValidateDimensionIdentities(identities);
        return ReadSnapshot((transaction, token) =>
        {
            if (identities.Count == 0) return [];
            (string values, DynamicParameters parameters, Dictionary<string, GameContext> games) =
                DimensionValues(identities, sqlKey);
            List<TResult> result = [];
            foreach (DimensionRow row in transaction.Connection!.Query<DimensionRow>($"""
                SELECT d.ContextKey, CAST(d.{keyColumn} AS VARCHAR) AS Key, {columns}
                FROM {table} d
                JOIN (VALUES {values}) AS requested(ContextKey, EntityKey)
                  ON d.ContextKey = requested.ContextKey AND d.{keyColumn} = requested.EntityKey
                ORDER BY d.ContextKey, d.{keyColumn}
                """, parameters, transaction, buffered: false))
            {
                token.ThrowIfCancellationRequested();
                result.Add(materialize(row, games[row.ContextKey]));
            }
            token.ThrowIfCancellationRequested();
            return (IReadOnlyList<TResult>)result;
        }, cancellationToken);
    }

    private static void ValidateDimensionIdentities<TKey>(IReadOnlyCollection<DimensionIdentity<TKey>> identities)
        where TKey : notnull
    {
        ArgumentNullException.ThrowIfNull(identities);
        if (identities.Count > MaximumDimensionBatchSize)
            throw new ArgumentOutOfRangeException(nameof(identities), $"A batch may contain at most {MaximumDimensionBatchSize} identities.");
        foreach (DimensionIdentity<TKey> identity in identities)
        {
            if (identity is null || identity.Game is null || identity.Key is null ||
                identity.Key is int number && number <= 0 ||
                identity.Key is string text && string.IsNullOrWhiteSpace(text))
                throw new ArgumentException("Dimension identities must contain a context and a valid key.", nameof(identities));
        }
    }

    private static (string Values, DynamicParameters Parameters, Dictionary<string, GameContext> Games)
        DimensionValues<TKey, TSqlKey>(IReadOnlyCollection<DimensionIdentity<TKey>> identities,
            Func<DimensionIdentity<TKey>, TSqlKey> sqlKey) where TKey : notnull
    {
        DynamicParameters parameters = new();
        Dictionary<string, GameContext> games = [];
        StringBuilder values = new();
        int index = 0;
        foreach (DimensionIdentity<TKey> identity in identities.Distinct())
        {
            string context = ContextKey(identity.Game);
            games.TryAdd(context, identity.Game);
            if (index > 0) values.Append(", ");
            values.Append($"($Context{index}, $Key{index})");
            parameters.Add($"Context{index}", context);
            parameters.Add($"Key{index}", sqlKey(identity));
            index++;
        }
        return (values.ToString(), parameters, games);
    }

    private sealed class DimensionRow
    {
        public string ContextKey { get; set; } = null!;
        public string Key { get; set; } = null!;
        public string? Name { get; set; }
        public string? Text1 { get; set; }
        public int? Number1 { get; set; }
        public int? Number2 { get; set; }
    }
}
