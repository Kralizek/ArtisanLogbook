local root = arg[1] or "src/ArtisanLogbook"
local testsRoot = arg[2] or "tests"
local addon = {}
assert(loadfile(root .. "/Storage/Ledger.lua"))("ArtisanLogbook", addon)
local Ledger = addon.Ledger
local legacyAddon = {}
assert(loadfile(testsRoot .. "/fixtures/legacy/Ledger-schema1.lua"))("ArtisanLogbook", legacyAddon)
local LegacyLedger = legacyAddon.Ledger
local fixture = assert(loadfile(testsRoot .. "/fixtures/retail-build-69933.lua"))()
local personalFixture = assert(loadfile(testsRoot .. "/fixtures/retail-personal-69933.lua"))()
local passed = 0
local maxInteger = 9007199254740991
local function rowCount(rows)
  local count = 0
  for _ in pairs(rows) do count = count + 1 end
  return count
end

local function unchangedAfter(value, action)
  local snapshots = {}
  local function capture(row)
    if type(row) ~= "table" or snapshots[row] then return end
    local snapshot = {}
    snapshots[row] = snapshot
    for key, child in pairs(row) do
      snapshot[key] = child
      capture(child)
    end
  end
  capture(value)
  local rejected, reason = action()
  assert(rejected == nil and type(reason) == "string")
  for row, snapshot in pairs(snapshots) do
    for key, child in pairs(row) do assert(snapshot[key] == child, tostring(key)) end
    for key, child in pairs(snapshot) do assert(row[key] == child, tostring(key)) end
  end
end

local function test(name, callback)
  callback()
  passed = passed + 1
  print("PASS " .. name)
end

local function newLedger(options, implementation)
  local clock = { current = 1800000000 }
  function clock.wall() return clock.current end
  local ledger = assert((implementation or Ledger).New(nil, clock, options))
  local sessionId = ledger:CreateSession({
    addonVersion = "0.2.0-ledger",
    wowVersion = fixture.version,
    wowBuild = fixture.build,
    startedAt = clock.current,
    characterName = "Sanitized Crafter",
    characterGUID = "Player-Sanitized",
    realmName = "Sanitized Realm",
    capabilities = { flavor = "retail", measurements = {} },
  })
  return ledger, clock, sessionId
end

-- Schema-1 history written by the verbatim schema-1 Ledger (outcomeVersion = 2).
local function newLegacyLedger(options)
  return newLedger(options, LegacyLedger)
end

local function primaryResult(ledger, result)
  local payload = {}
  for key, value in pairs(result) do payload[key] = value end
  payload.operationID = payload.operationID or ledger.database.nextCraftId
  payload.itemID = payload.itemID or 900000
  payload.quantity = payload.quantity or 1
  if ledger.database.schemaVersion == 2 and ledger.operationKind == nil then ledger:InvalidateCraft("CraftEnchant") end
  return ledger:RecordResult(payload)
end

local function fixtureResult(ledger, result)
  local payload = {}
  for key, value in pairs(result) do payload[key] = value end
  payload.operationID = payload.operationID or ledger.database.nextCraftId
  payload.itemID = payload.itemID or 900000
  payload.quantity = payload.quantity or 1
  return ledger:RecordResult(payload)
end

local function inputEvidence(itemIds, fixed, complete)
  local inputs = { evidenceVersion = 1, complete = complete ~= false, fixed = fixed or {}, completeItemIDs = {} }
  for _, itemId in ipairs(itemIds) do inputs.completeItemIDs[#inputs.completeItemIDs + 1] = { itemID = itemId } end
  return inputs
end

-- Converts schema-1 outcomeVersion=2 data to the pre-#21 variant (no outcome fields).
local function legacyDatabase(ledger)
  local data = ledger.database
  assert(data.schemaVersion == 1, "legacyDatabase requires schema-1 data")
  data.outcomeVersion, data.resourcefulnessSets, data.returnedReagents = nil, nil, nil
  for _, craft in ipairs(data.crafts) do
    craft.hasResourcefulnessProc, craft.resourcefulnessComplete = nil, nil
  end
  for _, row in ipairs(data.craftSeries) do
    for _, metric in ipairs({ "multicraftProcCount", "resourcefulnessProcCount", "resourcefulnessCompleteProcCount" }) do
      row[metric], row[metric .. "ObservedCount"] = nil, nil
    end
  end
  return data
end

local function reagentRow(data, itemId, recipeId)
  for _, row in ipairs(data.reagentSeries) do
    if row.itemId == itemId and (recipeId == nil or row.recipeId == recipeId) then return row end
  end
end

local function returnedQuantities(data)
  local quantities, count = {}, 0
  for _, row in ipairs(data.reagentSeries) do
    if row.returnedQuantity then
      quantities[row.itemId] = (quantities[row.itemId] or 0) + row.returnedQuantity
      count = count + 1
    end
  end
  return quantities, count
end

test("legacy ambiguous zero plus unavailable return does not prove false", function()
  local ledger, clock = newLegacyLedger()
  assert(ledger:SubmitCraft(12, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 8 } },
    { dataSlotIndex = 2, quantity = 2, reagent = { itemID = 8 } },
    { dataSlotIndex = 3, quantity = 2, reagent = { itemID = 9 } },
  }))
  assert(ledger:RecordResult({ resourcesReturned = {
    { reagent = { itemID = 8 }, quantity = 0 }, { reagent = { itemID = 10 } },
  } }))
  local data = legacyDatabase(ledger)
  assert(#data.reagents == 4 and data.reagents[1].returnedQuantity == nil and
    data.reagents[2].returnedQuantity == nil and data.reagents[3].returnedQuantity == 0 and
    data.reagents[4].returnedQuantity == 0)
  local loaded = assert(Ledger.New(data, clock))
  assert(loaded.database.schemaVersion == 2 and loaded.migration.fromSchemaVersion == 1)
  assert(loaded.database.crafts[1].hasResourcefulnessProc == nil)
  assert(loaded.database.crafts[1].outcomeSource == nil)
  local row = loaded.database.craftSeries[1]
  assert(row.resourcefulnessProcCountObservedCount == 0)
  assert(row.resourcefulnessCompleteProcCountObservedCount == 0)
  assert(row.resourcefulnessAuthoritativeProcCountObservedCount == 0 and row.matchedCraftCount == 0)
  -- Allocations are durable inputs; slot 8 + 8 consolidates without slot attribution.
  assert(row.quoteObservedCount == 1 and loaded.database.crafts[1].quoteObserved == true)
  assert(row.inputCompleteCount == 0 and loaded.database.crafts[1].inputComplete == nil)
  local eight = reagentRow(loaded.database, 8)
  assert(eight.allocatedQuantity == 4 and eight.allocationCount == 1 and eight.matchedCraftCount == nil)
end)

test("legacy partial positive return is not a complete returned item set", function()
  local ledger, clock = newLegacyLedger()
  assert(ledger:SubmitCraft(12, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 8 } },
    { dataSlotIndex = 2, quantity = 2, reagent = { itemID = 9 } },
  }))
  assert(ledger:RecordResult({ resourcesReturned = {
    { reagent = { itemID = 8 }, quantity = 1 }, { reagent = { itemID = 9 } },
  } }))
  local data = legacyDatabase(ledger)
  assert(data.reagents[1].returnedQuantity == 1 and data.reagents[2].returnedQuantity == 0)
  local loaded = assert(Ledger.New(data, clock))
  local row = loaded.database.craftSeries[1]
  assert(row.resourcefulnessProcCount == 1 and row.resourcefulnessProcCountObservedCount == 1)
  assert(row.resourcefulnessCompleteProcCountObservedCount == 0)
  assert(#loaded.database.resourcefulnessSets == 0 and reagentRow(loaded.database, 8).returnedQuantity == 1)
  assert(reagentRow(loaded.database, 9).returnedQuantity == nil and reagentRow(loaded.database, 9).allocatedQuantity == 2)
  assert(row.resourcefulnessAuthoritativeProcCountObservedCount == 0 and row.matchedCraftCount == 0)
  assert(Ledger.New(loaded.database, clock))
end)

test("legacy positive fractional return cannot become an observed no proc", function()
  local ledger, clock = newLegacyLedger()
  assert(ledger:SubmitCraft(12, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 8 } },
    { dataSlotIndex = 2, quantity = 2, reagent = { itemID = 8 } },
    { dataSlotIndex = 3, quantity = 2, reagent = { itemID = 9 } },
  }))
  assert(ledger:RecordResult({ resourcesReturned = { { reagent = { itemID = 8 }, quantity = 0.5 } } }))
  local data = legacyDatabase(ledger)
  assert(data.reagents[1].returnedQuantity == nil and data.reagents[2].returnedQuantity == nil and
    data.reagents[3].returnedQuantity == 0 and data.reagents[4].returnedQuantity == 0.5)
  local loaded = assert(Ledger.New(data, clock))
  assert(loaded.database.crafts[1].hasResourcefulnessProc == true)
  assert(loaded.database.craftSeries[1].resourcefulnessProcCount == 1)
  assert(loaded.database.craftSeries[1].resourcefulnessCompleteProcCountObservedCount == 0)
  assert(reagentRow(loaded.database, 8).returnedQuantity == 0.5)
end)

test("rounded Multicraft aggregate cannot prove the pruned residual outcome", function()
  local ledger, clock = newLegacyLedger({ retentionDays = 1 })
  assert(ledger:SubmitCraft(12, 1, false))
  assert(ledger:RecordResult({ multicraft = 1 }))
  clock.current = clock.current + 2
  assert(ledger:SubmitCraft(12, 1, false))
  assert(ledger:RecordResult({ multicraft = 1e16 }))
  ledger:Prune(clock.current + 86399)
  assert(#ledger.database.crafts == 1 and ledger.database.crafts[1].multicraftBonus == 1e16)
  local loaded = assert(Ledger.New(legacyDatabase(ledger), clock))
  local row = loaded.database.craftSeries[1]
  assert(row.craftCount == 2 and row.multicraftBonus == 1e16 and row.multicraftBonusObservedCount == 2)
  assert(row.multicraftProcCount == 1 and row.multicraftProcCountObservedCount == 1)
  local versionOne = assert(LegacyLedger.New(ledger.database, clock)).database
  versionOne.outcomeVersion = 1
  versionOne.craftSeries[1].resourcefulnessCompleteProcCountObservedCount = nil
  versionOne.craftSeries[1].multicraftProcCountObservedCount = 2
  local corrected = assert(Ledger.New(versionOne, clock))
  assert(corrected.database.craftSeries[1].multicraftProcCountObservedCount == 1)
end)

test("prior PR outcome backfill drops unsupported completeness without replaying quantities", function()
  local ledger, clock = newLegacyLedger({ retentionDays = 1 })
  local function record(result)
    result.itemID = 100
    local craft = assert(ledger:RecordResult(result))
    clock.current = clock.current + 2
    return craft
  end
  record({ resourcesReturned = { { reagent = { itemID = 10 }, quantity = 3 } } })
  record({ resourcesReturned = {} })
  record({ resourcesReturned = { { reagent = { itemID = 8 }, quantity = 1 } } })
  local fractional = record({ resourcesReturned = { { reagent = { itemID = 9 }, quantity = 0.5 } } })
  ledger:Prune(1800000000 + 86401)
  local data = ledger.database
  data.outcomeVersion = 1
  for _, craft in ipairs(data.crafts) do craft.resourcefulnessComplete = nil end
  fractional.hasResourcefulnessProc = false
  local row = data.craftSeries[1]
  row.resourcefulnessCompleteProcCount, row.resourcefulnessCompleteProcCountObservedCount = nil, nil
  row.resourcefulnessProcCount, row.resourcefulnessProcCountObservedCount = 2, 4
  for index, returned in ipairs(data.returnedReagents) do
    if returned.itemId == 9 then table.remove(data.returnedReagents, index); break end
  end
  local loaded = assert(Ledger.New(data, clock))
  assert(data.outcomeVersion == 1 and fractional.hasResourcefulnessProc == false)
  assert(loaded.database.schemaVersion == 2 and loaded.database.outcomeVersion == nil)
  assert(#loaded.database.resourcefulnessSets == 0)
  row = loaded.database.craftSeries[1]
  assert(row.resourcefulnessProcCount == 3 and row.resourcefulnessProcCountObservedCount == 3)
  assert(row.resourcefulnessCompleteProcCountObservedCount == 0)
  local quantities, rows = returnedQuantities(loaded.database)
  assert(rows == 3 and quantities[8] == 1 and quantities[9] == 0.5 and quantities[10] == 3)
  loaded = assert(Ledger.New(loaded.database, clock))
  assert(loaded.database.craftSeries[1].resourcefulnessProcCount == 3)
  assert(#loaded.database.reagentSeries == 3)
  assert(loaded:AddDimension("recipe", 12))
  assert(loaded:LearnRecipeOutput(12, 100))
  assert(loaded:RepairUnknownRecipes().repairedCount == 3)
  loaded = assert(Ledger.New(loaded.database, clock))
  local known, unknown
  for _, aggregate in ipairs(loaded.database.craftSeries) do
    if aggregate.recipeId == 12 then known = aggregate else unknown = aggregate end
  end
  assert(known.resourcefulnessProcCount == 2 and known.resourcefulnessCompleteProcCountObservedCount == 0)
  assert(unknown.resourcefulnessProcCount == 1)
  clock.current = clock.current + 2 * 86400
  loaded:Prune(clock.current)
  assert(#loaded.database.crafts == 0 and #loaded.database.reagentSeries == 3)
  assert(Ledger.New(loaded.database, clock))
end)

test("outcomes record authoritative true and false with canonical return sets", function()
  local ledger, clock = newLedger({ retentionDays = 1 })
  local function record(result)
    assert(ledger:SubmitCraft(12, 1, false))
    return assert(primaryResult(ledger, result))
  end
  record({ multicraft = 0, quantity = 5, hasIngenuityProc = false, ingenuityRefund = 99,
    resourcesReturned = {} })
  record({ multicraft = 3, quantity = 8, hasIngenuityProc = true, ingenuityRefund = 12,
    resourcesReturned = {
      { reagent = { itemID = 20 }, quantity = 2 },
      { reagent = { itemID = 3 }, quantity = 1 },
      { reagent = { itemID = 20 }, quantity = 3 },
    } })
  record({ resourcesReturned = {
    { reagent = { itemID = 3 }, quantity = 2 },
    { reagent = { itemID = 20 }, quantity = 4 },
  } })
  record({})
  local row = ledger.database.craftSeries[1]
  assert(row.craftCount == 4 and row.multicraftProcCount == 1 and row.multicraftProcCountObservedCount == 2)
  assert(row.multicraftBonus == 3 and row.outputQuantity == 15)
  assert(row.ingenuityProcCount == 1 and row.ingenuityProcCountObservedCount == 2)
  assert(row.ingenuityRefund == 12 and row.ingenuityRefundObservedCount == 2)
  -- A validated primary result without resourcesReturned is a complete negative.
  assert(row.resourcefulnessProcCount == 2 and row.resourcefulnessProcCountObservedCount == 4)
  assert(row.resourcefulnessCompleteProcCount == 2 and row.resourcefulnessCompleteProcCountObservedCount == 4)
  assert(row.resourcefulnessAuthoritativeProcCount == 2 and row.resourcefulnessAuthoritativeProcCountObservedCount == 4)
  assert(ledger.database.crafts[4].outcomeSource == "native" and ledger.database.crafts[4].hasResourcefulnessProc == false)
  assert(#ledger.database.resourcefulnessSets == 1)
  assert(ledger.database.resourcefulnessSets[1].returnedItemSet == "3,20")
  assert(ledger.database.resourcefulnessSets[1].craftCount == 2)
  assert(ledger.database.resourcefulnessSets[1].authoritativeCraftCount == 2)
  local quantities = returnedQuantities(ledger.database)
  assert(quantities[3] == 3 and quantities[20] == 9)
  clock.current = clock.current + 86401
  ledger:Prune(clock.current)
  assert(#ledger.database.crafts == 0 and #ledger.database.reagents == 0)
  local loaded = assert(Ledger.New(ledger.database, clock))
  assert(loaded.database.craftSeries[1].resourcefulnessProcCountObservedCount == 4)
  assert(loaded.database.resourcefulnessSets[1].craftCount == 2 and #loaded.database.reagentSeries == 2)
end)

test("legacy outcome upgrade never infers measured false Resourcefulness from absence", function()
  local ledger, clock = newLegacyLedger()
  assert(ledger:RecordResult({ multicraft = 0, resourcesReturned = {} }))
  assert(ledger:RecordResult({ multicraft = 4, resourcesReturned = {
    { reagent = { itemID = 8 }, quantity = 2 },
  } }))
  assert(ledger:RecordResult({}))
  local data = legacyDatabase(ledger)
  local loaded = assert(Ledger.New(data, clock))
  local row = loaded.database.craftSeries[1]
  assert(row.craftCount == 3 and row.multicraftProcCount == 1 and row.multicraftProcCountObservedCount == 2)
  assert(row.resourcefulnessProcCount == 1 and row.resourcefulnessProcCountObservedCount == 1)
  assert(data.outcomeVersion == nil and data.crafts[2].hasResourcefulnessProc == nil)
  local again = assert(Ledger.New(loaded.database, clock))
  assert(#again.database.resourcefulnessSets == 0)
  assert(again.database.craftSeries[1].resourcefulnessProcCountObservedCount == 1)
  data.crafts, data.reagents = {}, {}
  local pruned = assert(Ledger.New(data, clock)).database.craftSeries[1]
  assert(pruned.craftCount == 3 and pruned.multicraftProcCount == nil and pruned.resourcefulnessProcCount == nil)
  assert(pruned.multicraftProcCountObservedCount == 0 and pruned.resourcefulnessProcCountObservedCount == 0)
end)

test("legacy zeros lack completeness but singleton pruned Multicraft outcomes are provable", function()
  local ledger, clock = newLegacyLedger()
  assert(ledger:SubmitCraft(12, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 8 } },
  }))
  assert(ledger:RecordResult({ multicraft = 0, resourcesReturned = {} }))
  assert(ledger:SubmitCraft(12, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 8 } },
  }))
  assert(ledger:RecordResult({ multicraft = 5 }))
  assert(ledger:SubmitCraft(13, 1, false))
  assert(ledger:RecordResult({ multicraft = 2 }))
  local data = legacyDatabase(ledger)
  table.remove(data.crafts, 3)
  local loaded = assert(Ledger.New(data, clock))
  local row = loaded.database.craftSeries[1]
  assert(row.resourcefulnessProcCount == nil and row.resourcefulnessProcCountObservedCount == 0)
  assert(loaded.database.crafts[1].hasResourcefulnessProc == nil)
  assert(loaded.database.crafts[2].hasResourcefulnessProc == nil)
  assert(loaded.database.craftSeries[2].multicraftProcCount == 1)
  assert(loaded.database.craftSeries[2].multicraftProcCountObservedCount == 1)
  assert(loaded.database.craftSeries[2].resourcefulnessProcCountObservedCount == 0)
  assert(Ledger.New(loaded.database, clock))
end)

test("malformed lists keep provable positives but never claim a complete set or false", function()
  local ledger, clock = newLedger()
  assert(primaryResult(ledger, { resourcesReturned = { { reagent = { currencyID = 9 }, quantity = 2 } } }))
  assert(primaryResult(ledger, { resourcesReturned = { [2] = { reagent = { itemID = 8 }, quantity = 2 } } }))
  assert(primaryResult(ledger, { resourcesReturned = { { reagent = { itemID = 8 } } } }))
  assert(primaryResult(ledger, { resourcesReturned = { { reagent = { itemID = 8 }, quantity = 0 } } }))
  assert(primaryResult(ledger, { resourcesReturned = { { reagent = { itemID = 8 }, quantity = 2 }, {} } }))
  assert(primaryResult(ledger, { resourcesReturned = "unreadable" }))
  local crafts = ledger.database.crafts
  for _, index in ipairs({ 1, 3, 6 }) do
    assert(crafts[index].outcomeSource == "partial" and crafts[index].hasResourcefulnessProc == nil)
  end
  for _, index in ipairs({ 2, 5 }) do
    assert(crafts[index].outcomeSource == "partial" and crafts[index].hasResourcefulnessProc == true)
    assert(crafts[index].resourcefulnessComplete == nil)
  end
  assert(crafts[4].outcomeSource == "native" and crafts[4].hasResourcefulnessProc == false)
  local row = ledger.database.craftSeries[1]
  assert(row.craftCount == 6 and row.resourcefulnessProcCount == 2 and row.resourcefulnessProcCountObservedCount == 3)
  assert(row.resourcefulnessCompleteProcCountObservedCount == 1 and row.resourcefulnessCompleteProcCount == 0)
  assert(row.resourcefulnessAuthoritativeProcCountObservedCount == 1)
  assert(#ledger.database.resourcefulnessSets == 0 and reagentRow(ledger.database, 8).returnedQuantity == 4)
  assert(Ledger.New(ledger.database, clock))
end)

test("return set and quantity overflow reject the entire craft and pending consumption", function()
  for _, collection in ipairs({ "resourcefulnessSets", "reagentSeries" }) do
    local ledger = newLedger()
    local result = { operationID = 1, itemID = 900000, quantity = 1,
      resourcesReturned = { { reagent = { itemID = 8 }, quantity = 1 } } }
    assert(ledger:SubmitCraft(12, 2, false))
    assert(ledger:RecordResult(result))
    local metric = collection == "resourcefulnessSets" and "craftCount" or "returnedQuantity"
    ledger.database[collection][1][metric] = maxInteger
    result.operationID = 2
    unchangedAfter(ledger, function() return ledger:RecordResult(result) end)
  end
end)

test("repair transfers all outcome grains atomically and preserves pruned contributions", function()
  local ledger, clock = newLedger({ retentionDays = 1 })
  local result = { itemID = 100, multicraft = 2, resourcesReturned = {
    { reagent = { itemID = 8 }, quantity = 2 }, { reagent = { itemID = 9 }, quantity = 3 },
  } }
  assert(primaryResult(ledger, result))
  clock.current = clock.current + 100
  assert(primaryResult(ledger, result))
  assert(ledger:AddDimension("recipe", 12))
  assert(ledger:LearnRecipeOutput(12, 100))
  clock.current = clock.current + 86301
  ledger:Prune(clock.current)
  assert(#ledger.database.crafts == 1)
  assert(ledger:RepairUnknownRecipes().repairedCount == 1)
  local sets = ledger.database.resourcefulnessSets
  assert(#sets == 2 and sets[1].craftCount == 1 and sets[2].craftCount == 1)
  assert(sets[1].recipeId == nil and sets[2].recipeId == 12)
  assert(sets[1].authoritativeCraftCount == 1 and sets[2].authoritativeCraftCount == 1)
  assert(#ledger.database.reagentSeries == 4)
  local loaded = assert(Ledger.New(ledger.database, clock))
  assert(loaded.database.craftSeries[1].resourcefulnessProcCount == 1)
  assert(loaded.database.craftSeries[2].resourcefulnessProcCount == 1)
  assert(loaded.database.craftSeries[2].resourcefulnessAuthoritativeProcCount == 1)
  assert(loaded:ClearHistory())
  assert(#loaded.database.resourcefulnessSets == 0 and #loaded.database.reagentSeries == 0)
end)

test("reload rejects malformed canonical identities and inconsistent returned aggregates", function()
  local ledger, clock = newLedger()
  assert(primaryResult(ledger, { resourcesReturned = {
    { reagent = { itemID = 8 }, quantity = 1 }, { reagent = { itemID = 9 }, quantity = 2 },
  } }))
  for _, key in ipairs({ "9,8", "8,8,9", "08,9", "8,,9", "8,99", "" }) do
    local data = assert(Ledger.New(ledger.database, clock)).database
    data.resourcefulnessSets[1].returnedItemSet = key
    unchangedAfter(data, function() return Ledger.New(data, clock) end)
  end
  local data = assert(Ledger.New(ledger.database, clock)).database
  data.resourcefulnessSets[1].craftCount = 2
  unchangedAfter(data, function() return Ledger.New(data, clock) end)
end)

local function serializedSize(value, depth)
  if type(value) == "string" then return #string.format("%q", value) end
  if type(value) ~= "table" then return #tostring(value) end
  depth = depth or 0
  local size = 3 + depth
  for key, child in pairs(value) do
    size = size + depth + 1 + 7 + serializedSize(key) + serializedSize(child, depth + 1)
  end
  return size
end

test("239-craft storage sample stays at 62 return sets and 75 item measurement rows", function()
  local function sample(implementation)
    local ledger, clock = newLedger(nil, implementation)
    for index = 1, 239 do
      local pattern = (index - 1) % 62 + 1
      local returns = { { reagent = { itemID = pattern }, quantity = 1 } }
      if pattern <= 12 then returns[2] = { reagent = { itemID = 62 + pattern }, quantity = 2 } end
      assert(ledger:SubmitCraft(12, 1, false, nil, {
        { dataSlotIndex = 1, quantity = 3, reagent = { itemID = pattern } },
        { dataSlotIndex = 2, quantity = 5, reagent = { itemID = 200 } },
      }))
      assert(primaryResult(ledger, { quantity = 5, multicraft = index % 3 == 0 and 2 or 0,
        concentrationSpent = 20, hasIngenuityProc = index % 5 == 0,
        ingenuityRefund = 10, resourcesReturned = returns }))
    end
    return ledger, clock
  end
  local ledger, clock = sample(Ledger)
  local data = ledger.database
  assert(#data.resourcefulnessSets == 62 and #data.reagentSeries == 75)
  local _, returnedRows = returnedQuantities(data)
  assert(returnedRows == 74 and reagentRow(data, 200).allocatedQuantity == 239 * 5)
  -- Returns outside the quote never remove a craft from item-level matching. Without a
  -- schematic snapshot no craft has complete recipe inputs.
  assert(data.craftSeries[1].quoteObservedCount == 239 and data.craftSeries[1].inputCompleteCount == 0)
  assert(data.craftSeries[1].matchedCraftCount == 0 and reagentRow(data, 200).matchedCraftCount == nil)
  local legacy = sample(LegacyLedger).database
  local legacyBytes, currentBytes = serializedSize(legacy), serializedSize(data)
  local started = os.clock()
  local migrated = assert(Ledger.New(legacy, clock))
  local elapsed = os.clock() - started
  local migratedBytes = serializedSize(migrated.database)
  assert(#migrated.database.resourcefulnessSets == 62 and #migrated.database.reagentSeries == 75)
  assert(migrated.database.resourcefulnessSets[1].authoritativeCraftCount == nil)
  assert(migrated.database.craftSeries[1].resourcefulnessCompleteProcCountObservedCount == 239)
  assert(migrated.database.craftSeries[1].resourcefulnessAuthoritativeProcCountObservedCount == 0)
  assert(migrated.database.craftSeries[1].quoteObservedCount == data.craftSeries[1].quoteObservedCount)
  assert(migrated.database.craftSeries[1].matchedCraftCount == 0)
  print(string.format("STORAGE synthetic 239 crafts: schema1 %d, migrated %d (+%d), fresh schema2 %d (+%d) " ..
    "estimated Lua bytes; 62 sets, 75 item rows; migration %.4fs",
    legacyBytes, migratedBytes, migratedBytes - legacyBytes, currentBytes, currentBytes - legacyBytes, elapsed))
  clock.current = clock.current + 61 * 86400
  ledger:Prune(clock.current)
  assert(#ledger.database.crafts == 0 and #ledger.database.resourcefulnessSets == 62)
  assert(#ledger.database.reagentSeries == 75 and reagentRow(ledger.database, 200).matchedCraftCount == nil)
end)

local function replay(ledger, cases)
  for _, scenario in ipairs(cases) do
    for _, observed in ipairs(scenario.events) do
      local arguments = observed.arguments
      if observed.name == "TRADE_SKILL_CRAFT_BEGIN" then
        ledger:BeginCraft(arguments[1])
      elseif observed.name == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        assert(ledger:RecordResult(arguments[1]))
      end
    end
  end
end

local function craftByOperation(ledger, operationId)
  for _, craft in ipairs(ledger.database.crafts) do
    if craft.gameOperationId == operationId then return craft end
  end
end

test("build-69933 replay records one fact per observed result", function()
  local ledger = newLedger()
  replay(ledger, fixture.cases)
  assert(#ledger.database.crafts == 7)
  local basic = craftByOperation(ledger, 3923109748)
  assert(basic and basic.outputQuantity == 5 and basic.outputQuality == 1)
  assert(basic.multicraftBonus == 0 and basic.concentrationSpent == 0)
  assert(basic.hasIngenuityProc == false and basic.ingenuityRefund == 65)
  assert(basic.recipeId and basic.outputItemId)
end)

test("concentration and Multicraft facts preserve the observed result fields", function()
  local ledger = newLedger()
  replay(ledger, fixture.cases)
  local concentration = craftByOperation(ledger, 660565636)
  assert(concentration and concentration.concentrationSpent == 185)
  assert(concentration.hasIngenuityProc == false and concentration.ingenuityRefund == 93)
  local multicraft = craftByOperation(ledger, 952287519)
  assert(multicraft and multicraft.multicraftBonus == 10 and multicraft.outputQuantity == 15)
  assert(multicraft.gameOperationId ~= concentration.gameOperationId)
end)

test("Resourcefulness returns create reagent facts for every returned item", function()
  local ledger = newLedger()
  replay(ledger, fixture.cases)
  assert(#ledger.database.reagents == 9)
  local craft = craftByOperation(ledger, 1373831620)
  local rows = {}
  for _, reagent in ipairs(ledger.database.reagents) do
    if reagent.craftId == craft.id then rows[#rows + 1] = reagent end
  end
  assert(#rows == 3)
  assert(rows[1].returnedQuantity == 4 and rows[2].returnedQuantity == 5 and rows[3].returnedQuantity == 6)
  assert(rows[1].allocatedQuantity == nil and rows[1].quality == nil and rows[1].source == nil)
end)

test("zero and false remain distinct from unavailable result fields", function()
  local ledger = newLedger()
  local zero = assert(ledger:RecordResult({
    operationID = 0,
    itemID = 0,
    quantity = 0,
    concentrationSpent = 0,
    multicraft = 0,
    hasIngenuityProc = false,
    ingenuityRefund = 0,
  }))
  local unknown = assert(ledger:RecordResult({}))
  assert(zero.gameOperationId == 0 and zero.outputQuantity == 0)
  assert(zero.outputItemId == 0 and ledger.database.dimensions.items[0].id == 0)
  assert(zero.concentrationSpent == 0 and zero.multicraftBonus == 0)
  assert(zero.hasIngenuityProc == false and zero.ingenuityRefund == 0)
  assert(unknown.gameOperationId == nil and unknown.outputQuantity == nil)
  assert(unknown.concentrationSpent == nil and unknown.hasIngenuityProc == nil)
end)

test("reload preserves craft IDs and session identity advances", function()
  local ledger, clock, firstSession = newLedger()
  local first = assert(ledger:RecordResult({ operationID = 10, quantity = 1 }))
  local reloaded = assert(Ledger.New(ledger.database, clock))
  local secondSession = reloaded:CreateSession({ startedAt = clock.current })
  local second = assert(reloaded:RecordResult({ operationID = 11, quantity = 1 }))
  assert(first.id == 1 and second.id == 2)
  assert(first.sessionId == firstSession and second.sessionId == secondSession)
  assert(reloaded.database.nextCraftId == 3)
end)

test("age pruning removes craft and reagent rows but leaves dimensions and IDs", function()
  local ledger, clock = newLedger({ retentionDays = 1 })
  local old = assert(ledger:RecordResult({
    itemID = 50,
    resourcesReturned = { { reagent = { itemID = 51 }, quantity = 2 } },
  }))
  local dimensionCount = rowCount(ledger.database.dimensions.items)
  clock.current = clock.current + 86401
  ledger:Prune(clock.current)
  assert(#ledger.database.crafts == 0 and #ledger.database.reagents == 0)
  assert(rowCount(ledger.database.dimensions.items) == dimensionCount)
  local newer = assert(ledger:RecordResult({ quantity = 1 }))
  assert(newer.id == old.id + 1)
end)

test("capture retains all facts and keeps append-only dimensions", function()
  local ledger = newLedger()
  local itemDimension = ledger:AddDimension("item", 700)
  assert(ledger:AddDimension("item", 700, { name = "ignored" }) == itemDimension)
  local expansionId = ledger:AddDimension("expansion", "era-test", {
    displayName = "Test Era",
    chronologicalOrder = 90,
  })
  local recipeId = ledger:AddDimension("recipe", 800, {
    expansionDimensionId = expansionId,
  })
  local first = assert(ledger:RecordResult({ operationID = 1, quantity = 1,
    resourcesReturned = { { reagent = { itemID = 700 }, quantity = 1 } } }))
  local second = assert(ledger:RecordResult({ operationID = 2, quantity = 1 }))
  local third = assert(ledger:RecordResult({ operationID = 3, quantity = 1 }))
  assert(#ledger.database.crafts == 3 and ledger.database.crafts[1].id == first.id)
  assert(ledger.database.crafts[3].id == third.id and #ledger.database.reagents == 1)
  assert(ledger.database.nextCraftId == 4 and ledger.database.dimensions.items[700].id == itemDimension)
  assert(ledger.database.dimensions.recipes[800].id == recipeId)
  assert(ledger.database.dimensions.recipes[800].expansionDimensionId == expansionId)
  assert(ledger.database.dimensions.expansions[1].chronologicalOrder == 90)
  local invalidExpansion = ledger:AddDimension("item", 701, { expansionDimensionId = 999 })
  assert(invalidExpansion == nil)
  assert(first.id < second.id)
  ledger:BeginCraft(801)
  local reusedOperation = assert(ledger:RecordResult({ operationID = 1, quantity = 1 }))
  assert(reusedOperation.recipeId == nil)
end)

test("ambiguous begins and repeated or late results are retained without merging", function()
  local ledger = newLedger()
  ledger:BeginCraft(900)
  local zeroId = assert(fixtureResult(ledger, { operationID = 0, quantity = 1 }))
  assert(zeroId.recipeId == nil)
  ledger:BeginCraft(900)
  local first = assert(fixtureResult(ledger, { operationID = 42, itemID = 1, quantity = 1 }))
  local repeated = assert(fixtureResult(ledger, { operationID = 42, itemID = 1, quantity = 1 }))
  assert(first.id ~= repeated.id and first.gameOperationId == repeated.gameOperationId)

  ledger:BeginCraft(901)
  ledger:BeginCraft(902)
  local ambiguous = assert(fixtureResult(ledger, { operationID = 43, quantity = 1 }))
  assert(ambiguous.recipeId == nil)
  ledger:CancelCraft()
  ledger:BeginCraft(903)
  local later = assert(fixtureResult(ledger, { operationID = 44, quantity = 1 }))
  assert(later.recipeId == 903)
  ledger:BeginCraft(904)
  local late = assert(fixtureResult(ledger, { operationID = 42, quantity = 1 }))
  assert(late.recipeId == nil and late.gameOperationId == 42)
  ledger:BeginCraft(905)
  local missingId = assert(fixtureResult(ledger, { quantity = 1 }))
  assert(missingId.recipeId == nil)
  assert(#ledger.database.crafts == 7)
end)

test("unsupported flavor measurements remain absent", function()
  local ledger = assert(Ledger.New(nil, { wall = function() return 1800000000 end }))
  ledger:CreateSession({ capabilities = {
    flavor = "classic", events = {}, hooks = {}, measurements = {},
  } })
  local craft = assert(ledger:RecordResult({ quantity = 1 }))
  assert(craft.concentrationSpent == nil and craft.hasIngenuityProc == nil)
  assert(craft.professionId == nil and craft.recipeId == nil)
  assert(ledger.database.dimensions.sessions[1].capabilities.measurements.concentrationSpent == nil)
end)

test("newer and failed schemas are refused without changing saved data", function()
  local newer = { schemaVersion = Ledger.schemaVersion + 1, preserved = "yes" }
  local refused = Ledger.New(newer)
  assert(refused == nil and newer.schemaVersion == Ledger.schemaVersion + 1)
  assert(newer.preserved == "yes")

  local invalidLegacy = { schemaVersion = 0, crafts = false }
  local failed = Ledger.New(invalidLegacy)
  assert(failed == nil and invalidLegacy.schemaVersion == 0 and invalidLegacy.crafts == false)

  local malformedDimensions = assert(Ledger.New(nil)).database
  malformedDimensions.dimensions.items = {
    [7] = { id = 8 },
  }
  assert(Ledger.New(malformedDimensions) == nil)
end)

test("schema 1 requires its format identity and refuses every experimental version atomically", function()
  for version = 0, 5 do
    local ledger, clock = newLedger()
    assert(ledger:SubmitCraft(12, 2, false))
    assert(ledger:RecordResult({ quantity = 2, hasIngenuityProc = true, ingenuityRefund = 3 }))
    ledger.database.schemaVersion = version
    ledger.database.schemaIdentity = nil
    clock.current = clock.current + 61 * 86400
    unchangedAfter(ledger.database, function() return Ledger.New(ledger.database, clock) end)
    if version ~= Ledger.schemaVersion then
      ledger.database.schemaIdentity = "ArtisanLogbookLedger"
      unchangedAfter(ledger.database, function() return Ledger.New(ledger.database, clock) end)
    end
  end
  for _, identity in ipairs({ "", "OtherLedger", false, 1, {} }) do
    local ledger, clock = newLedger()
    ledger.database.schemaIdentity = identity
    unchangedAfter(ledger.database, function() return Ledger.New(ledger.database, clock) end)
  end
end)

test("clean schema 2 initializes the complete model and reload does not rebuild durable totals", function()
  local ledger = assert(Ledger.New(nil))
  assert(ledger.database.schemaVersion == 2 and ledger.database.schemaIdentity == "ArtisanLogbookLedger")
  assert(ledger.database.retentionDays == 60 and ledger.database.maxCrafts == nil)
  assert(ledger.database.nextCraftId == 1 and ledger.database.nextRequestId == 1)
  assert(#ledger.database.crafts == 0 and #ledger.database.requests == 0)
  assert(#ledger.database.reagents == 0 and #ledger.database.craftSeries == 0)
  for kind, rows in pairs(ledger.dimensionRows) do
    assert(next(rows) == nil)
    if kind == "item" or kind == "recipe" or kind == "profession" then
      assert(ledger.database.nextDimensionId[kind] == nil)
    else
      assert(ledger.database.nextDimensionId[kind] == 1)
    end
  end
  local populated, clock = newLedger()
  assert(populated:RecordResult({ quantity = 4, multicraft = 2, concentrationSpent = 5,
    hasIngenuityProc = true, ingenuityRefund = 3 }))
  local first = assert(Ledger.New(populated.database, clock))
  local second = assert(Ledger.New(first.database, clock))
  assert(second.database ~= first.database and first.database ~= populated.database)
  local row = second.database.craftSeries[1]
  assert(row.craftCount == 1 and row.outputQuantity == 4 and row.multicraftBonus == 2)
  assert(row.concentrationSpent == 5 and row.ingenuityProcCount == 1 and row.ingenuityRefund == 3)
  for _, metric in ipairs({ "outputQuantity", "multicraftBonus", "concentrationSpent",
    "ingenuityProcCount", "ingenuityRefund" }) do
    assert(row[metric .. "ObservedCount"] == 1)
  end
  assert(second.currentSessionId == nil and second.pendingRequest == nil)
end)

test("dimension enrichment is monotonic, atomic, and includes expansion metadata", function()
  local ledger = newLedger()
  for _, kind in ipairs({ "realm", "character", "profession", "recipe", "item", "session", "expansion" }) do
    local key = (kind == "recipe" or kind == "item" or kind == "profession") and 700 or "sparse"
    local id = assert(ledger:AddDimension(kind, key))
    assert(ledger:AddDimension(kind, key, { name = "Known" }) == id)
    assert(ledger:AddDimension(kind, key, { name = "Known" }) == id)
    local failed, reason = ledger:AddDimension(kind, key, { name = "Conflict", extra = "no" })
    assert(failed == nil and reason:find("conflicting", 1, true))
    assert(ledger:AddDimension(kind, key, { extra = "yes" }) == id)
    assert(ledger:AddDimension(kind, key, { id = id + 1 }) == nil)
  end
  local expansion = assert(ledger:AddDimension("expansion", "era", {
    displayName = "Observed Era", chronologicalOrder = 0,
  }))
  for _, kind in ipairs({ "recipe", "item", "profession" }) do
    local id = assert(ledger:AddDimension(kind, 700, { expansionDimensionId = expansion }))
    assert(ledger.dimensionRows[kind][id].expansionDimensionId == expansion)
    assert(ledger:AddDimension(kind, 700, { expansionDimensionId = expansion }) == id)
    assert(ledger:AddDimension(kind, 700, { expansionDimensionId = 999 }) == nil)
  end
  local metadata = { capabilities = { measurements = { available = false } } }
  local session = assert(ledger:AddDimension("session", "nested", metadata))
  metadata.capabilities.measurements.available = true
  assert(ledger.dimensionRows.session[session].capabilities.measurements.available == false)
  assert(ledger:AddDimension("session", "nested", metadata) == nil)
  assert(ledger:AddDimension("session", "nested", { capabilities = { flavor = "retail" } }) == session)
  assert(ledger.dimensionRows.session[session].capabilities.flavor == "retail")
  assert(Ledger.New(ledger.database))
end)

test("every persisted reference is validated before startup can prune", function()
  local cases = {
    { "crafts", "sessionId" }, { "crafts", "recipeId" },
    { "crafts", "outputItemId" }, { "crafts", "professionId" },
    { "reagents", "craftId" }, { "reagents", "itemId" },
    { "characters", "realmDimensionId" }, { "sessions", "characterDimensionId" },
    { "sessions", "realmDimensionId" }, { "recipes", "expansionDimensionId" },
    { "items", "expansionDimensionId" }, { "professions", "expansionDimensionId" },
    { "recipes", "professionId" },
  }
  for _, reference in ipairs(cases) do
    local ledger, clock = newLedger()
    replay(ledger, fixture.cases)
    ledger:AddDimension("profession", 164)
    local data = ledger.database
    local rows = data[reference[1]] or data.dimensions[reference[1]]
    local row = reference[1] == "recipes" and rows[fixture.cases[1].events[1].arguments[1]] or
      reference[1] == "items" and rows[next(rows)] or
      reference[1] == "professions" and rows[164] or rows[1]
    row[reference[2]] = 999
    clock.current = clock.current + 200 * 86400
    local refused, reason = Ledger.New(data, clock)
    assert(refused == nil and reason:find(reference[2], 1, true), reference[2])
    assert(data.schemaVersion == 2 and #data.crafts == 7 and #data.reagents == 9)
    assert(row[reference[2]] == 999)
  end
end)

test("natural metadata names are validated before commit and reload", function()
  for _, kind in ipairs({ "recipe", "item", "profession" }) do
    local ledger = newLedger()
    assert(ledger:AddDimension(kind, 700, { name = false }) == nil)
    assert(ledger.database.dimensions[kind .. "s"][700] == nil)
    assert(ledger:AddDimension(kind, 700, { name = "Known" }) == 700)
    ledger.database.dimensions[kind .. "s"][700].name = false
    assert(Ledger.New(ledger.database) == nil)
  end
end)

test("sparse collections and missing counters cannot be silently repaired", function()
  for _, collection in ipairs({ "crafts", "reagents" }) do
    local ledger = newLedger()
    replay(ledger, fixture.cases)
    local data = ledger.database
    local rows = data[collection] or data.dimensions[collection]
    rows[2] = nil
    assert(Ledger.New(data) == nil)
    assert(rows[3] ~= nil and data.schemaVersion == 2)
  end
  local ledger = newLedger()
  local data = ledger.database
  data.nextCraftId = nil
  assert(Ledger.New(data) == nil and data.nextCraftId == nil)
  data.nextCraftId = 100
  data.nextDimensionId.item = 100
  assert(Ledger.New(data) == nil and data.nextDimensionId.item == 100)
  data.nextDimensionId.item = nil
  data.retentionDays = false
  assert(Ledger.New(data) == nil and data.retentionDays == false)
  data.retentionDays = 180
  data.loop = data
  assert(Ledger.New(data) == nil and data.loop == data)
end)

test("dimension reference validation also rejects live invalid enrichment", function()
  local ledger = newLedger()
  for _, kind in ipairs({ "character", "session", "recipe", "item", "profession" }) do
    local key = (kind == "recipe" or kind == "item" or kind == "profession") and 700 or "target"
    local id = assert(ledger:AddDimension(kind, key))
    local field = (kind == "character" or kind == "session") and "realmDimensionId" or "expansionDimensionId"
    local counter = ledger.database.nextDimensionId[kind]
    assert(ledger:AddDimension(kind, key, { [field] = 999, name = "Must not stick" }) == nil)
    assert(ledger:AddDimension(kind, key, { name = "Valid" }) == id)
    assert(ledger.database.nextDimensionId[kind] == counter)
  end
end)

test("realm identities are scoped by runtime IDs, never inferred from names", function()
  local ledger = newLedger()
  local metadata = { projectId = 1, regionId = 1, gameRealmId = 12,
    realmName = "Shared Name", characterGUID = "Player-Test", characterName = "Crafter" }
  local first = assert(ledger:CreateSession(metadata))
  local firstRow = ledger.dimensionRows.session[first]
  local realmId = firstRow.realmDimensionId
  local characterId = firstRow.characterDimensionId
  local same = assert(ledger:CreateSession(metadata))
  assert(ledger.dimensionRows.session[same].realmDimensionId == realmId)
  assert(ledger.dimensionRows.session[same].characterDimensionId == characterId)
  metadata.regionId = 3
  local other = assert(ledger:CreateSession(metadata))
  assert(ledger.dimensionRows.session[other].realmDimensionId ~= realmId)
  assert(ledger.dimensionRows.session[other].characterDimensionId ~= characterId)
  metadata.projectId = 2
  local otherProject = assert(ledger:CreateSession(metadata))
  assert(ledger.dimensionRows.session[otherProject].realmDimensionId ~= ledger.dimensionRows.session[other].realmDimensionId)
  metadata.regionId = nil
  local unknown = assert(ledger:CreateSession(metadata))
  local unknownAgain = assert(ledger:CreateSession(metadata))
  local unresolved = ledger.dimensionRows.realm[ledger.dimensionRows.session[unknown].realmDimensionId]
  assert(unresolved.regionId == nil and unresolved.identityScope == "session")
  assert(ledger.dimensionRows.session[unknown].realmDimensionId ~= ledger.dimensionRows.session[unknownAgain].realmDimensionId)
  assert(Ledger.New(ledger.database))
end)

test("invalid result snapshots cannot partially persist a craft", function()
  local ledger = newLedger()
  local result = { operationID = 51, itemID = 100, resourcesReturned = {} }
  result.resourcesReturned[1] = result
  assert(ledger:RecordResult(result) == nil)
  assert(#ledger.database.crafts == 0 and #ledger.database.reagents == 0)
  assert(ledger.database.nextCraftId == 1 and rowCount(ledger.database.dimensions.items) == 0)
  assert(ledger:AddDimension("item", 100, { id = 101 }) == nil)
  assert(ledger:AddDimension("item", 100))
  assert(ledger:AddDimension("item", 100, { expansionDimensionId = 999 }) == nil)
  assert(ledger.dimensionRows.item[100].expansionDimensionId == nil)
  local recorded = assert(ledger:RecordResult({ itemID = 200, resourcesReturned = {
    { reagent = { itemID = 100 }, quantity = 1 },
  } }))
  assert(recorded.outputItemId == 200 and ledger.database.reagents[1].itemId == 100)
  assert(ledger.database.nextCraftId == 2 and next(ledger.operationIndex) == nil)
  ledger.wall = function() return nil end
  assert(ledger:RecordResult({}) == nil)
  assert(ledger.database.nextCraftId == 2)
end)

test("pruning is deterministic at age boundaries with consistent indexes", function()
  local ledger, clock, sessionId = newLedger({ retentionDays = 1 })
  local first = assert(primaryResult(ledger, { operationID = 10, quantity = 1 }))
  local second = assert(primaryResult(ledger, { operationID = 10, quantity = 1,
    resourcesReturned = { { reagent = { itemID = 100 }, quantity = 0 } } }))
  clock.current = clock.current + 86400
  ledger:Prune(clock.current)
  assert(#ledger.database.crafts == 2)
  ledger.database.crafts[1], ledger.database.crafts[2] = second, first
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(#reloaded.database.crafts == 2)
  assert(reloaded.craftIds[1] == first.id and reloaded.craftIds[2] == second.id)
  assert(reloaded.craftIdsByTime[1] == first.id and reloaded.craftIdsByTime[2] == second.id)
  -- A complete all-zero return list is an observed negative and needs no reagent row.
  assert(#reloaded.database.reagents == 0 and reloaded.database.crafts[2].hasResourcefulnessProc == false)
  assert(reloaded.operationIndex[sessionId][10] == 2)
  clock.current = clock.current + 1
  reloaded:Prune(clock.current)
  assert(#reloaded.database.crafts == 0 and #reloaded.database.reagents == 0)
  assert(reloaded.operationIndex[sessionId] == nil and reloaded.database.nextCraftId == 3)
  assert(next(reloaded.craftById) == nil and next(reloaded.reagentsByCraftId) == nil)
  assert(#reloaded.craftIds == 0 and #reloaded.craftIdsByTime == 0)
  assert(rowCount(reloaded.database.dimensions.items) == 1)
end)

test("real concentration batch retains separate results with intentionally absent recipe attribution", function()
  local ledger = newLedger()
  replay(ledger, { fixture.cases[2] })
  assert(#ledger.database.crafts == 2)
  local first, second = ledger.database.crafts[1], ledger.database.crafts[2]
  assert(first.id ~= second.id and first.gameOperationId ~= second.gameOperationId)
  for _, craft in ipairs(ledger.database.crafts) do
    assert(craft.recipeId == nil)
    assert(craft.concentrationSpent == 185 and craft.hasIngenuityProc == false and craft.ingenuityRefund == 93)
    assert(craft.netConcentration == nil and craft.actualRefund == nil)
  end
end)

test("one submission snapshot links only its observed batch results", function()
  local ledger = newLedger()
  local request = assert(ledger:SubmitCraft(456, 3, false, {
    concentrationCost = 81, baseSkill = 120, baseDifficulty = 200, craftingQuality = 2,
  }, {
    { dataSlotIndex = 1, quantity = 3, reagent = { itemID = 101 }, quality = 2 },
    { dataSlotIndex = 1, quantity = 0, reagent = { itemID = 102 } },
  }))
  assert(request.id == 1 and request.requestedCount == 3 and request.useConcentration == false)
  assert(request.concentrationCost == 81 and #request.allocations == 1)
  assert(request.allocations[1].allocatedQuantity == 3 and request.allocations[1].quality == 2)
  for operationId = 1, 3 do
    local craft = assert(primaryResult(ledger, { operationID = operationId,
      concentrationSpent = 80, resourcesReturned = operationId == 1 and {
        { reagent = { itemID = 101 }, quantity = 1 },
      } or {} }))
    assert(craft.requestId == request.id and craft.concentrationSpent == 80)
  end
  assert(#ledger.database.crafts == 3 and #ledger.database.reagents == 3)
  assert(ledger.database.reagents[1].allocatedQuantity == 3)
  assert(ledger.database.reagents[1].returnedQuantity == 1)
  assert(ledger.database.reagents[2].returnedQuantity == 0)
  assert(assert(ledger:RecordResult({ operationID = 4 })).requestId == nil)
end)

test("allocation snapshots reject zero slot and item IDs", function()
  local ledger = newLedger()
  local request = assert(ledger:SubmitCraft(456, 1, false, nil, {
    { dataSlotIndex = 0, quantity = 1, reagent = { itemID = 101 } },
    { dataSlotIndex = 1, quantity = 1, reagent = { itemID = 0 } },
    { dataSlotIndex = 2, quantity = 2, reagent = { itemID = 102 } },
  }))
  assert(request.allocations and #request.allocations == 1)
  assert(request.allocations[1].dataSlotIndex == 2)
  local item = ledger.dimensionRows.item[request.allocations[1].itemId]
  assert(item.id == 102)

  local unknown = assert(ledger:SubmitCraft(457, 1, false, nil, {
    { dataSlotIndex = 0, quantity = 1, reagent = { itemID = 103 } },
    { dataSlotIndex = 1, quantity = 1, reagent = { itemID = 0 } },
  }))
  assert(unknown.allocations == nil)
end)

test("sanitized personal craft replay preserves quote, allocation, returns, and partial batch", function()
  local ledger = newLedger()
  assert(personalFixture.build == fixture.build and personalFixture.version == fixture.version)
  for _, scenario in ipairs(personalFixture.cases) do
    local request = assert(ledger:SubmitCraft(scenario.recipeId, scenario.requestedCount,
      scenario.useConcentration, scenario.quote, scenario.selections))
    assert(request.requestedCount == scenario.requestedCount)
    for _, result in ipairs(scenario.results) do
      local craft = assert(fixtureResult(ledger, result))
      assert(craft.requestId == request.id and craft.recipeId == request.recipeId)
    end
    if scenario.failedQueuedOperation then ledger:CancelCraft() end
  end
  local data = ledger.database
  assert(#data.requests == 4 and #data.crafts == 6 and #data.reagents == 8)
  assert(data.requests[1].allocations[1].allocatedQuantity == 3)
  assert(data.requests[1].allocations[1].quality == 1)
  assert(data.requests[2].allocations[1].itemId ~= data.requests[1].allocations[1].itemId)
  assert(data.requests[2].useConcentration and data.requests[2].concentrationCost == 81)
  assert(data.crafts[2].concentrationSpent == 80 and data.crafts[2].hasIngenuityProc == false)
  assert(data.reagents[1].returnedQuantity == 1 and data.reagents[2].returnedQuantity == 1)
  assert(data.reagents[3].returnedQuantity == 0 and data.reagents[4].returnedQuantity == 0)
  assert(data.crafts[3].requestId == data.crafts[4].requestId)
  assert(data.crafts[4].requestId == data.crafts[5].requestId)
  assert(data.requests[4].requestedCount == 3 and data.crafts[6].requestId == data.requests[4].id)
  assert(assert(fixtureResult(ledger, { operationID = 3002 })).requestId == nil)
end)

test("new submissions supersede unfinished personal requests without guessing duplicate returns", function()
  local ledger = newLedger()
  local first = assert(ledger:SubmitCraft(1, 3, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 100 } },
    { dataSlotIndex = 2, quantity = 2, reagent = { itemID = 100 } },
  }))
  local result = assert(fixtureResult(ledger, { operationID = 4, resourcesReturned = {
    { reagent = { itemID = 100 }, quantity = 1 },
  } }))
  assert(result.requestId == first.id and #ledger.database.reagents == 3)
  assert(ledger.database.reagents[1].returnedQuantity == nil)
  assert(ledger.database.reagents[2].returnedQuantity == nil)
  assert(ledger.database.reagents[3].allocatedQuantity == nil)
  assert(ledger.database.reagents[3].returnedQuantity == 1)
  local second = assert(ledger:SubmitCraft(2, 2, false))
  local resumed = assert(fixtureResult(ledger, { operationID = 5 }))
  assert(resumed.requestId == nil and resumed.recipeId == nil and resumed.outcomeSource == "unverified")
  ledger:CancelCraft()
  ledger:SubmitCraft(3, 2, false)
  assert(assert(fixtureResult(ledger, { operationID = 5 })).requestId == nil)
  assert(assert(fixtureResult(ledger, {})).requestId == nil)
end)

test("a partial batch is superseded by a new recipe in the same session", function()
  local ledger = newLedger()
  local first = assert(ledger:SubmitCraft(101, 25, false))
  ledger:BeginCraft(101)
  assert(assert(fixtureResult(ledger, { operationID = 1 })).requestId == first.id)
  local second = assert(ledger:SubmitCraft(102, 2, false))
  for operationId = 2, 3 do
    ledger:BeginCraft(102)
    local craft = assert(fixtureResult(ledger, { operationID = operationId }))
    assert(craft.requestId == nil and craft.recipeId == nil and craft.outcomeSource == "unverified")
  end
  assert(ledger.pendingRequest == nil and ledger.requestAmbiguous == true)
  assert(ledger.database.requests[1].requestedCount == 25)
end)

test("unknown recipe repair transfers uniquely evidenced crafts and preserves durable series", function()
  local ledger, clock = newLedger()
  ledger:AddDimension("profession", 800, { name = "Sanitized Profession" })
  ledger:AddDimension("recipe", 101, { professionId = 800 })
  ledger:BeginCraft(101)
  local attributed = assert(fixtureResult(ledger, { operationID = 1, itemID = 500,
    quantity = 1, multicraft = 0, concentrationSpent = 0, hasIngenuityProc = false }))
  ledger:BeginCraft(102)
  assert(fixtureResult(ledger, { operationID = 2, itemID = 600 }))
  ledger:BeginCraft(103)
  assert(fixtureResult(ledger, { operationID = 3, itemID = 600 }))

  local request = assert(ledger:SubmitCraft(101, 1, false))
  ledger:CancelCraft()
  local function unknown(operationId, itemId, result)
    result = result or {}
    result.operationID = operationId
    result.itemID = itemId
    ledger:BeginCraft(nil)
    return assert(ledger:RecordResult(result))
  end
  local first = unknown(4, 500, { quantity = 2, multicraft = 1,
    concentrationSpent = 10, hasIngenuityProc = true, ingenuityRefund = 3 })
  local second = unknown(5, 500, { quantity = 4, concentrationSpent = 20,
    hasIngenuityProc = false })
  local ambiguous = unknown(6, 600)
  local unsupported = unknown(7, 700)
  local missingOutput = unknown(8, nil)
  local unknownSeries
  for _, row in ipairs(ledger.database.craftSeries) do
    if row.recipeId == nil then unknownSeries = row; break end
  end
  assert(unknownSeries and unknownSeries.craftCount == 5)
  unknownSeries.craftCount = unknownSeries.craftCount + 1
  unknownSeries.outputQuantity = unknownSeries.outputQuantity + 7
  unknownSeries.outputQuantityObservedCount = unknownSeries.outputQuantityObservedCount + 1

  local analysis = assert(ledger:AnalyzeUnknownRecipeRepair())
  assert(analysis.unattributedCount == 5 and analysis.repairableCount == 2)
  assert(ledger.unknownRecipeCount == 5)
  assert(analysis.ambiguousCount == 1 and analysis.insufficientEvidenceCount == 1)
  assert(analysis.missingOutputCount == 1 and #analysis.repairs == 2)
  assert(analysis.ambiguous[1].craftId == ambiguous.id)
  assert(#analysis.ambiguous[1].recipeIds == 2)
  assert(first.recipeId == nil and second.recipeId == nil)

  local originalAttributed = {
    recipeId = attributed.recipeId,
    requestId = attributed.requestId,
    outputItemId = attributed.outputItemId,
    timestamp = attributed.timestamp,
  }
  local result = assert(ledger:RepairUnknownRecipes())
  assert(result.repairedCount == 2)
  assert(ledger.unknownRecipeCount == 3)
  assert(ledger.database.schemaVersion == 2)
  local repairedFirst, repairedSecond = ledger.craftById[first.id], ledger.craftById[second.id]
  assert(repairedFirst.recipeId == 101 and repairedSecond.recipeId == 101)
  assert(repairedSecond.requestId == nil)
  assert(ledger.craftById[ambiguous.id].recipeId == nil)
  assert(ledger.craftById[unsupported.id].recipeId == nil)
  assert(ledger.craftById[missingOutput.id].recipeId == nil)
  assert(attributed.recipeId == originalAttributed.recipeId and
    attributed.requestId == originalAttributed.requestId and
    attributed.outputItemId == originalAttributed.outputItemId and
    attributed.timestamp == originalAttributed.timestamp)
  assert(#ledger.craftIdsByRecipe[101] == 3 and ledger.recipeCounts[101] == 3)
  assert(ledger.dimensionRows.recipe[101].professionId == 800)

  local unknownAfter, targetAfter
  for _, row in ipairs(ledger.database.craftSeries) do
    if row.recipeId == nil then unknownAfter = row end
    if row.recipeId == 101 then targetAfter = row end
  end
  assert(unknownAfter and unknownAfter.craftCount == 4)
  assert(unknownAfter.outputQuantity == 7 and unknownAfter.outputQuantityObservedCount == 1)
  assert(unknownAfter.multicraftBonusObservedCount == 0 and unknownAfter.multicraftBonus == nil)
  assert(unknownAfter.concentrationSpentObservedCount == 0 and unknownAfter.concentrationSpent == nil)
  assert(unknownAfter.ingenuityProcCountObservedCount == 0 and unknownAfter.ingenuityProcCount == nil)
  assert(unknownAfter.ingenuityRefundObservedCount == 0 and unknownAfter.ingenuityRefund == nil)
  assert(targetAfter and targetAfter.craftCount == 3)
  assert(targetAfter.outputQuantity == 7 and targetAfter.outputQuantityObservedCount == 3)
  assert(targetAfter.multicraftBonus == 1 and targetAfter.multicraftBonusObservedCount == 2)
  assert(targetAfter.concentrationSpent == 30 and targetAfter.concentrationSpentObservedCount == 3)
  assert(targetAfter.ingenuityProcCount == 1 and targetAfter.ingenuityProcCountObservedCount == 3)
  assert(targetAfter.ingenuityRefund == 3 and targetAfter.ingenuityRefundObservedCount == 3)

  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(reloaded.database.schemaVersion == 2 and reloaded.craftById[first.id].recipeId == 101)
  assert(reloaded.recipeCounts[101] == 3)
  assert(ledger:RepairUnknownRecipes().repairedCount == 0)
end)

test("recipe-output knowledge is idempotent, supports multiple outputs, and preserves ambiguity", function()
  local ledger = newLedger()
  local unknownX = assert(fixtureResult(ledger, { operationID = 1, itemID = 1200 }))
  local unknownY = assert(fixtureResult(ledger, { operationID = 2, itemID = 1201 }))
  ledger:BeginCraft(1100)
  assert(fixtureResult(ledger, { operationID = 3, itemID = 1200 }))
  ledger:BeginCraft(1100)
  assert(fixtureResult(ledger, { operationID = 4, itemID = 1201 }))
  ledger:BeginCraft(1100)
  assert(fixtureResult(ledger, { operationID = 5, itemID = 1200 }))
  assert(ledger.database.recipeOutputs[1100][1200] == true)
  assert(ledger.database.recipeOutputs[1100][1201] == true)
  assert(ledger.recipeOutputCount == 2)
  assert(ledger.recipeIdsByOutputItemId[1200][1100] == true)
  assert(ledger.recipeIdsByOutputItemId[1201][1100] == true)
  local analysis = assert(ledger:AnalyzeUnknownRecipeRepair())
  assert(analysis.repairableCount == 2 and analysis.ambiguousCount == 0)
  assert(ledger:RepairUnknownRecipes().repairedCount == 2)
  assert(ledger.craftById[unknownX.id].recipeId == 1100 and
    ledger.craftById[unknownY.id].recipeId == 1100)

  ledger:BeginCraft(1101)
  assert(fixtureResult(ledger, { operationID = 6, itemID = 1200 }))
  assert(ledger.database.recipeOutputs[1101][1200] == true)
  assert(ledger.recipeOutputCount == 3)
  assert(ledger.recipeIdsByOutputItemId[1200][1100] == true and
    ledger.recipeIdsByOutputItemId[1200][1101] == true)
  local ambiguous = assert(fixtureResult(ledger, { operationID = 7, itemID = 1200 }))
  analysis = assert(ledger:AnalyzeUnknownRecipeRepair())
  assert(analysis.ambiguousCount == 1 and analysis.repairableCount == 0)
  assert(ledger:RepairUnknownRecipes().repairedCount == 0)
  assert(ledger.craftById[ambiguous.id].recipeId == nil and ledger.unknownRecipeCount == 1)
  assert(ledger.database.recipeOutputs[1100][1200] == true)
end)

test("recipe-output bootstrap is idempotent and survives source-craft retention", function()
  local ledger, clock = newLegacyLedger({ retentionDays = 1 })
  ledger:BeginCraft(1300)
  assert(ledger:RecordResult({ operationID = 1, itemID = 1400, quantity = 2 }))
  assert(ledger.recipeOutputCount == 1)
  ledger.database.recipeOutputs = nil
  local loaded = assert(Ledger.New(ledger.database, clock))
  assert(loaded.database.schemaVersion == 2 and loaded.database.recipeOutputs ~= nil)
  assert(next(loaded.database.recipeOutputs) == nil)
  local bootstrap = assert(loaded:BootstrapRecipeOutputs())
  assert(bootstrap.learned == 1 and bootstrap.existing == 0 and bootstrap.relationshipCount == 1)
  bootstrap = assert(loaded:BootstrapRecipeOutputs())
  assert(bootstrap.learned == 0 and bootstrap.existing == 1 and bootstrap.relationshipCount == 1)
  assert(loaded.recipeIdsByOutputItemId[1400][1300] == true)

  clock.current = clock.current + 2 * 86400
  local pruned = assert(Ledger.New(loaded.database, clock))
  assert(#pruned.database.crafts == 0 and pruned.database.recipeOutputs[1300][1400] == true)
  assert(pruned.recipeIdsByOutputItemId[1400][1300] == true)
  assert(pruned:CreateSession({ startedAt = clock.current, characterName = "Later Crafter" }))
  local unknown = assert(pruned:RecordResult({ operationID = 2, itemID = 1400, quantity = 3 }))
  local analysis = assert(pruned:AnalyzeUnknownRecipeRepair())
  assert(analysis.repairableCount == 1)
  assert(pruned:RepairUnknownRecipes().repairedCount == 1)
  assert(pruned.craftById[unknown.id].recipeId == 1300 and pruned.unknownRecipeCount == 0)
  assert(pruned.database.schemaVersion == 2 and pruned.database.recipeOutputs[1300][1400] == true)
  local reloaded = assert(Ledger.New(pruned.database, clock))
  assert(reloaded.recipeIdsByOutputItemId[1400][1300] == true)
  assert(reloaded.craftById[unknown.id].recipeId == 1300)
end)

test("unknown recipe repair evidence can improve and staged index failures are atomic", function()
  local ledger = newLedger()
  ledger:BeginCraft(nil)
  local historical = assert(fixtureResult(ledger, { operationID = 1, itemID = 900 }))
  local before = assert(ledger:AnalyzeUnknownRecipeRepair())
  assert(before.insufficientEvidenceCount == 1 and before.repairableCount == 0)
  assert(ledger.unknownRecipeCount == 1)
  ledger:BeginCraft(901)
  assert(fixtureResult(ledger, { operationID = 2, itemID = 900 }))
  assert(ledger:AnalyzeUnknownRecipeRepair().repairableCount == 1)

  local database = ledger.database
  local oldRebuild = Ledger.RebuildIndexes
  Ledger.RebuildIndexes = function() error("injected staged rebuild failure") end
  local failed, reason = ledger:RepairUnknownRecipes()
  Ledger.RebuildIndexes = oldRebuild
  assert(failed == nil and reason:match("repair index staging failed"))
  assert(ledger.database == database and ledger.craftById[historical.id].recipeId == nil)
  assert(ledger.unknownRecipeCount == 1)
  assert(ledger:RepairUnknownRecipes().repairedCount == 1)
  assert(ledger.craftById[historical.id].recipeId == 901)
  assert(ledger.unknownRecipeCount == 0)
end)

test("unknown recipe count is derived on load and follows commits pruning and clear", function()
  local ledger, clock = newLedger({ retentionDays = 1 })
  for index = 1, 3 do
    ledger:BeginCraft(101)
    assert(fixtureResult(ledger, { operationID = index, itemID = 500 }))
  end
  assert(ledger.unknownRecipeCount == 0)
  ledger:BeginCraft(nil)
  local prunedUnknown = assert(fixtureResult(ledger, { operationID = 4, itemID = 600 }))
  assert(ledger.unknownRecipeCount == 1)
  ledger:BeginCraft(nil)
  assert(fixtureResult(ledger, { operationID = 5, itemID = 600 }))
  assert(ledger.unknownRecipeCount == 2)
  local database = ledger.database
  assert(database.unknownRecipeCount == nil)

  local reloaded = assert(Ledger.New(database, clock))
  assert(reloaded.database ~= database and reloaded.unknownRecipeCount == 2)
  assert(reloaded:RecordResult("invalid") == nil and reloaded.unknownRecipeCount == 2)
  reloaded.craftById[prunedUnknown.id].timestamp = clock.current - 86401
  reloaded:Prune(clock.current)
  assert(reloaded.unknownRecipeCount == 1)
  local durableUnknownSeries
  for _, row in ipairs(database.craftSeries) do
    if row.recipeId == nil then durableUnknownSeries = row end
  end
  assert(durableUnknownSeries and durableUnknownSeries.craftCount == 2)
  assert(reloaded:ClearHistory() and reloaded.unknownRecipeCount == 0)
end)

test("a late begin keeps its observed recipe without claiming the newer request", function()
  local ledger = newLedger()
  assert(ledger:SubmitCraft(101, 3, false))
  local second = assert(ledger:SubmitCraft(102, 1, false))
  ledger:BeginCraft(101)
  local late = assert(fixtureResult(ledger, { operationID = 1 }))
  assert(late.requestId == nil and late.recipeId == nil)
  ledger:BeginCraft(102)
  local craft = assert(fixtureResult(ledger, { operationID = 2 }))
  assert(craft.requestId == nil and craft.recipeId == nil)
  assert(ledger.requestById[second.id] and ledger.requestById[second.id].recipeId == 102 and
    ledger.requestById[second.id].requestedCount == 1)
end)

test("a new submission clears an abandoned begin without a result", function()
  local ledger = newLedger()
  assert(ledger:SubmitCraft(101, 3, false))
  ledger:BeginCraft(101)
  local second = assert(ledger:SubmitCraft(102, 1, false))
  local craft = assert(fixtureResult(ledger, { operationID = 1 }))
  assert(craft.requestId == nil and craft.recipeId == nil and craft.outcomeSource == "unverified")
end)

test("a completed batch does not obstruct a subsequent recipe", function()
  local ledger = newLedger()
  local first = assert(ledger:SubmitCraft(101, 1, false))
  assert(assert(fixtureResult(ledger, { operationID = 1 })).requestId == first.id)
  local second = assert(ledger:SubmitCraft(102, 1, false))
  assert(assert(fixtureResult(ledger, { operationID = 2 })).requestId == second.id)
end)

test("a same-recipe restart uses the latest submission and allocations", function()
  local ledger = newLedger()
  local first = assert(ledger:SubmitCraft(101, 3, false))
  assert(assert(fixtureResult(ledger, { operationID = 1 })).requestId == first.id)
  local second = assert(ledger:SubmitCraft(101, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 501 } },
  }))
  ledger:BeginCraft(101)
  local craft = assert(fixtureResult(ledger, { operationID = 2 }))
  assert(craft.requestId == nil and craft.recipeId == nil and craft.outcomeSource == "unverified")
  assert(#ledger.database.reagents == 0)
end)

test("cancelled batches and profession-window close discard pending correlation", function()
  local ledger = newLedger()
  assert(ledger:SubmitCraft(101, 3, false))
  ledger:CancelCraft()
  assert(assert(fixtureResult(ledger, { operationID = 1 })).requestId == nil)
  local second = assert(ledger:SubmitCraft(102, 2, false))
  assert(assert(fixtureResult(ledger, { operationID = 2 })).requestId == nil)
  ledger:CancelCraft()
  assert(ledger.pendingRequest == nil and ledger.requestAmbiguous == nil)
  assert(assert(fixtureResult(ledger, { operationID = 3 })).requestId == nil)
  local third = assert(ledger:SubmitCraft(103, 1, false))
  assert(assert(fixtureResult(ledger, { operationID = 4 })).requestId == nil)
end)

test("a character switch cannot inherit an unfinished request", function()
  local ledger = newLedger()
  local first = assert(ledger:SubmitCraft(101, 3, false))
  local newSession = assert(ledger:CreateSession({ startedAt = 1800000001,
    characterName = "Other Crafter", characterGUID = "Player-Other", realmName = "Sanitized Realm" }))
  assert(ledger.pendingRequest == nil and ledger.requestAmbiguous == nil)
  assert(assert(fixtureResult(ledger, { operationID = 1 })).requestId == nil)
  local second = assert(ledger:SubmitCraft(102, 1, false))
  local craft = assert(fixtureResult(ledger, { operationID = 2 }))
  assert(craft.requestId == second.id and craft.sessionId == newSession and first.sessionId ~= newSession)
end)

test("authoritative begin supersedes a stale incomplete request from another recipe", function()
  local ledger = newLedger()
  local stale = assert(ledger:SubmitCraft(101, 5, true))
  ledger:BeginCraft(101)
  local first = assert(fixtureResult(ledger, { operationID = 1, quantity = 1 }))
  assert(first.requestId == stale.id and first.recipeId == 101)
  assert(ledger.pendingRequest and ledger.pendingRequest.remaining == 4)

  -- Retail can stop an incomplete batch without a close/cancel signal. A later
  -- begin for a different recipe is authoritative and must not remain unknown.
  ledger:BeginCraft(202)
  local nextCraft = assert(fixtureResult(ledger, { operationID = 2, quantity = 1 }))
  assert(nextCraft.requestId == nil and nextCraft.recipeId == nil)
  assert(ledger.pendingRequest == nil and ledger.requestAmbiguous == true)

  ledger:BeginCraft(303)
  local following = assert(fixtureResult(ledger, { operationID = 3, quantity = 1 }))
  assert(following.recipeId == nil)
end)

test("unsupported concurrent crafts cannot be superseded into personal results", function()
  local ledger = newLedger()
  assert(ledger:SubmitCraft(101, 3, false))
  ledger:InvalidateCraft()
  assert(ledger:SubmitCraft(102, 1, false))
  ledger:BeginCraft(102)
  local craft = assert(fixtureResult(ledger, { operationID = 1 }))
  assert(craft.requestId == nil and craft.recipeId == nil)
  ledger:CancelCraft()
  assert(ledger:CreateSession({}))
  local nextRequest = assert(ledger:SubmitCraft(103, 1, false))
  assert(assert(fixtureResult(ledger, { operationID = 2 })).requestId == nextRequest.id)
end)

test("unsupported craft submission cannot inherit a personal request", function()
  local ledger = newLedger()
  assert(ledger:SubmitCraft(456, 2, false))
  ledger:InvalidateCraft()
  ledger:BeginCraft(789)
  assert(assert(ledger:RecordResult({ operationID = 1 })).requestId == nil)
  assert(ledger.database.crafts[1].recipeId == nil)
  assert(#ledger.database.requests == 1 and #ledger.database.crafts == 1)
end)

test("unrelated quote fields cannot leak into or block a request", function()
  local ledger = newLedger()
  local quote = { concentrationCost = 0, customer = function() end }
  local request = assert(ledger:SubmitCraft(456, 1, false, quote))
  assert(request.concentrationCost == 0 and request.customer == nil)
  assert(Ledger.New(ledger.database))
end)

test("reload preserves partial returns and refuses invalid request references", function()
  local ledger, clock = newLedger()
  local result = assert(ledger:RecordResult({ operationID = 1, resourcesReturned = {
    { reagent = { itemID = 101 }, quantity = 2 },
  } }))
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(reloaded.database.schemaVersion == 2 and reloaded.database.nextRequestId == 1)
  assert(#reloaded.database.requests == 0 and reloaded.database.crafts[1].id == result.id)
  assert(reloaded.database.reagents[1].allocatedQuantity == nil)
  reloaded:CreateSession({})
  local request = assert(reloaded:SubmitCraft(456, 1, false))
  assert(request.id == 1 and assert(reloaded:RecordResult({})).id == 2)
  assert(assert(Ledger.New(reloaded.database)).database.requests[1].completedCount == nil)
  for _, field in ipairs({ "requestId", "sessionId", "recipeId", "itemId" }) do
    local data = reloaded.database
    local copied = assert(Ledger.New(data)).database
    local row = field == "requestId" and copied.crafts[2] or
      field == "itemId" and copied.requests[1].allocations or copied.requests[1]
    if field == "itemId" then
      copied.requests[1].allocations = { { dataSlotIndex = 1, allocatedQuantity = 1, itemId = 999 } }
    else
      row[field] = 999
    end
    local refused = Ledger.New(copied)
    assert(refused == nil and copied.schemaVersion == 2 and copied.requests[1].id == 1, field)
  end
  local mismatched = assert(Ledger.New(reloaded.database)).database
  mismatched.crafts[2].recipeId = 999
  assert(Ledger.New(mismatched) == nil)
end)

test("request reload and pruning keep surviving references and monotonic IDs", function()
  local ledger, clock = newLedger({ retentionDays = 1 })
  local first = assert(ledger:SubmitCraft(1, 2, false))
  local craft = assert(ledger:RecordResult({ operationID = 1 }))
  local reloaded = assert(Ledger.New(ledger.database, clock))
  reloaded:CreateSession({})
  assert(assert(reloaded:RecordResult({ operationID = 2 })).requestId == nil)
  assert(#reloaded.database.requests == 1 and #reloaded.database.crafts == 2)
  local second = assert(reloaded:SubmitCraft(2, 1, true))
  assert(first.id == 1 and second.id == 2 and craft.id == 1)
  clock.current = clock.current + 86401
  reloaded:Prune(clock.current)
  assert(#reloaded.database.requests == 0 and #reloaded.database.reagents == 0)
  assert(reloaded.database.nextRequestId == 3 and reloaded.database.nextCraftId == 3)
end)

test("age pruning retains an old request while a newer craft references it", function()
  local ledger, clock = newLedger({ retentionDays = 1 })
  local request = assert(ledger:SubmitCraft(456, 2, false))
  clock.current = clock.current + 86401
  local craft = assert(fixtureResult(ledger, { operationID = 9 }))
  assert(craft.requestId == request.id and #ledger.database.requests == 1)
  assert(Ledger.New(ledger.database, clock))
  ledger:CancelCraft()
  clock.current = clock.current + 86401
  ledger:Prune(clock.current)
  assert(#ledger.database.requests == 0 and #ledger.database.crafts == 0)
end)

test("schema 2 refuses persisted and configured count caps", function()
  local ledger, clock = newLedger()
  for _, cap in ipairs({ false, 0, 1, 50000 }) do
    local refused, reason = Ledger.New(ledger.database, clock, { maxCrafts = cap })
    assert(refused == nil and reason:find("maxCrafts", 1, true))
    assert(ledger.database.maxCrafts == nil)
    ledger.database.maxCrafts = cap
    refused, reason = Ledger.New(ledger.database, clock)
    assert(refused == nil and reason:find("maxCrafts", 1, true))
    assert(ledger.database.schemaVersion == 2 and ledger.database.maxCrafts == cap)
    ledger.database.maxCrafts = nil
  end
end)

test("startup prunes before building runtime indexes once", function()
  local ledger, clock, sessionId = newLedger()
  local request = assert(ledger:SubmitCraft(12, 2, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 100 } },
  }))
  local old = assert(fixtureResult(ledger, { operationID = 10 }))
  clock.current = clock.current + 60 * 86400 + 1
  local retained = assert(fixtureResult(ledger, { operationID = 11 }))
  assert(#ledger.database.crafts == 2 and #ledger.database.reagents == 2)
  local orphan = assert(ledger:SubmitCraft(13, 1, false))
  orphan.timestamp = old.timestamp
  ledger:CancelCraft()
  local builds = 0
  local rebuild = Ledger.RebuildIndexes
  Ledger.RebuildIndexes = function(self)
    builds = builds + 1
    assert(self.craftById == nil and self.dimensionRows == nil and self.operationIndex == nil)
    assert(#self.database.crafts == 1 and self.database.crafts[1].id == retained.id)
    assert(#self.database.requests == 1 and #self.database.reagents == 1)
    rebuild(self)
  end
  local reloaded, reason = Ledger.New(ledger.database, clock)
  Ledger.RebuildIndexes = rebuild
  assert(reloaded, reason)
  assert(builds == 1 and #ledger.database.crafts == 2)
  assert(reloaded.craftById[old.id] == nil and reloaded.reagentsByCraftId[old.id] == nil)
  assert(reloaded.requestById[orphan.id] == nil)
  assert(reloaded.craftById[retained.id] == reloaded.database.crafts[1])
  assert(reloaded.requestById[request.id] == reloaded.database.requests[1])
  assert(reloaded.reagentsByCraftId[retained.id][1] == reloaded.database.reagents[1])
  assert(reloaded.operationIndex[sessionId][10] == nil)
  assert(reloaded.operationIndex[sessionId][11] == 1)
  assert(reloaded.pendingRequest == nil)
  reloaded.currentSessionId = sessionId
  reloaded:BeginCraft(14)
  assert(assert(reloaded:RecordResult({ operationID = 10, itemID = 900000, quantity = 1 })).recipeId == 14)
end)

test("secondary indexes track domain identities and monotonic dimension enrichment", function()
  local ledger, clock = newLedger()
  local sessionId = assert(ledger:CreateSession({}))
  local request = assert(ledger:SubmitCraft(12, 1, false))
  local craft = assert(fixtureResult(ledger, {}))
  local unknown = assert(fixtureResult(ledger, {}))
  assert(ledger.craftIdsByRecipe[12][1] == craft.id)
  assert(next(ledger.craftIdsByCharacter) == nil and next(ledger.craftIdsByRealm) == nil)
  assert(next(ledger.craftIdsByProfession) == nil and next(ledger.craftIdsByExpansion) == nil)
  local indexes = ledger.craftIdsByRecipe
  local expansion = assert(ledger:AddDimension("expansion", "era", {}))
  local otherExpansion = assert(ledger:AddDimension("expansion", "other-era", {}))
  local profession = assert(ledger:AddDimension("profession", 164, {
    expansionDimensionId = otherExpansion,
  }))
  local realm = assert(ledger:AddDimension("realm", "realm-key", {}))
  local character = assert(ledger:AddDimension("character", "character-key", {
    realmDimensionId = realm,
  }))
  assert(ledger.craftIdsByRecipe == indexes)
  assert(ledger:AddDimension("recipe", 12, {
    professionId = profession, expansionDimensionId = expansion,
  }) == request.recipeId)
  assert(ledger.craftIdsByExpansion.era[1] == craft.id)
  assert(ledger.craftIdsByExpansion["other-era"] == nil)
  assert(ledger.craftIdsByProfession[164][1] == craft.id)
  local session = ledger.dimensionRows.session[sessionId]
  assert(ledger:AddDimension("session", session.key, {
    characterDimensionId = character, realmDimensionId = realm,
  }) == sessionId)
  for _, ids in ipairs({ ledger.craftIdsByCharacter["character-key"], ledger.craftIdsByRealm["realm-key"] }) do
    assert(#ids == 2 and ids[1] == craft.id and ids[2] == unknown.id)
  end
  indexes = ledger.craftIdsByRecipe
  assert(ledger:AddDimension("recipe", 12, {
    professionId = profession, expansionDimensionId = expansion,
  }))
  assert(ledger.craftIdsByRecipe == indexes)
  assert(ledger:AddDimension("recipe", 12, { professionId = 999, name = "Conflict" }) == nil)
  assert(ledger.craftIdsByRecipe == indexes and ledger.dimensionRows.recipe[request.recipeId].name == nil)
  local override = assert(ledger:AddDimension("profession", 171))
  craft.professionId = override
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(reloaded.craftIdsByProfession[164] == nil)
  assert(reloaded.craftIdsByProfession[171][1] == craft.id)
  assert(reloaded.craftIdsByExpansion.era[1] == craft.id)
end)

test("time indexes append ties and insert backdated timestamps with ID tie breaks", function()
  local ledger, clock = newLedger()
  local first = assert(ledger:RecordResult({}))
  local second = assert(ledger:RecordResult({}))
  clock.current = clock.current - 10
  local third = assert(ledger:RecordResult({}))
  local fourth = assert(ledger:RecordResult({}))
  clock.current = clock.current + 20
  local fifth = assert(ledger:RecordResult({}))
  local expected = { third.id, fourth.id, first.id, second.id, fifth.id }
  for index, id in ipairs(expected) do assert(ledger.craftIdsByTime[index] == id) end
  ledger.database.crafts[1], ledger.database.crafts[5] = fifth, first
  local reloaded = assert(Ledger.New(ledger.database, clock))
  for index, id in ipairs(expected) do
    assert(reloaded.craftIdsByTime[index] == id and reloaded.craftIds[index] == index)
    assert(reloaded.craftById[index].id == index)
  end
end)

test("metadata-only dimension enrichment never rebuilds filter indexes", function()
  local ledger = newLedger()
  local request = assert(ledger:SubmitCraft(12, 1, false))
  assert(ledger:RecordResult({ itemID = 100 }))
  local expansion = assert(ledger:AddDimension("expansion", "era", {}))
  local profession = assert(ledger:AddDimension("profession", 164))
  local session = ledger.dimensionRows.session[ledger.currentSessionId]
  local character = ledger.dimensionRows.character[session.characterDimensionId]
  local realm = ledger.dimensionRows.realm[session.realmDimensionId]
  local indexedRecipes = ledger.craftIdsByRecipe
  ledger.RebuildFilterIndexes = function() error("metadata enrichment rebuilt filter indexes") end
  local ok, reason = pcall(function()
    assert(ledger:AddDimension("recipe", 12, { name = "Recipe" }) == request.recipeId)
    assert(ledger:AddDimension("item", 100, { name = "Item", expansionDimensionId = expansion }))
    assert(ledger:AddDimension("expansion", "era", { displayName = "Era", chronologicalOrder = 1 }))
    assert(ledger:AddDimension("profession", 164, {
      name = "Profession", expansionDimensionId = expansion,
    }) == profession)
    assert(ledger:AddDimension("session", session.key, {
      locale = "enUS", capabilities = { measurements = { available = false } },
    }))
    assert(ledger:AddDimension("character", character.key, { metadata = { note = "Observed" } }))
    assert(ledger:AddDimension("realm", realm.key, { metadata = { note = "Observed" } }))
    assert(ledger.craftIdsByRecipe == indexedRecipes)
    assert(session.capabilities.measurements.available == false)
    assert(ledger.dimensionRows.recipe[request.recipeId].name == "Recipe")
  end)
  ledger.RebuildFilterIndexes = nil
  assert(ok, reason)
end)

test("pruning a backdated result does not discard its recent request", function()
  local ledger, clock = newLedger()
  local request = assert(ledger:SubmitCraft(12, 1, false))
  clock.current = clock.current - 181 * 86400
  local craft = assert(ledger:RecordResult({}))
  clock.current = request.timestamp
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(reloaded.craftById[craft.id] == nil and #reloaded.database.crafts == 0)
  assert(reloaded.requestById[request.id] == reloaded.database.requests[1])
end)

test("incremental indexes are complete before the committed callback", function()
  local ledger = newLedger()
  local request = assert(ledger:SubmitCraft(12, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 100 } },
  }))
  assert(ledger.requestById[request.id] == request)
  local callbackCompleted = false
  ledger.onCraftCommitted = function(self, craft)
    assert(self.craftById[craft.id] == craft and self.database.crafts[1] == craft)
    assert(self.requestById[craft.requestId] == request)
    assert(self.reagentsByCraftId[craft.id][1] == self.database.reagents[1])
    assert(self.reagentsByCraftId[craft.id][1].returnedQuantity == 0)
    assert(self.craftIds[1] == craft.id and self.craftIdsByTime[1] == craft.id)
    assert(self.craftIdsByRecipe[12][1] == craft.id)
    assert(self.operationIndex[craft.sessionId][10] == 1)
    local series = self.database.craftSeries[1]
    local characterId = self.dimensionRows.session[craft.sessionId].characterDimensionId
    assert(series.craftCount == 1 and series.recipeId == request.recipeId)
    assert(series.characterDimensionId == characterId)
    assert(self.seriesByKey[series.bucketStart][characterId][request.recipeId] == series)
    assert(series.ingenuityProcCount == 1 and series.ingenuityProcCountObservedCount == 1)
    assert(series.ingenuityRefund == 162 and series.ingenuityRefundObservedCount == 1)
    callbackCompleted = true
  end
  assert(primaryResult(ledger, { operationID = 10, resourcesReturned = {},
    hasIngenuityProc = true, ingenuityRefund = 162 }))
  assert(callbackCompleted)
end)

test("more than 50000 crafts survive capture and reload without historical scans", function()
  local ledger, clock = newLedger()
  local selections = { { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 100 } } }
  for index = 1, 50001 do
    local request = assert(ledger:SubmitCraft(12, 1, false, nil, selections))
    local craft = assert(fixtureResult(ledger, { operationID = index, resourcesReturned = {} }))
    assert(craft.requestId == request.id)
  end
  assert(#ledger.database.crafts == 50001 and #ledger.database.requests == 50001)
  assert(#ledger.database.reagents == 50001 and #ledger.craftIdsByRecipe[12] == 50001)
  assert(#ledger.database.craftSeries == 1 and ledger.database.craftSeries[1].craftCount == 50001)
  local oldIpairs, oldPairs, oldSort, oldInsert = ipairs, pairs, table.sort, table.insert
  local forbidden = {
    [ledger.database.crafts] = true, [ledger.database.requests] = true,
    [ledger.database.reagents] = true, [ledger.craftIds] = true, [ledger.craftIdsByTime] = true,
    [ledger.craftById] = true, [ledger.requestById] = true, [ledger.reagentsByCraftId] = true,
    [ledger.database.craftSeries] = true, [ledger.seriesByKey] = true,
    [ledger.database.reagentSeries] = true, [ledger.database.resourcefulnessSets] = true,
    [ledger.reagentIndex] = true, [ledger.returnSetIndex] = true,
  }
  local function noScan() error("capture scanned or rebuilt historical state") end
  ipairs = function(rows)
    if forbidden[rows] then noScan() end
    return oldIpairs(rows)
  end
  pairs = function(rows)
    if forbidden[rows] then noScan() end
    return oldPairs(rows)
  end
  table.sort, table.insert = noScan, noScan
  ledger.Prune, ledger.RebuildIndexes, ledger.RebuildFilterIndexes = noScan, noScan, noScan
  local indexedRecipes, indexedCrafts = ledger.craftIdsByRecipe, ledger.craftById
  local ok, reason = pcall(function()
    local request = assert(ledger:SubmitCraft(12, 1, false, nil, selections))
    local craft = assert(fixtureResult(ledger, { operationID = 50002, resourcesReturned = {},
      hasIngenuityProc = true, ingenuityRefund = 162 }))
    assert(craft.requestId == request.id)
    assert(ledger.requestById[request.id] == request and ledger.craftById[craft.id] == craft)
    assert(ledger.reagentsByCraftId[craft.id][1] == ledger.database.reagents[50002])
    request = assert(ledger:SubmitCraft(13, 1, false))
    craft = assert(fixtureResult(ledger, { operationID = 50003, itemID = 101,
      hasIngenuityProc = false, ingenuityRefund = 162 }))
    assert(craft.requestId == request.id and ledger.craftIdsByRecipe[13][1] == craft.id)
  end)
  ipairs, pairs, table.sort, table.insert = oldIpairs, oldPairs, oldSort, oldInsert
  ledger.Prune, ledger.RebuildIndexes, ledger.RebuildFilterIndexes = nil, nil, nil
  assert(ok, reason)
  assert(ledger.craftIdsByRecipe == indexedRecipes and ledger.craftById == indexedCrafts)
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(#reloaded.database.crafts == 50003 and #reloaded.database.requests == 50003)
  assert(#reloaded.craftIds == 50003 and #reloaded.craftIdsByTime == 50003)
  assert(#reloaded.craftIdsByRecipe[12] == 50002 and reloaded.craftIdsByRecipe[13][1] == 50003)
  assert(reloaded.craftById[50003] == reloaded.database.crafts[50003])
  assert(reloaded.requestById[50003] == reloaded.database.requests[50003])
  assert(reloaded.reagentsByCraftId[50002][1] == reloaded.database.reagents[50002])
  assert(#reloaded.database.craftSeries == 2 and reloaded.database.craftSeries[1].craftCount == 50002)
  assert(reloaded.database.craftSeries[2].craftCount == 1)
  assert(reloaded.database.craftSeries[1].ingenuityProcCount == 1)
  assert(reloaded.database.craftSeries[1].ingenuityRefund == 162)
  assert(reloaded.database.craftSeries[1].ingenuityRefundObservedCount == 1)
  assert(reloaded.database.craftSeries[2].ingenuityProcCount == 0)
  assert(reloaded.database.craftSeries[2].ingenuityRefund == 0)
  assert(reloaded.database.craftSeries[2].ingenuityRefundObservedCount == 1)
end)

test("daily series distinguish observed zero from unavailable metrics", function()
  local ledger = newLedger()
  assert(ledger:RecordResult({}))
  local series = ledger.database.craftSeries[1]
  assert(series.craftCount == 1 and series.recipeId == nil)
  for _, metric in ipairs({ "outputQuantity", "multicraftBonus", "concentrationSpent",
    "ingenuityProcCount", "ingenuityRefund" }) do
    assert(series[metric] == nil and series[metric .. "ObservedCount"] == 0)
  end
  assert(ledger:RecordResult({ quantity = 0, multicraft = 0, concentrationSpent = 0 }))
  assert(series.craftCount == 2)
  for _, metric in ipairs({ "outputQuantity", "multicraftBonus", "concentrationSpent" }) do
    assert(series[metric] == 0 and series[metric .. "ObservedCount"] == 1)
  end
  assert(ledger:RecordResult({ quantity = 5, concentrationSpent = 7, ingenuityRefund = 3,
    resourcesReturned = { { reagent = { itemID = 100 }, quantity = 2 } } }))
  assert(series.craftCount == 3 and series.outputQuantity == 5 and series.concentrationSpent == 7)
  assert(series.outputQuantityObservedCount == 2 and series.concentrationSpentObservedCount == 2)
  assert(series.multicraftBonusObservedCount == 1 and series.ingenuityRefund == nil)
  assert(series.resourcesReturned == nil and #ledger.database.craftSeries == 1)
end)

test("daily series grain uses UTC day character and optional recipe across sessions", function()
  local ledger, clock = newLedger()
  clock.current = 1800000000 - 1800000000 % 86400
  local metadata = { projectId = 1, regionId = 1, gameRealmId = 12,
    realmName = "Realm", characterGUID = "Player-Test" }
  ledger:CreateSession(metadata)
  local request = assert(ledger:SubmitCraft(12, 1, false))
  assert(fixtureResult(ledger, { quantity = 1 }))
  local first = ledger.database.craftSeries[1]
  ledger:CreateSession(metadata)
  assert(ledger:SubmitCraft(12, 1, false))
  clock.current = clock.current + 86399
  assert(fixtureResult(ledger, { quantity = 2 }))
  assert(#ledger.database.craftSeries == 1 and first.craftCount == 2 and first.outputQuantity == 3)
  clock.current = clock.current + 1
  assert(ledger:SubmitCraft(12, 1, false))
  assert(fixtureResult(ledger, {}))
  assert(#ledger.database.craftSeries == 2)
  assert(ledger.database.craftSeries[2].bucketStart == first.bucketStart + 86400)
  ledger:CreateSession({})
  assert(fixtureResult(ledger, {}))
  ledger:CreateSession({})
  assert(fixtureResult(ledger, {}))
  local unknown = ledger.database.craftSeries[3]
  assert(unknown.characterDimensionId == nil and unknown.recipeId == nil)
  assert(unknown.craftCount == 2 and ledger.seriesByKey[unknown.bucketStart][0][0] == unknown)
  assert(ledger:SubmitCraft(12, 1, false))
  assert(fixtureResult(ledger, {}))
  assert(ledger.database.craftSeries[4].characterDimensionId == nil)
  assert(ledger.database.craftSeries[4].recipeId == request.recipeId)
  metadata.characterGUID = "Player-Other"
  ledger:CreateSession(metadata)
  assert(ledger:SubmitCraft(12, 1, false))
  assert(fixtureResult(ledger, {}))
  assert(#ledger.database.craftSeries == 5)
  assert(ledger.database.craftSeries[5].characterDimensionId ~= first.characterDimensionId)
end)

test("Ogrim Ingenuity series count observed procs and only applied refunds", function()
  local cases = {
    { result = { concentrationSpent = 323, hasIngenuityProc = true, ingenuityRefund = 162 },
      proc = 1, procCoverage = 1, refund = 162, refundCoverage = 1 },
    { result = { concentrationSpent = 323, hasIngenuityProc = false, ingenuityRefund = 162 },
      proc = 0, procCoverage = 1, refund = 0, refundCoverage = 1 },
    { result = { hasIngenuityProc = false },
      proc = 0, procCoverage = 1, refund = 0, refundCoverage = 1 },
    { result = { hasIngenuityProc = true },
      proc = 1, procCoverage = 1, refundCoverage = 0 },
    { result = { ingenuityRefund = 162 }, procCoverage = 0, refundCoverage = 0 },
    { result = {}, procCoverage = 0, refundCoverage = 0 },
  }
  local combined, clock = newLedger()
  for _, case in ipairs(cases) do
    local ledger = newLedger()
    local craft = assert(ledger:RecordResult(case.result))
    local row = ledger.database.craftSeries[1]
    assert(row.ingenuityProcCount == case.proc and row.ingenuityProcCountObservedCount == case.procCoverage)
    assert(row.ingenuityRefund == case.refund and row.ingenuityRefundObservedCount == case.refundCoverage)
    assert(craft.ingenuityRefund == case.result.ingenuityRefund)
    assert(craft.concentrationSpent == case.result.concentrationSpent)
    assert(combined:RecordResult(case.result))
  end
  local row = combined.database.craftSeries[1]
  assert(row.craftCount == 6 and row.concentrationSpent == 646)
  assert(row.ingenuityProcCount == 2 and row.ingenuityProcCountObservedCount == 4)
  assert(row.ingenuityRefund == 162 and row.ingenuityRefundObservedCount == 3)
  local loaded = assert(Ledger.New(combined.database, clock)).database.craftSeries[1]
  assert(loaded.ingenuityRefund == 162 and loaded.ingenuityRefundObservedCount == 3)
end)

test("reload preserves a persisted unknown-character grain after session enrichment", function()
  local ledger, clock = newLedger()
  ledger:CreateSession({})
  ledger:BeginCraft(77)
  local craft = assert(ledger:RecordResult({
    operationID = 1, hasIngenuityProc = true, ingenuityRefund = 162,
  }))
  local row = ledger.database.craftSeries[#ledger.database.craftSeries]
  assert(row.characterDimensionId == nil and row.recipeId == craft.recipeId)

  local characterId = assert(ledger:AddDimension("character", "late-character", { name = "Late Character" }))
  local session = ledger.dimensionRows.session[craft.sessionId]
  assert(ledger:AddDimension("session", session.key, { characterDimensionId = characterId }) == session.id)
  assert(session.characterDimensionId == characterId)
  assert(row.characterDimensionId == nil)

  local reloaded = assert(Ledger.New(ledger.database, clock))
  local loadedRow = reloaded.database.craftSeries[#reloaded.database.craftSeries]
  assert(loadedRow.characterDimensionId == nil)
  assert(loadedRow.recipeId == craft.recipeId)
  assert(loadedRow.ingenuityProcCount == 1 and loadedRow.ingenuityProcCountObservedCount == 1)
  assert(loadedRow.ingenuityRefund == 162 and loadedRow.ingenuityRefundObservedCount == 1)
end)

test("reload with all detail pruned preserves all durable measures", function()
  local ledger, clock = newLedger()
  assert(ledger:RecordResult({ quantity = 2, hasIngenuityProc = false, ingenuityRefund = 162 }))
  clock.current = clock.current + 61 * 86400
  ledger:Prune(clock.current)
  assert(#ledger.database.crafts == 0)
  local reloaded = assert(Ledger.New(ledger.database, clock))
  local row = reloaded.database.craftSeries[1]
  assert(row.craftCount == 1 and row.outputQuantity == 2 and row.outputQuantityObservedCount == 1)
  assert(row.ingenuityProcCount == 0 and row.ingenuityProcCountObservedCount == 1)
  assert(row.ingenuityRefund == 0 and row.ingenuityRefundObservedCount == 1)
end)

test("startup preserves durable history before 60 day pruning exactly once", function()
  local ledger, clock = newLedger()
  local originalTime = clock.current
  for _, age in ipairs({ 200, 61, 60, 0 }) do
    clock.current = originalTime - age * 86400
    assert(ledger:RecordResult({ quantity = age, multicraft = 0,
      hasIngenuityProc = true, ingenuityRefund = 162 }))
  end
  clock.current = originalTime
  local loaded = assert(Ledger.New(ledger.database, clock))
  assert(loaded.database.schemaVersion == 2 and loaded.database.retentionDays == 60)
  assert(#loaded.database.crafts == 2 and #loaded.database.craftSeries == 4)
  assert(loaded.database.craftSeries[1].outputQuantity == 200)
  assert(loaded.database.craftSeries[2].outputQuantity == 61)
  assert(#ledger.database.crafts == 4)
  local reloaded = assert(Ledger.New(loaded.database, clock))
  assert(#reloaded.database.craftSeries == 4)
  for _, row in ipairs(reloaded.database.craftSeries) do
    assert(row.craftCount == 1 and row.outputQuantityObservedCount == 1)
    assert(row.multicraftBonus == 0 and row.multicraftBonusObservedCount == 1)
    assert(row.concentrationSpent == nil and row.concentrationSpentObservedCount == 0)
    assert(row.ingenuityProcCount == 1 and row.ingenuityProcCountObservedCount == 1)
    assert(row.ingenuityRefund == 162 and row.ingenuityRefundObservedCount == 1)
  end
  reloaded:CreateSession({})
  assert(reloaded:RecordResult({ quantity = 2 }))
  assert(#reloaded.database.craftSeries == 5)
end)

test("reload preserves nondefault retention and honors an explicit 180 day override", function()
  for _, retention in ipairs({ 1, 90, 365 }) do
    local ledger, clock = newLedger({ retentionDays = retention })
    assert(assert(Ledger.New(ledger.database, clock)).database.retentionDays == retention)
  end
  local ledger, clock = newLedger()
  local reloaded = assert(Ledger.New(ledger.database, clock, { retentionDays = 180 }))
  assert(reloaded.database.retentionDays == 180)
  assert(assert(Ledger.New(reloaded.database, clock)).database.retentionDays == 180)
end)

test("series keep dimensions and enrichable metadata after all detailed facts expire", function()
  local ledger, clock = newLedger()
  local request = assert(ledger:SubmitCraft(12, 1, false))
  assert(fixtureResult(ledger, { quantity = 2 }))
  local row = ledger.database.craftSeries[1]
  clock.current = clock.current + 61 * 86400
  assert(#ledger.database.crafts == 1)
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(#reloaded.database.crafts == 0 and #reloaded.database.requests == 0)
  local series = reloaded.database.craftSeries[1]
  assert(series.craftCount == 1 and series.outputQuantity == 2)
  assert(reloaded.dimensionRows.character[row.characterDimensionId])
  local profession = assert(reloaded:AddDimension("profession", 164))
  local expansion = assert(reloaded:AddDimension("expansion", "era", {}))
  assert(reloaded:AddDimension("recipe", 12, {
    professionId = profession, expansionDimensionId = expansion, name = "Enriched",
  }) == request.recipeId)
  assert(series.recipeId == request.recipeId)
  assert(series.professionId == nil and series.expansionDimensionId == nil)
  assert(reloaded.dimensionRows.recipe[series.recipeId].professionId == profession)
  reloaded:Prune(clock.current + 1000 * 86400)
  assert(reloaded.database.craftSeries[1] == series and series.outputQuantity == 2)
  assert(reloaded.seriesByKey[series.bucketStart][series.characterDimensionId][series.recipeId] == series)
  assert(#assert(Ledger.New(reloaded.database, clock)).database.craftSeries == 1)
end)

test("series validation rejects malformed grains references coverage and sums atomically", function()
  local mutations = {
    function(data) data.craftSeries = nil end,
    function(data) data.craftSeries[3] = data.craftSeries[1] end,
    function(data) data.craftSeries[2] = data.craftSeries[1] end,
    function(data) data.craftSeries[1].bucketStart = 1 end,
    function(data) data.craftSeries[1].bucketStart = math.huge end,
    function(data) data.craftSeries[1].characterDimensionId = 999 end,
    function(data) data.craftSeries[1].recipeId = 999 end,
    function(data) data.craftSeries[1].realmDimensionId = 1 end,
    function(data) data.craftSeries[1].craftCount = 0 end,
    function(data) data.craftSeries[1].craftCount = 1.5 end,
    function(data) data.craftSeries[1].outputQuantityObservedCount = nil end,
    function(data) data.craftSeries[1].outputQuantityObservedCount = -1 end,
    function(data) data.craftSeries[1].outputQuantityObservedCount = 0.5 end,
    function(data) data.craftSeries[1].outputQuantityObservedCount = 2 end,
    function(data) data.craftSeries[1].outputQuantityObservedCount = 0 end,
    function(data) data.craftSeries[1].outputQuantity = nil end,
    function(data) data.craftSeries[1].outputQuantity = "1" end,
    function(data) data.craftSeries[1].outputQuantity = math.huge end,
    function(data) data.craftSeries[1].outputQuantity = 0 / 0 end,
    function(data) data.craftSeries[1].multicraftBonus = 0 end,
  }
  for index, mutate in ipairs(mutations) do
    local ledger, clock = newLedger()
    assert(ledger:RecordResult({ quantity = 1 }))
    mutate(ledger.database)
    clock.current = clock.current + 61 * 86400
    assert(Ledger.New(ledger.database, clock) == nil, tostring(index))
    assert(#ledger.database.crafts == 1 and ledger.database.schemaVersion == 2)
  end
end)

test("series overflow cannot partially commit facts or increment aggregate coverage", function()
  local ledger, clock = newLedger()
  assert(ledger:RecordResult({ quantity = 1e308 }))
  local callbackCalled = false
  ledger.onCraftCommitted = function() callbackCalled = true end
  local rejected, reason = ledger:RecordResult({ quantity = 1e308 })
  assert(rejected == nil and reason:find("overflow", 1, true))
  assert(#ledger.database.crafts == 1 and ledger.database.nextCraftId == 2 and not callbackCalled)
  local row = ledger.database.craftSeries[1]
  assert(row.craftCount == 1 and row.outputQuantityObservedCount == 1 and row.outputQuantity == 1e308)
  assert(Ledger.New(ledger.database, clock))
end)

test("failed series accumulation preserves recipe correlation and adds no dimensions", function()
  local ledger = newLedger()
  ledger:BeginCraft(77)
  assert(fixtureResult(ledger, {
    operationID = 1, quantity = 1e308, itemID = 100,
    resourcesReturned = { { reagent = { itemID = 101 }, quantity = 1 } },
  }))
  local itemCount = rowCount(ledger.database.dimensions.items)
  local recipeCount = rowCount(ledger.database.dimensions.recipes)
  local row = ledger.database.craftSeries[1]
  assert(row.outputQuantity == 1e308 and row.craftCount == 1)

  ledger:BeginCraft(77)
  local rejected, reason = fixtureResult(ledger, {
    operationID = 2, quantity = 1e308, itemID = 200,
    resourcesReturned = { { reagent = { itemID = 201 }, quantity = 1 } },
  })
  assert(rejected == nil and reason:find("overflow", 1, true))
  assert(#ledger.database.crafts == 1 and ledger.database.nextCraftId == 2)
  assert(rowCount(ledger.database.dimensions.items) == itemCount)
  assert(rowCount(ledger.database.dimensions.recipes) == recipeCount)
  assert(ledger.dimensionRows.item[200] == nil and ledger.dimensionRows.item[201] == nil)
  assert(ledger.pendingRecipeId == 77 and ledger.ambiguousRecipe == nil)
  assert(row.outputQuantity == 1e308 and row.craftCount == 1)

  local recovered = assert(fixtureResult(ledger, { operationID = 3, quantity = 1 }))
  assert(recovered.recipeId == 77)
  assert(ledger.pendingRecipeId == nil and ledger.ambiguousRecipe == nil)
  assert(row.craftCount == 2 and row.outputQuantityObservedCount == 2)
end)

test("schema 1 validates Ingenuity coverage sums and cross-metric constraints atomically", function()
  local mutations = {
    function(row) row.ingenuityProcCount = -1 end,
    function(row) row.ingenuityProcCount = 0.5 end,
    function(row) row.ingenuityProcCount = 2 end,
    function(row) row.ingenuityProcCount = 0 end,
    function(row)
      row.ingenuityProcCount = 0
      row.ingenuityRefund = nil
      row.ingenuityRefundObservedCount = 0
    end,
    function(row)
      row.craftCount = 3
      row.ingenuityProcCountObservedCount = 3
      row.ingenuityProcCount = 1
      row.ingenuityRefundObservedCount = 1
    end,
    function(row)
      row.ingenuityRefundObservedCount = 2
      row.craftCount = 2
    end,
  }
  for _, metric in ipairs({ "ingenuityProcCount", "ingenuityRefund" }) do
    local field = metric
    for _, value in ipairs({ -1, 0, 0.5, 2, "1", false, math.huge, 0 / 0 }) do
      local invalid = value
      mutations[#mutations + 1] = function(row) row[field .. "ObservedCount"] = invalid end
    end
    for _, value in ipairs({ "1", false, math.huge, -math.huge, 0 / 0 }) do
      local invalid = value
      mutations[#mutations + 1] = function(row) row[field] = invalid end
    end
    mutations[#mutations + 1] = function(row) row[field] = nil end
    mutations[#mutations + 1] = function(row) row[field .. "ObservedCount"] = nil end
  end
  for index, mutate in ipairs(mutations) do
    local ledger, clock = newLedger()
    assert(ledger:RecordResult({ hasIngenuityProc = true, ingenuityRefund = 162 }))
    local data = ledger.database
    mutate(data.craftSeries[1])
    clock.current = clock.current + 61 * 86400
    local refused, reason = Ledger.New(data, clock)
    assert(refused == nil and type(reason) == "string", tostring(index))
    assert(data.schemaVersion == 2 and #data.crafts == 1 and data.nextCraftId == 2)
  end
  for _, metric in ipairs({ "ingenuityProcCount", "ingenuityRefund" }) do
    local ledger, clock = newLedger()
    assert(ledger:RecordResult({}))
    ledger.database.craftSeries[1][metric] = 0
    assert(Ledger.New(ledger.database, clock) == nil)
  end
end)

test("Ingenuity refund overflow leaves facts coverage indexes request and callback uncommitted", function()
  local ledger, clock = newLedger()
  assert(ledger:SubmitCraft(12, 2, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 100 } },
  }))
  assert(fixtureResult(ledger, { operationID = 1, quantity = 1, concentrationSpent = 323,
    hasIngenuityProc = true, ingenuityRefund = 1e308, resourcesReturned = {} }))
  local called = false
  ledger.onCraftCommitted = function() called = true end
  local rejected, reason = fixtureResult(ledger, { operationID = 2, quantity = 1, concentrationSpent = 323,
    hasIngenuityProc = true, ingenuityRefund = 1e308, resourcesReturned = {} })
  assert(rejected == nil and reason:find("overflow", 1, true))
  assert(not called and #ledger.database.crafts == 1 and ledger.database.nextCraftId == 2)
  assert(#ledger.database.reagents == 1 and #ledger.craftIds == 1 and ledger.craftById[2] == nil)
  assert(#ledger.craftIdsByRecipe[12] == 1 and ledger.operationIndex[ledger.currentSessionId][2] == nil)
  assert(ledger.pendingRequest.remaining == 1)
  local row = ledger.database.craftSeries[1]
  assert(row.craftCount == 1 and row.outputQuantity == 1 and row.outputQuantityObservedCount == 1)
  assert(row.concentrationSpent == 323 and row.concentrationSpentObservedCount == 1)
  assert(row.ingenuityProcCount == 1 and row.ingenuityProcCountObservedCount == 1)
  assert(row.ingenuityRefund == 1e308 and row.ingenuityRefundObservedCount == 1)
  assert(Ledger.New(ledger.database, clock))
  assert(fixtureResult(ledger, { operationID = 2, hasIngenuityProc = false, ingenuityRefund = 1e308 }))
  assert(row.craftCount == 2 and row.ingenuityRefund == 1e308 and row.ingenuityRefundObservedCount == 2)
end)

test("persisted craft and request measurements reject malformed values before pruning", function()
  local collections = {
    crafts = { "timestamp", "gameOperationId", "outputQuality", "outputItemLevel", "outputQuantity",
      "multicraftBonus", "concentrationSpent", "concentrationCurrencyId", "ingenuityRefund" },
    requests = { "timestamp", "concentrationCost", "baseSkill", "baseDifficulty", "craftingQuality" },
  }
  for collection, fields in pairs(collections) do
    for _, field in ipairs(fields) do
      for _, value in ipairs({ "0", false, true, {}, math.huge, -math.huge, 0 / 0 }) do
        local ledger, clock = newLedger()
        assert(ledger:SubmitCraft(12, 1, false))
        assert(ledger:RecordResult({ quantity = 1 }))
        local data = ledger.database
        local series = data.craftSeries
        data[collection][1][field] = value
        clock.current = clock.current + 61 * 86400
        local refused, reason = Ledger.New(data, clock)
        assert(refused == nil and type(reason) == "string", collection .. "." .. field)
        assert(data.schemaVersion == 2 and data.craftSeries == series)
        assert(#data.crafts == 1 and #data.requests == 1 and data.nextCraftId == 2)
        local original = data[collection][1][field]
        assert(original == value or (original ~= original and value ~= value))
      end
    end
  end
end)

test("persisted craft and request booleans reject non-booleans without coercion", function()
  for _, target in ipairs({ { "crafts", "hasIngenuityProc" }, { "requests", "useConcentration" } }) do
    for _, value in ipairs({ 0, 1, "false", "true", {}, math.huge, 0 / 0 }) do
      local ledger, clock = newLedger()
      assert(ledger:SubmitCraft(12, 1, false))
      assert(ledger:RecordResult({}))
      local data = ledger.database
      local series = data.craftSeries
      data[target[1]][1][target[2]] = value
      assert(Ledger.New(data, clock) == nil, target[2])
      assert(data.schemaVersion == 2 and data.craftSeries == series and #data.crafts == 1)
    end
  end
end)

test("persisted finite measurements and optional booleans preserve existing value semantics", function()
  for _, value in ipairs({ 0, -1.5, 2.5 }) do
    for _, flag in ipairs({ false, true, "absent" }) do
      local ledger, clock = newLedger()
      assert(ledger:SubmitCraft(12, 1, false, {
        concentrationCost = value, baseSkill = value, baseDifficulty = value, craftingQuality = value,
      }))
      local result = { operationID = value, craftingQuality = value, itemLevel = value, quantity = value,
        multicraft = value, concentrationSpent = value, concentrationCurrencyID = value, ingenuityRefund = value }
      if flag ~= "absent" then result.hasIngenuityProc = flag end
      assert(ledger:RecordResult(result))
      local loaded = assert(Ledger.New(ledger.database, clock))
      for _, field in ipairs({ "gameOperationId", "outputQuality", "outputItemLevel", "outputQuantity",
        "multicraftBonus", "concentrationSpent", "concentrationCurrencyId", "ingenuityRefund" }) do
        assert(loaded.database.crafts[1][field] == value)
      end
      for _, field in ipairs({ "concentrationCost", "baseSkill", "baseDifficulty", "craftingQuality" }) do
        assert(loaded.database.requests[1][field] == value)
      end
      assert(loaded.database.crafts[1].hasIngenuityProc == result.hasIngenuityProc)
      assert(loaded.database.requests[1].useConcentration == false)
      local row = loaded.database.craftSeries[1]
      if flag == true then
        assert(row.ingenuityProcCount == 1 and row.ingenuityRefund == value)
        assert(row.ingenuityProcCountObservedCount == 1 and row.ingenuityRefundObservedCount == 1)
      elseif flag == false then
        assert(row.ingenuityProcCount == 0 and row.ingenuityRefund == 0)
        assert(row.ingenuityProcCountObservedCount == 1 and row.ingenuityRefundObservedCount == 1)
      else
        assert(row.ingenuityProcCount == nil and row.ingenuityRefund == nil)
        assert(row.ingenuityProcCountObservedCount == 0 and row.ingenuityRefundObservedCount == 0)
      end
    end
  end
  local ledger, clock = newLedger()
  assert(ledger:SubmitCraft(12, 1, true))
  assert(ledger:RecordResult({}))
  local loaded = assert(Ledger.New(ledger.database, clock))
  assert(loaded.database.requests[1].useConcentration == true)
  assert(loaded.database.requests[1].concentrationCost == nil)
  assert(loaded.database.crafts[1].outputQuantity == nil)
end)

test("craft and request IDs stop at the last safely advanceable counter without side effects", function()
  local ledger, clock = newLedger()
  ledger.database.nextCraftId = maxInteger - 2
  ledger.database.nextRequestId = maxInteger - 2
  local first = assert(ledger:SubmitCraft(12, 1, false))
  assert(first.id == maxInteger - 2)
  assert(assert(fixtureResult(ledger, {})).id == maxInteger - 2)
  local second = assert(ledger:SubmitCraft(13, maxInteger, false))
  assert(second.id == maxInteger - 1 and second.requestedCount == maxInteger)
  assert(assert(fixtureResult(ledger, {})).id == maxInteger - 1)
  assert(ledger.pendingRequest.remaining == maxInteger - 1)
  assert(ledger.database.nextCraftId == maxInteger and ledger.database.nextRequestId == maxInteger)
  ledger:BeginCraft(14)
  unchangedAfter(ledger, function()
    return fixtureResult(ledger, { operationID = 1, itemID = 100, quantity = 1 })
  end)
  unchangedAfter(ledger, function()
    return ledger:SubmitCraft(14, 1, false, nil, {
      { dataSlotIndex = 1, quantity = 1, reagent = { itemID = 101 } },
    })
  end)
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(reloaded.database.nextCraftId == maxInteger and reloaded.database.nextRequestId == maxInteger)
  assert(reloaded.craftById[maxInteger - 1] and reloaded.requestById[maxInteger - 1])
end)

test("Core-owned dimension counters allow their final ID and existing keys still work", function()
  for _, kind in ipairs({ "realm", "character", "session", "expansion" }) do
    local ledger, clock = newLedger()
    ledger.database.nextDimensionId[kind] = maxInteger - 1
    local id = assert(ledger:AddDimension(kind, "last", { name = "Last" }))
    assert(id == maxInteger - 1 and ledger.database.nextDimensionId[kind] == maxInteger)
    assert(ledger:AddDimension(kind, "last", { name = "Last" }) == id)
    assert(ledger:AddDimension(kind, "last", { extra = "Enriched" }) == id)
    unchangedAfter(ledger, function() return ledger:AddDimension(kind, "new") end)
    unchangedAfter(ledger, function() return ledger:AddDimension(kind, "last", { name = "Conflict" }) end)
    assert(Ledger.New(ledger.database, clock))
  end
end)

test("session creation stages all dimensions and preserves correlation on every failure", function()
  for _, kind in ipairs({ "realm", "character", "session" }) do
    local ledger = newLedger()
    assert(ledger:SubmitCraft(12, 2, false))
    ledger:BeginCraft(13)
    ledger.database.nextDimensionId[kind] = maxInteger
    unchangedAfter(ledger, function()
      return ledger:CreateSession({ realmName = "New Realm", characterName = "New Character" })
    end)
  end
  local ledger, clock = newLedger()
  ledger.database.nextDimensionId.session = maxInteger - 2
  local first = assert(ledger:CreateSession({ realmName = "Realm", characterName = "Crafter" }))
  local second = assert(ledger:CreateSession({ realmName = "Realm", characterName = "Crafter" }))
  assert(first == maxInteger - 2 and second == maxInteger - 1)
  assert(ledger.dimensionRows.session[first].key ~= ledger.dimensionRows.session[second].key)
  unchangedAfter(ledger, function() return ledger:CreateSession({}) end)
  assert(Ledger.New(ledger.database, clock))

  ledger = newLedger()
  local metadata = { projectId = 1, regionId = 1, gameRealmId = 1,
    realmName = "Realm", characterGUID = "Player", characterName = "Name" }
  assert(ledger:CreateSession(metadata))
  metadata.realmName = nil
  metadata.characterName = "Conflict"
  unchangedAfter(ledger, function() return ledger:CreateSession(metadata) end)
  unchangedAfter(ledger, function()
    return ledger:CreateSession({ realmName = "New Realm", characterName = "New Character",
      capabilities = { bad = function() end } })
  end)
  ledger.database.nextDimensionId.realm = maxInteger
  ledger.database.nextDimensionId.character = maxInteger
  metadata.realmName, metadata.characterName = "Realm", "Name"
  assert(ledger:CreateSession(metadata))
end)

test("result and request record distinct WoW item IDs without allocating surrogates", function()
  for _, capture in ipairs({ "result", "request" }) do
    local ledger, clock = newLedger()
    assert(ledger:SubmitCraft(12, 2, false))
    ledger:BeginCraft(13)
    local function attempt(twoItems)
      if capture == "result" then
        return ledger:RecordResult({ operationID = 1, itemID = 100, resourcesReturned = {
          { reagent = { itemID = twoItems and 101 or 100 }, quantity = 1 },
        } })
      end
      return ledger:SubmitCraft(14, 1, false, nil, {
        { dataSlotIndex = 1, quantity = 1, reagent = { itemID = 100 } },
        { dataSlotIndex = 2, quantity = 1, reagent = { itemID = twoItems and 101 or 100 } },
      })
    end
    assert(attempt(true))
    assert(ledger.dimensionRows.item[100] and ledger.dimensionRows.item[101])
    assert(attempt(false))
    assert(ledger.database.nextDimensionId.item == nil)
    assert(rowCount(ledger.database.dimensions.items) == 2)
    assert(attempt(false))
    assert(Ledger.New(ledger.database, clock))
  end
end)

test("failed captures do not create natural metadata or consume pending correlation", function()
  local ledger = newLedger()
  ledger:BeginCraft(12)
  unchangedAfter(ledger, function() return ledger:RecordResult(false) end)
  unchangedAfter(ledger, function() return ledger:RecordResult({ itemID = 100, quantity = math.huge }) end)
  assert(ledger.dimensionRows.recipe[12] == nil and ledger.dimensionRows.item[100] == nil)
  assert(ledger.pendingRecipeId == 12)
  unchangedAfter(ledger, function() return ledger:SubmitCraft(13, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 1, reagent = { itemID = 101 }, invalid = function() end },
  }) end)
  assert(ledger.dimensionRows.recipe[13] == nil and ledger.dimensionRows.item[101] == nil)
  ledger.wall = function() return nil end
  unchangedAfter(ledger, function() return ledger:RecordResult({}) end)
end)

test("recipe identity is the WoW ID without a surrogate counter", function()
  local ledger, clock = newLedger()
  ledger:BeginCraft(12)
  local first = assert(fixtureResult(ledger, { operationID = 1 }))
  assert(first.recipeId == 12 and ledger.database.nextDimensionId.recipe == nil)
  ledger:BeginCraft(13)
  local second = assert(fixtureResult(ledger, { operationID = 2, itemID = 100 }))
  assert(second.recipeId == 13 and second.outputItemId == 100)
  assert(ledger:SubmitCraft(13, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 1, reagent = { itemID = 100 } },
  }))
  ledger:CancelCraft()
  ledger:BeginCraft(12)
  assert(assert(fixtureResult(ledger, { operationID = 3 })).recipeId == nil)
  assert(ledger:SubmitCraft(12, 1, false))
  assert(rowCount(ledger.database.dimensions.recipes) == 2 and rowCount(ledger.database.dimensions.items) == 2)
  assert(Ledger.New(ledger.database, clock))
end)

test("aggregate counts can reach the exact integer maximum but cannot advance past it", function()
  for _, proc in ipairs({ false, true }) do
    local ledger, clock = newLedger()
    assert(ledger:SubmitCraft(12, 3, false))
    assert(ledger:RecordResult({ quantity = 0, multicraft = 0, concentrationSpent = 0,
      hasIngenuityProc = proc, ingenuityRefund = 0 }))
    local row = ledger.database.craftSeries[1]
    row.craftCount = maxInteger - 1
    row.ingenuityProcCount = proc and maxInteger - 1 or 0
    for _, metric in ipairs({ "outputQuantity", "multicraftBonus", "concentrationSpent",
      "ingenuityProcCount", "ingenuityRefund" }) do
      row[metric .. "ObservedCount"] = maxInteger - 1
    end
    assert(Ledger.New(ledger.database, clock))
    assert(ledger:RecordResult({ quantity = 0, multicraft = 0, concentrationSpent = 0,
      hasIngenuityProc = proc, ingenuityRefund = 0 }))
    assert(row.craftCount == maxInteger and row.outputQuantityObservedCount == maxInteger)
    assert(row.ingenuityProcCount == (proc and maxInteger or 0))
    assert(row.ingenuityProcCountObservedCount == maxInteger and row.ingenuityRefundObservedCount == maxInteger)
    ledger:BeginCraft(12)
    unchangedAfter(ledger, function()
      return ledger:RecordResult({ itemID = 100, hasIngenuityProc = proc, ingenuityRefund = 0 })
    end)
    assert(Ledger.New(ledger.database, clock))
  end
end)

test("persisted counts counters and reference IDs reject unsafe integers before pruning", function()
  local setters = {
    function(data, value) data.nextCraftId = value end,
    function(data, value) data.nextRequestId = value end,
    function(data, value) data.nextDimensionId.session = value end,
    function(data, value) data.crafts[1].id = value end,
    function(data, value) data.crafts[1].sessionId = value end,
    function(data, value) data.crafts[1].requestId = value end,
    function(data, value) data.requests[1].id = value end,
    function(data, value) data.requests[1].requestedCount = value end,
    function(data, value) data.requests[1].allocations[1].dataSlotIndex = value end,
    function(data, value) data.requests[1].allocations[1].allocatedQuantity = value end,
    function(data, value) data.reagents[1].allocatedQuantity = value end,
    function(data, value) data.reagents[1].dataSlotIndex = value end,
    function(data, value) data.dimensions.items[100].id = value end,
    function(data, value) data.craftSeries[1].craftCount = value end,
    function(data, value) data.craftSeries[1].outputQuantityObservedCount = value end,
    function(data, value) data.craftSeries[1].ingenuityProcCount = value end,
    function(data, value) data.craftSeries[1].ingenuityProcCountObservedCount = value end,
    function(data, value) data.craftSeries[1].ingenuityRefundObservedCount = value end,
  }
  for _, value in ipairs({ maxInteger + 1, maxInteger + 3, -1, 0.5 }) do
    for _, mutate in ipairs(setters) do
      local ledger, clock = newLedger()
      assert(ledger:SubmitCraft(12, 1, false, nil, {
        { dataSlotIndex = 1, quantity = 1, reagent = { itemID = 100 } },
      }))
      assert(fixtureResult(ledger, { quantity = 1, hasIngenuityProc = true, ingenuityRefund = 0 }))
      mutate(ledger.database, value)
      clock.current = clock.current + 61 * 86400
      unchangedAfter(ledger.database, function() return Ledger.New(ledger.database, clock) end)
    end
    local ledger = newLedger()
    unchangedAfter(ledger, function() return ledger:SubmitCraft(12, value, false) end)
  end
end)

test("native game IDs and finite signed fractional measurements are not safe-counter constrained", function()
  local ledger, clock = newLedger()
  local nativeId = maxInteger + 1
  local request = assert(ledger:SubmitCraft(nativeId, maxInteger, false, { concentrationCost = -0.5 }, {
    { dataSlotIndex = maxInteger, quantity = maxInteger, quality = nativeId, reagent = { itemID = nativeId } },
  }))
  local craft = assert(ledger:RecordResult({ operationID = nativeId, itemID = nativeId,
    quantity = -0.5, multicraft = 0.25, concentrationSpent = nativeId,
    hasIngenuityProc = true, ingenuityRefund = -0.75,
    resourcesReturned = { { reagent = { itemID = nativeId }, quantity = -0.25 } },
  }))
  assert(request.allocations[1].allocatedQuantity == maxInteger)
  assert(craft.gameOperationId == nativeId and craft.outputQuantity == -0.5)
  -- A negative or unsafe-ID return entry proves nothing; the outcome stays partial and unknown.
  assert(#ledger.database.reagents == 0 and craft.outcomeSource == "unverified")
  assert(craft.hasResourcefulnessProc == nil and craft.quoteObserved == nil)
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(reloaded.database.craftSeries[1].ingenuityRefund == -0.75)
end)

test("adjacent near-limit numeric dimension identities remain distinct across capture and reload", function()
  local ledger, clock = newLedger()
  local lower, upper = maxInteger - 1, maxInteger
  local request = assert(ledger:SubmitCraft(lower, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 1, reagent = { itemID = lower } },
    { dataSlotIndex = 2, quantity = 1, reagent = { itemID = upper } },
  }))
  local craft = assert(fixtureResult(ledger, { itemID = upper, operationID = upper }))
  assert(request.allocations[1].itemId ~= request.allocations[2].itemId)
  assert(craft.outputItemId == request.allocations[2].itemId)
  ledger:BeginCraft(upper)
  local nextCraft = assert(fixtureResult(ledger, { itemID = lower, operationID = lower }))
  assert(nextCraft.recipeId ~= request.recipeId)
  assert(nextCraft.outputItemId == request.allocations[1].itemId)
  for _, kind in ipairs({ "recipe", "item" }) do
    assert(ledger.dimensionRows[kind][lower] and ledger.dimensionRows[kind][upper])
    assert(ledger.dimensionRows[kind][lower] ~= ledger.dimensionRows[kind][upper])
  end
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(reloaded.operationIndex[craft.sessionId][upper] == 1)
  assert(reloaded.operationIndex[craft.sessionId][lower] == 1)
  assert(reloaded:AddDimension("recipe", upper) == nextCraft.recipeId)
  assert(reloaded:AddDimension("item", lower) == nextCraft.outputItemId)
end)

test("reagent return sum overflow does not commit staged dimensions or request changes", function()
  local ledger = newLedger()
  assert(ledger:SubmitCraft(12, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 1, reagent = { itemID = 100 } },
  }))
  unchangedAfter(ledger, function()
    return ledger:RecordResult({ itemID = 101, resourcesReturned = {
      { reagent = { itemID = 100 }, quantity = 1e308 },
      { reagent = { itemID = 100 }, quantity = 1e308 },
    } })
  end)
end)

local function deepCopy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, child in pairs(value) do copy[key] = deepCopy(child) end
  return copy
end

local function deepEqual(left, right, path)
  path = path or "root"
  if type(left) ~= "table" or type(right) ~= "table" then
    assert(left == right, path .. ": " .. tostring(left) .. " ~= " .. tostring(right))
    return
  end
  for key, value in pairs(left) do deepEqual(value, right[key], path .. "." .. tostring(key)) end
  for key in pairs(right) do assert(left[key] ~= nil, path .. "." .. tostring(key) .. " is unexpected") end
end

local legacyVariants = { "pre21", "outcome1", "outcome2" }
local function legacyFixture(name)
  local clock = { current = 1796004060 }
  function clock.wall() return clock.current end
  return dofile(testsRoot .. "/fixtures/legacy/v1-" .. name .. ".lua"), clock
end

test("issue 24: 100 primary results with 20 positive and 80 nil or empty lists are authoritative", function()
  for _, explicitEmpty in ipairs({ false, true }) do
    local ledger = newLedger()
    for index = 1, 100 do
      assert(ledger:SubmitCraft(12, 1, false, nil, { { dataSlotIndex = 1, quantity = 4, reagent = { itemID = 8 } } },
        inputEvidence({ 8 })))
      local returned = index <= 20 and { { reagent = { itemID = 8 }, quantity = 1 } } or
        (explicitEmpty and {} or nil)
      assert(primaryResult(ledger, { operationID = index, resourcesReturned = returned }))
    end
    local row = ledger.database.craftSeries[1]
    assert(row.craftCount == 100 and row.resourcefulnessProcCount == 20 and row.resourcefulnessProcCountObservedCount == 100)
    assert(row.resourcefulnessAuthoritativeProcCount == 20 and row.resourcefulnessAuthoritativeProcCountObservedCount == 100)
    assert(row.resourcefulnessCompleteProcCountObservedCount == 100)
    assert(row.quoteObservedCount == 100 and row.inputCompleteCount == 100 and row.matchedCraftCount == 100)
    local item = reagentRow(ledger.database, 8)
    assert(item.allocatedQuantity == 400 and item.allocationCount == 100 and item.returnedQuantity == 20)
    assert(item.matchedCraftCount == 100 and item.matchedAllocatedQuantity == 400)
    assert(item.matchedReturnedQuantity == 20 and item.matchedReturnCount == 20)
    assert(ledger.database.resourcefulnessSets[1].authoritativeCraftCount == 20)
    for index = 21, 100 do
      local craft = ledger.database.crafts[index]
      assert(craft.outcomeSource == "native" and craft.hasResourcefulnessProc == false)
      assert(ledger.reagentsByCraftId[craft.id][1].returnedQuantity == 0)
    end
  end
end)

test("issue 24: legacy positive-only history never becomes the authoritative cohort", function()
  local legacy, clock = newLegacyLedger()
  for index = 1, 100 do
    assert(legacy:SubmitCraft(12, 1, false))
    assert(legacy:RecordResult({ operationID = index,
      resourcesReturned = index <= 20 and { { reagent = { itemID = 8 }, quantity = 1 } } or nil }))
  end
  for _, variant in ipairs({ "outcome2", "pre21" }) do
    local source = variant == "pre21" and legacyDatabase({ database = deepCopy(legacy.database) }) or
      deepCopy(legacy.database)
    local original = deepCopy(source)
    local migrated = assert(Ledger.New(source, clock))
    deepEqual(source, original)
    local row = migrated.database.craftSeries[1]
    -- Neither 20/100 nor 20/20 is offered as an authoritative rate.
    assert(row.resourcefulnessProcCount == 20 and row.resourcefulnessProcCountObservedCount == 20)
    assert(row.resourcefulnessCompleteProcCountObservedCount == (variant == "outcome2" and 20 or 0))
    assert(row.resourcefulnessAuthoritativeProcCount == nil and row.resourcefulnessAuthoritativeProcCountObservedCount == 0)
    assert(migrated:CreateSession({ characterName = "Sanitized Crafter", characterGUID = "Player-Sanitized",
      realmName = "Sanitized Realm" }))
    for index = 1, 10 do
      assert(migrated:SubmitCraft(12, 1, false))
      assert(primaryResult(migrated, { operationID = 1000 + index,
        resourcesReturned = index <= 3 and { { reagent = { itemID = 8 }, quantity = 1 } } or nil }))
    end
    local totals = {}
    for _, series in ipairs(migrated.database.craftSeries) do
      for key, value in pairs(series) do
        if type(value) == "number" and key ~= "bucketStart" and key ~= "recipeId" and key ~= "characterDimensionId" then
          totals[key] = (totals[key] or 0) + value
        end
      end
    end
    row = totals
    assert(row.craftCount == 110 and row.resourcefulnessAuthoritativeProcCount == 3)
    assert(row.resourcefulnessAuthoritativeProcCountObservedCount == 10)
    assert(row.resourcefulnessProcCount == 23 and row.resourcefulnessProcCountObservedCount == 30)
    local sets = { craftCount = 0, authoritativeCraftCount = 0 }
    for _, set in ipairs(migrated.database.resourcefulnessSets) do
      sets.craftCount = sets.craftCount + set.craftCount
      sets.authoritativeCraftCount = sets.authoritativeCraftCount + (set.authoritativeCraftCount or 0)
    end
    assert(sets.craftCount == (variant == "outcome2" and 23 or 3) and sets.authoritativeCraftCount == 3)
  end
end)

test("issue 24: duplicate slots consolidate per craft and item for positive and negative outcomes", function()
  local ledger = newLedger()
  local slots = { { dataSlotIndex = 1, quantity = 5, reagent = { itemID = 8 } },
    { dataSlotIndex = 2, quantity = 7, reagent = { itemID = 8 } } }
  assert(ledger:SubmitCraft(12, 2, false, nil, slots, inputEvidence({ 8 })))
  local positive = assert(primaryResult(ledger, { operationID = 1,
    resourcesReturned = { { reagent = { itemID = 8 }, quantity = 2 } } }))
  local negative = assert(primaryResult(ledger, { operationID = 2 }))
  local rows = ledger.reagentsByCraftId[positive.id]
  assert(#rows == 3 and rows[1].returnedQuantity == nil and rows[2].returnedQuantity == nil)
  assert(rows[3].allocatedQuantity == nil and rows[3].returnedQuantity == 2)
  rows = ledger.reagentsByCraftId[negative.id]
  assert(#rows == 2 and rows[1].returnedQuantity == 0 and rows[2].returnedQuantity == 0)
  assert(positive.quoteObserved and negative.quoteObserved)
  local item = reagentRow(ledger.database, 8)
  assert(item.allocatedQuantity == 24 and item.allocationCount == 2 and item.returnedQuantity == 2)
  assert(item.matchedCraftCount == 2 and item.matchedAllocatedQuantity == 24)
  assert(item.matchedReturnedQuantity == 2 and item.matchedReturnCount == 1)
end)

test("issue 24: first-craft rewards are children that never inflate attempts or batch counts", function()
  local ledger, clock = newLedger()
  assert(ledger:SubmitCraft(12, 2, false, nil, { { dataSlotIndex = 1, quantity = 3, reagent = { itemID = 8 } } }))
  ledger:BeginCraft(12)
  local first = assert(primaryResult(ledger, { operationID = 10, itemID = 500 }))
  local reward, kind = ledger:RecordResult({ operationID = 10, itemID = 600, quantity = 1, firstCraftReward = true })
  assert(kind == "first-craft-reward" and reward.recipeId == 12 and reward.parentCraftId == first.id)
  assert(ledger.pendingRequest and ledger.pendingRequest.remaining == 1 and #ledger.database.crafts == 1)
  local second = assert(primaryResult(ledger, { operationID = 11, itemID = 500,
    resourcesReturned = { { reagent = { itemID = 8 }, quantity = 1 } } }))
  assert(second.requestId == first.requestId and ledger.pendingRequest == nil)
  local row = ledger.database.craftSeries[1]
  assert(row.craftCount == 2 and row.resourcefulnessAuthoritativeProcCountObservedCount == 2)
  assert(row.resourcefulnessAuthoritativeProcCount == 1 and row.quoteObservedCount == 2)
  local rewards = ledger.database.firstCraftRewards
  assert(#rewards == 1 and rewards[1].recipeId == 12 and rewards[1].itemId == 600)
  assert(rewards[1].rewardCount == 1 and rewards[1].quantity == 1 and rewards[1].quantityObservedCount == 1)
  -- A reward whose parent is unknown keeps pending recipe correlation intact.
  assert(ledger:SubmitCraft(13, 1, false))
  ledger:BeginCraft(13)
  reward = assert(ledger:RecordResult({ operationID = 99, itemID = 600, firstCraftReward = true }))
  assert(reward.recipeId == nil and ledger.pendingRecipeId == 13)
  assert(assert(primaryResult(ledger, { operationID = 20, itemID = 501 })).recipeId == 13)
  assert(#ledger.database.firstCraftRewards == 2 and ledger.database.firstCraftRewards[2].quantityObservedCount == 0)
  unchangedAfter(ledger.database, function()
    return ledger:RecordResult({ operationID = 20, firstCraftReward = true })
  end)
  local reloaded = assert(Ledger.New(ledger.database, clock))
  deepEqual(reloaded.database.firstCraftRewards, ledger.database.firstCraftRewards)
  local broken = deepCopy(ledger.database)
  broken.firstCraftRewards[1].quantityObservedCount = 2
  unchangedAfter(broken, function() return Ledger.New(broken, clock) end)
  assert(reloaded:ClearHistory() and #reloaded.database.firstCraftRewards == 0)
end)

test("issue 24: special operations have explicit attempt and outcome semantics", function()
  local ledger = newLedger()
  -- Enchanting: one primary callback per enchant; no request inputs.
  ledger:InvalidateCraft("CraftEnchant")
  ledger:BeginCraft(1236083)
  local enchant = assert(primaryResult(ledger, { operationID = 1, itemID = 244005, isEnchant = true }))
  assert(enchant.outcomeSource == "native" and enchant.hasResourcefulnessProc == false)
  assert(enchant.requestId == nil and enchant.quoteObserved == nil and enchant.inputComplete == nil)
  -- Prospecting/crushing: several item callbacks per salvage call share one operation ID,
  -- so no callback is treated as an independent attempt with an authoritative outcome.
  ledger:InvalidateCraft("CraftSalvage")
  ledger:BeginCraft(434018)
  local gems = {
    assert(ledger:RecordResult({ operationID = 2, itemID = 700, quantity = 2 })),
    assert(ledger:RecordResult({ operationID = 2, itemID = 701, quantity = 1,
      resourcesReturned = { { reagent = { itemID = 900 }, quantity = 1 } } })),
    assert(ledger:RecordResult({ operationID = 2, itemID = 702, quantity = 1, resourcesReturned = {} })),
  }
  for index, craft in ipairs(gems) do
    assert(craft.outcomeSource == "unverified" and craft.resourcefulnessComplete == nil)
    assert(craft.hasResourcefulnessProc == (index == 2 and true or nil))
  end
  assert(gems[1].recipeId == nil and gems[2].recipeId == nil and gems[3].recipeId == nil)
  -- Recrafts and order crafts are primary attempts without personal input snapshots.
  ledger:InvalidateCraft("RecraftRecipe")
  local recraft = assert(primaryResult(ledger, { operationID = 3, itemID = 703 }))
  assert(recraft.outcomeSource == "unverified" and recraft.quoteObserved == nil)
  ledger:CancelCraft()
  assert(ledger:CreateSession({}))
  assert(ledger:CreateSession({}))
  assert(ledger:CreateSession({}))
  assert(ledger:CreateSession({}))
  assert(ledger:CreateSession({}))
  assert(ledger:SubmitCraft(12, 1, false))
  assert(assert(primaryResult(ledger, { operationID = 4 })).outcomeSource == "native")
  local salvage
  for _, row in ipairs(ledger.database.craftSeries) do
    if row.recipeId == nil then salvage = row end
  end
  assert(salvage.craftCount == 4 and salvage.resourcefulnessAuthoritativeProcCountObservedCount == 0)
  assert(salvage.resourcefulnessProcCountObservedCount == 1)
  assert(reagentRow(ledger.database, 900).returnedQuantity == 1)
end)

test("issue 24: context-free build-69933 replay cannot certify primary outcomes", function()
  local ledger = newLedger()
  replay(ledger, fixture.cases)
  local observed, procs = 0, 0
  for _, row in ipairs(ledger.database.craftSeries) do
    observed = observed + row.resourcefulnessAuthoritativeProcCountObservedCount
    procs = procs + (row.resourcefulnessAuthoritativeProcCount or 0)
  end
  -- Result payloads without supported call context retain positives, never inferred negatives.
  assert(observed == 0 and procs == 0)
end)

test("issue 24: every supported schema-1 fixture migrates exactly once and preserves history", function()
  for _, variant in ipairs(legacyVariants) do
    local source, clock = legacyFixture(variant)
    local original = deepCopy(source)
    local reference = assert(LegacyLedger.New(deepCopy(original), clock)).database
    local migrated = assert(Ledger.New(source, clock))
    deepEqual(source, original, variant .. " source")
    local data = migrated.database
    assert(data.schemaVersion == 2 and data.outcomeVersion == nil and data.returnedReagents == nil)
    assert(migrated.migration.fromSchemaVersion == 1 and migrated.migration.quoteObservedCrafts == 7)
    for _, field in ipairs({ "dimensions", "nextDimensionId", "recipeOutputs", "requests", "reagents",
        "nextCraftId", "nextRequestId", "retentionDays", "schemaIdentity" }) do
      deepEqual(data[field], reference[field], variant .. "." .. field)
    end
    assert(#data.crafts == #reference.crafts)
    for index, craft in ipairs(reference.crafts) do
      local copy = deepCopy(craft)
      copy.quoteObserved = data.crafts[index].quoteObserved
      deepEqual(data.crafts[index], copy, variant .. ".crafts")
    end
    assert(#data.craftSeries == #reference.craftSeries)
    for index, row in ipairs(reference.craftSeries) do
      local migratedRow = data.craftSeries[index]
      for key, value in pairs(row) do assert(migratedRow[key] == value, variant .. " series " .. key) end
      assert(migratedRow.resourcefulnessAuthoritativeProcCountObservedCount == 0 and migratedRow.matchedCraftCount == 0)
    end
    deepEqual(data.resourcefulnessSets, reference.resourcefulnessSets, variant .. ".sets")
    local returned = 0
    for index, row in ipairs(reference.returnedReagents) do
      local migratedRow = data.reagentSeries[index]
      assert(migratedRow.itemId == row.itemId and migratedRow.recipeId == row.recipeId and
        migratedRow.bucketStart == row.bucketStart and migratedRow.returnedQuantity == row.returnedQuantity)
      returned = returned + 1
    end
    local _, returnRows = returnedQuantities(data)
    assert(returnRows == returned)
    -- Inputs are recoverable only from retained details: 1230868 (5 crafts) and 1237557 (2 crafts).
    local function recent(itemId, recipeId)
      for _, row in ipairs(data.reagentSeries) do
        if row.itemId == itemId and row.recipeId == recipeId and row.bucketStart > 1790000000 then return row end
      end
    end
    assert(recent(240991, 1230868).allocatedQuantity == 15 and recent(240991, 1230868).allocationCount == 5)
    assert(recent(236761, 1237557).allocatedQuantity == 24 and recent(236761, 1237557).allocationCount == 2)
    for _, row in ipairs(data.reagentSeries) do
      assert(row.matchedCraftCount == nil and (row.bucketStart > 1790000000 or row.allocationCount == nil))
    end
    -- Reload is idempotent and never replays retained details into aggregates.
    local reloaded = assert(Ledger.New(data, clock))
    assert(reloaded.migration == nil)
    deepEqual(reloaded.database, data, variant .. " reload")
    deepEqual(assert(Ledger.New(reloaded.database, clock)).database, data, variant .. " second reload")
    -- Retention removes details only; every durable aggregate survives unchanged.
    local durable = deepCopy({ data.craftSeries, data.resourcefulnessSets, data.reagentSeries, data.firstCraftRewards })
    clock.current = clock.current + 61 * 86400
    local pruned = assert(Ledger.New(data, clock))
    assert(#pruned.database.crafts == 0 and #pruned.database.reagents == 0)
    deepEqual({ pruned.database.craftSeries, pruned.database.resourcefulnessSets,
      pruned.database.reagentSeries, pruned.database.firstCraftRewards }, durable, variant .. " pruned")
  end
end)

test("issue 24: rejected schema-1 inputs leave the original SavedVariables untouched", function()
  local corruptions = {
    function(data) data.reagents[1].craftId = 999 end,
    function(data) data.craftSeries[#data.craftSeries + 1] = deepCopy(data.craftSeries[1]) end,
    function(data) data.returnedReagents[1].bucketStart = data.returnedReagents[1].bucketStart + 86400 end,
    function(data)
      for _, reagent in ipairs(data.reagents) do
        if reagent.itemId == 236761 and reagent.allocatedQuantity then reagent.allocatedQuantity = maxInteger end
      end
    end,
    function(data) data.outcomeVersion = 3 end,
    function(data) data.crafts[1].outcomeSource = "native" end,
    function(data) data.craftSeries[1].quoteObservedCount = 0 end,
    function(data) data.requests[1].fixedReagents = {} end,
    function(data) data.reagentSeries = {} end,
  }
  for index, corrupt in ipairs(corruptions) do
    local source, clock = legacyFixture("outcome2")
    corrupt(source)
    local rejected, reason
    unchangedAfter(source, function()
      rejected, reason = Ledger.New(source, clock)
      return rejected, reason
    end)
    assert(reason:find("refused", 1, true), "corruption " .. index)
  end
  local source, clock = legacyFixture("outcome2")
  assert(Ledger.New(source, clock) and source.schemaVersion == 1)
end)

test("issue 24: unknown-recipe repair transfers migrated and authoritative grains", function()
  local source, fixtureClock = legacyFixture("outcome2")
  local migrated = assert(Ledger.New(source, fixtureClock))
  local before = migrated.unknownRecipeCount
  local result = assert(migrated:RepairUnknownRecipes())
  assert(result.repairedCount == 1 and migrated.unknownRecipeCount == before - 1)
  assert(assert(Ledger.New(migrated.database, fixtureClock)))

  local ledger, clock = newLedger()
  assert(primaryResult(ledger, { operationID = 1, itemID = 100,
    resourcesReturned = { { reagent = { itemID = 8 }, quantity = 2 } } }))
  assert(primaryResult(ledger, { operationID = 2, itemID = 100 }))
  assert(primaryResult(ledger, { operationID = 3, itemID = 100, resourcesReturned = { { reagent = { itemID = 9 } } } }))
  assert(ledger:AddDimension("recipe", 12) and ledger:LearnRecipeOutput(12, 100))
  assert(ledger:RepairUnknownRecipes().repairedCount == 3)
  local data = ledger.database
  assert(#data.craftSeries == 1 and data.craftSeries[1].recipeId == 12 and data.craftSeries[1].craftCount == 3)
  local row = data.craftSeries[1]
  assert(row.resourcefulnessAuthoritativeProcCount == 1 and row.resourcefulnessAuthoritativeProcCountObservedCount == 2)
  assert(row.resourcefulnessProcCountObservedCount == 2 and row.matchedCraftCount == 0)
  assert(#data.resourcefulnessSets == 1 and data.resourcefulnessSets[1].recipeId == 12)
  assert(data.resourcefulnessSets[1].authoritativeCraftCount == 1)
  assert(#data.reagentSeries == 1 and data.reagentSeries[1].recipeId == 12 and data.reagentSeries[1].returnedQuantity == 2)
  assert(Ledger.New(data, clock))
end)

local sterling, ore, flux = 1229000, 237359, 243060
local alloyQuote = { { dataSlotIndex = 1, quantity = 5, reagent = { itemID = ore } } }
local alloyInputs = inputEvidence({ ore, flux }, { { dataSlotIndex = 2, itemID = flux, quantity = 2 } })

-- Mirrors the real-database pattern: Luminant Flux is a fixed reagent quotes never contain.
local function alloyHistory(target, inputs)
  for index = 1, 50 do
    assert(target:SubmitCraft(sterling, 1, false, nil, alloyQuote, inputs))
    local returned
    if index <= 16 then
      returned = { { reagent = { itemID = flux }, quantity = 1 } }
      if index <= 8 then returned[2] = { reagent = { itemID = ore }, quantity = 2 } end
    end
    assert(primaryResult(target, { operationID = 7000 + index, resourcesReturned = returned }))
  end
end

test("issue 24: returns outside the quote keep outcomes and item-level matching", function()
  local ledger = newLedger()
  alloyHistory(ledger, inputEvidence({ ore }, nil, false))
  local row = ledger.database.craftSeries[1]
  assert(row.craftCount == 50 and row.resourcefulnessAuthoritativeProcCount == 16)
  assert(row.resourcefulnessAuthoritativeProcCountObservedCount == 50)
  assert(row.quoteObservedCount == 50 and row.inputCompleteCount == 0 and row.matchedCraftCount == 0)
  for index = 1, 16 do
    local craft = ledger.database.crafts[index]
    assert(craft.outcomeSource == "native" and craft.hasResourcefulnessProc and craft.quoteObserved)
    assert(craft.inputComplete == nil)
  end
  -- The 16 proc crafts stay in the ore population instead of biasing it toward no returns.
  local oreRow, fluxRow = reagentRow(ledger.database, ore), reagentRow(ledger.database, flux)
  assert(oreRow.matchedCraftCount == 50 and oreRow.matchedAllocatedQuantity == 250)
  assert(oreRow.matchedReturnedQuantity == 16 and oreRow.matchedReturnCount == 8)
  -- Flux's required quantity was never observed, so it has no allocation or matched measure.
  assert(fluxRow.returnedQuantity == 16 and fluxRow.allocationCount == nil and fluxRow.matchedCraftCount == nil)
end)

test("issue 24: schematic fixed reagents complete recipe inputs and fixed-reagent savings", function()
  local ledger, clock = newLedger()
  alloyHistory(ledger, alloyInputs)
  local request = ledger.database.requests[1]
  assert(request.inputComplete == true and request.fixedReagents[1].itemId == flux)
  assert(request.fixedReagents[1].requiredQuantity == 2)
  local facts = ledger.reagentsByCraftId[1]
  assert(#facts == 2 and facts[2].fixed == true and facts[2].allocatedQuantity == 2 and facts[2].returnedQuantity == 1)
  local row = ledger.database.craftSeries[1]
  assert(row.quoteObservedCount == 50 and row.inputCompleteCount == 50 and row.matchedCraftCount == 50)
  local fluxRow = reagentRow(ledger.database, flux)
  assert(fluxRow.allocatedQuantity == 100 and fluxRow.allocationCount == 50)
  assert(fluxRow.matchedAllocatedQuantity == 100 and fluxRow.matchedReturnedQuantity == 16)
  assert(fluxRow.matchedReturnCount == 16)
  -- A return outside both quote and schematic disproves completeness, never the outcome.
  assert(ledger:SubmitCraft(sterling, 1, false, nil, alloyQuote, alloyInputs))
  local surprise = assert(primaryResult(ledger, { operationID = 7100,
    resourcesReturned = { { reagent = { itemID = 999 }, quantity = 1 } } }))
  assert(surprise.outcomeSource == "native" and surprise.hasResourcefulnessProc and surprise.quoteObserved)
  assert(surprise.inputComplete == nil and ledger.database.craftSeries[1].inputCompleteCount == 50)
  local reloaded = assert(Ledger.New(ledger.database, clock))
  deepEqual(reloaded.database, ledger.database)
end)

test("issue 24: partial schematic evidence never claims complete recipe inputs", function()
  local invalidSelection = { alloyQuote[1], { dataSlotIndex = 1, quantity = -1, reagent = { itemID = ore } } }
  local cases = {
    { inputs = { complete = false, hasModifiedSlots = true, fixed = alloyInputs.fixed }, fixed = 1 },
    { inputs = { complete = true, hasModifiedSlots = true,
      fixed = { { dataSlotIndex = 2, itemID = flux, quantity = 0 } } }, fixed = 0 },
    { inputs = { complete = true, hasModifiedSlots = true, fixed = {} }, selections = {}, fixed = 0 },
    { inputs = { complete = true, hasModifiedSlots = true, fixed = {} }, selections = invalidSelection, fixed = 0 },
  }
  for index, case in ipairs(cases) do
    local ledger = newLedger()
    local request = assert(ledger:SubmitCraft(sterling, 1, false, nil, case.selections or alloyQuote, case.inputs))
    assert(request.inputComplete == nil and #(request.fixedReagents or {}) == case.fixed, "case " .. index)
    local craft = assert(fixtureResult(ledger, { operationID = 1 }))
    assert(craft.inputComplete == nil and ledger.database.craftSeries[1].matchedCraftCount == 0, "case " .. index)
  end
  local ledger, clock = newLedger()
  local variants = { alloyQuote[1], { dataSlotIndex = 1, quantity = 0, reagent = { itemID = 237360 } } }
  assert(assert(ledger:SubmitCraft(sterling, 1, false, nil, variants,
    inputEvidence({ ore }))).inputComplete == true)
  assert(fixtureResult(ledger, { operationID = 1 }))
  -- All-fixed recipes have no quote but can still have complete recipe inputs.
  local request = assert(ledger:SubmitCraft(sterling, 1, false, nil, nil,
    inputEvidence({ flux }, { { dataSlotIndex = 1, itemID = flux, quantity = 3 } })))
  local craft = assert(fixtureResult(ledger, { operationID = 2 }))
  assert(request.inputComplete and craft.inputComplete and craft.quoteObserved == nil and craft.requestId == request.id)
  for _, corrupt in ipairs({
    function(data) data.requests[2].inputComplete = nil end,
    function(data) data.reagents[1].allocatedQuantity = nil end,
    function(data) data.reagents[1].fixed = false end,
    function(data) data.requests[2].fixedReagents[1].requiredQuantity = 0 end,
  }) do
    local data = deepCopy(ledger.database)
    corrupt(data)
    unchangedAfter(data, function() return Ledger.New(data, clock) end)
  end
end)

test("review F3 repair preserves proven partial and pre-fix item populations across reload", function()
  for _, mode in ipairs({ "proven", "partial", "pre-fix" }) do
    local ledger, clock = newLedger()
    assert(ledger:SubmitCraft(12, 1, false, nil,
      { { dataSlotIndex = 1, quantity = 5, reagent = { itemID = 8 } } },
      mode ~= "partial" and inputEvidence({ 8 }) or nil))
    assert(primaryResult(ledger, { itemID = 100,
      resourcesReturned = { { reagent = { itemID = 8 }, quantity = 2 } } }))
    local data = deepCopy(ledger.database)
    data.crafts[1].recipeId, data.crafts[1].requestId = nil, nil
    data.crafts[1].quoteObserved, data.crafts[1].inputComplete = nil, nil
    for _, row in ipairs(data.craftSeries) do
      row.recipeId = nil
      row.quoteObservedCount, row.inputCompleteCount, row.matchedCraftCount = 0, 0, 0
    end
    for _, collection in ipairs({ data.reagentSeries, data.resourcefulnessSets }) do
      for _, row in ipairs(collection) do row.recipeId = nil end
    end
    if mode == "pre-fix" then
      for _, row in ipairs(data.reagents) do row.inputTotalComplete = nil end
      for _, allocation in ipairs(data.requests[1].allocations) do allocation.inputTotalComplete = nil end
    end
    ledger = assert(Ledger.New(data, clock))
    assert(ledger:RepairUnknownRecipes().repairedCount == 1)
    local item = reagentRow(ledger.database, 8, 12)
    assert(item.allocatedQuantity == 5 and item.returnedQuantity == 2)
    assert((item.matchedCraftCount or 0) == (mode == "partial" and 0 or 1))
    local core = { ledger = assert(Ledger.New(ledger.database, clock)) }
    assert(loadfile(root .. "/Core/API.lua"))("ArtisanLogbook", core)
    local row = ArtisanLogbookAPI.GetRecipeReagentStatistics(12).reagents[1]
    assert(row.allocatedQuantity == 5 and row.returnedQuantity == 2)
    assert(row.matchedCraftCount == (mode == "partial" and 0 or 1))
  end
end)

print(string.format("%d ledger tests passed", passed))