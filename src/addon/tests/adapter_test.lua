local root = arg[1] or "src/ArtisanLogbook"
local addon = {}
assert(loadfile(root .. "/Flavors/Registry.lua"))("ArtisanLogbook", addon)
assert(loadfile(root .. "/Flavors/Retail/Adapter.lua"))("ArtisanLogbook", addon)
local passed = 0

local function test(name, callback)
  callback()
  passed = passed + 1
  print("PASS " .. name)
end

local function environment()
  local hooks = {}
  local frame = { events = {}, units = {} }
  function frame:RegisterEvent(event)
    if event == "TRADE_SKILL_CURRENCY_REWARD_RESULT" then error("unsupported") end
    self.events[event] = true
  end
  function frame:RegisterUnitEvent(event, unit)
    self.units[event] = unit
    self:RegisterEvent(event)
  end
  function frame:IsEventRegistered(event) return self.events[event] or false end
  function frame:SetScript(_, callback) self.onEvent = callback end
  local api = {
    WOW_PROJECT_ID = 1,
    WOW_PROJECT_MAINLINE = 1,
    CreateFrame = function() return frame end,
    C_TradeSkillUI = { CraftRecipe = function() end, CraftEnchant = function() end },
    hooksecurefunc = function(_, name, callback) hooks[name] = callback end,
  }
  return api, frame, hooks
end

test("Retail registers player-only unit events and reports unsupported events", function()
  local api, frame = environment()
  local received = {}
  local adapter = addon.CreateFlavorAdapter(api, function(event, ...)
    received[#received + 1] = { event = event, n = select("#", ...), ... }
  end)
  assert(adapter.capabilities.flavor == "retail")
  assert(frame.units.UNIT_SPELLCAST_SUCCEEDED == "player")
  assert(adapter.capabilities.events.TRADE_SKILL_ITEM_CRAFTED_RESULT)
  assert(adapter.capabilities.events.TRADE_SKILL_CURRENCY_REWARD_RESULT == false)
  assert(adapter.capabilities.measurements.concentrationSpent == nil)
  frame.onEvent(frame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 456, nil)
  assert(received[1].n == 4 and received[1][2] == "Cast-1")
end)

test("post-hooks preserve batch arguments and do not replace craft functions", function()
  local api, _, hooks = environment()
  local original = api.C_TradeSkillUI.CraftRecipe
  local received = {}
  local adapter = addon.CreateFlavorAdapter(api, function(event, ...)
    received[#received + 1] = { event = event, n = select("#", ...), ... }
  end)
  hooks.CraftRecipe(456, 3, { { itemID = 123, quantity = 2 } }, nil, nil, true)
  hooks.CraftEnchant(789, 1, nil, nil, false)
  assert(api.C_TradeSkillUI.CraftRecipe == original)
  assert(received[1].event == "CALL_POST:C_TradeSkillUI.CraftRecipe")
  assert(received[1].n == 6 and received[1][2] == 3 and received[1][6] == true)
  assert(received[2].event == "CALL_POST:C_TradeSkillUI.CraftEnchant")
  assert(adapter.capabilities.hooks.CraftSalvage == false)
end)

test("opt-in post-call probes preserve allocations, quality and operation quote separately from results", function()
  local api, frame, hooks = environment()
  local received, queries = {}, {}
  api.C_TradeSkillUI.GetItemReagentQualityByItemInfo = function(itemID)
    return itemID == 101 and 2 or nil
  end
  api.C_TradeSkillUI.GetCraftingOperationInfo = function(...)
    queries[#queries + 1] = { n = select("#", ...), ... }
    return { baseSkill = 120, baseDifficulty = 200, concentrationCost = 80, craftingQuality = 3 }
  end
  local recording = false
  addon.CreateFlavorAdapter(api, function(event, ...)
    received[#received + 1] = { event = event, ... }
  end, function() return recording end)
  local reagents = { { reagent = { itemID = 101 }, dataSlotIndex = 1, quantity = 3 },
    { reagent = { itemID = 102 }, dataSlotIndex = 1, quantity = 2 } }
  hooks.CraftRecipe(456, 2, reagents, nil, nil, true)
  assert(#received == 1 and #queries == 0)
  recording = true
  hooks.CraftRecipe(456, 2, reagents, nil, nil, true)
  frame.onEvent(frame, "TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 9 })
  assert(received[2].event == "CALL_POST:C_TradeSkillUI.CraftRecipe")
  assert(received[2][3] == reagents and received[2][2] == 2)
  assert(received[3].event == "REQUEST_PROBE:C_TradeSkillUI.CraftRecipe")
  assert(received[3][1].operation == "ok" and received[3][1].info.concentrationCost == 80)
  assert(received[3][1].reagentQuality[1].quality == 2)
  assert(received[3][1].reagentQuality[2].quality == nil)
  assert(queries[1].n == 4 and queries[1][3] == nil and queries[1][4] == true)
  assert(received[4].event == "TRADE_SKILL_ITEM_CRAFTED_RESULT")
end)

test("order queries and recraft gaps remain diagnostic, without guessed values", function()
  local api, _, hooks = environment()
  local received = {}
  api.C_TradeSkillUI.RecraftRecipeForOrder = function() end
  api.C_CraftingOrders = { GetClaimedOrder = function()
    return {
      orderID = 77,
      customerName = "other-player",
      customerNotes = "secret",
      minQuality = 3,
      tipAmount = 500,
      crafterGuid = "Player-1",
      reagents = {
        {
          source = 1,
          slotIndex = 2,
          isBasicReagent = true,
          reagentInfo = { dataSlotIndex = 5, quantity = 3, reagent = { itemID = 190311 } },
        },
      },
    }
  end }
  api.C_TradeSkillUI.GetCraftingOperationInfoForOrder = function(recipe, reagents, order, concentrate)
    assert(recipe == 456 and order == 77 and concentrate == false)
    return { concentrationCost = 0 }
  end
  addon.CreateFlavorAdapter(api, function(event, ...)
    received[#received + 1] = { event = event, ... }
  end, function() return true end)
  hooks.CraftRecipe(456, 1, {}, nil, 77, false)
  assert(received[2][1].operation == "ok" and received[2][1].info.concentrationCost == 0)
  assert(received[2][1].claimedOrderStatus == "matched")
  assert(received[2][1].claimedOrder.minQuality == 3)
  assert(received[2][1].claimedOrder.tipAmount == 500)
  assert(received[2][1].claimedOrder.customerName == nil and received[2][1].claimedOrder.customerNotes == nil)
  assert(received[2][1].claimedOrder.crafterGuid == nil)
  assert(received[2][1].claimedOrder.reagents[1].source == 1)
  assert(received[2][1].claimedOrder.reagents[1].reagentInfo.reagent.itemID == 190311)
  hooks.CraftRecipe(456, 1, {}, nil, nil, nil)
  assert(received[4][1].operation == "not-queried" and received[4][1].info == nil)
  hooks.RecraftRecipeForOrder(77, "private-guid", {}, nil, true)
  assert(received[6][1].operation == "no-recipe-id-in-call")
  assert(received[6][1].claimedOrderStatus == "matched")
end)

test("UI quote arguments are observed separately before batch request and results", function()
  local api, frame, hooks = environment()
  api.C_TradeSkillUI.GetCraftingOperationInfo = function()
    return { baseSkill = 122, concentrationCost = 60 }
  end
  local received = {}
  local adapter = addon.CreateFlavorAdapter(api, function(event, ...)
    received[#received + 1] = { event = event, n = select("#", ...), ... }
  end, function() return true end)
  assert(adapter.capabilities.quoteHooks.GetCraftingOperationInfo)
  assert(adapter.capabilities.quoteHooks.GetCraftingOperationInfoForOrder == false)
  local reagents = { { reagent = { itemID = 101 }, dataSlotIndex = 2, quantity = 4 } }
  hooks.GetCraftingOperationInfo(456, reagents, nil, true)
  hooks.CraftRecipe(456, 2, reagents, nil, nil, true)
  frame.onEvent(frame, "TRADE_SKILL_CRAFT_BEGIN", 456)
  frame.onEvent(frame, "TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 9 })
  frame.onEvent(frame, "TRADE_SKILL_CRAFT_BEGIN", 456)
  frame.onEvent(frame, "TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 10 })
  assert(received[1].event == "QUOTE_CALL_POST:C_TradeSkillUI.GetCraftingOperationInfo")
  assert(received[1].n == 4 and received[1][2] == reagents and received[1][4] == true)
  assert(received[2].event == "QUOTE_PROBE:C_TradeSkillUI.GetCraftingOperationInfo")
  assert(received[2][1].status == "ok" and received[2][1].info.baseSkill == 122)
  assert(received[3].event == "CALL_POST:C_TradeSkillUI.CraftRecipe")
  assert(received[4].event == "REQUEST_PROBE:C_TradeSkillUI.CraftRecipe")
  assert(received[5].event == "TRADE_SKILL_CRAFT_BEGIN" and received[6].event == "TRADE_SKILL_ITEM_CRAFTED_RESULT")
  assert(received[8][1].operationID == 10)
end)

test("personal submission freezes submitted allocations while diagnostic tracing is paused", function()
  local api, _, hooks = environment()
  local submissions, invalidations, kinds = {}, 0, {}
  api.C_TradeSkillUI.GetCraftingOperationInfo = function(recipe, reagents, order, concentration)
    assert(recipe == 456 and order == nil and concentration == true)
    assert(reagents[1].reagent.itemID == 101)
    return { concentrationCost = 81, baseSkill = 120 }
  end
  addon.CreateFlavorAdapter(api, function() end, function() return false end,
    function(recipe, count, concentration, quote, selections)
      submissions[#submissions + 1] = { recipe, count, concentration, quote, selections }
    end, function(kind) invalidations = invalidations + 1; kinds[invalidations] = kind end)
  local selected = { { dataSlotIndex = 2, quantity = 3, reagent = { itemID = 101 } },
    { dataSlotIndex = 2, quantity = 0, reagent = { itemID = 102 } } }
  hooks.GetCraftingOperationInfo(456, selected, nil, true)
  hooks.CraftRecipe(456, 3, selected, nil, nil, true)
  selected[1].quantity = 99
  assert(#submissions == 1 and submissions[1][2] == 3)
  assert(submissions[1][4].concentrationCost == 81)
  assert(submissions[1][5][1].quantity == 3 and submissions[1][5][2].quantity == 0)
  hooks.CraftRecipe(456, 1, {}, nil, 77, true)
  assert(#submissions == 1 and invalidations == 1)
  hooks.CraftEnchant(456, 1, {}, nil, true)
  assert(invalidations == 2 and kinds[1] == "CraftRecipe" and kinds[2] == "CraftEnchant")
end)

test("schematic snapshots trust only single-item fixed basic slots beside quote slots", function()
  local function slot(fields)
    local row = { dataSlotType = 1, reagentType = 1, required = true, hiddenInCraftingForm = false,
      quantityRequired = 2, dataSlotIndex = 4, reagents = { { itemID = 243060 } }, variableQuantities = {} }
    for key, value in pairs(fields or {}) do row[key] = value end
    return row
  end
  local function capture(slots, configure)
    local api, _, hooks = environment()
    api.Enum = { TradeskillSlotDataType = { Reagent = 1, ModifiedReagent = 2, Currency = 3 },
      CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 } }
    local levels = {}
    api.C_TradeSkillUI.GetRecipeSchematic = function(recipeId, isRecraft, recipeLevel)
      levels[#levels + 1] = { recipeId, isRecraft, recipeLevel }
      return { recipeID = recipeId, reagentSlotSchematics = slots }
    end
    if configure then configure(api) end
    local submitted
    addon.CreateFlavorAdapter(api, function() end, function() return false end,
      function(_, _, _, _, _, inputs) submitted = inputs end, function() end)
    hooks.CraftRecipe(456, 1, {}, 3, nil, false)
    return submitted, levels
  end
  local modified = slot({ dataSlotType = 2, reagents = { { itemID = 101 }, { itemID = 102 } } })
  local currency = slot({ dataSlotType = 3, reagents = { { currencyID = 9 } } })
  local inputs, levels = capture({ modified, slot(), currency })
  assert(levels[1][1] == 456 and levels[1][2] == false and levels[1][3] == 3)
  assert(inputs.complete == false and #inputs.fixed == 0)
  inputs = capture({ slot(), currency })
  assert(inputs.complete == true and #inputs.fixed == 1)
  assert(inputs.fixed[1].itemID == 243060 and inputs.fixed[1].quantity == 2 and inputs.fixed[1].dataSlotIndex == 4)
  for _, partial in ipairs({
    slot({ reagents = { { itemID = 1 }, { itemID = 2 } } }),
    slot({ variableQuantities = { { reagent = { itemID = 243060 }, quantity = 3 } } }),
    slot({ hiddenInCraftingForm = true }), slot({ required = false }), slot({ reagentType = 3 }),
    slot({ quantityRequired = 0 }), slot({ reagents = { { currencyID = 9 } } }), slot({ dataSlotType = 9 }), 7,
  }) do
    inputs = capture({ modified, partial })
    assert(inputs and inputs.complete == false)
  end
  assert(capture({ slot() }, function(api) api.Enum = nil end) == nil)
  assert(capture({ slot() }, function(api)
    api.C_TradeSkillUI.GetRecipeSchematic = function() error("unavailable") end
  end) == nil)
  assert(capture({ slot() }, function(api)
    api.C_TradeSkillUI.GetRecipeSchematic = function() return { recipeID = 999, reagentSlotSchematics = {} } end
  end) == nil)
  assert(capture({ slot() }, function(api)
    api.issecretvalue = function(value) return type(value) == "table" and value.recipeID ~= nil end
  end) == nil)
end)

test("empty and invalid quotes cannot resurrect removed submitted selections", function()
  local api, _, hooks = environment()
  local submissions = {}
  api.C_TradeSkillUI.GetCraftingOperationInfo = function()
    return { concentrationCost = 80 }
  end
  addon.CreateFlavorAdapter(api, function() end, function() return false end,
    function(recipe, count, concentration, quote, selections)
      submissions[#submissions + 1] = { recipe = recipe, quote = quote, selections = selections }
    end)
  local first = { { dataSlotIndex = 1, quantity = 3, reagent = { itemID = 101 } } }
  local newer = { { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 102 } } }
  hooks.GetCraftingOperationInfo(456, first, nil, false)
  hooks.GetCraftingOperationInfo(456, {}, nil, false)
  hooks.GetCraftingOperationInfo(456, { { dataSlotIndex = 1, quantity = 0,
    reagent = { itemID = 103 } } }, nil, false)
  hooks.GetCraftingOperationInfo(456, { { dataSlotIndex = 0, quantity = 1,
    reagent = { itemID = 106 } } }, nil, false)
  hooks.GetCraftingOperationInfo(456, { { dataSlotIndex = 1, quantity = 1,
    reagent = { itemID = 0 } } }, nil, false)
  hooks.GetCraftingOperationInfo(456, { { dataSlotIndex = 1, quantity = 4,
    reagent = { itemID = 104 } } }, 77, false)
  hooks.GetCraftingOperationInfo(456, { { quantity = 1, reagent = { itemID = 105 } } }, nil, false)
  hooks.GetCraftingOperationInfo(789, newer, nil, false)
  hooks.CraftRecipe(456, 1, {}, nil, nil, false)
  assert(#submissions[1].selections == 0)
  hooks.GetCraftingOperationInfo(456, first, nil, false)
  hooks.GetCraftingOperationInfo(456, newer, nil, false)
  hooks.CraftRecipe(456, 1, newer, nil, nil, false)
  assert(submissions[2].selections[1].reagent.itemID == 102)
end)

test("submissions never inherit quotes from another level, concentration or prior batch", function()
  local api, frame, hooks = environment()
  local submissions = {}
  api.C_TradeSkillUI.GetCraftingOperationInfo = function() return {} end
  addon.CreateFlavorAdapter(api, function() end, function() return false end,
    function(recipe, count, concentration, quote, selections)
      submissions[#submissions + 1] = { recipe = recipe, concentration = concentration,
        selections = selections }
    end)
  hooks.GetCraftingOperationInfo(456, { { dataSlotIndex = 1, quantity = 1,
    reagent = { itemID = 101 } } }, nil, false)
  hooks.GetCraftingOperationInfo(456, { { dataSlotIndex = 1, quantity = 2,
    reagent = { itemID = 102 } } }, nil, true)
  hooks.GetCraftingOperationInfo(789, { { dataSlotIndex = 1, quantity = 3,
    reagent = { itemID = 103 } } }, nil, false)
  hooks.CraftRecipe(456, 1, {}, nil, nil, true)
  hooks.CraftRecipe(456, 1, {}, nil, nil, true)
  hooks.CraftRecipe(789, 1, {}, nil, nil, false)
  hooks.CraftRecipe(456, 1, {}, nil, nil, false)
  for index = 1, 4 do assert(#submissions[index].selections == 0) end
  hooks.GetCraftingOperationInfo(456, {}, nil, false)
  hooks.CraftRecipe(456, 1, { { dataSlotIndex = 1, quantity = 7,
    reagent = { itemID = 999 } } }, nil, nil, false)
  assert(submissions[5].selections[1].reagent.itemID == 999)
  hooks.GetCraftingOperationInfo(456, { { dataSlotIndex = 1, quantity = 2,
    reagent = { itemID = 101 } } }, nil, false)
  frame.onEvent(frame, "TRADE_SKILL_CLOSE")
  hooks.CraftRecipe(456, 1, {}, nil, nil, false)
  assert(#submissions[6].selections == 0)
end)

test("quote probe suppresses its own nested hook and stays idle while paused", function()
  local api, _, hooks = environment()
  local received, calls = {}, 0
  api.C_TradeSkillUI.GetCraftingOperationInfo = function(...)
    calls = calls + 1
    hooks.GetCraftingOperationInfo(...)
    return nil
  end
  local recording = false
  addon.CreateFlavorAdapter(api, function(event, ...)
    received[#received + 1] = { event = event, ... }
  end, function() return recording end)
  hooks.GetCraftingOperationInfo(456, {}, nil, false)
  assert(calls == 0 and #received == 0)
  recording = true
  hooks.GetCraftingOperationInfo(456, {}, nil, false)
  assert(calls == 1 and #received == 2)
  assert(received[2][1].status == "nil" and received[2][1].info == nil)
end)

test("query failures do not prevent later craft results", function()
  local api, frame, hooks = environment()
  local received = {}
  api.C_TradeSkillUI.GetCraftingOperationInfo = function() error("unavailable") end
  addon.CreateFlavorAdapter(api, function(event, ...)
    received[#received + 1] = { event = event, ... }
  end, function() return true end)
  hooks.CraftRecipe(456, 1, {}, nil, nil, false)
  frame.onEvent(frame, "TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 22 })
  assert(received[2][1].operation == "error" and received[2][1].info == nil)
  assert(received[3].event == "TRADE_SKILL_ITEM_CRAFTED_RESULT")
end)

test("target-dependent quotes stay unavailable and quote hook errors stay contained", function()
  local api, _, hooks = environment()
  local received = {}
  api.C_TradeSkillUI.CraftSalvage = function() end
  api.C_TradeSkillUI.CraftEnchant = function() end
  api.C_TradeSkillUI.GetCraftingOperationInfo = function() error("should not query target-dependent quote") end
  addon.CreateFlavorAdapter(api, function(event, ...)
    received[#received + 1] = { event = event, ... }
  end, function() return true end)
  hooks.CraftEnchant(456, 1, { { quantity = 2 } }, "target", false)
  assert(received[2][1].operation == "unavailable")
  hooks.CraftSalvage(456, 1, "target", { { quantity = 1 } }, false)
  assert(received[4][1].operation == "unavailable")
  hooks.GetCraftingOperationInfo(456, {}, nil, false)
  assert(received[6][1].status == "error")
end)

test("capture failures cannot propagate through a craft hook", function()
  local api, frame, hooks = environment()
  local adapter = addon.CreateFlavorAdapter(api, function() error("capture failure") end)
  hooks.CraftRecipe(456)
  frame.onEvent(frame, "TRADE_SKILL_CRAFT_BEGIN", 456)
  assert(adapter.capabilities.captureError == true)
end)

test("missing trade skill APIs or hooks do not break event registration", function()
  local api = environment()
  api.C_TradeSkillUI = nil
  api.hooksecurefunc = nil
  local adapter = addon.CreateFlavorAdapter(api, function() end)
  assert(adapter.capabilities.hooks.CraftRecipe == false)
  assert(adapter.capabilities.events.TRADE_SKILL_CRAFT_BEGIN)
end)

test("unsupported flavors never touch Retail APIs", function()
  local adapter = addon.CreateFlavorAdapter({ WOW_PROJECT_ID = 2, WOW_PROJECT_MAINLINE = 1 }, function() end)
  assert(adapter.capabilities.flavor == "other" and adapter.frame == nil)
  assert(next(adapter.capabilities.measurements) == nil)
end)

test("known non-Retail clients get an explicit empty flavor boundary", function()
  local api = { WOW_PROJECT_ID = 2, WOW_PROJECT_CLASSIC = 2 }
  local name, projectID = addon.DetectFlavor(api)
  local adapter = addon.CreateFlavorAdapter(api, function() end)
  assert(name == "classic" and projectID == 2)
  assert(adapter.capabilities.flavor == "classic")
  assert(next(adapter.capabilities.events) == nil and next(adapter.capabilities.measurements) == nil)
end)

test("review F1-F3 reconcile submitted slots through ledger API reload and repair", function()
  local function slot(index, item, quantity, fields)
    local row = { dataSlotType = 2, reagentType = 1, required = true,
      dataSlotIndex = index, quantityRequired = quantity, reagents = { { itemID = item } } }
    for key, value in pairs(fields or {}) do row[key] = value end
    return row
  end
  local function selection(index, item, quantity)
    return { dataSlotIndex = index, reagent = { itemID = item }, quantity = quantity }
  end
  local function capture(slots, submitted, quoted, count, inaccessible, negative)
    local api, _, hooks = environment()
    if inaccessible then api.canaccesstable = function(value) return value ~= submitted end end
    api.Enum = { TradeskillSlotDataType = { Reagent = 1, ModifiedReagent = 2, Currency = 3 },
      CraftingReagentType = { Basic = 1 } }
    api.C_TradeSkillUI.GetRecipeSchematic = function(recipeId, _, level)
      assert(level == 3)
      return { recipeID = recipeId, reagentSlotSchematics = slots }
    end
    api.C_TradeSkillUI.GetCraftingOperationInfo = function() return {} end
    local core = {}
    assert(loadfile(root .. "/Storage/Ledger.lua"))("ArtisanLogbook", core)
    assert(loadfile(root .. "/Core/API.lua"))("ArtisanLogbook", core)
    local clock = { wall = function() return 1800000000 end }
    core.ledger = assert(core.Ledger.New(nil, clock))
    assert(core.ledger:CreateSession({}))
    addon.CreateFlavorAdapter(api, function() end, function() return false end,
      function(...) return assert(core.ledger:SubmitCraft(...)) end,
      function(kind) core.ledger:InvalidateCraft(kind) end)
    hooks.GetCraftingOperationInfo(456, quoted or {}, nil, false)
    hooks.GetCraftingOperationInfo(456, {}, nil, false)
    hooks.CraftRecipe(456, count or 1, submitted, 3, nil, false)
    for index = 1, count or 1 do
      assert(core.ledger:RecordResult({ operationID = index, itemID = 900, quantity = 1,
        resourcesReturned = not negative and { { reagent = { itemID = 100 }, quantity = 2 } } or nil }))
    end
    local function check()
      local outcomes = ArtisanLogbookAPI.GetRecipeOutcomes(456)
      local page = ArtisanLogbookAPI.GetRecipeReagentStatistics(456)
      return outcomes, page.reagents
    end
    local before, items = check()
    core.ledger = assert(core.Ledger.New(core.ledger.database, clock))
    local after, reloadedItems = check()
    assert(after.totals.inputCompleteCount == before.totals.inputCompleteCount)
    assert(after.totals.matchedCraftCount == before.totals.matchedCraftCount)
    for index, row in ipairs(items) do
      assert(row.matchedCraftCount == reloadedItems[index].matchedCraftCount)
      assert(row.matchedAllocatedQuantity == reloadedItems[index].matchedAllocatedQuantity)
      assert(row.returnedQuantity == reloadedItems[index].returnedQuantity)
    end
    return core.ledger, before, items
  end
  local quote = { selection(1, 100, 5) }
  local cases = {
    { slots = { slot(1, 100, 5), slot(2, 200, 3) }, submitted = quote, matched = true },
    { slots = { slot(1, 100, 5) }, submitted = { selection(1, 100, 4) } },
    { slots = { [1] = slot(1, 100, 5), [3] = slot(3, 200, 3) }, submitted = quote },
    { slots = { slot(1, 100, 5), slot(2, 100, 3, { dataSlotType = 1,
        variableQuantities = { { quantity = 3 } } }) }, submitted = quote },
    { slots = { slot(1, 100, 5), slot(2, 100, 3) }, submitted = quote },
    { slots = { slot(1, 100, 5) }, submitted = {}, count = 2 },
    { slots = { slot(1, 100, 5) }, submitted = { selection(1, 200, 5) } },
    { slots = { slot(1, 100, 5), slot(2, 200, 3) }, submitted = { selection(1, 100, 5), selection(2, 100, 3) } },
    { slots = { slot(1, 100, 5), slot(1, 200, 3) }, submitted = quote },
    { slots = { slot(1, 100, 5, { reagentType = 3 }) }, submitted = quote },
    { slots = { slot(1, 100, 5), slot(2, 200, 1, { required = false }) },
      submitted = { selection(1, 100, 5), selection(2, 200, 2) }, matched = true },
    { slots = { slot(1, 100, 5) }, submitted = { [2] = selection(1, 100, 5) } },
  }
  for _, case in ipairs(cases) do
    if case.submitted[2] and not case.submitted[1] then
      local ledger = capture(case.slots, case.submitted, quote)
      assert(#ledger.database.requests == 0)
      assert(ledger.database.crafts[1].outcomeSource == "unverified")
    else
      local ledger, outcomes, items = capture(case.slots, case.submitted, quote, case.count)
      assert(ledger.database.crafts[1].inputComplete == nil)
      assert(outcomes.totals.inputCompleteCount == 0)
      for _, row in ipairs(ledger.database.reagentSeries) do
        if row.itemId == 100 then
          assert(((row.matchedCraftCount or 0) > 0) == (case.matched == true))
        end
      end
      for _, row in ipairs(items) do
        if row.item.id == 100 then
          assert((row.matchedCraftCount > 0) == (case.matched == true))
        end
      end
    end
  end
  local ledger = capture({ slot(1, 100, 5), slot(2, 200, 1, { required = false }) }, quote, quote)
  assert(ledger.database.crafts[1].inputComplete == true)
  ledger = capture({ slot(1, 100, 1, { required = false }) }, {}, quote, nil, false, true)
  assert(ledger.database.requests[1].allocations == nil)
  assert(ledger.database.crafts[1].inputComplete == true and #ledger.database.reagentSeries == 0)
  ledger = capture({ slot(1, 100, 5) }, quote, { selection(1, 200, 5) })
  assert(ledger.database.requests[1].allocations[1].itemId == 100)
  assert(ledger.database.crafts[1].inputComplete == true)
  ledger = capture({ slot(1, 100, 5) }, quote, quote, nil, true)
  assert(ledger.database.requests[1].allocations == nil and ledger.database.crafts[1].inputComplete == nil)
end)

test("review F4 unknown cleared failed and malformed primary contexts fail closed", function()
  local core = {}
  assert(loadfile(root .. "/Storage/Ledger.lua"))("ArtisanLogbook", core)
  local clock = { wall = function() return 1800000000 end }
  local ledger = assert(core.Ledger.New(nil, clock))
  assert(ledger:CreateSession({}))
  local result = { operationID = 1, itemID = 900, quantity = 1 }
  assert(ledger:RecordResult(result).outcomeSource == "unverified")
  ledger:InvalidateCraft("CraftSalvage")
  ledger:CancelCraft()
  assert(ledger:RecordResult(result).outcomeSource == "unverified")
  result.resourcesReturned = { { reagent = { itemID = 100 }, quantity = 2 } }
  local positive = assert(ledger:RecordResult(result))
  assert(positive.hasResourcefulnessProc == true and positive.resourcefulnessComplete == nil)
  ledger:InvalidateCraft("CraftEnchant")
  assert(ledger:RecordResult({}).outcomeSource == "unverified")
  result.resourcesReturned = nil
  assert(ledger:CreateSession({}))
  ledger:InvalidateCraft("CraftEnchant")
  assert(ledger:RecordResult(result).outcomeSource == "native")
  local api, _, hooks = environment()
  addon.CreateFlavorAdapter(api, function() end, function() return false end,
    function() error("failed submission") end, function(kind) ledger:InvalidateCraft(kind) end)
  hooks.CraftRecipe(456, 1, {}, nil, nil, false)
  assert(ledger:RecordResult(result).outcomeSource == "unverified")
  ledger:CancelCraft()
  assert(ledger:CreateSession({}))
  assert(ledger:SubmitCraft(456, 1, false))
  assert(ledger:RecordResult({}).outcomeSource == "unverified")
  assert(ledger.pendingRequest.remaining == 1)
  assert(ledger:RecordResult(result).outcomeSource == "native")
  ledger:BeginCraft(456)
  ledger:BeginCraft(789)
  assert(ledger:RecordResult(result).outcomeSource == "unverified")
  ledger:CancelCraft()
  local unavailable, frame = environment()
  unavailable.hooksecurefunc = function() error("hook installation failed") end
  local adapter = addon.CreateFlavorAdapter(unavailable, function(event, payload)
    if event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
      assert(ledger:RecordResult(payload).outcomeSource == "unverified")
    end
  end)
  assert(adapter.capabilities.hooks.CraftRecipe == false)
  frame.onEvent(frame, "TRADE_SKILL_ITEM_CRAFTED_RESULT", result)
  local loaded = assert(core.Ledger.New(ledger.database, clock))
  local observed = 0
  for _, row in ipairs(loaded.database.craftSeries) do
    observed = observed + row.resourcefulnessAuthoritativeProcCountObservedCount
  end
  assert(observed == 2)
end)

test("unverified malformed operation IDs cannot acquire a newer request", function()
  local core = {}
  assert(loadfile(root .. "/Storage/Ledger.lua"))("ArtisanLogbook", core)
  local ledger = assert(core.Ledger.New(nil, { wall = function() return 1800000000 end }))
  assert(ledger:CreateSession({}))
  assert(ledger:RecordResult({ operationID = 99 }).outcomeSource == "unverified")
  local request = assert(ledger:SubmitCraft(456, 1, false))
  local late = assert(ledger:RecordResult({ operationID = 99, itemID = 900, quantity = 1 }))
  assert(late.outcomeSource == "unverified" and late.requestId == nil and late.inputComplete == nil)
  assert(ledger.pendingRequest.id == request.id and ledger.pendingRequest.remaining == 1)
  local actual = assert(ledger:RecordResult({ operationID = 100, itemID = 900, quantity = 1 }))
  assert(actual.outcomeSource == "native" and actual.requestId == request.id)
end)

print(string.format("%d adapter tests passed", passed))
