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
  local alchemy = assert(ledger:AddDimension("profession", "171", { skillLineId = 171, name = "Alchemy" }))
  local enchanting = assert(ledger:AddDimension("profession", "333", { skillLineId = 333, name = "Enchanting" }))
  assert(ledger:AddDimension("recipe", 101, { gameRecipeId = 101, name = "Potion",
    expansionDimensionId = midnight, professionDimensionId = alchemy }))
  assert(ledger:AddDimension("recipe", 102, { gameRecipeId = 102, name = "Enchant",
    expansionDimensionId = midnight, professionDimensionId = enchanting }))
  assert(ledger:AddDimension("recipe", 103, { gameRecipeId = 103, name = "Old potion",
    expansionDimensionId = legion, professionDimensionId = alchemy }))
  assert(ledger:AddDimension("item", 201, { gameItemId = 201, name = "Output",
    expansionDimensionId = legion }))
  assert(ledger:AddDimension("item", 202, { gameItemId = 202, name = "Reagent",
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
  local recipeRow = ledger.database.dimensions.recipes[1]
  assert(ledger:AddDimension("recipe", recipeRow.key, { internalOnly = { secretSchema = true } }))
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
  assert(result.recipes[1].details.key == nil and result.recipes[1].details.professionDimensionId == nil)
  result.recipes[1].details.expansion.name = "Changed"
  result.characters[1].details.realm.name = "Changed"
  assert(api.GetCraft(1).expansion.name == "Midnight" and api.GetCraft(1).realm.name == "Realm 1")
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
    [ledger.database.reagents] = true }
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
  local profession = assert(ledger:AddDimension("profession", "new-profession", { skillLineId = 555 }))
  assert(ledger:AddDimension("recipe", 104,
    { expansionDimensionId = expansion, professionDimensionId = profession }))
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
  assert(api.GetCapabilities().craftResults)
  addon.adapter = nil
  errorIs("not-ready", api.GetCapabilities())
  assert(api.RegisterCallback("CRAFT_COMMITTED", function() end))
end)

print(string.format("%d API tests passed", passed))
