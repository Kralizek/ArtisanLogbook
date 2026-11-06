local root = arg[1] or "src/ArtisanLogbook_Tracer"
local testsRoot = arg[2] or "tests"
local addon = {}
assert(loadfile(root .. "/Capture/Trace.lua"))("ArtisanLogbook_Tracer", addon)
assert(loadfile(root .. "/Capture/Probes.lua"))("ArtisanLogbook_Tracer", addon)
addon.capabilities = {}

local function environment()
  local hooks = {}
  local tradeSkill = {
    CraftRecipe = function() end,
    CraftEnchant = function() end,
    CraftSalvage = function() end,
    RecraftRecipe = function() end,
    RecraftRecipeForOrder = function() end,
    GetCraftingOperationInfo = function(recipe, reagents, order, concentration)
      return { recipeID = recipe, concentrationCost = concentration and 80 or 0 }
    end,
    GetCraftingOperationInfoForOrder = function(recipe, reagents, order, concentration)
      return { recipeID = recipe, orderID = order, concentrationCost = concentration and 80 or 0 }
    end,
    GetItemReagentQualityByItemInfo = function(itemID) return itemID == 101 and 2 or nil end,
  }
  local api = {
    C_TradeSkillUI = tradeSkill,
    hooksecurefunc = function(_, name, callback) hooks[name] = callback; return true end,
  }
  return api, hooks
end

local received, verbose = {}, false
local api, hooks = environment()
local function emit(event, ...)
  received[#received + 1] = { event = event, arguments = { n = select("#", ...), ... } }
end
addon.RegisterDiagnosticProbes(api, emit, function() return verbose end)

hooks.CraftRecipe(456, 2, { { dataSlotIndex = 1, quantity = 3, reagent = { itemID = 101 } } }, nil, nil, true)
assert(#received == 1 and received[1].event == "CALL_POST:C_TradeSkillUI.CraftRecipe")
assert(received[1].arguments[1] == 456 and received[1].arguments[2] == 2)
hooks.GetCraftingOperationInfo(456, {}, nil, true)
assert(#received == 1)

verbose = true
local selections = { { dataSlotIndex = 1, quantity = 3, reagent = { itemID = 101 } } }
hooks.CraftRecipe(456, 2, selections, nil, nil, true)
assert(received[2].event == "CALL_POST:C_TradeSkillUI.CraftRecipe")
assert(received[2].arguments[3] == selections)
assert(received[3].event == "REQUEST_PROBE:C_TradeSkillUI.CraftRecipe")
assert(received[3].arguments[1].operation == "ok")
assert(received[3].arguments[1].info.concentrationCost == 80)
assert(received[3].arguments[1].reagentQuality[1].quality == 2)

local quoteStart = #received + 1
hooks.GetCraftingOperationInfo(456, selections, nil, true)
assert(received[quoteStart].event == "QUOTE_CALL_POST:C_TradeSkillUI.GetCraftingOperationInfo")
assert(received[quoteStart].arguments[2] == selections)
assert(received[quoteStart + 1].event == "QUOTE_PROBE:C_TradeSkillUI.GetCraftingOperationInfo")
assert(received[quoteStart + 1].arguments[1].info.concentrationCost == 80)

api.C_TradeSkillUI.GetCraftingOperationInfo = function() error("salvage quote is target-dependent") end
local salvageStart = #received + 1
hooks.CraftSalvage(1229930, 184, { bagID = 5, slotIndex = 3 }, selections, false)
assert(received[salvageStart].event == "CALL_POST:C_TradeSkillUI.CraftSalvage")
assert(received[salvageStart].arguments[2] == 184 and received[salvageStart].arguments[4] == selections)
assert(received[salvageStart + 1].event == "REQUEST_PROBE:C_TradeSkillUI.CraftSalvage")
assert(received[salvageStart + 1].arguments[1].operation == "unavailable")

local fixture = dofile(testsRoot .. "/fixtures/retail-recycling-70448.lua")
local recorder = assert(addon.Trace.New(nil, {
  wall = function() return 1800000000 end,
  elapsed = function() return 1 end,
}))
assert(recorder:Start({ build = fixture.build, verbose = true }))
local traceApi, tracedHooks = environment()
addon.RegisterDiagnosticProbes(traceApi, function(event, ...)
  recorder:Capture(event, ...)
end, function() return true end)
for _, observed in ipairs(fixture.events) do
  if observed.name == "CALL_POST:C_TradeSkillUI.CraftSalvage" then
    tracedHooks.CraftSalvage(unpack(observed.arguments, 1, observed.arguments.n))
  elseif observed.name ~= "REQUEST_PROBE:C_TradeSkillUI.CraftSalvage" then
    recorder:Capture(observed.name, unpack(observed.arguments, 1, observed.arguments.n))
  end
end

local results, salvageCall, requestProbe = {}, false, false
for _, record in ipairs(recorder.database.records) do
  if record.event == "CALL_POST:C_TradeSkillUI.CraftSalvage" then salvageCall = true end
  if record.event == "REQUEST_PROBE:C_TradeSkillUI.CraftSalvage" then requestProbe = true end
  if record.event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
    local arguments = assert(loadstring("return " .. record.payload))()
    results[#results + 1] = arguments[1]
  end
end
assert(salvageCall and requestProbe and #results == 3)
assert(results[1].operationID == 3854211863 and results[2].operationID == 533880495)
assert(results[3].resourcesReturned[1].reagent.itemID == 245807)
assert(results[3].resourcesReturned[1].quantity == 3)
print("PASS normal/verbose probes and bounded salvage multi-output evidence")
