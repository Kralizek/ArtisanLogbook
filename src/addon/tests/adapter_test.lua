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
    return { orderID = 77, minQuality = 3, reagents = { { source = 1 } } }
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

test("salvage uses documented argument positions and quote hook errors stay contained", function()
  local api, _, hooks = environment()
  local received = {}
  api.C_TradeSkillUI.CraftSalvage = function() end
  api.C_TradeSkillUI.GetCraftingOperationInfo = function(recipe, reagents, guid, concentrate)
    assert(recipe == 456 and reagents[1].quantity == 1 and guid == nil and concentrate == false)
    return { concentrationCost = 0 }
  end
  addon.CreateFlavorAdapter(api, function(event, ...)
    received[#received + 1] = { event = event, ... }
  end, function() return true end)
  hooks.CraftSalvage(456, 1, "target", { { quantity = 1 } }, false)
  assert(received[2][1].operation == "ok")
  hooks.GetCraftingOperationInfo(456, {}, nil, false)
  assert(received[4][1].status == "error")
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

print(string.format("%d adapter tests passed", passed))
