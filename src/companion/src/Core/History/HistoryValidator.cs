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
            if (craft.ConcentrationCurrencyId is < 0)
                errors.Add(new(craft.Identity, "ConcentrationCurrencyId", "Currency ID must be nonnegative when observed."));
            if (craft.MulticraftBonus is < 0)
                errors.Add(new(craft.Identity, "MulticraftBonus", "Multicraft bonus cannot be negative."));
            if (craft.InputsComplete == true && craft.Reagents is null)
                errors.Add(new(craft.Identity, "InputsComplete", "Complete input evidence requires an observed reagent collection."));
            if (craft.InputsComplete == true && craft.Reagents is not null &&
                craft.Reagents.Any(r => r.AllocatedQuantity is null))
                errors.Add(new(craft.Identity, "InputsComplete", "Complete input evidence requires every reagent allocation to be known."));
            if (craft.OutputsComplete == true &&
                (craft.Outputs is null || craft.Outputs.Any(output => output.Quantity is null)))
                errors.Add(new(craft.Identity, "OutputsComplete", "Complete output evidence requires an observed collection with known quantities."));
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
            if (craft.OutputEvidence is { Count: 0 })
                errors.Add(new(craft.Identity, "OutputEvidence", "An evidence collection cannot be empty."));
            foreach (CraftOutputEvidence evidence in craft.OutputEvidence ?? [])
            {
                if (string.IsNullOrWhiteSpace(evidence.SourceId) || evidence.Callbacks.Count == 0)
                    errors.Add(new(craft.Identity, "OutputEvidence", "Output evidence requires a source identity and callback observations."));
                foreach (CraftOutputObservation callback in evidence.Callbacks)
                {
                    if (callback.Output.ItemId <= 0 || callback.Output.Quantity is not > 0 ||
                        callback.Output.Quality is < 0 || callback.ItemLevel is < 0 || callback.LegacyCraftId is <= 0 ||
                        callback.Measurements.ConcentrationSpent is < 0 || callback.Measurements.IngenuityRefund is < 0 ||
                        callback.Measurements.MulticraftBonus is < 0 || callback.Measurements.ConcentrationCurrencyId is < 0)
                        errors.Add(new(craft.Identity, "OutputEvidence", "Callbacks require positive output identities/quantities and nonnegative measurements."));
                    if (callback.Returns.Any(row => row.ItemId <= 0 || row.AllocatedQuantity is not null || row.ReturnedQuantity is not > 0) ||
                        callback.Returns.Select(row => row.ItemId).Distinct().Count() != callback.Returns.Count)
                        errors.Add(new(craft.Identity, "OutputEvidence", "Callback returns require distinct item identities and positive observed returns only."));
                }
            }
            if (craft.ConfigurationEvidence is { Count: 0 })
                errors.Add(new(craft.Identity, "ConfigurationEvidence", "A configuration evidence collection cannot be empty."));
            foreach (CraftConfigurationEvidence evidence in craft.ConfigurationEvidence ?? [])
                if (string.IsNullOrWhiteSpace(evidence.SourceId) || evidence.LocalKey is <= 0 || string.IsNullOrWhiteSpace(evidence.Payload))
                    errors.Add(new(craft.Identity, "ConfigurationEvidence", "Configuration evidence requires a source identity, valid optional local key, and payload."));
        }
        return errors;
    }
}
