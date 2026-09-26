local root = arg[1] or "."
local addon = {}
assert(loadfile(root .. "/Storage/Ledger.lua"))("ArtisanLogbook", addon)
local Ledger = addon.Ledger
local fixture = assert(loadfile(root .. "/tests/fixtures/retail-build-69933.lua"))()
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
  local legacy = {
    schemaVersion = 0,
    nextCraftId = 6,
    crafts = { { id = 5 } },
    reagents = {},
    dimensions = {},
    nextDimensionId = {},
  }
  local migrated = assert(Ledger.New(legacy, { wall = function() return 1800000000 end }))
  assert(migrated.database.schemaVersion == Ledger.schemaVersion)
  assert(migrated.database.crafts[1].id == 5 and migrated.database.nextCraftId == 6)
  migrated:CreateSession({})
  assert(assert(migrated:RecordResult({})).id == 6)
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

print(string.format("%d ledger tests passed", passed))