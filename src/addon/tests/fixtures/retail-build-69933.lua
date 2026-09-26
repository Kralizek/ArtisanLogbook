local function event(name, arguments)
  return { name = name, arguments = arguments }
end

local function craft(recipeID, result, castToken, castBarID)
  return {
    event("TRADE_SKILL_CRAFT_BEGIN", { n = 1, recipeID }),
    event("CALL_POST:C_TradeSkillUI.CraftRecipe", {
      n = 6, [1] = recipeID, [2] = 1, [3] = {}, [6] = false,
    }),
    event("UNIT_SPELLCAST_SENT", {
      n = 4, [1] = "player", [3] = castToken, [4] = recipeID,
    }),
    event("UNIT_SPELLCAST_START", {
      n = 4, [1] = "player", [2] = castToken, [3] = recipeID, [4] = castBarID,
    }),
    event("UNIT_SPELLCAST_SUCCEEDED", {
      n = 4, [1] = "player", [2] = castToken, [3] = recipeID, [4] = castBarID,
    }),
    event("UNIT_SPELLCAST_STOP", {
      n = 4, [1] = "player", [2] = castToken, [3] = recipeID, [4] = castBarID,
    }),
    event("TRADE_SKILL_ITEM_CRAFTED_RESULT", { n = 1, result }),
  }
end

local basicAndMulticraft = {
  event("TRADE_SKILL_CRAFT_BEGIN", { n = 1, 1230868 }),
  event("CALL_POST:C_TradeSkillUI.CraftRecipe", {
    n = 6, [1] = 1230868, [2] = 1, [3] = {}, [6] = false,
  }),
  event("UNIT_SPELLCAST_SENT", {
    n = 4, [1] = "player", [3] = "Cast-Sanitized-1", [4] = 1230868,
  }),
  event("UNIT_SPELLCAST_START", {
    n = 4, [1] = "player", [2] = "Cast-Sanitized-1", [3] = 1230868, [4] = 1,
  }),
  event("UNIT_SPELLCAST_START", {
    n = 4, [1] = "player", [3] = 1230868, [4] = 2,
  }),
  event("UNIT_SPELLCAST_SUCCEEDED", {
    n = 4, [1] = "player", [2] = "Cast-Sanitized-1", [3] = 1230868, [4] = 2,
  }),
  event("UNIT_SPELLCAST_STOP", {
    n = 4, [1] = "player", [2] = "Cast-Sanitized-1", [3] = 1230868, [4] = 2,
  }),
  event("TRADE_SKILL_ITEM_CRAFTED_RESULT", { n = 1, {
    concentrationCurrencyID = 3161,
    concentrationSpent = 0,
    craftingQuality = 1,
    hasIngenuityProc = false,
    ingenuityRefund = 65,
    itemID = 241307,
    multicraft = 0,
    operationID = 3923109748,
    quantity = 5,
    resourcesReturned = { { quantity = 2, reagent = { itemID = 240991 } } },
  } }),
  event("TRADE_SKILL_CRAFT_BEGIN", { n = 1, 1230868 }),
  event("CALL_POST:C_TradeSkillUI.CraftRecipe", {
    n = 6, [1] = 1230868, [2] = 1, [3] = {}, [6] = false,
  }),
  event("UNIT_SPELLCAST_SENT", {
    n = 4, [1] = "player", [3] = "Cast-Sanitized-2", [4] = 1230868,
  }),
  event("UNIT_SPELLCAST_START", {
    n = 4, [1] = "player", [2] = "Cast-Sanitized-2", [3] = 1230868, [4] = 3,
  }),
  event("UNIT_SPELLCAST_SUCCEEDED", {
    n = 4, [1] = "player", [2] = "Cast-Sanitized-2", [3] = 1230868, [4] = 3,
  }),
  event("UNIT_SPELLCAST_STOP", {
    n = 4, [1] = "player", [2] = "Cast-Sanitized-2", [3] = 1230868, [4] = 3,
  }),
  event("TRADE_SKILL_ITEM_CRAFTED_RESULT", { n = 1, {
    concentrationCurrencyID = 3161,
    concentrationSpent = 0,
    craftingQuality = 1,
    hasIngenuityProc = false,
    ingenuityRefund = 65,
    itemID = 241307,
    multicraft = 10,
    operationID = 952287519,
    quantity = 15,
    resourcesReturned = { { quantity = 1, reagent = { itemID = 236761 } } },
  } }),
}

local concentrationBatch = {
  event("TRADE_SKILL_CRAFT_BEGIN", { n = 1, 1236083 }),
  event("CALL_POST:C_TradeSkillUI.CraftEnchant", {
    n = 5,
    [1] = 1236083,
    [2] = 2,
    [3] = {},
    [4] = { bagID = 0, slotIndex = 9 },
    [5] = true,
  }),
  event("UNIT_SPELLCAST_SENT", {
    n = 4, [1] = "player", [3] = "Cast-Sanitized-3", [4] = 1236083,
  }),
  event("UNIT_SPELLCAST_START", {
    n = 4, [1] = "player", [2] = "Cast-Sanitized-3", [3] = 1236083, [4] = 1,
  }),
  event("UNIT_SPELLCAST_START", {
    n = 4, [1] = "player", [3] = 1236083, [4] = 2,
  }),
  event("UNIT_SPELLCAST_SUCCEEDED", {
    n = 4, [1] = "player", [2] = "Cast-Sanitized-3", [3] = 1236083, [4] = 2,
  }),
  event("TRADE_SKILL_CRAFT_BEGIN", { n = 1, 1236083 }),
  event("CURRENCY_DISPLAY_UPDATE", { n = 5, 3163, 269, -185, 75, 13 }),
  event("TRADE_SKILL_ITEM_CRAFTED_RESULT", { n = 1, {
    concentrationCurrencyID = 3163,
    concentrationSpent = 185,
    craftingQuality = 2,
    hasIngenuityProc = false,
    ingenuityRefund = 93,
    itemID = 244005,
    multicraft = 0,
    operationID = 660565636,
    quantity = 1,
  } }),
  event("UNIT_SPELLCAST_SENT", {
    n = 4, [1] = "player", [3] = "Cast-Sanitized-4", [4] = 1236083,
  }),
  event("UNIT_SPELLCAST_START", {
    n = 4, [1] = "player", [2] = "Cast-Sanitized-4", [3] = 1236083, [4] = 2,
  }),
  event("UNIT_SPELLCAST_SUCCEEDED", {
    n = 4, [1] = "player", [2] = "Cast-Sanitized-4", [3] = 1236083, [4] = 2,
  }),
  event("UNIT_SPELLCAST_STOP", {
    n = 4, [1] = "player", [2] = "Cast-Sanitized-4", [3] = 1236083, [4] = 2,
  }),
  event("UPDATE_TRADESKILL_CAST_STOPPED", { n = 1, false }),
  event("CURRENCY_DISPLAY_UPDATE", { n = 5, 3163, 84, -185, 75, 13 }),
  event("TRADE_SKILL_ITEM_CRAFTED_RESULT", { n = 1, {
    concentrationCurrencyID = 3163,
    concentrationSpent = 185,
    craftingQuality = 2,
    hasIngenuityProc = false,
    ingenuityRefund = 93,
    itemID = 244005,
    multicraft = 0,
    operationID = 494621055,
    quantity = 1,
  } }),
}

local resourceReturns = {}
for index, data in ipairs({
  {
    recipeID = 1237557,
    operationID = 1373831620,
    itemID = 244615,
    returned = {
      { quantity = 4, reagent = { itemID = 236761 } },
      { quantity = 5, reagent = { itemID = 238511 } },
      { quantity = 6, reagent = { itemID = 238513 } },
    },
  },
  {
    recipeID = 1237554,
    operationID = 3202963410,
    itemID = 244618,
    returned = { { quantity = 13, reagent = { itemID = 238511 } } },
  },
  {
    recipeID = 1237548,
    operationID = 266641340,
    itemID = 244620,
    returned = {
      { quantity = 3, reagent = { itemID = 251665 } },
      { quantity = 14, reagent = { itemID = 238511 } },
      { quantity = 10, reagent = { itemID = 238513 } },
    },
  },
}) do
  local sequence = craft(data.recipeID, {
    concentrationCurrencyID = 3167,
    concentrationSpent = 0,
    craftingQuality = 5,
    hasIngenuityProc = false,
    ingenuityRefund = 0,
    itemID = data.itemID,
    multicraft = 0,
    operationID = data.operationID,
    quantity = 1,
    recraftable = true,
    resourcesReturned = data.returned,
  }, "Cast-Sanitized-Resource-" .. index, index)
  for _, observedEvent in ipairs(sequence) do
    resourceReturns[#resourceReturns + 1] = observedEvent
  end
end

local detailsUpdateBurst = {}
for _ = 1, 127 do
  detailsUpdateBurst[#detailsUpdateBurst + 1] = event("CRAFTING_DETAILS_UPDATE", { n = 0 })
end

return {
  build = "69933",
  version = "12.1.0",
  cases = {
    { name = "basic-and-multicraft", events = basicAndMulticraft },
    { name = "concentration-batch-two", events = concentrationBatch },
    { name = "resource-returns", events = resourceReturns },
    { name = "crafting-details-update-burst", events = detailsUpdateBurst },
  },
}
