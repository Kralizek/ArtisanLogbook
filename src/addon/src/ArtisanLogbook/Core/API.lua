local _, addon = ...
local API = {}
ArtisanLogbookAPI = API

local facets = { "characters", "realms", "expansions", "professions", "recipes" }
local filterFields = { time = true, characters = true, realms = true, expansions = true,
  professions = true, recipes = true }
local subscribers = {}

local function fields(row, names)
  if not row then return nil end
  local result = {}
  for _, name in ipairs(names) do
    local value = row[name]
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
      result[name] = value
    end
  end
  return result
end

local function dimension(ledger, kind, id)
  return ledger.dimensionRows[kind][id]
end

local function expansion(ledger, row)
  return fields(row, { "key", "name", "chronologicalOrder" })
end

local function realm(ledger, row)
  return fields(row, { "key", "name", "identityScope", "projectId", "regionId", "gameRealmId" })
end

local function character(ledger, row)
  local result = fields(row, { "key", "name", "guid" })
  if result then result.realm = realm(ledger, dimension(ledger, "realm", row.realmDimensionId)) end
  return result
end

local function profession(ledger, row)
  local result = fields(row, { "skillLineId", "name" })
  if result then
    result.expansion = expansion(ledger, dimension(ledger, "expansion", row.expansionDimensionId))
  end
  return result
end

local function recipe(ledger, row)
  local result = fields(row, { "name" })
  if result then
    if type(row.gameRecipeId) == "number" then result.id = row.gameRecipeId end
    result.profession = profession(ledger, dimension(ledger, "profession", row.professionDimensionId))
    result.expansion = expansion(ledger, dimension(ledger, "expansion", row.expansionDimensionId))
  end
  return result
end

local function item(ledger, id)
  local row = dimension(ledger, "item", id)
  local result = fields(row, { "name" })
  if result then
    if type(row.gameItemId) == "number" then result.id = row.gameItemId end
    result.expansion = expansion(ledger, dimension(ledger, "expansion", row.expansionDimensionId))
  end
  return result
end

local projectors = { characters = character, realms = realm, expansions = expansion,
  professions = profession, recipes = recipe }

local function related(ledger, craft)
  local session = dimension(ledger, "session", craft.sessionDimensionId)
  local recipeRow = dimension(ledger, "recipe", craft.recipeDimensionId)
  return {
    characters = session and dimension(ledger, "character", session.characterDimensionId),
    realms = session and dimension(ledger, "realm", session.realmDimensionId),
    recipes = recipeRow,
    professions = dimension(ledger, "profession", craft.professionDimensionId or
      (recipeRow and recipeRow.professionDimensionId)),
    expansions = recipeRow and dimension(ledger, "expansion", recipeRow.expansionDimensionId),
  }
end

local function identity(facet, row)
  if not row then return nil end
  if facet == "recipes" then return type(row.gameRecipeId) == "number" and row.gameRecipeId or nil end
  if facet == "professions" then return type(row.skillLineId) == "number" and row.skillLineId or nil end
  return row.key
end

local function allocation(ledger, row)
  local result = fields(row, { "dataSlotIndex", "quality", "allocatedQuantity", "returnedQuantity", "source" })
  result.item = item(ledger, row.itemDimensionId)
  return result
end

local function projectCraft(ledger, craft)
  local result = fields(craft, { "id", "timestamp", "gameOperationId", "outputQuality", "outputItemLevel",
    "outputQuantity", "multicraftBonus", "concentrationSpent", "concentrationCurrencyId",
    "hasIngenuityProc", "ingenuityRefund" })
  local rows = related(ledger, craft)
  result.character = character(ledger, rows.characters)
  result.realm = realm(ledger, rows.realms)
  result.profession = profession(ledger, rows.professions)
  result.recipe = recipe(ledger, rows.recipes)
  result.expansion = expansion(ledger, rows.expansions)
  result.outputItem = item(ledger, craft.outputItemDimensionId)
  result.reagents = {}
  for _, row in ipairs(ledger.reagentsByCraftId[craft.id] or {}) do
    result.reagents[#result.reagents + 1] = allocation(ledger, row)
  end
  local request = ledger.requestById[craft.requestId]
  if request then
    result.request = fields(request, { "id", "timestamp", "requestedCount", "useConcentration",
      "concentrationCost", "baseSkill", "baseDifficulty", "craftingQuality" })
    result.request.recipe = recipe(ledger, dimension(ledger, "recipe", request.recipeDimensionId))
    if request.allocations then
      result.request.allocations = {}
      for _, row in ipairs(request.allocations) do
        result.request.allocations[#result.request.allocations + 1] = allocation(ledger, row)
      end
    end
  end
  return result
end

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function integer(value, minimum)
  return finite(value) and value >= minimum and value % 1 == 0
end

local function keysAllowed(value, allowed)
  if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
  for key in pairs(value) do
    if not allowed[key] then return false end
  end
  return true
end

local function normalizeFilter(filter)
  if filter == nil then filter = {} end
  if not keysAllowed(filter, filterFields) then return nil, "invalid-filter" end
  local normalized, signature = {}, {}
  if filter.time ~= nil then
    if not keysAllowed(filter.time, { from = true, to = true }) then return nil, "invalid-filter" end
    local from, to = filter.time.from, filter.time.to
    if (from ~= nil and not finite(from)) or (to ~= nil and not finite(to)) or
        (from ~= nil and to ~= nil and from > to) then return nil, "invalid-filter" end
    normalized.time = { from = from, to = to }
    signature[#signature + 1] = from and string.format("%.17g", from) or ""
    signature[#signature + 1] = to and string.format("%.17g", to) or ""
  else
    signature = { "", "" }
  end
  for _, facet in ipairs(facets) do
    local values = filter[facet]
    local sorted, set = {}, {}
    if values ~= nil then
      if type(values) ~= "table" or getmetatable(values) ~= nil then return nil, "invalid-filter" end
      local count = 0
      for key, value in pairs(values) do
        if not integer(key, 1) then return nil, "invalid-filter" end
        if facet == "recipes" or facet == "professions" then
          if not integer(value, 0) then return nil, "invalid-filter" end
        elseif type(value) ~= "string" or value == "" then
          return nil, "invalid-filter"
        end
        count = count + 1
        if not set[value] then sorted[#sorted + 1] = value; set[value] = true end
      end
      if count ~= #values then return nil, "invalid-filter" end
      for index = 1, count do
        if values[index] == nil then return nil, "invalid-filter" end
      end
      normalized[facet] = set
    end
    table.sort(sorted)
    local encoded = {}
    for _, value in ipairs(sorted) do
      local text = type(value) == "number" and string.format("%.17g", value) or value
      encoded[#encoded + 1] = #text .. ":" .. text
    end
    signature[#signature + 1] = values ~= nil and ("[" .. table.concat(encoded) .. "]") or "-"
  end
  return normalized, table.concat(signature, "|")
end

local function matches(craft, rows, filter, excluded)
  local time = filter.time
  if time and ((time.from and craft.timestamp < time.from) or
      (time.to and craft.timestamp >= time.to)) then return false end
  for _, facet in ipairs(facets) do
    if facet ~= excluded and filter[facet] then
      local value = identity(facet, rows[facet])
      if value == nil or not filter[facet][value] then return false end
    end
  end
  return true
end

local indexNames = {
  characters = "craftIdsByCharacter", realms = "craftIdsByRealm",
  recipes = "craftIdsByRecipe", professions = "craftIdsByProfession",
  expansions = "craftIdsByExpansion",
}

local function union(left, right)
  local result, i, j = {}, 1, 1
  while i <= #left or j <= #right do
    local a, b = left[i], right[j]
    if b == nil or (a ~= nil and a < b) then
      result[#result + 1] = a; i = i + 1
    elseif a == nil or b < a then
      result[#result + 1] = b; j = j + 1
    else
      result[#result + 1] = a; i = i + 1; j = j + 1
    end
  end
  return result
end

-- Start with the smallest selected population; other facets remain AND constraints.
local function candidateIds(ledger, filter, excluded, maximum)
  local chosen, smallest = nil, math.min(#ledger.craftIds, maximum or math.huge)
  for _, facet in ipairs(facets) do
    if facet ~= excluded and filter[facet] then
      local index, count = ledger[indexNames[facet]], 0
      for value in pairs(filter[facet]) do count = count + #(index[value] or {}) end
      if count <= smallest then chosen, smallest = facet, count end
    end
  end
  if not chosen then return ledger.craftIds end
  local result
  for value in pairs(filter[chosen]) do
    local ids = ledger[indexNames[chosen]][value]
    if ids then result = result and union(result, ids) or ids end
  end
  return result or {}
end

local function timeBefore(left, right)
  if left.timestamp == right.timestamp then return left.id < right.id end
  return left.timestamp < right.timestamp
end

local function lowerBound(ledger, ids, boundary)
  local first, last = 1, #ids + 1
  while first < last do
    local middle = math.floor((first + last) / 2)
    if timeBefore(ledger.craftById[ids[middle]], boundary) then
      first = middle + 1
    else
      last = middle
    end
  end
  return first
end

function API.GetCraft(id)
  if not integer(id, 1) then return nil, "invalid-id" end
  local ledger = addon.ledger
  if not ledger then return nil, "not-ready" end
  local craft = ledger.craftById[id]
  if craft then return projectCraft(ledger, craft) end
  return nil, "not-found"
end

function API.GetCrafts(filter, options)
  local normalized, signature = normalizeFilter(filter)
  if not normalized then return nil, signature end
  if options == nil then options = {} end
  if not keysAllowed(options, { limit = true, direction = true, cursor = true }) then
    return nil, "invalid-options"
  end
  local limit = options.limit
  if limit == nil then limit = 50 end
  local direction = options.direction
  if direction == nil then direction = "desc" end
  if not integer(limit, 1) or limit > 200 or (direction ~= "asc" and direction ~= "desc") then
    return nil, "invalid-options"
  end
  local ledger = addon.ledger
  if not ledger then return nil, "not-ready" end
  local highWater = ledger.database.nextCraftId - 1
  local anchorTime, anchorId
  if options.cursor ~= nil then
    if type(options.cursor) ~= "string" then return nil, "invalid-cursor" end
    local order, high, id, timestamp, query =
      options.cursor:match("^1:(%a+):(%d+):(%d+):([^:]+):(.*)$")
    high, id, timestamp = tonumber(high), tonumber(id), tonumber(timestamp)
    if order ~= direction or query ~= signature or not integer(high, 1) or high > highWater or
        not integer(id, 1) or id > high or not finite(timestamp) then
      return nil, "invalid-cursor"
    end
    highWater, anchorId, anchorTime = high, id, timestamp
  end
  local ordered = ledger.craftIdsByTime
  local candidates = candidateIds(ledger, normalized, nil, #ordered / 4)
  -- Sparse selections sort only their IDs. Broad/unfiltered pages seek the time index.
  if #candidates < #ordered / 4 then
    ordered = {}
    for index, id in ipairs(candidates) do ordered[index] = id end
    table.sort(ordered, function(left, right)
      return timeBefore(ledger.craftById[left], ledger.craftById[right])
    end)
  end
  local time = normalized.time or {}
  local first = time.from and lowerBound(ledger, ordered, { timestamp = time.from, id = -math.huge }) or 1
  local last = time.to and lowerBound(ledger, ordered, { timestamp = time.to, id = -math.huge }) - 1 or #ordered
  if anchorId then
    local position = lowerBound(ledger, ordered, { timestamp = anchorTime, id = anchorId })
    if direction == "asc" then
      if ordered[position] == anchorId and ledger.craftById[anchorId].timestamp == anchorTime then
        position = position + 1
      end
      first = math.max(first, position)
    else
      last = math.min(last, position - 1)
    end
  end
  local step = direction == "asc" and 1 or -1
  local position = direction == "asc" and first or last
  local selected = {}
  while position >= first and position <= last and #selected <= limit do
    local craft = ledger.craftById[ordered[position]]
    if craft.id <= highWater and matches(craft, related(ledger, craft), normalized) then
      selected[#selected + 1] = craft
    end
    position = position + step
  end
  local hasMore = #selected > limit
  if hasMore then selected[#selected] = nil end
  local page = { crafts = {} }
  for _, craft in ipairs(selected) do
    page.crafts[#page.crafts + 1] = projectCraft(ledger, craft)
  end
  if hasMore then
    local last = selected[#selected]
    page.nextCursor = string.format("1:%s:%.0f:%.0f:%.17g:%s",
      direction, highWater, last.id, last.timestamp, signature)
  end
  return page
end

function API.GetFacets(filter, options)
  local normalized, reason = normalizeFilter(filter)
  if not normalized then return nil, reason end
  if options == nil then options = {} end
  if not keysAllowed(options, { mode = true }) then return nil, "invalid-options" end
  local mode = options.mode
  if mode == nil then mode = "self-excluding" end
  if mode ~= "self-excluding" and mode ~= "strict" then return nil, "invalid-options" end
  local ledger = addon.ledger
  if not ledger then return nil, "not-ready" end
  local result, seen = {}, {}
  for _, facet in ipairs(facets) do result[facet] = {}; seen[facet] = {} end
  for _, facet in ipairs(facets) do
    local excluded = mode == "self-excluding" and facet or nil
    for _, id in ipairs(candidateIds(ledger, normalized, excluded)) do
      local craft = ledger.craftById[id]
      local rows = related(ledger, craft)
      local value = identity(facet, rows[facet])
      if value ~= nil and matches(craft, rows, normalized, excluded) then
        local entry = seen[facet][value]
        if not entry then
          entry = { value = value, count = 0, details = projectors[facet](ledger, rows[facet]) }
          seen[facet][value] = entry
          table.insert(result[facet], entry)
        end
        entry.count = entry.count + 1
      end
    end
  end
  for _, facet in ipairs(facets) do
    table.sort(result[facet], function(left, right) return left.value < right.value end)
  end
  return result
end

function API.GetCapabilities()
  if not addon.adapter then return nil, "not-ready" end
  local capabilities = addon.adapter.capabilities
  local result = { flavor = capabilities.flavor }
  result.craftResults = capabilities.events.TRADE_SKILL_ITEM_CRAFTED_RESULT == true
  result.personalRequests = result.craftResults and capabilities.hooks.CraftRecipe == true
  result.reagentAllocations = result.personalRequests and capabilities.quoteHooks ~= nil and
    capabilities.quoteHooks.GetCraftingOperationInfo == true
  return result
end

function API.RegisterCallback(event, callback)
  if event ~= "CRAFT_COMMITTED" then return nil, "invalid-event" end
  if type(callback) ~= "function" then return nil, "invalid-callback" end
  local subscription = { callback = callback }
  subscribers[#subscribers + 1] = subscription
  return function()
    subscription.callback = nil
    for index, entry in ipairs(subscribers) do
      if entry == subscription then table.remove(subscribers, index); break end
    end
  end
end

function addon.PublishCraftCommitted(ledger, craft)
  if #subscribers == 0 then return end
  local delivery = {}
  for index, subscription in ipairs(subscribers) do delivery[index] = subscription.callback end
  for _, callback in ipairs(delivery) do
    -- Each consumer gets its own projection, including nested related objects.
    pcall(function() callback(projectCraft(ledger, craft)) end)
  end
end
