local function scenario(name, operationID, result)
  result.operationID = operationID
  result.itemID = 123
  return {
    name = name,
    events = {
      { name = "TRADE_SKILL_CRAFT_BEGIN", arguments = { n = 1, 456 } },
      { name = "UNIT_SPELLCAST_SUCCEEDED", arguments = { n = 4, "player", "Cast-" .. operationID, 456 } },
      { name = "TRADE_SKILL_ITEM_CRAFTED_RESULT", arguments = { n = 1, result } },
    },
  }
end

return {
  scenario("basic", 1, { quantity = 1 }),
  scenario("concentration", 2, { quantity = 1, concentrationSpent = 100, ingenuityRefund = 0 }),
  scenario("ingenuity", 3, { quantity = 1, concentrationSpent = 100, ingenuityRefund = 50, hasIngenuityProc = true }),
  scenario("multicraft", 4, { quantity = 5, multicraft = 3, bonusCraft = true }),
  scenario("resourcefulness", 5, {
    quantity = 1,
    resourcesReturned = { { reagent = { itemID = 789 }, quantity = 2 } },
  }),
}