local root = arg[1] or "src/ArtisanLogbook_Core"
local testsRoot = arg[2] or "tests"
local fixture = dofile(testsRoot .. "/fixtures/forever-alchemy-70862.lua")
local passed = 0
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end
local metadata = {}
for _, session in ipairs(fixture.sessions) do
  for _, event in ipairs(session.events) do
    local method = event.name:match("^API_PROBE:C_TradeSkillUI%.(.+)$")
    local observation = method and event.arguments[1]
    if observation and observation.status == "ok" then
      local value = observation.values[1]
      local id = method == "GetProfessionInfoByRecipeID" and
        (session.firstSequence == 31 and 2331 or 7183) or value.recipeID
      metadata[id] = metadata[id] or {}
      metadata[id][method] = copy(value)
    end
  end
end
-- Fortitude request/results are real; no Fortitude metadata was probed.
-- This synthetic ordinary schematic tests support, not native metadata availability.
metadata[2334] = copy(metadata[2331])
metadata[2334].GetRecipeInfo.recipeID = 2334
metadata[2334].GetRecipeInfo.name = "Elixir of Minor Fortitude"
metadata[2334].GetRecipeSchematic.recipeID = 2334
metadata[2334].GetRecipeSchematic.outputItemID = 2458
metadata[2334].GetRecipeSchematic.name = "Elixir of Minor Fortitude"

local function environment(options)
  options = options or {}
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.ArtisanLogbookDB = options.database
  env.WOW_PROJECT_ID, env.WOW_PROJECT_CAMELOT, env.WOW_PROJECT_MAINLINE = 18, 18, 1
  env.GetServerTime = function() return env.now or 1800000000 end
  env.GetBuildInfo = function() return fixture.version, fixture.build, "mock", fixture.interface end
  env.GetLocale = function() return "enUS" end
  env.UnitName = function() return "TestCrafter" end
  env.UnitGUID = function() return "Player-Test" end
  env.GetRealmName = function() return "TestRealm" end
  env.GetItemInfo = function(id) return "Item " .. id end
  env.C_AddOns = { GetAddOnMetadata = function() return "0.0.0-test" end }
  env.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
  env.Enum = {
    TradeskillRecipeType = { Item = 1, Salvage = 2, Enchant = 3, Gathering = 4 },
    TradeskillSlotDataType = { Reagent = 1, ModifiedReagent = 2, Currency = 3 },
    CraftingReagentType = { Basic = 1, Modifying = 2, Finishing = 3 },
  }
  local frames, hooks, diagnostics = {}, {}, {}
  env.CreateFrame = function()
    local frame = { events = {}, scripts = {} }
    function frame:RegisterEvent(event)
      if event == options.unsupportedEvent then error("unsupported event") end
      self.events[event] = true
    end
    function frame:RegisterUnitEvent(event) self:RegisterEvent(event) end
    function frame:IsEventRegistered(event) return self.events[event] == true end
    function frame:UnregisterEvent(event) self.events[event] = nil end
    function frame:SetScript(name, handler) self.scripts[name] = handler end
    frames[#frames + 1] = frame
    return frame
  end
  env.hooksecurefunc = function(_, name, handler) hooks[name] = handler end
  env.metadata = copy(metadata)
  env.quoteQueries = 0
  env.C_TradeSkillUI = {
    CraftRecipe = function() end, CraftEnchant = function() end, CraftSalvage = function() end,
    RecraftRecipe = function() end, RecraftRecipeForOrder = function() end,
    GetAllRecipeIDs = function() return {} end,
    GetRecipeInfo = function(id) return env.metadata[id] and copy(env.metadata[id].GetRecipeInfo) end,
    GetRecipeSchematic = function(id) return env.metadata[id] and copy(env.metadata[id].GetRecipeSchematic) end,
    GetProfessionInfoByRecipeID = function(id)
      return env.metadata[id] and copy(env.metadata[id].GetProfessionInfoByRecipeID)
    end,
    GetCraftingOperationInfo = function()
      env.quoteQueries = env.quoteQueries + 1
      error("No operation info for ordinary Forever recipes")
    end,
  }
  if options.missingMethod then env.C_TradeSkillUI[options.missingMethod] = nil end
  local addon = {}
  for line in io.lines(root .. "/ArtisanLogbook_Core.toc") do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      setfenv(assert(loadfile(root .. "/" .. line)), env)("ArtisanLogbook_Core", addon)
    end
  end
  frames[1].scripts.OnEvent(frames[1], "ADDON_LOADED", "ArtisanLogbook_Core")
  assert(addon.ledger, addon.ledgerError)
  env.ArtisanLogbookAPI.SetDiagnosticObserver(function(event, context)
    diagnostics[#diagnostics + 1] = { event = event, context = context }
  end)
  env.fire = function(name, ...)
    return addon.adapter.frame.scripts.OnEvent(addon.adapter.frame, name, ...)
  end
  env.call = function(id, count) hooks.CraftRecipe(id, count or 1, {}, nil, nil, false) end
  env.result = function(id, quantity)
    env.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 0, itemID = id, quantity = quantity or 1 })
  end
  return addon, env, hooks, diagnostics
end

local function test(name, run)
  run()
  passed = passed + 1
  print("PASS " .. name)
end
local function replay(addon, env, hooks, session, duplicates)
  for _, event in ipairs(session.events) do
    env.now = 1800000000 + event.time
    local arguments = copy(event.arguments)
    if event.name == "CALL_POST:C_TradeSkillUI.CraftRecipe" then
      hooks.CraftRecipe(unpack(arguments, 1, arguments.n))
    elseif addon.adapter.capabilities.events[event.name] then
      env.fire(event.name, unpack(arguments, 1, arguments.n))
      if duplicates and event.name == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        env.fire(event.name, unpack(arguments, 1, arguments.n))
      end
    end
  end
end

test("runtime fixture contains five distinct cumulative sessions and eleven results", function()
  assert(fixture.originalRecordCount == 256 and #fixture.sessions == 5)
  local previous, counts = 0, {}
  for _, session in ipairs(fixture.sessions) do
    assert(session.firstSequence > previous and session.lastSequence >= session.firstSequence)
    previous = session.lastSequence
    for _, event in ipairs(session.events) do
      if event.name == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        local result = event.arguments[1]
        assert(result.operationID == 0 and result.itemGUID:match("^Observed%-"))
        counts[result.itemID] = (counts[result.itemID] or 0) + result.quantity
      elseif event.name == "TRACE_START" then
        local captured = event.arguments[1]
        assert(captured.character == nil and captured.characterGUID == nil and captured.realm == nil)
      elseif event.name == "CHAT_MSG_LOOT" then
        assert(event.arguments[2] == "TestCrafter" and event.arguments[5] == "TestCrafter")
        assert(event.arguments[12]:match("^Observed%-"))
      end
    end
  end
  assert(counts[2455] == 2 and counts[2458] == 7 and counts[5997] == 2)
  assert(metadata[2331].GetRecipeSchematic.reagentSlotSchematics[2].reagents[1].itemID == 2447)
  assert(metadata[7183].GetRecipeSchematic.reagentSlotSchematics[1].reagents[1].itemID == 765)
end)

test("Core-only replay records confirmed results, fixed reagents, API and reload without mechanics", function()
  local addon, env, hooks, diagnostics = environment()
  local totals = {}
  for _, session in ipairs(fixture.sessions) do replay(addon, env, hooks, session) end
  local reasons = {}
  for _, diagnostic in ipairs(diagnostics) do
    if diagnostic.context.reason then reasons[#reasons + 1] = diagnostic.context.reason end
  end
  assert(#addon.ledger.database.crafts == 11,
    "Recorded " .. #addon.ledger.database.crafts .. " crafts: " .. table.concat(reasons, "; "))
  assert(#addon.ledger.database.requests == 6)
  assert(env.quoteQueries == 0)
  local api = env.ArtisanLogbookAPI
  assert(api.GetCapabilities().flavor == "forever" and api.GetCapabilities().reagentAllocations)
  assert(not api.GetCapabilities().craftingStats and not api.GetCapabilities().qualities)
  for _, craft in ipairs(addon.ledger.database.crafts) do
    totals[craft.recipeId] = (totals[craft.recipeId] or 0) + craft.outputQuantity
    assert(craft.gameOperationId == 0 and craft.requestId and craft.inputComplete)
    assert(craft.materialsSavingsEligible == false and craft.grossRequirementsComplete)
    assert(craft.hasResourcefulnessProc == nil and craft.resourcefulnessComplete == nil)
    assert(craft.multicraftBonus == nil and craft.outputQuality == nil and craft.concentrationSpent == nil)
    local projected = api.GetCraft(craft.id)
    assert(projected.recipe.id == craft.recipeId and #projected.reagents == 3)
    for _, reagent in ipairs(projected.reagents) do
      assert(reagent.fixed and reagent.allocatedQuantity == 1 and reagent.returnedQuantity == nil)
    end
  end
  assert(totals[2331] == 2 and totals[2334] == 7 and totals[7183] == 2)
  assert(not addon.ledger.pendingRequest and not addon.ledgerCaptureError)
  local cancellations = 0
  for _, observation in ipairs(diagnostics) do
    if observation.event == "craft-cancelled" then cancellations = cancellations + 1 end
  end
  assert(cancellations == 1)
  assert(addon.ledger.database.schemaVersion == 5)
  local reloaded, reloadedEnv = environment({ database = copy(addon.ledger.database) })
  assert(#reloaded.ledger.database.crafts == 11 and reloadedEnv.ArtisanLogbookAPI.GetCraft(11).recipe.id == 7183)
  assert(not reloaded.ledger.pendingRequest)
  reloadedEnv.result(2455)
  assert(#reloaded.ledger.database.crafts == 11)
end)

test("real interrupted batch counts one of seven before later one and five requests", function()
  local addon, env, hooks = environment()
  for _, event in ipairs(fixture.sessions[3].events) do
    if event.sequence > 103 then break end
    if event.name == "CALL_POST:C_TradeSkillUI.CraftRecipe" then
      hooks.CraftRecipe(unpack(event.arguments, 1, event.arguments.n))
    elseif addon.adapter.capabilities.events[event.name] then
      env.fire(event.name, unpack(event.arguments, 1, event.arguments.n))
    end
  end
  assert(#addon.ledger.database.crafts == 1 and addon.ledger.database.requests[1].requestedCount == 7)
  assert(not addon.ledger.pendingRequest)
end)

test("duplicate successes, nil starts, repeated results and loot never double count", function()
  local addon, env, hooks = environment()
  for _, session in ipairs(fixture.sessions) do replay(addon, env, hooks, session, true) end
  assert(#addon.ledger.database.crafts == 11)
  env.call(2331)
  env.fire("UNIT_SPELLCAST_START", "player", "same-cast", 2331)
  env.fire("UNIT_SPELLCAST_START", "player", nil, 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "same-cast", 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "same-cast", 2331)
  assert(#addon.ledger.database.crafts == 11)
  env.result(2455)
  assert(#addon.ledger.database.crafts == 12)
end)

test("unmatched failures cannot cancel and normal stopped(false) preserves final result", function()
  local addon, env = environment()
  env.call(7183, 2)
  env.fire("UNIT_SPELLCAST_START", "player", "first", 7183)
  env.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "unrelated", 123)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "first", 7183)
  env.fire("TRADE_SKILL_CRAFT_BEGIN", 7183)
  env.result(5997)
  env.fire("UNIT_SPELLCAST_START", "player", "second", 7183)
  env.fire("UNIT_SPELLCAST_INTERRUPTED", "party1", "second", 7183)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "second", 7183)
  env.fire("UPDATE_TRADESKILL_CAST_STOPPED", false)
  env.result(5997)
  assert(#addon.ledger.database.crafts == 2 and not addon.ledger.pendingRequest)
end)

test("missing recipe APIs and unsupported schematics fail explicitly without guesses", function()
  for _, method in ipairs({ "GetRecipeInfo", "GetRecipeSchematic" }) do
    local addon, env = environment({ missingMethod = method })
    env.call(2331)
    env.fire("UNIT_SPELLCAST_START", "player", "cast", 2331)
    env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 2331)
    env.result(2455)
    assert(#addon.ledger.database.crafts == 0 and addon.adapter.capabilities.lastUnsupportedReason)
  end
  local mutations = {
    function(data) data.GetRecipeInfo.supportsQualities = true end,
    function(data) data.GetRecipeInfo.supportsCraftingStats = true end,
    function(data) data.GetRecipeSchematic.outputItemID = nil end,
    function(data) data.GetRecipeSchematic.quantityMax = 2 end,
    function(data) data.GetRecipeSchematic.recipeID = 999 end,
    function(data) data.GetRecipeSchematic.reagentSlotSchematics[1].required = false end,
    function(data) data.GetRecipeSchematic.reagentSlotSchematics[1].reagents[2] = { itemID = 999 } end,
    function(data) data.GetRecipeSchematic.reagentSlotSchematics[1].quantityRequired = 0 end,
    function(data) data.GetRecipeSchematic.reagentSlotSchematics[1].dataSlotType = 3 end,
    function(data) data.GetRecipeSchematic.reagentSlotSchematics[1].variableQuantities = { 1, 2 } end,
    function(data) data.GetRecipeSchematic.reagentSlotSchematics[1].reagents[1].currencyID = 123 end,
  }
  for _, mutate in ipairs(mutations) do
    local addon, env = environment()
    mutate(env.metadata[2331])
    env.call(2331)
    assert(#addon.ledger.database.requests == 0 and addon.adapter.capabilities.lastUnsupportedReason)
  end
end)

test("unknown cast identity, stale results, mismatched output and unsupported operations do not corrupt pending", function()
  local addon, env, hooks = environment()
  env.call(2331)
  env.result(2455)
  assert(#addon.ledger.database.crafts == 0)
  env.fire("UNIT_SPELLCAST_START", "player", "cast", 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 2331)
  env.result(5997)
  assert(#addon.ledger.database.crafts == 0 and not addon.ledger.pendingRequest)
  env.call(2331)
  hooks.CraftSalvage(2331, 1, {}, {}, false)
  env.result(2455)
  assert(#addon.ledger.database.crafts == 0 and not addon.ledger.pendingSalvage)
  env.call(2331)
  env.fire("UNIT_SPELLCAST_START", "player", "cast2", 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast2", 2331)
  env.fire("TRADE_SKILL_CLOSE")
  env.result(2455)
  assert(#addon.ledger.database.crafts == 0)
end)

test("missing optional event is unavailable and Forever takes precedence over Mainline alias", function()
  local addon, env = environment({ unsupportedEvent = "CURRENCY_DISPLAY_UPDATE" })
  assert(not addon.adapter.capabilities.events.CURRENCY_DISPLAY_UPDATE)
  env.WOW_PROJECT_MAINLINE = 18
  assert(addon.DetectFlavor(env) == "forever")
  local adapter = addon.CreateFlavorAdapter(env, function() end, function() end, function() end)
  assert(adapter.capabilities.flavor == "forever")
end)

test("cast completion is only correlation and no synthetic game operation ID is persisted", function()
  local addon, env, _, diagnostics = environment()
  env.call(2331, 2)
  env.fire("UNIT_SPELLCAST_START", "player", "first", 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "first", 2331)
  assert(#addon.ledger.database.crafts == 0)
  env.fire("UNIT_SPELLCAST_START", "player", "second", 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "second", 2331)
  env.result(2455)
  assert(#addon.ledger.database.crafts == 0 and not addon.ledger.pendingRequest)
  local cancelled = false
  for _, observation in ipairs(diagnostics) do
    if observation.event == "craft-cancelled" and
        observation.context.reason:find("Multiple completed casts", 1, true) then cancelled = true end
  end
  assert(cancelled)
end)

test("next cast can start before previous result without losing interruption ownership", function()
  local addon, env = environment()
  env.call(2331, 2)
  env.fire("UNIT_SPELLCAST_START", "player", "first", 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "first", 2331)
  env.fire("TRADE_SKILL_CRAFT_BEGIN", 2331)
  env.fire("UNIT_SPELLCAST_START", "player", "second", 2331)
  env.result(2455)
  env.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "second", 2331)
  assert(#addon.ledger.database.crafts == 1 and not addon.ledger.pendingRequest)
  env.call(2331)
  env.fire("UNIT_SPELLCAST_START", "player", "third", 2331)
  env.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "second", 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "third", 2331)
  env.result(2455)
  assert(#addon.ledger.database.crafts == 2)
end)

test("overlapping requests and missing required events refuse unsafe capture", function()
  local addon, env = environment()
  env.call(2331, 2)
  env.call(2331)
  assert(#addon.ledger.database.requests == 1)
  env.fire("UNIT_SPELLCAST_START", "player", "cast", 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 2331)
  env.result(2455)
  assert(#addon.ledger.database.crafts == 0)
  addon, env = environment({ unsupportedEvent = "UNIT_SPELLCAST_START" })
  assert(not env.ArtisanLogbookAPI.GetCapabilities().captureReady)
  assert(not env.ArtisanLogbookAPI.GetCapabilities().personalRequests)
  env.call(2331)
  assert(#addon.ledger.database.requests == 0)
end)

test("ledger errors retain pending evidence and duplicate cast tokens cannot be consumed twice", function()
  local addon, env = environment()
  local original = addon.ledger.RecordResult
  local correlation
  addon.ledger.RecordResult = function(_, _, _, token)
    correlation = copy(token)
    return nil, "injected ledger error"
  end
  env.call(2331, 2)
  env.fire("UNIT_SPELLCAST_START", "player", "first", 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "first", 2331)
  env.result(2455)
  assert(#addon.ledger.database.crafts == 0 and addon.ledger.pendingRequest.remaining == 2)
  addon.ledger.RecordResult = original
  env.result(2455)
  assert(#addon.ledger.database.crafts == 1 and addon.ledger.pendingRequest.remaining == 1)
  local result, reason = addon.ledger:RecordResult({ operationID = 0, itemID = 2455, quantity = 1 }, nil, correlation)
  assert(result == nil and reason == "invalid or already consumed confirmed-cast correlation")
  assert(#addon.ledger.database.crafts == 1 and addon.ledger.pendingRequest.remaining == 1)
end)

test("Forever UI bootstrap refuses initialization without touching Core capture", function()
  local addon, env = environment()
  local handlers, notice = {}, nil
  env.CreateFrame = function()
    return {
      RegisterEvent = function() end, UnregisterEvent = function() end,
      SetScript = function(_, name, callback) handlers[name] = callback end,
    }
  end
  env.SlashCmdList = {}
  env.DEFAULT_CHAT_FRAME.AddMessage = function(_, message) notice = message end
  local ui = { CreateProductionWindow = function() error("Retail UI must not initialize") end }
  local uiRoot = root:gsub("ArtisanLogbook_Core$", "ArtisanLogbook")
  setfenv(assert(loadfile(uiRoot .. "/Bootstrap.lua")), env)("ArtisanLogbook", ui)
  handlers.OnEvent(nil, "ADDON_LOADED", "ArtisanLogbook")
  assert(notice and notice:find("Forever production UI is not validated", 1, true))
  env.SlashCmdList.ARTISANLOGBOOK()
  assert(notice:find("Core + Tracer", 1, true))
  env.call(2331)
  env.fire("UNIT_SPELLCAST_START", "player", "cast", 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 2331)
  env.result(2455)
  assert(#addon.ledger.database.crafts == 1)
end)

test("deterministic multi-item output is one confirmed craft and invalid selections stay unsupported", function()
  local addon, env, hooks = environment()
  env.metadata[2331].GetRecipeSchematic.quantityMin = 2
  env.metadata[2331].GetRecipeSchematic.quantityMax = 2
  env.call(2331)
  env.fire("UNIT_SPELLCAST_START", "player", "cast", 2331)
  env.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 2331)
  env.result(2455, 2)
  assert(#addon.ledger.database.crafts == 1 and addon.ledger.database.crafts[1].outputQuantity == 2)
  for _, arguments in ipairs({
    { 2331, 1, { { dataSlotIndex = 1, reagent = { itemID = 785 }, quantity = 1 } }, nil, nil, false },
    { 2331, 1, {}, nil, 77, false },
    { 2331, 1, {}, nil, nil, true },
  }) do
    hooks.CraftRecipe(unpack(arguments, 1, 6))
  end
  assert(#addon.ledger.database.requests == 1)
  assert(env.ArtisanLogbookAPI.GetDiagnostics().captureHealth.unsupportedReason)
end)

print(passed .. " Forever adapter tests passed")
