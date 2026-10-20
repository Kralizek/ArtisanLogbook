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
            if (craft.Game is null)
                errors.Add(new(craft.Identity, "Game", "Every craft needs a game context."));
            if (craft.Character is null)
                errors.Add(new(craft.Identity, "Character", "A craft needs a character identity."));
            if (craft.RecipeId is <= 0)
                errors.Add(new(craft.Identity, "RecipeId", "Recipe ID must be positive when known."));
            if (craft.ProfessionExpansionKey is not null && string.IsNullOrWhiteSpace(craft.ProfessionExpansionKey))
                errors.Add(new(craft.Identity, "ProfessionExpansionKey", "Expansion key cannot be blank."));
            if (craft.ProfessionId is <= 0)
                errors.Add(new(craft.Identity, "ProfessionId", "Profession ID must be positive when known."));
            if (craft.ConcentrationSpent is < 0 || craft.IngenuityRefund is < 0)
                errors.Add(new(craft.Identity, "Concentration", "Concentration measurements cannot be negative."));
            if (craft.ConcentrationCurrencyId is <= 0)
                errors.Add(new(craft.Identity, "ConcentrationCurrencyId", "Currency ID must be positive when known."));
            if (craft.MulticraftBonus is < 0)
                errors.Add(new(craft.Identity, "MulticraftBonus", "Multicraft bonus cannot be negative."));
            if (craft.InputsComplete == true && craft.Reagents is null)
                errors.Add(new(craft.Identity, "InputsComplete", "Complete input evidence requires an observed reagent collection."));
            if (craft.InputsComplete == true && craft.Reagents is not null &&
                craft.Reagents.Any(r => r.AllocatedQuantity is null))
                errors.Add(new(craft.Identity, "InputsComplete", "Complete input evidence requires every reagent allocation to be known."));
            if (craft.ResourcefulnessComplete == true && craft.HasResourcefulnessProc is null)
                errors.Add(new(craft.Identity, "ResourcefulnessComplete", "Complete Resourcefulness evidence requires an observed proc outcome."));
            HashSet<int> reagentItems = [];
            foreach (CraftReagent reagent in craft.Reagents ?? [])
            {
                if (reagent.ItemId <= 0 || reagent.AllocatedQuantity is < 0 || reagent.ReturnedQuantity is < 0)
                    errors.Add(new(craft.Identity, "Reagents", "Reagent IDs must be positive and known quantities nonnegative."));
                if (!reagentItems.Add(reagent.ItemId))
                    errors.Add(new(craft.Identity, "Reagents", "Reagent rows must be aggregated at craft × item grain."));
            }
            if (craft.HasResourcefulnessProc == false &&
                (craft.Reagents ?? []).Any(r => r.ReturnedQuantity is > 0))
                errors.Add(new(craft.Identity, "HasResourcefulnessProc", "A negative Resourcefulness outcome conflicts with a positive returned quantity."));
            if (craft.ResourcefulnessComplete == true && craft.HasResourcefulnessProc == true &&
                !(craft.Reagents ?? []).Any(r => r.ReturnedQuantity is > 0))
                errors.Add(new(craft.Identity, "ResourcefulnessComplete", "A complete positive proc requires at least one observed positive returned quantity."));

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
