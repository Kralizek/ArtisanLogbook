local root = arg[1] or "src/ArtisanLogbook"
local testsRoot = arg[2] or "tests"
local addon = {}
assert(loadfile(root .. "/Storage/Ledger.lua"))("ArtisanLogbook", addon)
local Ledger = addon.Ledger
local fixture = assert(loadfile(testsRoot .. "/fixtures/retail-build-69933.lua"))()
local personalFixture = assert(loadfile(testsRoot .. "/fixtures/retail-personal-69933.lua"))()
local passed = 0

local function test(name, callback)
  callback()
  passed = passed + 1
  print("PASS " .. name)
end

local function newLedger(options)
  local clock = { current = 1800000000 }
  function clock.wall() return clock.current end
  local ledger = assert(Ledger.New(nil, clock, options))
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
  assert(basic.recipeDimensionId and basic.outputItemDimensionId)
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
  assert(zero.outputItemDimensionId ~= nil)
  assert(ledger.database.dimensions.items[1].gameItemId == 0)
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
  assert(first.sessionDimensionId == firstSession and second.sessionDimensionId == secondSession)
  assert(reloaded.database.nextCraftId == 3)
end)

test("age pruning removes craft and reagent rows but leaves dimensions and IDs", function()
  local ledger, clock = newLedger({ retentionDays = 1, maxCrafts = 20 })
  local old = assert(ledger:RecordResult({
    itemID = 50,
    resourcesReturned = { { reagent = { itemID = 51 }, quantity = 2 } },
  }))
  local dimensionCount = #ledger.database.dimensions.items
  clock.current = clock.current + 86401
  ledger:Prune(clock.current)
  assert(#ledger.database.crafts == 0 and #ledger.database.reagents == 0)
  assert(#ledger.database.dimensions.items == dimensionCount)
  local newer = assert(ledger:RecordResult({ quantity = 1 }))
  assert(newer.id == old.id + 1)
end)

test("count pruning removes oldest facts and keeps append-only dimensions", function()
  local ledger = newLedger({ retentionDays = 180, maxCrafts = 2 })
  local itemDimension = ledger:AddDimension("item", 700, { gameItemId = 700 })
  assert(ledger:AddDimension("item", 700, { gameItemId = 700, name = "ignored" }) == itemDimension)
  local expansionId = ledger:AddDimension("expansion", "era-test", {
    displayName = "Test Era",
    chronologicalOrder = 90,
  })
  local recipeId = ledger:AddDimension("recipe", 800, {
    gameRecipeId = 800,
    expansionDimensionId = expansionId,
  })
  local first = assert(ledger:RecordResult({ operationID = 1, quantity = 1,
    resourcesReturned = { { reagent = { itemID = 700 }, quantity = 1 } } }))
  local second = assert(ledger:RecordResult({ operationID = 2, quantity = 1 }))
  local third = assert(ledger:RecordResult({ operationID = 3, quantity = 1 }))
  assert(#ledger.database.crafts == 2 and ledger.database.crafts[1].id == second.id)
  assert(ledger.database.crafts[2].id == third.id and #ledger.database.reagents == 0)
  assert(ledger.database.nextCraftId == 4 and ledger.database.dimensions.items[1].id == itemDimension)
  assert(ledger.database.dimensions.recipes[1].id == recipeId)
  assert(ledger.database.dimensions.recipes[1].expansionDimensionId == expansionId)
  assert(ledger.database.dimensions.expansions[1].chronologicalOrder == 90)
  local invalidExpansion = ledger:AddDimension("item", 701, { expansionDimensionId = 999 })
  assert(invalidExpansion == nil)
  assert(first.id < second.id)
  ledger:BeginCraft(801)
  local reusedOperation = assert(ledger:RecordResult({ operationID = 1, quantity = 1 }))
  assert(reusedOperation.recipeDimensionId ~= nil)
end)

test("ambiguous begins and repeated or late results are retained without merging", function()
  local ledger = newLedger()
  ledger:BeginCraft(900)
  local zeroId = assert(ledger:RecordResult({ operationID = 0, quantity = 1 }))
  assert(zeroId.recipeDimensionId == nil)
  ledger:BeginCraft(900)
  local first = assert(ledger:RecordResult({ operationID = 42, itemID = 1, quantity = 1 }))
  local repeated = assert(ledger:RecordResult({ operationID = 42, itemID = 1, quantity = 1 }))
  assert(first.id ~= repeated.id and first.gameOperationId == repeated.gameOperationId)

  ledger:BeginCraft(901)
  ledger:BeginCraft(902)
  local ambiguous = assert(ledger:RecordResult({ operationID = 43, quantity = 1 }))
  assert(ambiguous.recipeDimensionId == nil)
  ledger:BeginCraft(903)
  local later = assert(ledger:RecordResult({ operationID = 44, quantity = 1 }))
  assert(later.recipeDimensionId ~= nil)
  ledger:BeginCraft(904)
  local late = assert(ledger:RecordResult({ operationID = 42, quantity = 1 }))
  assert(late.recipeDimensionId == nil and late.gameOperationId == 42)
  ledger:BeginCraft(905)
  local missingId = assert(ledger:RecordResult({ quantity = 1 }))
  assert(missingId.recipeDimensionId == nil)
  assert(#ledger.database.crafts == 7)
end)

test("unsupported flavor measurements remain absent", function()
  local ledger = assert(Ledger.New(nil, { wall = function() return 1800000000 end }))
  ledger:CreateSession({ capabilities = {
    flavor = "classic", events = {}, hooks = {}, measurements = {},
  } })
  local craft = assert(ledger:RecordResult({ quantity = 1 }))
  assert(craft.concentrationSpent == nil and craft.hasIngenuityProc == nil)
  assert(craft.professionDimensionId == nil and craft.recipeDimensionId == nil)
  assert(ledger.database.dimensions.sessions[1].capabilities.measurements.concentrationSpent == nil)
end)

test("schema zero migrates without recycling IDs", function()
  local ledger = newLedger()
  ledger.database.nextCraftId = 5
  assert(ledger:RecordResult({}))
  local legacy = ledger.database
  legacy.schemaVersion = 0
  legacy.requests, legacy.nextRequestId = nil, nil
  legacy.retentionDays, legacy.maxCrafts = nil, nil
  local migrated = assert(Ledger.New(legacy, { wall = function() return 1800000000 end }))
  assert(migrated.database.schemaVersion == Ledger.schemaVersion)
  assert(migrated.database.crafts[1].id == 5 and migrated.database.nextCraftId == 6)
  migrated:CreateSession({})
  assert(assert(migrated:RecordResult({})).id == 6)
  assert(legacy.schemaVersion == 0 and legacy.retentionDays == nil and legacy.nextCraftId == 6)
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
    { id = 1, key = "7", gameItemId = 7 },
    { id = 2, key = "7", gameItemId = 7 },
  }
  malformedDimensions.nextDimensionId.item = 3
  assert(Ledger.New(malformedDimensions) == nil)
end)

test("dimension enrichment is monotonic, atomic, and includes expansion metadata", function()
  local ledger = newLedger()
  for _, kind in ipairs({ "realm", "character", "profession", "recipe", "item", "session", "expansion" }) do
    local id = assert(ledger:AddDimension(kind, "sparse"))
    assert(ledger:AddDimension(kind, "sparse", { name = "Known" }) == id)
    assert(ledger:AddDimension(kind, "sparse", { name = "Known" }) == id)
    local failed, reason = ledger:AddDimension(kind, "sparse", { name = "Conflict", extra = "no" })
    assert(failed == nil and reason:find("conflicting", 1, true))
    assert(ledger:AddDimension(kind, "sparse", { extra = "yes" }) == id)
    assert(ledger:AddDimension(kind, "sparse", { id = id + 1 }) == nil)
  end
  local expansion = assert(ledger:AddDimension("expansion", "era", {
    displayName = "Observed Era", chronologicalOrder = 0,
  }))
  for _, kind in ipairs({ "recipe", "item", "profession" }) do
    local id = assert(ledger:AddDimension(kind, "sparse", { expansionDimensionId = expansion }))
    assert(ledger.dimensionRows[kind][id].expansionDimensionId == expansion)
    assert(ledger:AddDimension(kind, "sparse", { expansionDimensionId = expansion }) == id)
    assert(ledger:AddDimension(kind, "sparse", { expansionDimensionId = 999 }) == nil)
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

test("every persisted reference is validated before load or migration can prune", function()
  local cases = {
    { "crafts", "sessionDimensionId" }, { "crafts", "recipeDimensionId" },
    { "crafts", "outputItemDimensionId" }, { "crafts", "professionDimensionId" },
    { "reagents", "craftId" }, { "reagents", "itemDimensionId" },
    { "characters", "realmDimensionId" }, { "sessions", "characterDimensionId" },
    { "sessions", "realmDimensionId" }, { "recipes", "expansionDimensionId" },
    { "items", "expansionDimensionId" }, { "professions", "expansionDimensionId" },
    { "recipes", "professionDimensionId" },
  }
  for _, version in ipairs({ 0, 1 }) do
    for _, reference in ipairs(cases) do
      local ledger, clock = newLedger()
      replay(ledger, fixture.cases)
      ledger:AddDimension("profession", "test")
      local data = ledger.database
      data.schemaVersion = version
      data.requests, data.nextRequestId = nil, nil
      local rows = data[reference[1]] or data.dimensions[reference[1]]
      rows[1][reference[2]] = 999
      clock.current = clock.current + 200 * 86400
      local refused, reason = Ledger.New(data, clock)
      assert(refused == nil and reason:find(reference[2], 1, true), reference[2])
      assert(data.schemaVersion == version and #data.crafts == 7 and #data.reagents == 9)
      assert(rows[1][reference[2]] == 999)
    end
  end
end)

test("sparse collections and missing counters cannot be silently repaired", function()
  for _, version in ipairs({ 0, 1 }) do
    for _, collection in ipairs({ "crafts", "reagents", "items" }) do
      local ledger = newLedger()
      replay(ledger, fixture.cases)
      local data = ledger.database
      data.schemaVersion = version
      data.requests, data.nextRequestId = nil, nil
      local rows = data[collection] or data.dimensions[collection]
      rows[2] = nil
      assert(Ledger.New(data) == nil)
      assert(rows[3] ~= nil and data.schemaVersion == version)
    end
    local ledger = newLedger()
    local data = ledger.database
    data.schemaVersion, data.nextCraftId = version, nil
    data.requests, data.nextRequestId = nil, nil
    assert(Ledger.New(data) == nil and data.nextCraftId == nil)
    data.nextCraftId = 100
    data.nextDimensionId.item = nil
    assert(Ledger.New(data) == nil and data.nextDimensionId.item == nil)
    data.nextDimensionId.item = 100
    data.retentionDays = false
    assert(Ledger.New(data) == nil and data.retentionDays == false)
    data.retentionDays = 180
    data.loop = data
    assert(Ledger.New(data) == nil and data.loop == data)
  end
end)

test("dimension reference validation also rejects live invalid enrichment", function()
  local ledger = newLedger()
  for _, kind in ipairs({ "character", "session", "recipe", "item", "profession" }) do
    local id = assert(ledger:AddDimension(kind, "target"))
    local field = (kind == "character" or kind == "session") and "realmDimensionId" or "expansionDimensionId"
    local counter = ledger.database.nextDimensionId[kind]
    assert(ledger:AddDimension(kind, "target", { [field] = 999, name = "Must not stick" }) == nil)
    assert(ledger:AddDimension(kind, "target", { name = "Valid" }) == id)
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
  assert(ledger.database.nextCraftId == 1 and #ledger.database.dimensions.items == 0)
  ledger:AddDimension("item", 100, { gameItemId = 101 })
  assert(ledger:RecordResult({ itemID = 200, resourcesReturned = {
    { reagent = { itemID = 100 }, quantity = 1 },
  } }) == nil)
  assert(#ledger.database.crafts == 0 and #ledger.database.reagents == 0)
  assert(ledger.database.nextCraftId == 1 and next(ledger.operationIndex) == nil)
  ledger.wall = function() return nil end
  assert(ledger:RecordResult({}) == nil)
  assert(ledger.database.nextCraftId == 1)
end)

test("pruning is deterministic at age boundaries and count ties with consistent indexes", function()
  local ledger, clock, sessionId = newLedger({ retentionDays = 1, maxCrafts = 10 })
  local first = assert(ledger:RecordResult({ operationID = 10, quantity = 1 }))
  local second = assert(ledger:RecordResult({ operationID = 10, quantity = 1,
    resourcesReturned = { { reagent = { itemID = 100 }, quantity = 0 } } }))
  clock.current = clock.current + 86400
  ledger:Prune(clock.current)
  assert(#ledger.database.crafts == 2)
  ledger.database.crafts[1], ledger.database.crafts[2] = second, first
  ledger.database.maxCrafts = 1
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(#reloaded.database.crafts == 1 and reloaded.database.crafts[1].id == second.id)
  assert(#reloaded.database.reagents == 1 and reloaded.database.reagents[1].returnedQuantity == 0)
  assert(reloaded.operationIndex[sessionId][10] == 1)
  clock.current = clock.current + 1
  reloaded:Prune(clock.current)
  assert(#reloaded.database.crafts == 0 and #reloaded.database.reagents == 0)
  assert(reloaded.operationIndex[sessionId] == nil and reloaded.database.nextCraftId == 3)
  assert(#reloaded.database.dimensions.items == 1)
end)

test("real concentration batch retains separate results with intentionally absent recipe attribution", function()
  local ledger = newLedger()
  replay(ledger, { fixture.cases[2] })
  assert(#ledger.database.crafts == 2)
  local first, second = ledger.database.crafts[1], ledger.database.crafts[2]
  assert(first.id ~= second.id and first.gameOperationId ~= second.gameOperationId)
  for _, craft in ipairs(ledger.database.crafts) do
    assert(craft.recipeDimensionId == nil)
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
    local craft = assert(ledger:RecordResult({ operationID = operationId,
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
  local item = ledger.dimensionRows.item[request.allocations[1].itemDimensionId]
  assert(item.gameItemId == 102)

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
      local craft = assert(ledger:RecordResult(result))
      assert(craft.requestId == request.id and craft.recipeDimensionId == request.recipeDimensionId)
    end
    if scenario.failedQueuedOperation then ledger:CancelCraft() end
  end
  local data = ledger.database
  assert(#data.requests == 4 and #data.crafts == 6 and #data.reagents == 8)
  assert(data.requests[1].allocations[1].allocatedQuantity == 3)
  assert(data.requests[1].allocations[1].quality == 1)
  assert(data.requests[2].allocations[1].itemDimensionId ~= data.requests[1].allocations[1].itemDimensionId)
  assert(data.requests[2].useConcentration and data.requests[2].concentrationCost == 81)
  assert(data.crafts[2].concentrationSpent == 80 and data.crafts[2].hasIngenuityProc == false)
  assert(data.reagents[1].returnedQuantity == 1 and data.reagents[2].returnedQuantity == 1)
  assert(data.reagents[3].returnedQuantity == 0 and data.reagents[4].returnedQuantity == 0)
  assert(data.crafts[3].requestId == data.crafts[4].requestId)
  assert(data.crafts[4].requestId == data.crafts[5].requestId)
  assert(data.requests[4].requestedCount == 3 and data.crafts[6].requestId == data.requests[4].id)
  assert(assert(ledger:RecordResult({ operationID = 3002 })).requestId == nil)
end)

test("ambiguous submissions and duplicate allocation items do not guess attribution", function()
  local ledger = newLedger()
  local first = assert(ledger:SubmitCraft(1, 3, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 100 } },
    { dataSlotIndex = 2, quantity = 2, reagent = { itemID = 100 } },
  }))
  local result = assert(ledger:RecordResult({ operationID = 4, resourcesReturned = {
    { reagent = { itemID = 100 }, quantity = 1 },
  } }))
  assert(result.requestId == first.id and #ledger.database.reagents == 3)
  assert(ledger.database.reagents[1].returnedQuantity == nil)
  assert(ledger.database.reagents[2].returnedQuantity == nil)
  assert(ledger.database.reagents[3].allocatedQuantity == nil)
  assert(ledger.database.reagents[3].returnedQuantity == 1)
  ledger:SubmitCraft(2, 2, false)
  assert(assert(ledger:RecordResult({ operationID = 5 })).requestId == nil)
  ledger:CancelCraft()
  ledger:SubmitCraft(3, 2, false)
  assert(assert(ledger:RecordResult({ operationID = 5 })).requestId == 3)
  assert(assert(ledger:RecordResult({})).requestId == 3)
end)

test("unsupported craft submission cannot inherit a personal request", function()
  local ledger = newLedger()
  assert(ledger:SubmitCraft(456, 2, false))
  ledger:InvalidateCraft()
  ledger:BeginCraft(789)
  assert(assert(ledger:RecordResult({ operationID = 1 })).requestId == nil)
  assert(ledger.database.crafts[1].recipeDimensionId == nil)
  assert(#ledger.database.requests == 1 and #ledger.database.crafts == 1)
end)

test("unrelated quote fields cannot leak into or block a request", function()
  local ledger = newLedger()
  local quote = { concentrationCost = 0, customer = function() end }
  local request = assert(ledger:SubmitCraft(456, 1, false, quote))
  assert(request.concentrationCost == 0 and request.customer == nil)
  assert(Ledger.New(ledger.database))
end)

test("schema 1 migration preserves partial returns and refuses invalid new references", function()
  local ledger, clock = newLedger()
  local result = assert(ledger:RecordResult({ operationID = 1, resourcesReturned = {
    { reagent = { itemID = 101 }, quantity = 2 },
  } }))
  local old = ledger.database
  old.schemaVersion, old.nextRequestId, old.requests = 1, nil, nil
  local migrated = assert(Ledger.New(old, clock))
  assert(migrated.database.schemaVersion == 2 and migrated.database.nextRequestId == 1)
  assert(#migrated.database.requests == 0 and migrated.database.crafts[1].id == result.id)
  assert(migrated.database.reagents[1].allocatedQuantity == nil)
  assert(old.schemaVersion == 1 and old.requests == nil)
  local unexpected = Ledger.New({ schemaVersion = 1, requests = { { id = 1 } } })
  assert(unexpected == nil)
  migrated:CreateSession({})
  local request = assert(migrated:SubmitCraft(456, 1, false))
  assert(request.id == 1 and assert(migrated:RecordResult({})).id == 2)
  assert(assert(Ledger.New(migrated.database)).database.requests[1].completedCount == nil)
  for _, field in ipairs({ "requestId", "sessionDimensionId", "recipeDimensionId", "itemDimensionId" }) do
    local data = migrated.database
    local copied = assert(Ledger.New(data)).database
    local row = field == "requestId" and copied.crafts[2] or
      field == "itemDimensionId" and copied.requests[1].allocations or copied.requests[1]
    if field == "itemDimensionId" then
      copied.requests[1].allocations = { { dataSlotIndex = 1, allocatedQuantity = 1, itemDimensionId = 999 } }
    else
      row[field] = 999
    end
    local refused = Ledger.New(copied)
    assert(refused == nil and copied.schemaVersion == 2 and copied.requests[1].id == 1, field)
  end
  local mismatched = assert(Ledger.New(migrated.database)).database
  mismatched.crafts[2].recipeDimensionId = mismatched.crafts[1].recipeDimensionId
  assert(Ledger.New(mismatched) == nil)
end)

test("request reload and pruning keep surviving references and monotonic IDs", function()
  local ledger, clock = newLedger({ retentionDays = 1, maxCrafts = 1 })
  local first = assert(ledger:SubmitCraft(1, 2, false))
  local craft = assert(ledger:RecordResult({ operationID = 1 }))
  local reloaded = assert(Ledger.New(ledger.database, clock))
  reloaded:CreateSession({})
  assert(assert(reloaded:RecordResult({ operationID = 2 })).requestId == nil)
  assert(#reloaded.database.requests == 0 and #reloaded.database.crafts == 1)
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
  local craft = assert(ledger:RecordResult({ operationID = 9 }))
  assert(craft.requestId == request.id and #ledger.database.requests == 1)
  assert(Ledger.New(ledger.database, clock))
  ledger:CancelCraft()
  clock.current = clock.current + 86401
  ledger:Prune(clock.current)
  assert(#ledger.database.requests == 0 and #ledger.database.crafts == 0)
end)

print(string.format("%d ledger tests passed", passed))