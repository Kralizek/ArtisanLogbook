-- First three results of the captured 184-operation batch, in original order.
-- Quotes/UI chatter, locations, links and item GUIDs are omitted; cast GUIDs are pseudonyms.
local recipeId = 1229930
local function event(sequence, elapsed, name, ...)
  return { sequence = sequence, elapsed = elapsed, name = name, arguments = { n = select("#", ...), ... } }
end

return {
  build = "70448",
  recipeId = recipeId,
  requestedCount = 184,
  events = {
    event(41924, 345770.6931341, "TRADE_SKILL_CRAFT_BEGIN", recipeId),
    event(41933, 345770.717189, "CALL_POST:C_TradeSkillUI.CraftSalvage", recipeId, 184, {}, {}, false),
    event(41934, 345770.717227, "REQUEST_PROBE:C_TradeSkillUI.CraftSalvage",
      { operation = "unavailable", reagentQuality = {} }),
    event(41936, 345770.803287, "UNIT_SPELLCAST_START", "player", "Cast-Recycling-1", recipeId),
    event(41940, 345772.540002, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Recycling-1", recipeId),
    event(41941, 345772.540565, "UNIT_SPELLCAST_STOP", "player", "Cast-Recycling-1", recipeId),
    event(41942, 345772.5753771, "TRADE_SKILL_CRAFT_BEGIN", recipeId),
    event(41943, 345772.6564928, "TRADE_SKILL_ITEM_CRAFTED_RESULT", {
      operationID = 3854211863, itemID = 243581, quantity = 4, craftingQuality = 1,
      bonusCraft = false, firstCraftReward = false, concentrationSpent = 0,
      concentrationCurrencyID = 3164, hasIngenuityProc = false, ingenuityRefund = 147, multicraft = 0,
    }),
    event(41945, 345772.657206, "UNIT_SPELLCAST_START", "player", "Cast-Recycling-2", recipeId),
    event(42946, 345774.739960, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Recycling-2", recipeId),
    event(42947, 345774.740521, "UNIT_SPELLCAST_STOP", "player", "Cast-Recycling-2", recipeId),
    event(42948, 345774.764398, "TRADE_SKILL_CRAFT_BEGIN", recipeId),
    event(42949, 345774.766312, "TRADE_SKILL_ITEM_CRAFTED_RESULT", {
      operationID = 533880495, itemID = 243581, quantity = 3, craftingQuality = 1,
      bonusCraft = false, firstCraftReward = false, concentrationSpent = 0,
      concentrationCurrencyID = 3164, hasIngenuityProc = false, ingenuityRefund = 147, multicraft = 0,
    }),
    event(42997, 345774.910574, "UNIT_SPELLCAST_START", "player", "Cast-Recycling-3", recipeId),
    event(43958, 345776.806103, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Recycling-3", recipeId),
    event(43959, 345776.806630, "UNIT_SPELLCAST_STOP", "player", "Cast-Recycling-3", recipeId),
    event(43960, 345776.830418, "TRADE_SKILL_CRAFT_BEGIN", recipeId),
    event(44001, 345776.924349, "TRADE_SKILL_ITEM_CRAFTED_RESULT", {
      operationID = 2010458240, itemID = 243581, quantity = 3, craftingQuality = 1,
      bonusCraft = false, firstCraftReward = false, concentrationSpent = 0,
      concentrationCurrencyID = 3164, hasIngenuityProc = false, ingenuityRefund = 147, multicraft = 0,
      resourcesReturned = { { reagent = { itemID = 245807 }, quantity = 3 } },
    }),
  },
}
