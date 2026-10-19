namespace ArtisanLogbook.History;

public sealed record HistoryValidationError(CraftIdentity? Identity, string Field, string Message);

public static class HistoryValidator
{
    public static IReadOnlyList<HistoryValidationError> Validate(IEnumerable<CraftObservation> history)
    {
        ArgumentNullException.ThrowIfNull(history);
        List<HistoryValidationError> errors = [];
        HashSet<CraftIdentity> seen = [];
        foreach (CraftObservation craft in history)
        {
            if (craft is null)
            {
                errors.Add(new(null, "Craft", "A craft observation cannot be null."));
                continue;
            }

            if (craft.Identity is null)
            {
                errors.Add(new(null, "Identity", "Every craft needs an identity."));
                continue;
            }

            if (!seen.Add(craft.Identity))
                errors.Add(new(craft.Identity, "Identity", "Duplicate identity in a single history."));
            if (craft.Character is null)
                errors.Add(new(craft.Identity, "Character", "A craft needs a character identity."));
            if (craft.RecipeId is <= 0)
                errors.Add(new(craft.Identity, "RecipeId", "Recipe ID must be positive when known."));
            if (craft.ProfessionId is <= 0)
                errors.Add(new(craft.Identity, "ProfessionId", "Profession ID must be positive when known."));
            if (craft.ConcentrationSpent is < 0 || craft.IngenuityRefund is < 0)
                errors.Add(new(craft.Identity, "Concentration", "Concentration measurements cannot be negative."));
            if (craft.ConcentrationCurrencyId is <= 0)
                errors.Add(new(craft.Identity, "ConcentrationCurrencyId", "Currency ID must be positive when known."));
            if (craft.MulticraftBonus is < 0)
                errors.Add(new(craft.Identity, "MulticraftBonus", "Multicraft bonus cannot be negative."));
            HashSet<int> reagentItems = [];
            foreach (CraftReagent reagent in craft.Reagents ?? [])
            {
                if (reagent.ItemId <= 0 || reagent.AllocatedQuantity is < 0 || reagent.ReturnedQuantity is < 0)
                    errors.Add(new(craft.Identity, "Reagents", "Reagent IDs must be positive and known quantities nonnegative."));
                if (!reagentItems.Add(reagent.ItemId))
                    errors.Add(new(craft.Identity, "Reagents", "Reagent rows must be aggregated at craft × item grain."));
            }

            HashSet<(int, int?)> outputItems = [];
            foreach (CraftOutput output in craft.Outputs ?? [])
            {
                if (output.ItemId <= 0 || output.Quantity <= 0 || output.Quality is < 0)
                    errors.Add(new(craft.Identity, "Outputs", "Output ID and quantity must be positive and quality nonnegative when known."));
                if (!outputItems.Add((output.ItemId, output.Quality)))
                    errors.Add(new(craft.Identity, "Outputs", "Output rows must be aggregated at craft × item × quality grain."));
            }
        }
        return errors;
    }
}
