local root = arg[1] or "src/ArtisanLogbook"
local testsRoot = arg[2] or "tests"
local addon = {}
assert(loadfile(root .. "/Storage/Ledger.lua"))("ArtisanLogbook", addon)
local Ledger = addon.Ledger
local fixture = assert(loadfile(testsRoot .. "/fixtures/retail-build-69933.lua"))()
local personalFixture = assert(loadfile(testsRoot .. "/fixtures/retail-personal-69933.lua"))()
local passed = 0
local maxInteger = 9007199254740991

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
  local ledger, clock = newLedger({ retentionDays = 1 })
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

test("capture retains all facts and keeps append-only dimensions", function()
  local ledger = newLedger()
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
  assert(#ledger.database.crafts == 3 and ledger.database.crafts[1].id == first.id)
  assert(ledger.database.crafts[3].id == third.id and #ledger.database.reagents == 1)
  assert(ledger.database.nextCraftId == 4 and ledger.database.dimensions.items[1].id == itemDimension)
  assert(ledger.database.dimensions.recipes[1].id == recipeId)
  assert(ledger.database.dimensions.recipes[1].expansionDimensionId == expansionId)
  assert(ledger.database.dimensions.expansions[1].chronologicalOrder == 90)
  local invalidExpansion = ledger:AddDimension("item", 701, { expansionDimensionId = 999 })
  assert(invalidExpansion == nil)
  assert(first.id < second.id)
  ledger:BeginCraft(801)
  local reusedOperation = assert(ledger:RecordResult({ operationID = 1, quantity = 1 }))
  assert(reusedOperation.recipeDimensionId == nil)
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

test("schema 1 requires its format identity and refuses every experimental version atomically", function()
  for version = 0, 5 do
    local ledger, clock = newLedger()
    assert(ledger:SubmitCraft(12, 2, false))
    assert(ledger:RecordResult({ quantity = 2, hasIngenuityProc = true, ingenuityRefund = 3 }))
    ledger.database.schemaVersion = version
    ledger.database.schemaIdentity = nil
    clock.current = clock.current + 61 * 86400
    unchangedAfter(ledger.database, function() return Ledger.New(ledger.database, clock) end)
    if version ~= 1 then
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

test("clean schema 1 initializes the complete model and reload does not rebuild durable totals", function()
  local ledger = assert(Ledger.New(nil))
  assert(ledger.database.schemaVersion == 1 and ledger.database.schemaIdentity == "ArtisanLogbookLedger")
  assert(ledger.database.retentionDays == 60 and ledger.database.maxCrafts == nil)
  assert(ledger.database.nextCraftId == 1 and ledger.database.nextRequestId == 1)
  assert(#ledger.database.crafts == 0 and #ledger.database.requests == 0)
  assert(#ledger.database.reagents == 0 and #ledger.database.craftSeries == 0)
  for kind, rows in pairs(ledger.dimensionRows) do
    assert(next(rows) == nil and ledger.database.nextDimensionId[kind] == 1)
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

test("every persisted reference is validated before startup can prune", function()
  local cases = {
    { "crafts", "sessionDimensionId" }, { "crafts", "recipeDimensionId" },
    { "crafts", "outputItemDimensionId" }, { "crafts", "professionDimensionId" },
    { "reagents", "craftId" }, { "reagents", "itemDimensionId" },
    { "characters", "realmDimensionId" }, { "sessions", "characterDimensionId" },
    { "sessions", "realmDimensionId" }, { "recipes", "expansionDimensionId" },
    { "items", "expansionDimensionId" }, { "professions", "expansionDimensionId" },
    { "recipes", "professionDimensionId" },
  }
  for _, reference in ipairs(cases) do
    local ledger, clock = newLedger()
    replay(ledger, fixture.cases)
    ledger:AddDimension("profession", "test")
    local data = ledger.database
    local rows = data[reference[1]] or data.dimensions[reference[1]]
    rows[1][reference[2]] = 999
    clock.current = clock.current + 200 * 86400
    local refused, reason = Ledger.New(data, clock)
    assert(refused == nil and reason:find(reference[2], 1, true), reference[2])
    assert(data.schemaVersion == 1 and #data.crafts == 7 and #data.reagents == 9)
    assert(rows[1][reference[2]] == 999)
  end
end)

test("sparse collections and missing counters cannot be silently repaired", function()
  for _, collection in ipairs({ "crafts", "reagents", "items" }) do
    local ledger = newLedger()
    replay(ledger, fixture.cases)
    local data = ledger.database
    local rows = data[collection] or data.dimensions[collection]
    rows[2] = nil
    assert(Ledger.New(data) == nil)
    assert(rows[3] ~= nil and data.schemaVersion == 1)
  end
  local ledger = newLedger()
  local data = ledger.database
  data.nextCraftId = nil
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

test("pruning is deterministic at age boundaries with consistent indexes", function()
  local ledger, clock, sessionId = newLedger({ retentionDays = 1 })
  local first = assert(ledger:RecordResult({ operationID = 10, quantity = 1 }))
  local second = assert(ledger:RecordResult({ operationID = 10, quantity = 1,
    resourcesReturned = { { reagent = { itemID = 100 }, quantity = 0 } } }))
  clock.current = clock.current + 86400
  ledger:Prune(clock.current)
  assert(#ledger.database.crafts == 2)
  ledger.database.crafts[1], ledger.database.crafts[2] = second, first
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(#reloaded.database.crafts == 2)
  assert(reloaded.craftIds[1] == first.id and reloaded.craftIds[2] == second.id)
  assert(reloaded.craftIdsByTime[1] == first.id and reloaded.craftIdsByTime[2] == second.id)
  assert(#reloaded.database.reagents == 1 and reloaded.database.reagents[1].returnedQuantity == 0)
  assert(reloaded.operationIndex[sessionId][10] == 2)
  clock.current = clock.current + 1
  reloaded:Prune(clock.current)
  assert(#reloaded.database.crafts == 0 and #reloaded.database.reagents == 0)
  assert(reloaded.operationIndex[sessionId] == nil and reloaded.database.nextCraftId == 3)
  assert(next(reloaded.craftById) == nil and next(reloaded.reagentsByCraftId) == nil)
  assert(#reloaded.craftIds == 0 and #reloaded.craftIdsByTime == 0)
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

test("reload preserves partial returns and refuses invalid request references", function()
  local ledger, clock = newLedger()
  local result = assert(ledger:RecordResult({ operationID = 1, resourcesReturned = {
    { reagent = { itemID = 101 }, quantity = 2 },
  } }))
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(reloaded.database.schemaVersion == 1 and reloaded.database.nextRequestId == 1)
  assert(#reloaded.database.requests == 0 and reloaded.database.crafts[1].id == result.id)
  assert(reloaded.database.reagents[1].allocatedQuantity == nil)
  reloaded:CreateSession({})
  local request = assert(reloaded:SubmitCraft(456, 1, false))
  assert(request.id == 1 and assert(reloaded:RecordResult({})).id == 2)
  assert(assert(Ledger.New(reloaded.database)).database.requests[1].completedCount == nil)
  for _, field in ipairs({ "requestId", "sessionDimensionId", "recipeDimensionId", "itemDimensionId" }) do
    local data = reloaded.database
    local copied = assert(Ledger.New(data)).database
    local row = field == "requestId" and copied.crafts[2] or
      field == "itemDimensionId" and copied.requests[1].allocations or copied.requests[1]
    if field == "itemDimensionId" then
      copied.requests[1].allocations = { { dataSlotIndex = 1, allocatedQuantity = 1, itemDimensionId = 999 } }
    else
      row[field] = 999
    end
    local refused = Ledger.New(copied)
    assert(refused == nil and copied.schemaVersion == 1 and copied.requests[1].id == 1, field)
  end
  local mismatched = assert(Ledger.New(reloaded.database)).database
  mismatched.crafts[2].recipeDimensionId = mismatched.crafts[1].recipeDimensionId
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
  local craft = assert(ledger:RecordResult({ operationID = 9 }))
  assert(craft.requestId == request.id and #ledger.database.requests == 1)
  assert(Ledger.New(ledger.database, clock))
  ledger:CancelCraft()
  clock.current = clock.current + 86401
  ledger:Prune(clock.current)
  assert(#ledger.database.requests == 0 and #ledger.database.crafts == 0)
end)

test("schema 1 refuses persisted and configured count caps", function()
  local ledger, clock = newLedger()
  for _, cap in ipairs({ false, 0, 1, 50000 }) do
    local refused, reason = Ledger.New(ledger.database, clock, { maxCrafts = cap })
    assert(refused == nil and reason:find("maxCrafts", 1, true))
    assert(ledger.database.maxCrafts == nil)
    ledger.database.maxCrafts = cap
    refused, reason = Ledger.New(ledger.database, clock)
    assert(refused == nil and reason:find("maxCrafts", 1, true))
    assert(ledger.database.schemaVersion == 1 and ledger.database.maxCrafts == cap)
    ledger.database.maxCrafts = nil
  end
end)

test("startup prunes before building runtime indexes once", function()
  local ledger, clock, sessionId = newLedger()
  local request = assert(ledger:SubmitCraft(12, 2, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 100 } },
  }))
  local old = assert(ledger:RecordResult({ operationID = 10 }))
  clock.current = clock.current + 60 * 86400 + 1
  local retained = assert(ledger:RecordResult({ operationID = 11 }))
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
  assert(assert(reloaded:RecordResult({ operationID = 10 })).recipeDimensionId ~= nil)
end)

test("secondary indexes track domain identities and monotonic dimension enrichment", function()
  local ledger, clock = newLedger()
  local sessionId = assert(ledger:CreateSession({}))
  local request = assert(ledger:SubmitCraft(12, 1, false))
  local craft = assert(ledger:RecordResult({}))
  local unknown = assert(ledger:RecordResult({}))
  assert(ledger.craftIdsByRecipe[12][1] == craft.id)
  assert(next(ledger.craftIdsByCharacter) == nil and next(ledger.craftIdsByRealm) == nil)
  assert(next(ledger.craftIdsByProfession) == nil and next(ledger.craftIdsByExpansion) == nil)
  local indexes = ledger.craftIdsByRecipe
  local expansion = assert(ledger:AddDimension("expansion", "era", {}))
  local otherExpansion = assert(ledger:AddDimension("expansion", "other-era", {}))
  local profession = assert(ledger:AddDimension("profession", "profession", {
    expansionDimensionId = otherExpansion,
  }))
  local realm = assert(ledger:AddDimension("realm", "realm-key", {}))
  local character = assert(ledger:AddDimension("character", "character-key", {
    realmDimensionId = realm,
  }))
  assert(ledger.craftIdsByRecipe == indexes)
  assert(ledger:AddDimension("recipe", 12, {
    gameRecipeId = 12, professionDimensionId = profession, expansionDimensionId = expansion,
  }) == request.recipeDimensionId)
  assert(ledger.craftIdsByExpansion.era[1] == craft.id)
  assert(ledger.craftIdsByExpansion["other-era"] == nil)
  assert(next(ledger.craftIdsByProfession) == nil)
  assert(ledger:AddDimension("profession", "profession", { skillLineId = 164 }) == profession)
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
    gameRecipeId = 12, professionDimensionId = profession, expansionDimensionId = expansion,
  }))
  assert(ledger.craftIdsByRecipe == indexes)
  assert(ledger:AddDimension("recipe", 12, { professionDimensionId = 999, name = "Conflict" }) == nil)
  assert(ledger.craftIdsByRecipe == indexes and ledger.dimensionRows.recipe[request.recipeDimensionId].name == nil)
  local override = assert(ledger:AddDimension("profession", "override", { skillLineId = 171 }))
  craft.professionDimensionId = override
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
  local profession = assert(ledger:AddDimension("profession", "profession", { skillLineId = 164 }))
  local session = ledger.dimensionRows.session[ledger.currentSessionId]
  local character = ledger.dimensionRows.character[session.characterDimensionId]
  local realm = ledger.dimensionRows.realm[session.realmDimensionId]
  local indexedRecipes = ledger.craftIdsByRecipe
  ledger.RebuildFilterIndexes = function() error("metadata enrichment rebuilt filter indexes") end
  local ok, reason = pcall(function()
    assert(ledger:AddDimension("recipe", 12, { name = "Recipe" }) == request.recipeDimensionId)
    assert(ledger:AddDimension("item", 100, { name = "Item", expansionDimensionId = expansion }))
    assert(ledger:AddDimension("expansion", "era", { displayName = "Era", chronologicalOrder = 1 }))
    assert(ledger:AddDimension("profession", "profession", {
      name = "Profession", expansionDimensionId = expansion,
    }) == profession)
    assert(ledger:AddDimension("session", session.key, {
      locale = "enUS", capabilities = { measurements = { available = false } },
    }))
    assert(ledger:AddDimension("character", character.key, { metadata = { note = "Observed" } }))
    assert(ledger:AddDimension("realm", realm.key, { metadata = { note = "Observed" } }))
    assert(ledger.craftIdsByRecipe == indexedRecipes)
    assert(session.capabilities.measurements.available == false)
    assert(ledger.dimensionRows.recipe[request.recipeDimensionId].name == "Recipe")
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
    assert(self.operationIndex[craft.sessionDimensionId][10] == 1)
    local series = self.database.craftSeries[1]
    local characterId = self.dimensionRows.session[craft.sessionDimensionId].characterDimensionId
    assert(series.craftCount == 1 and series.recipeDimensionId == request.recipeDimensionId)
    assert(series.characterDimensionId == characterId)
    assert(self.seriesByKey[series.bucketStart][characterId][request.recipeDimensionId] == series)
    assert(series.ingenuityProcCount == 1 and series.ingenuityProcCountObservedCount == 1)
    assert(series.ingenuityRefund == 162 and series.ingenuityRefundObservedCount == 1)
    callbackCompleted = true
  end
  assert(ledger:RecordResult({ operationID = 10, resourcesReturned = {},
    hasIngenuityProc = true, ingenuityRefund = 162 }))
  assert(callbackCompleted)
end)

test("more than 50000 crafts survive capture and reload without historical scans", function()
  local ledger, clock = newLedger()
  local selections = { { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 100 } } }
  for index = 1, 50001 do
    local request = assert(ledger:SubmitCraft(12, 1, false, nil, selections))
    local craft = assert(ledger:RecordResult({ operationID = index, resourcesReturned = {} }))
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
    local craft = assert(ledger:RecordResult({ operationID = 50002, resourcesReturned = {},
      hasIngenuityProc = true, ingenuityRefund = 162 }))
    assert(craft.requestId == request.id)
    assert(ledger.requestById[request.id] == request and ledger.craftById[craft.id] == craft)
    assert(ledger.reagentsByCraftId[craft.id][1] == ledger.database.reagents[50002])
    request = assert(ledger:SubmitCraft(13, 1, false))
    craft = assert(ledger:RecordResult({ operationID = 50003, itemID = 101,
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
  assert(series.craftCount == 1 and series.recipeDimensionId == nil)
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
  assert(ledger:RecordResult({ quantity = 1 }))
  local first = ledger.database.craftSeries[1]
  ledger:CreateSession(metadata)
  assert(ledger:SubmitCraft(12, 1, false))
  clock.current = clock.current + 86399
  assert(ledger:RecordResult({ quantity = 2 }))
  assert(#ledger.database.craftSeries == 1 and first.craftCount == 2 and first.outputQuantity == 3)
  clock.current = clock.current + 1
  assert(ledger:SubmitCraft(12, 1, false))
  assert(ledger:RecordResult({}))
  assert(#ledger.database.craftSeries == 2)
  assert(ledger.database.craftSeries[2].bucketStart == first.bucketStart + 86400)
  ledger:CreateSession({})
  assert(ledger:RecordResult({}))
  ledger:CreateSession({})
  assert(ledger:RecordResult({}))
  local unknown = ledger.database.craftSeries[3]
  assert(unknown.characterDimensionId == nil and unknown.recipeDimensionId == nil)
  assert(unknown.craftCount == 2 and ledger.seriesByKey[unknown.bucketStart][0][0] == unknown)
  assert(ledger:SubmitCraft(12, 1, false))
  assert(ledger:RecordResult({}))
  assert(ledger.database.craftSeries[4].characterDimensionId == nil)
  assert(ledger.database.craftSeries[4].recipeDimensionId == request.recipeDimensionId)
  metadata.characterGUID = "Player-Other"
  ledger:CreateSession(metadata)
  assert(ledger:SubmitCraft(12, 1, false))
  assert(ledger:RecordResult({}))
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
  assert(row.characterDimensionId == nil and row.recipeDimensionId == craft.recipeDimensionId)

  local characterId = assert(ledger:AddDimension("character", "late-character", { name = "Late Character" }))
  local session = ledger.dimensionRows.session[craft.sessionDimensionId]
  assert(ledger:AddDimension("session", session.key, { characterDimensionId = characterId }) == session.id)
  assert(session.characterDimensionId == characterId)
  assert(row.characterDimensionId == nil)

  local reloaded = assert(Ledger.New(ledger.database, clock))
  local loadedRow = reloaded.database.craftSeries[#reloaded.database.craftSeries]
  assert(loadedRow.characterDimensionId == nil)
  assert(loadedRow.recipeDimensionId == craft.recipeDimensionId)
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
  assert(loaded.database.schemaVersion == 1 and loaded.database.retentionDays == 60)
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
  assert(ledger:RecordResult({ quantity = 2 }))
  local row = ledger.database.craftSeries[1]
  clock.current = clock.current + 61 * 86400
  assert(#ledger.database.crafts == 1)
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(#reloaded.database.crafts == 0 and #reloaded.database.requests == 0)
  local series = reloaded.database.craftSeries[1]
  assert(series.craftCount == 1 and series.outputQuantity == 2)
  assert(reloaded.dimensionRows.character[row.characterDimensionId])
  local profession = assert(reloaded:AddDimension("profession", "profession", { skillLineId = 164 }))
  local expansion = assert(reloaded:AddDimension("expansion", "era", {}))
  assert(reloaded:AddDimension("recipe", 12, {
    professionDimensionId = profession, expansionDimensionId = expansion, name = "Enriched",
  }) == request.recipeDimensionId)
  assert(series.recipeDimensionId == request.recipeDimensionId)
  assert(series.professionDimensionId == nil and series.expansionDimensionId == nil)
  assert(reloaded.dimensionRows.recipe[series.recipeDimensionId].professionDimensionId == profession)
  reloaded:Prune(clock.current + 1000 * 86400)
  assert(reloaded.database.craftSeries[1] == series and series.outputQuantity == 2)
  assert(reloaded.seriesByKey[series.bucketStart][series.characterDimensionId][series.recipeDimensionId] == series)
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
    function(data) data.craftSeries[1].recipeDimensionId = 999 end,
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
    assert(#ledger.database.crafts == 1 and ledger.database.schemaVersion == 1)
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
  assert(ledger:RecordResult({
    operationID = 1, quantity = 1e308, itemID = 100,
    resourcesReturned = { { reagent = { itemID = 101 }, quantity = 1 } },
  }))
  local itemCount = #ledger.database.dimensions.items
  local recipeCount = #ledger.database.dimensions.recipes
  local row = ledger.database.craftSeries[1]
  assert(row.outputQuantity == 1e308 and row.craftCount == 1)

  ledger:BeginCraft(77)
  local rejected, reason = ledger:RecordResult({
    operationID = 2, quantity = 1e308, itemID = 200,
    resourcesReturned = { { reagent = { itemID = 201 }, quantity = 1 } },
  })
  assert(rejected == nil and reason:find("overflow", 1, true))
  assert(#ledger.database.crafts == 1 and ledger.database.nextCraftId == 2)
  assert(#ledger.database.dimensions.items == itemCount)
  assert(#ledger.database.dimensions.recipes == recipeCount)
  assert(ledger.dimensionIndex.item["200"] == nil and ledger.dimensionIndex.item["201"] == nil)
  assert(ledger.pendingRecipeId == 77 and ledger.ambiguousRecipe == nil)
  assert(row.outputQuantity == 1e308 and row.craftCount == 1)

  local recovered = assert(ledger:RecordResult({ operationID = 3, quantity = 1 }))
  assert(recovered.recipeDimensionId == ledger.dimensionIndex.recipe["77"])
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
    assert(data.schemaVersion == 1 and #data.crafts == 1 and data.nextCraftId == 2)
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
  assert(ledger:RecordResult({ operationID = 1, quantity = 1, concentrationSpent = 323,
    hasIngenuityProc = true, ingenuityRefund = 1e308, resourcesReturned = {} }))
  local called = false
  ledger.onCraftCommitted = function() called = true end
  local rejected, reason = ledger:RecordResult({ operationID = 2, quantity = 1, concentrationSpent = 323,
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
  assert(ledger:RecordResult({ operationID = 2, hasIngenuityProc = false, ingenuityRefund = 1e308 }))
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
        assert(data.schemaVersion == 1 and data.craftSeries == series)
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
      assert(data.schemaVersion == 1 and data.craftSeries == series and #data.crafts == 1)
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
  assert(assert(ledger:RecordResult({})).id == maxInteger - 2)
  local second = assert(ledger:SubmitCraft(13, maxInteger, false))
  assert(second.id == maxInteger - 1 and second.requestedCount == maxInteger)
  assert(assert(ledger:RecordResult({})).id == maxInteger - 1)
  assert(ledger.pendingRequest.remaining == maxInteger - 1)
  assert(ledger.database.nextCraftId == maxInteger and ledger.database.nextRequestId == maxInteger)
  ledger:BeginCraft(14)
  unchangedAfter(ledger, function()
    return ledger:RecordResult({ operationID = 1, itemID = 100, quantity = 1 })
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

test("all dimension counters allow their final ID and existing keys still work at exhaustion", function()
  for _, kind in ipairs({ "realm", "character", "profession", "recipe", "item", "session", "expansion" }) do
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

test("result and request preflight collectively reserve distinct item dimensions", function()
  for _, capture in ipairs({ "result", "request" }) do
    local ledger, clock = newLedger()
    assert(ledger:SubmitCraft(12, 2, false))
    ledger:BeginCraft(13)
    ledger.database.nextDimensionId.item = maxInteger - 1
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
    unchangedAfter(ledger, function() return attempt(true) end)
    assert(attempt(false))
    assert(ledger.database.nextDimensionId.item == maxInteger)
    assert(#ledger.database.dimensions.items == 1)
    assert(attempt(false))
    assert(Ledger.New(ledger.database, clock))
  end
end)

test("failed captures cannot enrich existing dimensions or consume pending correlation", function()
  for _, capture in ipairs({ "result", "request" }) do
    local ledger = newLedger()
    local recipe = assert(ledger:AddDimension("recipe", 12))
    local item = assert(ledger:AddDimension("item", 100))
    assert(ledger:AddDimension("item", 101, { gameItemId = 999 }))
    ledger:BeginCraft(12)
    unchangedAfter(ledger, function()
      if capture == "result" then
        return ledger:RecordResult({ operationID = 1, itemID = 100, resourcesReturned = {
          { reagent = { itemID = 101 }, quantity = 1 },
        } })
      end
      return ledger:SubmitCraft(12, 1, false, nil, {
        { dataSlotIndex = 1, quantity = 1, reagent = { itemID = 100 } },
        { dataSlotIndex = 2, quantity = 1, reagent = { itemID = 101 } },
      })
    end)
    assert(ledger.dimensionRows.recipe[recipe].gameRecipeId == nil)
    assert(ledger.dimensionRows.item[item].gameItemId == nil)
  end
  local ledger = newLedger()
  assert(ledger:SubmitCraft(12, 2, false))
  ledger:BeginCraft(13)
  unchangedAfter(ledger, function() return ledger:RecordResult(false) end)
  unchangedAfter(ledger, function() return ledger:RecordResult({ quantity = math.huge }) end)
  ledger.wall = function() return nil end
  unchangedAfter(ledger, function() return ledger:RecordResult({}) end)
end)

test("recipe capacity failures are atomic while existing recipes remain usable", function()
  local ledger, clock = newLedger()
  ledger.database.nextDimensionId.recipe = maxInteger - 1
  ledger:BeginCraft(12)
  local first = assert(ledger:RecordResult({ operationID = 1 }))
  assert(first.recipeDimensionId == maxInteger - 1)
  assert(ledger.database.nextDimensionId.recipe == maxInteger)
  ledger:BeginCraft(13)
  unchangedAfter(ledger, function() return ledger:RecordResult({ operationID = 2, itemID = 100 }) end)
  unchangedAfter(ledger, function()
    return ledger:SubmitCraft(13, 1, false, nil, {
      { dataSlotIndex = 1, quantity = 1, reagent = { itemID = 100 } },
    })
  end)
  ledger:CancelCraft()
  ledger:BeginCraft(12)
  assert(assert(ledger:RecordResult({ operationID = 2 })).recipeDimensionId == first.recipeDimensionId)
  assert(ledger:SubmitCraft(12, 1, false))
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
    ledger:BeginCraft(13)
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
    function(data, value) data.nextDimensionId.item = value end,
    function(data, value) data.crafts[1].id = value end,
    function(data, value) data.crafts[1].sessionDimensionId = value end,
    function(data, value) data.crafts[1].requestId = value end,
    function(data, value) data.requests[1].id = value end,
    function(data, value) data.requests[1].requestedCount = value end,
    function(data, value) data.requests[1].allocations[1].dataSlotIndex = value end,
    function(data, value) data.requests[1].allocations[1].allocatedQuantity = value end,
    function(data, value) data.reagents[1].allocatedQuantity = value end,
    function(data, value) data.reagents[1].dataSlotIndex = value end,
    function(data, value) data.dimensions.items[1].id = value end,
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
      assert(ledger:RecordResult({ quantity = 0, hasIngenuityProc = true, ingenuityRefund = 0 }))
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
  assert(ledger.database.reagents[1].returnedQuantity == -0.25)
  local reloaded = assert(Ledger.New(ledger.database, clock))
  assert(reloaded.database.craftSeries[1].ingenuityRefund == -0.75)
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

print(string.format("%d ledger tests passed", passed))