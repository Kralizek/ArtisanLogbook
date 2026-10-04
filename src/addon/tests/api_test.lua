local root = arg[1] or "src/ArtisanLogbook"
local testsRoot = arg[2] or "tests"
local passed = 0
local function test(name, callback)
  callback()
  passed = passed + 1
  print("PASS " .. name)
end

local function equal(actual, expected)
  assert(type(actual) == type(expected), "different types: " .. type(actual) .. "/" .. type(expected))
  if type(expected) ~= "table" then assert(actual == expected); return end
  for key, value in pairs(expected) do equal(actual[key], value) end
  for key in pairs(actual) do assert(expected[key] ~= nil, "unexpected field: " .. tostring(key)) end
end

local function newLedger(options)
  local addon = {}
  assert(loadfile(root .. "/Storage/Ledger.lua"))("ArtisanLogbook", addon)
  assert(loadfile(root .. "/Core/API.lua"))("ArtisanLogbook", addon)
  local clock = { current = 1800000000 }
  function clock.wall() return clock.current end
  addon.ledger = assert(addon.Ledger.New(nil, clock, options))
  addon.ledger.onCraftCommitted = addon.PublishCraftCommitted
  addon.adapter = { capabilities = { flavor = "retail",
    events = { TRADE_SKILL_ITEM_CRAFTED_RESULT = true },
    hooks = { CraftRecipe = true }, quoteHooks = { GetCraftingOperationInfo = true } } }
  return addon.ledger, ArtisanLogbookAPI, clock, addon
end

local function session(ledger, name, realmId)
  return assert(ledger:CreateSession({ startedAt = ledger.wall(), projectId = 1, regionId = 3,
    gameRealmId = realmId, realmName = "Realm " .. realmId, characterName = name,
    characterGUID = "Player-" .. name }))
end

local function fixture(options)
  local ledger, api, clock, addon = newLedger(options)
  local midnight = assert(ledger:AddDimension("expansion", "midnight", { name = "Midnight", chronologicalOrder = 11 }))
  local legion = assert(ledger:AddDimension("expansion", "legion", { name = "Legion", chronologicalOrder = 6 }))
  local alchemy = assert(ledger:AddDimension("profession", 171, { name = "Alchemy" }))
  local enchanting = assert(ledger:AddDimension("profession", 333, { name = "Enchanting" }))
  assert(ledger:AddDimension("recipe", 101, { name = "Potion",
    expansionDimensionId = midnight, professionId = alchemy }))
  assert(ledger:AddDimension("recipe", 102, { name = "Enchant",
    expansionDimensionId = midnight, professionId = enchanting }))
  assert(ledger:AddDimension("recipe", 103, { name = "Old potion",
    expansionDimensionId = legion, professionId = alchemy }))
  assert(ledger:AddDimension("item", 201, { name = "Output",
    expansionDimensionId = legion }))
  assert(ledger:AddDimension("item", 202, { name = "Reagent",
    expansionDimensionId = legion }))
  session(ledger, "A", 1)
  assert(ledger:SubmitCraft(101, 1, false,
    { concentrationCost = 0, baseSkill = 10, baseDifficulty = 20, craftingQuality = 0 },
    { { dataSlotIndex = 1, quantity = 3, quality = 0, reagent = { itemID = 202 } } }))
  assert(ledger:RecordResult({ operationID = 0, itemID = 201, quantity = 5, craftingQuality = 0,
    itemLevel = 0, multicraft = 0, concentrationSpent = 0, concentrationCurrencyID = 0,
    hasIngenuityProc = false, ingenuityRefund = 9, resourcesReturned = {} }))
  clock.current = clock.current + 1
  session(ledger, "B", 1)
  ledger:BeginCraft(102)
  assert(ledger:RecordResult({ operationID = 2, itemID = 201 }))
  clock.current = clock.current + 1
  session(ledger, "C", 2)
  ledger:BeginCraft(103)
  assert(ledger:RecordResult({ operationID = 3 }))
  session(ledger, "A", 1)
  ledger:BeginCraft(104)
  assert(ledger:RecordResult({ operationID = 4 }))
  clock.current = clock.current + 1
  assert(ledger:RecordResult({}))
  ledger:BeginCraft(101)
  assert(ledger:RecordResult({ operationID = 6 }))
  return ledger, api, clock, addon
end

local function ids(page)
  local result = {}
  for _, craft in ipairs(assert(page).crafts) do result[#result + 1] = craft.id end
  return result
end

local function errorIs(code, value, reason)
  assert(value == nil and reason == code, tostring(reason) .. " instead of " .. code)
end

test("recipe outcomes summarize durable evidence with bounded charts and factual returns", function()
  local ledger, api, clock, addon = newLedger({ retentionDays = 1 })
  session(ledger, "A", 1)
  local from = math.floor(clock.current / 86400) * 86400
  local function record(recipeId, result)
    assert(ledger:SubmitCraft(recipeId, 1, false))
    return assert(ledger:RecordResult(result))
  end
  record(101, { quantity = 5, multicraft = 0, resourcesReturned = {}, hasIngenuityProc = false, ingenuityRefund = 90 })
  record(101, { quantity = 8, multicraft = 3, resourcesReturned = {
    { reagent = { itemID = 9 }, quantity = 2 }, { reagent = { itemID = 8 }, quantity = 1 },
  }, hasIngenuityProc = true, ingenuityRefund = 20 })
  record(101, {})
  local character = api.GetCharacters()[1].key
  clock.current = clock.current + 3 * 86400
  session(ledger, "B", 1)
  record(101, { resourcesReturned = { { reagent = { itemID = 8 }, quantity = 4 } } })
  record(102, { quantity = 99, resourcesReturned = { { reagent = { itemID = 10 }, quantity = 99 } } })
  local all = assert(api.GetRecipeOutcomes(101, nil, { buckets = 2 }))
  assert(all.totals.craftCount == 4 and #all.series == 2 and all.bucketSeconds == 2 * 86400)
  assert(all.totals.multicraftProcCount == 1 and all.totals.multicraftProcCountObservedCount == 2)
  assert(all.totals.multicraftBonus == 3 and all.totals.outputQuantity == 13)
  assert(all.totals.ingenuityRefund == 20 and all.totals.ingenuityRefundObservedCount == 2)
  assert(all.totals.resourcefulnessProcCount == 2 and all.totals.resourcefulnessProcCountObservedCount == 3)
  assert(api.GetRecipeOutcomes(101, { characters = { character } }).totals.craftCount == 3)
  assert(api.GetRecipeOutcomes(101, { characters = {} }).totals.craftCount == 0)
  assert(api.GetRecipeOutcomes(101, { time = { from = from, to = from + 86400 } }).totals.craftCount == 3)
  assert(api.GetRecipeOutcomes(101, { time = { from = from, to = from } }).totals.craftCount == 0)
  local page = assert(api.GetRecipeReturnSets(101, nil, { limit = 1 }))
  equal(page.returns, { { itemIds = { 8 }, craftCount = 1 } })
  assert(page.nextCursor)
  local last = assert(api.GetRecipeReturnSets(101, nil, { limit = 1, cursor = page.nextCursor }))
  equal(last.returns, { { itemIds = { 8, 9 }, craftCount = 1 } })
  assert(last.nextCursor == nil)
  equal(api.GetRecipeReturnedReagents(101).returns, {
    { item = { id = 8 }, returnedQuantity = 5 }, { item = { id = 9 }, returnedQuantity = 2 },
  })
  equal(api.GetRecipeReturnedReagents(101, { characters = { character } }).returns, {
    { item = { id = 8 }, returnedQuantity = 1 }, { item = { id = 9 }, returnedQuantity = 2 },
  })
  page.returns[1].itemIds[1] = 999
  assert(api.GetRecipeReturnSets(101).returns[1].itemIds[1] == 8)
  clock.current = clock.current + 86401
  addon.ledger = assert(addon.Ledger.New(ledger.database, clock))
  assert(#addon.ledger.database.crafts == 0)
  equal(api.GetRecipeOutcomes(101, nil, { buckets = 2 }), all)
  assert(api.GetRecipeReturnedReagents(101).returns[1].returnedQuantity == 5)
  local empty = api.GetRecipeOutcomes(999)
  assert(empty.totals.craftCount == 0 and empty.totals.resourcefulnessProcCount == nil)
  assert(empty.totals.resourcefulnessProcCountObservedCount == 0 and #empty.series == 0)
  errorIs("invalid-id", api.GetRecipeOutcomes(-1))
  errorIs("invalid-filter", api.GetRecipeOutcomes(101, { time = { from = 1 } }))
  errorIs("invalid-filter", api.GetRecipeOutcomes(101, { recipes = { 101 } }))
  errorIs("invalid-options", api.GetRecipeOutcomes(101, nil, { buckets = 201 }))
  errorIs("invalid-options", api.GetRecipeOutcomes(101, nil, false))
  errorIs("invalid-options", api.GetRecipeReturnSets(101, nil, false))
  errorIs("invalid-options", api.GetRecipeReturnSets(101, nil, { limit = 201 }))
  errorIs("invalid-cursor", api.GetRecipeReturnSets(102, nil, { cursor = page.nextCursor }))
  errorIs("invalid-cursor", api.GetRecipeReturnedReagents(101, nil, { cursor = page.nextCursor }))
  errorIs("invalid-cursor", api.GetRecipeReturnSets(101, { characters = {} }, { cursor = page.nextCursor }))
end)

test("returned materials total each item identity across characters days and small pages", function()
  local ledger, api, clock, addon = newLedger({ retentionDays = 1 })
  local start = math.floor(clock.current / 86400) * 86400
  session(ledger, "A", 1)
  local function record(itemId, quantity)
    assert(ledger:AddDimension("item", itemId, { name = "Same-named herb" }))
    assert(ledger:SubmitCraft(101, 1, false))
    assert(ledger:RecordResult({ resourcesReturned = { { reagent = { itemID = itemId }, quantity = quantity } } }))
  end
  for itemId = 12, 8, -1 do record(itemId, itemId) end
  record(8, 2)
  local character = api.GetCharacters()[1].key
  clock.current = clock.current + 86400
  session(ledger, "B", 1)
  for itemId = 8, 12 do record(itemId, 3) end
  local function verify(filter, expected)
    local cursor, seen = nil, {}
    repeat
      local page = assert(api.GetRecipeReturnedReagents(101, filter, { limit = 1, cursor = cursor }))
      assert(#page.returns <= 1)
      for _, row in ipairs(page.returns) do
        assert(not seen[row.item.id], "duplicate material identity across pages")
        assert(row.item.name == "Same-named herb")
        seen[row.item.id] = row.returnedQuantity
      end
      cursor = page.nextCursor
    until not cursor
    equal(seen, expected)
  end
  verify(nil, { [8] = 13, [9] = 12, [10] = 13, [11] = 14, [12] = 15 })
  verify({ characters = { character } }, { [8] = 10, [9] = 9, [10] = 10, [11] = 11, [12] = 12 })
  verify({ time = { from = start + 86400, to = start + 2 * 86400 } },
    { [8] = 3, [9] = 3, [10] = 3, [11] = 3, [12] = 3 })
  clock.current = clock.current + 2 * 86400
  addon.ledger = assert(addon.Ledger.New(ledger.database, clock))
  assert(#addon.ledger.database.crafts == 0)
  verify(nil, { [8] = 13, [9] = 12, [10] = 13, [11] = 14, [12] = 15 })
end)

test("legacy positive evidence is separate from complete return coverage in recipe queries", function()
  local ledger, api, clock, addon = newLedger()
  session(ledger, "A", 1)
  assert(ledger:SubmitCraft(101, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 8 } },
    { dataSlotIndex = 2, quantity = 2, reagent = { itemID = 9 } },
  }))
  assert(ledger:RecordResult({ resourcesReturned = {
    { reagent = { itemID = 8 }, quantity = 1 }, { reagent = { itemID = 9 } },
  } }))
  local data = ledger.database
  data.outcomeVersion, data.resourcefulnessSets, data.returnedReagents = nil, nil, nil
  for _, craft in ipairs(data.crafts) do craft.hasResourcefulnessProc, craft.resourcefulnessComplete = nil, nil end
  for _, row in ipairs(data.craftSeries) do
    for _, metric in ipairs({ "multicraftProcCount", "resourcefulnessProcCount", "resourcefulnessCompleteProcCount" }) do
      row[metric], row[metric .. "ObservedCount"] = nil, nil
    end
  end
  addon.ledger = assert(addon.Ledger.New(data, clock))
  local totals = api.GetRecipeOutcomes(101).totals
  assert(totals.resourcefulnessProcCount == 1 and totals.resourcefulnessProcCountObservedCount == 1)
  assert(totals.resourcefulnessCompleteProcCount == nil and totals.resourcefulnessCompleteProcCountObservedCount == 0)
  assert(#api.GetRecipeReturnSets(101).returns == 0)
  assert(api.GetRecipeReturnedReagents(101).returns[1].returnedQuantity == 1)
  session(addon.ledger, "A", 1)
  assert(addon.ledger:SubmitCraft(101, 1, false))
  assert(addon.ledger:RecordResult({ resourcesReturned = {} }))
  totals = api.GetRecipeOutcomes(101).totals
  assert(totals.resourcefulnessProcCount == 1 and totals.resourcefulnessProcCountObservedCount == 2)
  assert(totals.resourcefulnessCompleteProcCount == 0 and totals.resourcefulnessCompleteProcCountObservedCount == 1)
  clock.current = clock.current + 61 * 86400
  addon.ledger = assert(addon.Ledger.New(addon.ledger.database, clock))
  equal(api.GetRecipeOutcomes(101).totals, totals)
end)

test("recipe outcome queries never scan craft history or unrelated daily recipes", function()
  local ledger, api, clock = newLedger()
  session(ledger, "A", 1)
  for index = 1, 205 do
    assert(ledger:SubmitCraft(101, 1, false))
    assert(ledger:RecordResult({ resourcesReturned = { { reagent = { itemID = index }, quantity = 2 } } }))
  end
  local oldPairs, oldIpairs = pairs, ipairs
  local forbidden = { [ledger.database.crafts] = true, [ledger.database.reagents] = true,
    [ledger.database.craftSeries] = true, [ledger.database.resourcefulnessSets] = true,
    [ledger.database.returnedReagents] = true }
  pairs = function(rows) assert(not forbidden[rows]); return oldPairs(rows) end
  ipairs = function(rows) assert(not forbidden[rows]); return oldIpairs(rows) end
  local ok, reason = pcall(function()
    local page = assert(api.GetRecipeReturnedReagents(101, nil, { limit = 200 }))
    assert(#page.returns == 200 and page.nextCursor)
    local last = assert(api.GetRecipeReturnedReagents(101, nil, { limit = 200, cursor = page.nextCursor }))
    assert(#last.returns == 5 and not last.nextCursor)
    assert(api.GetRecipeOutcomes(101).totals.resourcefulnessProcCount == 205)
    assert(#api.GetRecipeReturnSets(101, nil, { limit = 200 }).returns == 200)
  end)
  pairs, ipairs = oldPairs, oldIpairs
  assert(ok, reason)
end)

test("GetCraft has an explicit denormalized shape and preserves zero and false", function()
  local _, api = fixture()
  local craft = assert(api.GetCraft(1))
  local realm = { key = "project:1:region:3:realm:1", name = "Realm 1", identityScope = "runtime",
    projectId = 1, regionId = 3, gameRealmId = 1 }
  local expansion = { key = "midnight", name = "Midnight", chronologicalOrder = 11 }
  local oldExpansion = { key = "legion", name = "Legion", chronologicalOrder = 6 }
  local profession = { skillLineId = 171, name = "Alchemy" }
  local recipe = { id = 101, name = "Potion", expansion = expansion, profession = profession }
  local reagentItem = { id = 202, name = "Reagent", expansion = oldExpansion }
  equal(craft, {
    id = 1, timestamp = 1800000000, gameOperationId = 0,
    character = { key = realm.key .. ":guid:Player-A", name = "A", guid = "Player-A", realm = realm },
    realm = realm, profession = profession, recipe = recipe, expansion = expansion,
    outputItem = { id = 201, name = "Output", expansion = oldExpansion },
    outputQuality = 0, outputQuantity = 5, outputItemLevel = 0, multicraftBonus = 0,
    concentrationSpent = 0, concentrationCurrencyId = 0, hasIngenuityProc = false, ingenuityRefund = 9,
    request = { id = 1, timestamp = 1800000000, requestedCount = 1, useConcentration = false,
      concentrationCost = 0, baseSkill = 10, baseDifficulty = 20, craftingQuality = 0, recipe = recipe,
      allocations = { { dataSlotIndex = 1, item = reagentItem, allocatedQuantity = 3, quality = 0 } } },
    reagents = { { dataSlotIndex = 1, item = reagentItem, allocatedQuantity = 3, returnedQuantity = 0, quality = 0 } },
  })
  local unknown = assert(api.GetCraft(5))
  assert(unknown.recipe == nil and unknown.request == nil and unknown.outputItem == nil)
  assert(unknown.outputQuantity == nil and unknown.hasIngenuityProc == nil and unknown.ingenuityRefund == nil)
  equal(unknown.reagents, {})
  errorIs("not-found", api.GetCraft(999))
  errorIs("invalid-id", api.GetCraft(0))
end)

test("GetCrafts shares projection semantics and all nested values are detached", function()
  local ledger, api = fixture()
  for _, craft in ipairs(api.GetCrafts().crafts) do equal(craft, api.GetCraft(craft.id)) end
  local original = api.GetCraft(1)
  local function vandalize(value)
    for key, child in pairs(value) do
      if type(child) == "table" then vandalize(child) else value[key] = "mutated" end
    end
    value.injected = true
  end
  vandalize(api.GetCraft(1))
  vandalize(api.GetCrafts().crafts)
  equal(api.GetCraft(1), original)
  assert(ledger.database.requests[1].useConcentration == false)
  local recipeRow = ledger.database.dimensions.recipes[101]
  assert(ledger:AddDimension("recipe", recipeRow.id, { internalOnly = { secretSchema = true } }))
  equal(api.GetCraft(1), original)
end)

test("shared time filtering is absolute and half-open", function()
  local _, api = fixture()
  equal(ids(api.GetCrafts({ time = { from = 1800000001, to = 1800000003 } })), { 4, 3, 2 })
  equal(ids(api.GetCrafts({ time = { from = 1800000003 } })), { 6, 5 })
  equal(ids(api.GetCrafts({ time = { to = 1800000001 } })), { 1 })
  equal(ids(api.GetCrafts({ time = { from = 1800000000, to = 1800000000 } })), {})
  assert(api.GetFacets({ time = { to = 1800000001 } }).recipes[1].count == 1)
end)

test("all dimensions filter by public identities with OR within and AND across", function()
  local _, api = fixture()
  local a, b, c = api.GetCraft(1), api.GetCraft(2), api.GetCraft(3)
  equal(ids(api.GetCrafts({ characters = { a.character.key } })), { 6, 5, 4, 1 })
  equal(ids(api.GetCrafts({ realms = { c.realm.key } })), { 3 })
  equal(ids(api.GetCrafts({ professions = { 171 } })), { 6, 3, 1 })
  equal(ids(api.GetCrafts({ recipes = { 102, 104 } })), { 4, 2 })
  equal(ids(api.GetCrafts({ characters = { a.character.key, b.character.key },
    expansions = { "midnight" }, professions = { 171, 333 } })), { 6, 2, 1 })
  equal(ids(api.GetCrafts({ characters = { c.character.key }, expansions = { "midnight" } })), {})
  equal(ids(api.GetCrafts({ recipes = {} })), {})
end)

test("expansion comes only from attributed recipe metadata, never items or runtime", function()
  local _, api = fixture()
  assert(api.GetCraft(1).outputItem.expansion.key == "legion")
  equal(ids(api.GetCrafts({ expansions = { "midnight" } })), { 6, 2, 1 })
  equal(ids(api.GetCrafts({ expansions = { "legion" } })), { 3 })
  assert(api.GetCraft(4).recipe.id == 104 and api.GetCraft(4).expansion == nil)
  assert(api.GetCraft(5).recipe == nil and api.GetCraft(5).expansion == nil)
end)

test("deterministic bidirectional paging uses timestamp then ID and excludes new commits", function()
  local ledger, api, clock = fixture()
  equal(ids(api.GetCrafts(nil, { direction = "asc" })), { 1, 2, 3, 4, 5, 6 })
  for _, direction in ipairs({ "asc", "desc" }) do
    local all, cursor = {}, nil
    repeat
      local page = assert(api.GetCrafts(nil, { direction = direction, limit = 2, cursor = cursor }))
      for _, id in ipairs(ids(page)) do all[#all + 1] = id end
      cursor = page.nextCursor
    until not cursor
    equal(all, direction == "asc" and { 1, 2, 3, 4, 5, 6 } or { 6, 5, 4, 3, 2, 1 })
  end
  local page = api.GetCrafts(nil, { direction = "asc", limit = 2 })
  clock.current = clock.current + 1
  assert(ledger:RecordResult({}))
  equal(ids(api.GetCrafts(nil, { direction = "asc", cursor = page.nextCursor })), { 3, 4, 5, 6 })
  local filtered = api.GetCrafts({ recipes = { 101, 102 } }, { limit = 1 })
  equal(ids(api.GetCrafts({ recipes = { 102, 101, 101 } }, { cursor = filtered.nextCursor })), { 2, 1 })
end)

test("page size defaults and hard bounds", function()
  local ledger, api = newLedger()
  session(ledger, "A", 1)
  for _ = 1, 205 do assert(ledger:RecordResult({})) end
  assert(#api.GetCrafts().crafts == 50)
  local page = api.GetCrafts(nil, { limit = 200 })
  assert(#page.crafts == 200 and page.nextCursor)
  local last = api.GetCrafts(nil, { limit = 200, cursor = page.nextCursor })
  assert(#last.crafts == 5 and last.nextCursor == nil)
end)

test("invalid filters, paging and facet options fail explicitly", function()
  local _, api = fixture()
  for _, options in ipairs({ false, 2, { limit = 0 }, { limit = 201 }, { limit = 1.5 },
    { limit = false }, { direction = "random" }, { direction = false }, { offset = 1 }, { mode = "strict" } }) do
    errorIs("invalid-options", api.GetCrafts(nil, options))
  end
  for _, cursor in ipairs({ false, {}, "", "garbage", "1:desc:6:7:1800000000:||-|-|-|-|-",
    "1:desc:6:1:nan:||-|-|-|-|-", "1:desc:999:1:1800000000:||-|-|-|-|-",
    "1:desc:6:1:inf:||-|-|-|-|-" }) do
    errorIs("invalid-cursor", api.GetCrafts(nil, { cursor = cursor }))
  end
  local cursor = api.GetCrafts(nil, { limit = 1 }).nextCursor
  errorIs("invalid-cursor", api.GetCrafts({ recipes = { 101 } }, { cursor = cursor }))
  errorIs("invalid-cursor", api.GetCrafts(nil, { cursor = cursor, direction = "asc" }))
  for _, filter in ipairs({ false, 5, { recipe = 101 }, { concentration = true }, { limit = 5 },
    { context = "personal" }, { time = { from = 2, to = 1 } }, { time = { from = math.huge } },
    { time = { to = 0 / 0 } }, { time = { from = false } }, { time = { days = 30 } },
    { recipes = 101 }, { recipes = { "101" } }, { recipes = { [2] = 101 } },
    { characters = { 1 } }, { realms = { "" } }, { professions = { -1 } },
    { expansions = setmetatable({}, {}) } }) do
    errorIs("invalid-filter", api.GetCrafts(filter))
    errorIs("invalid-filter", api.GetFacets(filter))
  end
  for _, options in ipairs({ false, { mode = false }, { mode = "other" }, { limit = 1 },
    { direction = "asc" }, { cursor = cursor } }) do
    errorIs("invalid-options", api.GetFacets(nil, options))
  end
end)

test("facets count retained crafts only, sort by identity, and return detached domain details", function()
  local ledger, api = fixture()
  assert(ledger:AddDimension("expansion", "unused", { name = "Unused" }))
  local result = api.GetFacets()
  equal(result.professions, {
    { value = 171, count = 3, details = { skillLineId = 171, name = "Alchemy" } },
    { value = 333, count = 1, details = { skillLineId = 333, name = "Enchanting" } },
  })
  assert(#result.characters == 3 and result.characters[1].count == 4)
  assert(#result.realms == 2 and result.realms[1].count == 5)
  assert(#result.expansions == 2 and result.expansions[1].value == "legion")
  assert(result.expansions[2].value == "midnight" and result.expansions[2].count == 3)
  assert(#result.recipes == 4 and result.recipes[1].value == 101 and result.recipes[1].count == 2)
  assert(result.recipes[1].details.id == 101 and result.recipes[1].details.profession.skillLineId == 171)
  assert(result.recipes[1].details.key == nil and result.recipes[1].details.professionId == nil)
  result.recipes[1].details.expansion.name = "Changed"
  result.characters[1].details.realm.name = "Changed"
  assert(api.GetCraft(1).expansion.name == "Midnight" and api.GetCraft(1).realm.name == "Realm 1")
end)

test("recipe summaries use durable counts and alphabetical bounded pages", function()
  local ledger, api = fixture()
  local first = assert(api.GetRecipeSummaries({ limit = 2 }))
  assert(#first.recipes == 2 and first.recipes[1].recipe.name == "Enchant")
  assert(first.recipes[1].craftCount == 1 and first.recipes[2].recipe.name == "Old potion")
  local second = assert(api.GetRecipeSummaries({ limit = 2, cursor = first.nextCursor }))
  assert(second.recipes[1].recipe.name == "Potion" and second.recipes[1].craftCount == 2)
  assert(second.recipes[2].recipe.name == "Recipe #104")
  assert(second.nextCursor == nil)
  first.recipes[1].recipe.name = "Changed"
  assert(api.GetRecipeSummaries({ limit = 1 }).recipes[1].recipe.name == "Enchant")
  ledger:Prune(ledger.wall() + 86400 * 61)
  assert(#api.GetCrafts().crafts == 0)
  assert(api.GetRecipeSummaries().recipes[3].craftCount == 2)
  errorIs("invalid-options", api.GetRecipeSummaries({ limit = 201 }))
  errorIs("invalid-cursor", api.GetRecipeSummaries({ cursor = "invalid" }))
end)

test("recipe summary filters and count sort page durable character totals", function()
  local ledger, api = fixture()
  local characterKey = api.GetCraft(1).character.key
  local first = assert(api.GetRecipeSummaries({ character = characterKey,
    sort = "count", limit = 1 }))
  assert(#first.recipes == 1 and first.recipes[1].recipe.id == 101)
  assert(first.recipes[1].craftCount == 2 and first.nextCursor == "1")
  local second = assert(api.GetRecipeSummaries({ character = characterKey,
    sort = "count", cursor = first.nextCursor, limit = 1 }))
  assert(second.recipes[1].recipe.id == 104 and second.recipes[1].craftCount == 1)
  assert(second.nextCursor == nil)
  assert(#api.GetRecipeSummaries({ character = characterKey, profession = 171 }).recipes == 1)
  local all = assert(api.GetRecipeSummaries({ sort = "count" }))
  assert(all.recipes[1].recipe.id == 101 and all.recipes[1].craftCount == 2)
  assert(#api.GetRecipeSummaries({ character = "missing" }).recipes == 0)
  errorIs("invalid-cursor", api.GetRecipeSummaries({ character = "missing", cursor = "1" }))
  for _, options in ipairs({ { character = false }, { profession = -1 }, { sort = "recent" } }) do
    errorIs("invalid-options", api.GetRecipeSummaries(options))
  end
  ledger:Prune(ledger.wall() + 86400 * 61)
  assert(api.GetRecipeSummaries({ character = characterKey, profession = 171,
    sort = "count" }).recipes[1].craftCount == 2)
end)

test("first craft for an existing recipe invalidates the catalogue order", function()
  local ledger, api = fixture()
  assert(ledger:AddDimension("recipe", 105))
  assert(#api.GetRecipeSummaries().recipes == 4)
  ledger:BeginCraft(105)
  assert(ledger:RecordResult({ operationID = 99 }))
  assert(#api.GetRecipeSummaries().recipes == 5)
  assert(ledger:AddDimension("recipe", 105, { name = "A new recipe" }))
  local result = api.GetRecipeSummaries({ limit = 1 })
  assert(result.recipes[1].recipe.id == 105 and result.recipes[1].craftCount == 1)
end)

test("observed identities follow durable indexes across enrichment, pruning, reload and clear", function()
  local ledger, api, clock, addon = fixture()
  assert(api.GetVersion() == 1)
  local first = api.GetCraft(1).character.key
  local second = api.GetCraft(2).character.key
  local characters = assert(api.GetCharacters())
  assert(#characters == 3 and #api.GetProfessions() == 2)
  equal(api.GetProfessions(first), { { skillLineId = 171, name = "Alchemy" } })
  assert(api.GetProfessions(second)[1].skillLineId == 333)
  assert(#api.GetProfessions("missing-character") == 0)
  errorIs("invalid-filter", api.GetProfessions(false))
  errorIs("invalid-filter", api.GetProfessions(""))
  characters[1].name = "Changed"
  assert(api.GetCharacters()[1].name ~= "Changed")

  assert(ledger:AddDimension("recipe", 105))
  ledger:BeginCraft(105)
  assert(ledger:RecordResult({ operationID = 99 }))
  local newProfession = assert(ledger:AddDimension("profession", 444, { name = "Inscription" }))
  assert(ledger:AddDimension("recipe", 105, { professionId = newProfession }))
  assert(#api.GetProfessions(first) == 2)
  assert(ledger:AddDimension("profession", 444))
  assert(api.GetProfessions(first)[2].skillLineId == 444)

  ledger:Prune(clock.current + 61 * 86400)
  assert(#api.GetCrafts().crafts == 0)
  assert(#api.GetCharacters() == 3 and #api.GetProfessions(first) == 2)
  addon.ledger = assert(addon.Ledger.New(ledger.database, clock))
  assert(#api.GetCharacters() == 3 and #api.GetProfessions(first) == 2)
  assert(addon.ledger:ClearHistory())
  assert(#api.GetCharacters() == 0 and #api.GetProfessions() == 0)
  session(addon.ledger, "A", 1)
  addon.ledger:BeginCraft(105)
  assert(addon.ledger:RecordResult({ operationID = 100 }))
  assert(api.GetProfessions(first)[1].skillLineId == 444)
end)

test("self-excluding facets remove only their own selection; strict applies all selections", function()
  local _, api = fixture()
  local filter = { expansions = { "midnight" }, professions = { 171 } }
  local excluding = api.GetFacets(filter)
  assert(#excluding.professions == 2 and excluding.professions[1].count == 2)
  assert(#excluding.expansions == 2 and excluding.expansions[1].value == "legion")
  assert(#excluding.recipes == 1 and excluding.recipes[1].value == 101)
  local strict = api.GetFacets(filter, { mode = "strict" })
  assert(#strict.professions == 1 and strict.professions[1].count == 2)
  assert(#strict.expansions == 1 and strict.expansions[1].value == "midnight")
  for _, facet in ipairs({ "characters", "realms", "expansions", "professions", "recipes" }) do
    local values = api.GetFacets()[facet]
    local selection = { [facet] = { values[1].value } }
    equal(api.GetFacets(selection)[facet], values)
    assert(#api.GetFacets(selection, { mode = "strict" })[facet] == 1)
  end
  assert(#api.GetFacets({ recipes = {} }).recipes == 4)
  assert(#api.GetFacets({ recipes = {} }, { mode = "strict" }).recipes == 0)
end)

test("capabilities describe runtime support, not retained history", function()
  local _, api, _, addon = fixture()
  equal(api.GetCapabilities(), { flavor = "retail", craftResults = true,
    personalRequests = true, reagentAllocations = true })
  local history = api.GetFacets()
  addon.adapter.capabilities = { flavor = "classic", events = {}, hooks = {}, measurements = {} }
  local capabilities = api.GetCapabilities()
  equal(capabilities, { flavor = "classic", craftResults = false, personalRequests = false, reagentAllocations = false })
  capabilities.flavor = "Changed"
  equal(api.GetFacets(), history)
  assert(api.GetCapabilities().flavor == "classic" and api.GetCraft(1).hasIngenuityProc == false)
end)

test("callbacks isolate failures and mutations, deliver one projection per commit, and unsubscribe", function()
  local ledger, api = fixture()
  errorIs("invalid-event", api.RegisterCallback("REQUEST_SUBMITTED", function() end))
  errorIs("invalid-callback", api.RegisterCallback("CRAFT_COMMITTED", false))
  local calls, second, third = 0
  local stop = assert(api.RegisterCallback("CRAFT_COMMITTED", function(craft)
    assert(api.GetCraft(craft.id))
    craft.recipe.name = "Changed"
    craft.request.allocations[1].item.name = "Changed"
    craft.reagents[1].allocatedQuantity = 999
    error("consumer failure")
  end))
  local stopSecond = api.RegisterCallback("CRAFT_COMMITTED", function(craft) second = craft; calls = calls + 1 end)
  api.RegisterCallback("CRAFT_COMMITTED", function(craft) third = craft end)
  assert(ledger:SubmitCraft(101, 1, false, nil,
    { { dataSlotIndex = 1, quantity = 3, reagent = { itemID = 202 } } }))
  local craft = assert(ledger:RecordResult({ itemID = 201, resourcesReturned = {} }))
  assert(calls == 1 and second.recipe.name == "Potion")
  equal(second, api.GetCraft(craft.id))
  equal(second, third)
  second.request.allocations[1].item.name = "Changed"
  assert(third.request.allocations[1].item.name == "Reagent")
  stop(); stop(); stopSecond()
  assert(ledger:RecordResult({}))
  assert(calls == 1 and third.id == craft.id + 1)
end)

test("subscription changes take effect on the next event", function()
  local ledger, api = fixture()
  local calls, stopSecond = {}, nil
  local stopFirst = api.RegisterCallback("CRAFT_COMMITTED", function()
    calls[#calls + 1] = "first"
    stopSecond()
    api.RegisterCallback("CRAFT_COMMITTED", function() calls[#calls + 1] = "new" end)
  end)
  stopSecond = api.RegisterCallback("CRAFT_COMMITTED", function() calls[#calls + 1] = "second" end)
  assert(ledger:RecordResult({}))
  equal(calls, { "first", "second" })
  stopFirst()
  assert(ledger:RecordResult({}))
  equal(calls, { "first", "second", "new" })
end)

test("startup pruning and index rebuild preserve projections and pruned cursor anchors", function()
  local ledger, api, clock, addon = fixture()
  local page = api.GetCrafts(nil, { direction = "asc", limit = 2 })
  local expected = api.GetCraft(6)
  clock.current = 1800000002 + ledger.database.retentionDays * 86400
  addon.ledger = assert(addon.Ledger.New(ledger.database, clock))
  errorIs("not-found", api.GetCraft(1))
  equal(ids(api.GetCrafts(nil, { direction = "asc", cursor = page.nextCursor })), { 3, 4, 5, 6 })
  equal(api.GetCraft(6), expected)
  assert(api.GetFacets().recipes[1].count == 1)
  clock.current = clock.current + 181 * 86400
  addon.ledger = assert(addon.Ledger.New(addon.ledger.database, clock))
  equal(api.GetCrafts(), { crafts = {} })
  equal(api.GetFacets(), { characters = {}, realms = {}, expansions = {}, professions = {}, recipes = {} })
end)

test("capture does not prune old history until the next startup", function()
  local ledger, api, clock, addon = fixture()
  local received
  api.RegisterCallback("CRAFT_COMMITTED", function(craft) received = craft end)
  clock.current = clock.current + 181 * 86400
  assert(ledger:SubmitCraft(101, 1, false, nil,
    { { dataSlotIndex = 1, quantity = 3, reagent = { itemID = 202 } } }))
  local committed = assert(ledger:RecordResult({ resourcesReturned = {} }))
  assert(received.id == committed.id and received.request.id and received.reagents[1].returnedQuantity == 0)
  assert(api.GetCraft(1) and api.GetCraft(committed.id))
  addon.ledger = assert(addon.Ledger.New(ledger.database, clock))
  errorIs("not-found", api.GetCraft(1))
  equal(api.GetCraft(committed.id), received)
end)

test("GetCraft and callbacks use direct lookups without traversing history", function()
  local ledger, api = fixture()
  local expected = api.GetCraft(1)
  local rawIpairs = ipairs
  local history = { [ledger.database.crafts] = true, [ledger.database.requests] = true,
    [ledger.database.reagents] = true, [ledger.database.craftSeries] = true }
  local visits, callbacks = 0, 0
  ipairs = function(rows)
    if history[rows] then visits = visits + 1; error("history traversal") end
    return rawIpairs(rows)
  end
  local ok, reason = pcall(function()
    equal(api.GetCraft(1), expected)
    equal(ids(api.GetCrafts({ recipes = { 101 } })), { 6, 1 })
    assert(api.GetFacets({ recipes = { 101 } }, { mode = "strict" }).recipes[1].count == 2)
    api.RegisterCallback("CRAFT_COMMITTED", function(craft)
      equal(api.GetCraft(craft.id), craft)
      callbacks = callbacks + 1
    end)
    assert(ledger:SubmitCraft(101, 1, false, nil,
      { { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 202 } } }))
    local craft = assert(ledger:RecordResult({ resourcesReturned = {} }))
    assert(api.GetCraft(craft.id).reagents[1].returnedQuantity == 0)
  end)
  ipairs = rawIpairs
  assert(ok, reason)
  assert(visits == 0 and callbacks == 1)
end)

test("metadata enrichment updates indexed filters and facets without cached projections", function()
  local ledger, api = fixture()
  assert(#api.GetCrafts({ expansions = { "new-era" } }).crafts == 0)
  local expansion = assert(ledger:AddDimension("expansion", "new-era", { name = "New era" }))
  local profession = assert(ledger:AddDimension("profession", 555))
  assert(ledger:AddDimension("recipe", 104,
    { expansionDimensionId = expansion, professionId = profession }))
  equal(ids(api.GetCrafts({ expansions = { "new-era" }, professions = { 555 } })), { 4 })
  assert(api.GetFacets({ recipes = { 104 } }, { mode = "strict" }).professions[1].value == 555)
  local projected = api.GetCraft(4)
  projected.recipe.expansion.name = "Changed"
  assert(api.GetCraft(4).recipe.expansion.name == "New era")
end)

test("large histories page by indexed boundaries, including backdated timestamps and sparse filters", function()
  local ledger, api, clock, addon = newLedger()
  session(ledger, "A", 1)
  local start = clock.current
  for index = 1, 51000 do
    clock.current = start + math.floor(index / 3)
    ledger:BeginCraft(index % 1000 == 0 and 102 or 101)
    assert(ledger:RecordResult({ operationID = index }))
  end
  assert(#ledger.database.crafts == 51000)
  local page = api.GetCrafts(nil, { limit = 2 })
  equal(ids(page), { 51000, 50999 })
  equal(ids(api.GetCrafts(nil, { limit = 2, cursor = page.nextCursor })), { 50998, 50997 })
  equal(ids(api.GetCrafts({ recipes = { 102 } }, { limit = 2 })), { 51000, 50000 })
  equal(ids(api.GetCrafts({ recipes = { 102, 999 } }, { direction = "asc", limit = 2 })), { 1000, 2000 })
  local sparsePage = api.GetCrafts({ recipes = { 102 } }, { direction = "asc", limit = 2 })
  equal(ids(api.GetCrafts({ recipes = { 102 } },
    { direction = "asc", limit = 2, cursor = sparsePage.nextCursor })), { 3000, 4000 })
  local rawSort = table.sort
  table.sort = function(values, compare)
    assert(#values <= 200, "full-history page sort")
    return rawSort(values, compare)
  end
  local ok, reason = pcall(function()
    equal(ids(api.GetCrafts(nil, { limit = 2, cursor = page.nextCursor })), { 50998, 50997 })
    equal(ids(api.GetCrafts({ recipes = { 101 } }, { limit = 2 })), { 50999, 50998 })
  end)
  table.sort = rawSort
  assert(ok, reason)
  local reads = 0
  local map = ledger.craftById
  ledger.craftById = setmetatable({}, { __index = function(_, id)
    reads = reads + 1
    return map[id]
  end })
  assert(api.GetCrafts(nil, { limit = 2, cursor = page.nextCursor }))
  assert(reads < 100, "unfiltered paging rescanned the history")
  ledger.craftById = map
  clock.current = start + 1
  local backdated = assert(ledger:RecordResult({}))
  local interval = { time = { from = start + 1, to = start + 2 } }
  equal(ids(api.GetCrafts(interval, { direction = "asc" })), { 3, 4, 5, backdated.id })
  equal(ids(api.GetCrafts(interval)), { backdated.id, 5, 4, 3 })
  local facet = api.GetFacets({ recipes = { 102 } }, { mode = "strict" })
  assert(facet.recipes[1].value == 102 and facet.recipes[1].count == 51)
  clock.current = start + 17000
  addon.ledger = assert(addon.Ledger.New(ledger.database, clock))
  equal(ids(api.GetCrafts(interval)), { backdated.id, 5, 4, 3 })
  assert(#api.GetFacets().recipes == 2)
end)

test("sanitized replay preserves partial returns and ambiguous allocation evidence", function()
  local ledger, api = newLedger()
  session(ledger, "A", 1)
  local fixture = assert(loadfile(testsRoot .. "/fixtures/retail-build-69933.lua"))()
  for _, scenario in ipairs(fixture.cases) do
    for _, observed in ipairs(scenario.events) do
      if observed.name == "TRADE_SKILL_CRAFT_BEGIN" then ledger:BeginCraft(observed.arguments[1])
      elseif observed.name == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        assert(ledger:RecordResult(observed.arguments[1]))
      end
    end
  end
  for _, craft in ipairs(api.GetCrafts().crafts) do
    equal(craft, api.GetCraft(craft.id))
    for _, reagent in ipairs(craft.reagents) do
      assert(reagent.item.id and reagent.returnedQuantity ~= nil and reagent.allocatedQuantity == nil)
    end
  end
  ledger:CancelCraft()
  assert(ledger:SubmitCraft(101, 1, true, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 202 } },
    { dataSlotIndex = 2, quantity = 3, reagent = { itemID = 202 } },
  }))
  local craft = ledger:RecordResult({ resourcesReturned = { { reagent = { itemID = 202 }, quantity = 1 } } })
  local projected = api.GetCraft(craft.id)
  assert(projected.reagents[1].returnedQuantity == nil and projected.reagents[2].returnedQuantity == nil)
  assert(projected.reagents[3].allocatedQuantity == nil and projected.reagents[3].returnedQuantity == 1)
end)

test("unavailable ledger has explicit errors without hiding runtime capabilities", function()
  local _, api, _, addon = newLedger()
  addon.ledger = nil
  errorIs("not-ready", api.GetCraft(1))
  errorIs("not-ready", api.GetCrafts())
  errorIs("not-ready", api.GetFacets())
  errorIs("not-ready", api.GetCraftSeries())
  assert(api.GetCapabilities().craftResults)
  addon.adapter = nil
  errorIs("not-ready", api.GetCapabilities())
  assert(api.RegisterCallback("CRAFT_COMMITTED", function() end))
end)

test("requested facets return only requested results and avoid unused traversals", function()
  local ledger, api = fixture()
  local filter = { expansions = { "midnight" }, professions = { 171 } }
  for _, mode in ipairs({ "strict", "self-excluding" }) do
    local all = api.GetFacets(filter, { mode = mode })
    equal(api.GetFacets(filter, { mode = mode, facets = { "professions", "recipes", "recipes" } }),
      { professions = all.professions, recipes = all.recipes })
  end
  local original, visits = ledger.craftById, 0
  ledger.craftById = setmetatable({}, { __index = function(_, id)
    visits = visits + 1
    return original[id]
  end })
  equal(api.GetFacets(nil, { facets = {} }), {})
  assert(visits == 0)
  assert(api.GetFacets(nil, { facets = { "recipes" } }).recipes)
  assert(visits == #ledger.craftIds, "traversed unrequested facet populations")
  ledger.craftById = original
  for _, value in ipairs({ false, 1, "recipes", { "items" }, { [2] = "recipes" },
    { recipes = true }, { false }, setmetatable({}, {}) }) do
    errorIs("invalid-options", api.GetFacets(nil, { facets = value }))
  end
end)

test("series use UTC days and only the specified additive metrics with observation coverage", function()
  local ledger, api, clock = fixture()
  local start = math.floor(clock.current / 86400) * 86400
  local result = api.GetCraftSeries({ recipes = { 101 } }).series
  assert(#result == 1)
  local row = result[1]
  assert(row.bucketStart == start and row.craftCount == 2)
  assert(row.outputQuantity == 5 and row.outputQuantityObservedCount == 1)
  assert(row.multicraftBonus == 0 and row.multicraftBonusObservedCount == 1)
  assert(row.concentrationSpent == 0 and row.concentrationSpentObservedCount == 1)
  assert(row.recipe.id == 101 and row.character.name == "A" and row.realm.name == "Realm 1")
  assert(row.expansion.key == "midnight" and row.profession.skillLineId == 171)
  assert(row.reagents == nil and row.hasIngenuityProc == nil)
  assert(row.ingenuityRefund == 0 and row.ingenuityRefundObservedCount == 1)
  assert(row.ingenuityProcCount == 0 and row.ingenuityProcCountObservedCount == 1)
  assert(row.id == nil and row.recipeId == nil and row.characterDimensionId == nil)
  local absent = api.GetCraftSeries({ recipes = { 104 } }).series[1]
  assert(absent.outputQuantity == nil and absent.outputQuantityObservedCount == 0)
  assert(absent.concentrationSpent == nil and absent.concentrationSpentObservedCount == 0)
  local original = api.GetCraftSeries()
  row.recipe.name = "Changed"
  row.character.realm.name = "Changed"
  row.outputQuantityObservedCount = 999
  equal(api.GetCraftSeries(), original)
  assert(ledger.database.craftSeries[1].craftCount == 2)
end)

test("series require aligned half-open day bounds; factual queries allow arbitrary timestamps", function()
  local ledger, api, clock = newLedger()
  clock.current = 1800057600
  assert(clock.current % 86400 == 0)
  local start = clock.current
  session(ledger, "A", 1)
  for _, offset in ipairs({ -1, 0, 86399, 86400 }) do
    clock.current = start + offset
    ledger:BeginCraft(101)
    assert(ledger:RecordResult({ operationID = offset + 2, quantity = 0 }))
  end
  local all = api.GetCraftSeries().series
  assert(#all == 3 and all[1].bucketStart == start - 86400 and all[3].bucketStart == start + 86400)
  local day = api.GetCraftSeries({ time = { from = start, to = start + 86400 } }).series
  assert(#day == 1 and day[1].craftCount == 2 and day[1].outputQuantityObservedCount == 2)
  equal(api.GetCraftSeries({ time = { from = start, to = start } }), { series = {} })
  assert(#api.GetCraftSeries({ time = { to = start } }).series == 1)
  assert(#api.GetCraftSeries({ time = { from = start } }).series == 2)
  for _, time in ipairs({ { from = start + 1 }, { to = start + 86399 },
    { from = start + 0.5 }, { from = start + 86400, to = start },
    { from = math.huge }, { to = false } }) do
    errorIs("invalid-filter", api.GetCraftSeries({ time = time }))
  end
  assert(#api.GetCrafts({ time = { from = start + 1, to = start + 86400 } }).crafts == 1)
  for _, options in ipairs({ false, { limit = 1 }, { direction = "desc" }, { mode = "strict" },
    { cursor = "cursor" }, { facets = {} } }) do
    errorIs("invalid-options", api.GetCraftSeries(nil, options))
  end
  errorIs("invalid-filter", api.GetCraftSeries({ context = "personal" }))
end)

test("series dimensional filters preserve OR/AND and use recipe rather than output attribution", function()
  local _, api = fixture()
  local a, b, c = api.GetCraft(1), api.GetCraft(2), api.GetCraft(3)
  assert(#api.GetCraftSeries({ characters = { a.character.key } }).series == 3)
  assert(#api.GetCraftSeries({ realms = { c.realm.key } }).series == 1)
  assert(#api.GetCraftSeries({ expansions = { "midnight" } }).series == 2)
  local old = api.GetCraftSeries({ expansions = { "legion" } }).series
  assert(#old == 1 and old[1].recipe.id == 103)
  assert(#api.GetCraftSeries({ professions = { 171 } }).series == 2)
  assert(#api.GetCraftSeries({ characters = { a.character.key, b.character.key },
    expansions = { "midnight" }, professions = { 171, 333 } }).series == 2)
  equal(api.GetCraftSeries({ recipes = {} }), { series = {} })
  equal(api.GetCraftSeries({ characters = { c.character.key }, expansions = { "midnight" } }), { series = {} })
end)

test("series remain identical across 60-day detail pruning and are visible during callbacks", function()
  local ledger, api, clock, addon = fixture()
  assert(ledger.database.retentionDays == 60)
  local delivered = 0
  api.RegisterCallback("CRAFT_COMMITTED", function(craft)
    local series = api.GetCraftSeries({ recipes = { craft.recipe.id } }).series
    assert(#series == 2 and series[2].craftCount == 1 and series[2].outputQuantity == 7)
    delivered = delivered + 1
  end)
  clock.current = clock.current + 61 * 86400
  ledger:BeginCraft(101)
  local recent = assert(ledger:RecordResult({ operationID = 99, quantity = 7 }))
  assert(delivered == 1)
  local before = api.GetCraftSeries()
  addon.ledger = assert(addon.Ledger.New(ledger.database, clock))
  equal(api.GetCraftSeries(), before)
  equal(ids(api.GetCrafts()), { recent.id })
  errorIs("not-found", api.GetCraft(1))
  assert(#api.GetFacets().recipes == 1)
  assert(#api.GetCraftSeries({ recipes = { 103 } }).series == 1)
  clock.current = clock.current + 61 * 86400
  addon.ledger = assert(addon.Ledger.New(addon.ledger.database, clock))
  equal(api.GetCraftSeries(), before)
  equal(api.GetCrafts(), { crafts = {} })
  equal(api.GetFacets(), { characters = {}, realms = {}, expansions = {}, professions = {}, recipes = {} })
end)

test("unknown series identities are not inferred and durable metadata enrichment remains visible", function()
  local ledger, api, clock, addon = newLedger()
  clock.current = -1
  assert(ledger:CreateSession({ startedAt = -1, realmName = "Known session realm" }))
  assert(ledger:RecordResult({ quantity = 0 }))
  local unknown = api.GetCraftSeries().series[1]
  assert(unknown.bucketStart == -86400 and unknown.craftCount == 1)
  assert(unknown.character == nil and unknown.realm == nil and unknown.recipe == nil)
  assert(unknown.outputQuantity == 0 and unknown.outputQuantityObservedCount == 1)
  equal(api.GetCraftSeries({ recipes = { 101 } }), { series = {} })
  equal(api.GetCraftSeries({ time = { from = 0 } }), { series = {} })
  errorIs("invalid-filter", api.GetCraftSeries({ time = { from = -1 } }))
  clock.current = 0
  session(ledger, "A", 1)
  ledger:BeginCraft(101)
  assert(ledger:RecordResult({ operationID = 1 }))
  clock.current = 61 * 86400
  addon.ledger = assert(addon.Ledger.New(ledger.database, clock))
  ledger = addon.ledger
  equal(api.GetCrafts(), { crafts = {} })
  local expansion = assert(ledger:AddDimension("expansion", "known", { name = "Known" }))
  local profession = assert(ledger:AddDimension("profession", 171))
  assert(ledger:AddDimension("recipe", 101,
    { name = "Enriched", professionId = profession, expansionDimensionId = expansion }))
  local row = api.GetCraftSeries({ expansions = { "known" }, professions = { 171 } }).series[1]
  assert(row.recipe.name == "Enriched" and row.bucketStart == 0 and row.craftCount == 1)
end)

test("Ogrim-verified series refund is applied only with observed proc evidence", function()
  local ledger, api, clock, addon = newLedger()
  session(ledger, "A", 1)
  -- Measurements supplied from the Ogrim export; no unprovided trace metadata is inferred.
  local observations = {
    { hasIngenuityProc = true, concentrationSpent = 323, ingenuityRefund = 162 },
    { hasIngenuityProc = false, concentrationSpent = 185, ingenuityRefund = 93 },
    { hasIngenuityProc = false },
    { hasIngenuityProc = true },
    { ingenuityRefund = 80 },
  }
  for _, result in ipairs(observations) do
    ledger:BeginCraft(101)
    result.operationID = ledger.database.nextCraftId
    assert(ledger:RecordResult(result))
  end
  local series = api.GetCraftSeries().series[1]
  assert(series.craftCount == 5 and series.ingenuityProcCount == 2)
  assert(series.ingenuityProcCountObservedCount == 4)
  assert(series.ingenuityRefund == 162 and series.ingenuityRefundObservedCount == 3)
  assert(series.concentrationSpent == 508 and series.concentrationSpentObservedCount == 2)
  assert(api.GetCraft(1).ingenuityRefund == 162)
  assert(api.GetCraft(2).ingenuityRefund == 93 and api.GetCraft(2).hasIngenuityProc == false)
  assert(api.GetCraft(5).ingenuityRefund == 80 and api.GetCraft(5).hasIngenuityProc == nil)
  series.ingenuityRefund = 999
  assert(api.GetCraftSeries().series[1].ingenuityRefund == 162)
  local before = api.GetCraftSeries()
  clock.current = clock.current + 61 * 86400
  addon.ledger = assert(addon.Ledger.New(ledger.database, clock))
  equal(api.GetCraftSeries(), before)
  equal(api.GetCrafts(), { crafts = {} })
end)

test("series unknown Ingenuity coverage is distinct from observed zero", function()
  local ledger, api = newLedger()
  session(ledger, "A", 1)
  assert(ledger:RecordResult({ ingenuityRefund = 162 }))
  local row = api.GetCraftSeries().series[1]
  assert(row.ingenuityProcCount == nil and row.ingenuityProcCountObservedCount == 0)
  assert(row.ingenuityRefund == nil and row.ingenuityRefundObservedCount == 0)
  assert(ledger:RecordResult({ hasIngenuityProc = true, ingenuityRefund = 0 }))
  row = api.GetCraftSeries().series[1]
  assert(row.ingenuityProcCount == 1 and row.ingenuityProcCountObservedCount == 1)
  assert(row.ingenuityRefund == 0 and row.ingenuityRefundObservedCount == 1)
end)

test("recipe repair is immediately visible through public craft and catalogue queries", function()
  local ledger, api = newLedger()
  local profession = assert(ledger:AddDimension("profession", 171, { name = "Alchemy" }))
  assert(ledger:AddDimension("recipe", 105, { name = "Observed recipe", professionId = profession }))
  session(ledger, "Repair Crafter", 1)
  ledger:BeginCraft(105)
  assert(ledger:RecordResult({ operationID = 1, itemID = 905, quantity = 1 }))
  ledger:BeginCraft(nil)
  local unknown = assert(ledger:RecordResult({ operationID = 2, itemID = 905, quantity = 2 }))
  assert(api.GetCraft(unknown.id).recipe == nil)

  local repair = assert(ledger:RepairUnknownRecipes())
  assert(repair.repairedCount == 1 and api.GetCraft(unknown.id).recipe.id == 105)
  local characterKey = api.GetCraft(unknown.id).character.key
  assert(#api.GetCrafts({ recipes = { 105 } }).crafts == 2)
  assert(#api.GetCrafts({ professions = { 171 } }).crafts == 2)
  assert(#api.GetCrafts({ characters = { characterKey } }).crafts == 2)
  local series = api.GetCraftSeries({ recipes = { 105 }, professions = { 171 },
    characters = { characterKey } }).series
  assert(#series == 1 and series[1].craftCount == 2 and series[1].profession.skillLineId == 171)
  local catalogue = api.GetRecipeSummaries({ profession = 171, sort = "count" }).recipes
  local summary
  for _, entry in ipairs(catalogue) do
    if entry.recipe.id == 105 then summary = entry end
  end
  assert(summary and summary.craftCount == 2 and summary.profession.skillLineId == 171)
  local facets = api.GetFacets(nil, { facets = { "recipes" } }).recipes
  local facet
  for _, entry in ipairs(facets) do
    if entry.value == 105 then facet = entry end
  end
  assert(facet and facet.count == 2)
end)

test("supported aggregate-only history reloads without synthesizing unknown Ingenuity coverage", function()
  local ledger, api, clock, addon = newLedger()
  session(ledger, "A", 1)
  assert(ledger:RecordResult({ concentrationSpent = 323, ingenuityRefund = 162 }))
  clock.current = clock.current + 61 * 86400
  ledger:Prune(clock.current)
  assert(#ledger.database.crafts == 0)
  assert(ledger.database.schemaVersion == 1)
  addon.ledger = assert(addon.Ledger.New(ledger.database, clock))
  local row = api.GetCraftSeries().series[1]
  assert(row.craftCount == 1 and row.concentrationSpent == 323)
  assert(row.ingenuityProcCount == nil and row.ingenuityProcCountObservedCount == 0)
  assert(row.ingenuityRefund == nil and row.ingenuityRefundObservedCount == 0)
  assert(#api.GetCrafts().crafts == 0)
  local expected = api.GetCraftSeries()
  addon.ledger = assert(addon.Ledger.New(addon.ledger.database, clock))
  equal(api.GetCraftSeries(), expected)
end)

print(string.format("%d API tests passed", passed))
