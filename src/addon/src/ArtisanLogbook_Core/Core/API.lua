local _, addon = ...
local API = {}
ArtisanLogbookAPI = API

function API.GetVersion()
  return 1
end

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
  local result = fields(row, { "key", "name", "guid", "classFile" })
  if result then result.realm = realm(ledger, dimension(ledger, "realm", row.realmDimensionId)) end
  return result
end

local function profession(ledger, row)
  local result = fields(row, { "name" })
  if result then
    result.skillLineId = row.id
    result.expansion = expansion(ledger, dimension(ledger, "expansion", row.expansionDimensionId))
  end
  return result
end

local function recipe(ledger, row)
  local result = fields(row, { "name", "maxQuality" })
  if result then
    result.id = row.id
    result.profession = profession(ledger, dimension(ledger, "profession", row.professionId))
    result.expansion = expansion(ledger, dimension(ledger, "expansion", row.expansionDimensionId))
  end
  return result
end

local function item(ledger, id)
  local row = dimension(ledger, "item", id)
  local result = fields(row, { "name" })
  if result then
    result.id = row.id
    result.expansion = expansion(ledger, dimension(ledger, "expansion", row.expansionDimensionId))
  end
  return result
end

local projectors = { characters = character, realms = realm, expansions = expansion,
  professions = profession, recipes = recipe }

local function related(ledger, craft)
  local session = dimension(ledger, "session", craft.sessionId)
  local recipeRow = dimension(ledger, "recipe", craft.recipeId)
  return {
    characters = session and dimension(ledger, "character", session.characterDimensionId),
    realms = session and dimension(ledger, "realm", session.realmDimensionId),
    recipes = recipeRow,
    professions = dimension(ledger, "profession", craft.professionId or
      (recipeRow and recipeRow.professionId)),
    expansions = recipeRow and dimension(ledger, "expansion", recipeRow.expansionDimensionId),
  }
end

local function identity(facet, row)
  if not row then return nil end
  if facet == "recipes" or facet == "professions" then return row.id end
  return row.key
end

local function allocation(ledger, row)
  local result = fields(row, { "dataSlotIndex", "quality", "allocatedQuantity", "returnedQuantity", "source" })
  result.item = item(ledger, row.itemId)
  return result
end

local function projectCraft(ledger, craft)
  local result = fields(craft, { "id", "timestamp", "gameOperationId", "outputQuality", "outputItemLevel",
    "outputQuantity", "multicraftBonus", "concentrationSpent", "concentrationCurrencyId",
    "hasIngenuityProc", "ingenuityRefund", "hasResourcefulnessProc", "resourcefulnessComplete" })
  local rows = related(ledger, craft)
  result.character = character(ledger, rows.characters)
  result.realm = realm(ledger, rows.realms)
  result.profession = profession(ledger, rows.professions)
  result.recipe = recipe(ledger, rows.recipes)
  result.expansion = expansion(ledger, rows.expansions)
  result.outputItem = item(ledger, craft.outputItemId)
  result.reagents = {}
  for _, row in ipairs(ledger.reagentsByCraftId[craft.id] or {}) do
    result.reagents[#result.reagents + 1] = allocation(ledger, row)
  end
  local request = ledger.requestById[craft.requestId]
  if request then
    result.request = fields(request, { "id", "timestamp", "requestedCount", "useConcentration",
      "concentrationCost", "baseSkill", "baseDifficulty", "craftingQuality" })
    result.request.recipe = recipe(ledger, dimension(ledger, "recipe", request.recipeId))
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

local function seriesRelated(ledger, row)
  local characterRow = dimension(ledger, "character", row.characterDimensionId)
  local recipeRow = dimension(ledger, "recipe", row.recipeId)
  return {
    characters = characterRow,
    realms = characterRow and dimension(ledger, "realm", characterRow.realmDimensionId),
    recipes = recipeRow,
    professions = recipeRow and dimension(ledger, "profession", recipeRow.professionId),
    expansions = recipeRow and dimension(ledger, "expansion", recipeRow.expansionDimensionId),
  }
end

function API.GetCraftSeries(filter, options)
  local normalized, reason = normalizeFilter(filter)
  if not normalized then return nil, reason end
  local time = normalized.time
  if time and ((time.from and time.from % 86400 ~= 0) or (time.to and time.to % 86400 ~= 0)) then
    return nil, "invalid-filter"
  end
  if options == nil then options = {} end
  if not keysAllowed(options, {}) then return nil, "invalid-options" end
  local ledger = addon.ledger
  if not ledger then return nil, "not-ready" end
  local selected = {}
  local days = ledger.seriesDays
  local first, last = 1, #days + 1
  if time and time.from then
    while first < last do
      local middle = math.floor((first + last) / 2)
      if days[middle] < time.from then first = middle + 1 else last = middle end
    end
  end
  for index = first, #days do
    local day = days[index]
    if time and time.to and day >= time.to then break end
    for _, group in pairs(ledger.seriesByKey[day]) do
      for _, row in pairs(group) do
        if matches({ timestamp = day }, seriesRelated(ledger, row), normalized) then
          selected[#selected + 1] = row
        end
      end
    end
  end
  table.sort(selected, function(left, right)
    if left.bucketStart ~= right.bucketStart then return left.bucketStart < right.bucketStart end
    local leftCharacter = dimension(ledger, "character", left.characterDimensionId)
    local rightCharacter = dimension(ledger, "character", right.characterDimensionId)
    local leftKey, rightKey = leftCharacter and leftCharacter.key or "", rightCharacter and rightCharacter.key or ""
    if leftKey ~= rightKey then return leftKey < rightKey end
    local leftRecipe = dimension(ledger, "recipe", left.recipeId)
    local rightRecipe = dimension(ledger, "recipe", right.recipeId)
    local leftId = identity("recipes", leftRecipe) or -1
    local rightId = identity("recipes", rightRecipe) or -1
    if leftId ~= rightId then return leftId < rightId end
    return (left.recipeId or 0) < (right.recipeId or 0)
  end)
  local result = { series = {} }
  for _, row in ipairs(selected) do
    local projected = fields(row, { "bucketStart", "craftCount", "outputQuantity", "multicraftBonus",
      "concentrationSpent", "outputQuantityObservedCount", "multicraftBonusObservedCount",
      "concentrationSpentObservedCount", "ingenuityProcCount", "ingenuityProcCountObservedCount",
      "ingenuityRefund", "ingenuityRefundObservedCount" })
    local rows = seriesRelated(ledger, row)
    projected.character = character(ledger, rows.characters)
    projected.realm = realm(ledger, rows.realms)
    projected.recipe = recipe(ledger, rows.recipes)
    projected.profession = profession(ledger, rows.professions)
    projected.expansion = expansion(ledger, rows.expansions)
    result.series[#result.series + 1] = projected
  end
  return result
end

local outcomeMetrics = { "outputQuantity", "multicraftBonus", "multicraftProcCount",
  "concentrationSpent", "ingenuityProcCount", "ingenuityRefund", "resourcefulnessProcCount",
  "resourcefulnessCompleteProcCount" }

local function outcomeQuery(recipeId, filter)
  if not integer(recipeId, 0) then return nil, "invalid-id" end
  if filter ~= nil and not keysAllowed(filter, { time = true, characters = true }) then
    return nil, "invalid-filter"
  end
  local normalized, signature = normalizeFilter(filter)
  if not normalized then return nil, signature end
  local time = normalized.time
  if time and ((time.from and time.from % 86400 ~= 0) or (time.to and time.to % 86400 ~= 0)) then
    return nil, "invalid-filter"
  end
  local ledger = addon.ledger
  if not ledger then return nil, "not-ready" end
  local days = ledger.seriesDays
  local first, last = 1, #days + 1
  if time and time.from then
    while first < last do
      local middle = math.floor((first + last) / 2)
      if days[middle] < time.from then first = middle + 1 else last = middle end
    end
  end
  return { ledger = ledger, recipeId = recipeId, filter = normalized, first = first,
    signature = tostring(recipeId) .. ":" .. signature }
end

local function visitOutcomes(query, visit)
  local ledger, filter = query.ledger, query.filter
  for position = query.first, #ledger.seriesDays do
    local day = ledger.seriesDays[position]
    if filter.time and filter.time.to and day >= filter.time.to then break end
    for characterId, recipes in pairs(ledger.seriesByKey[day]) do
      local row = recipes[query.recipeId]
      local characterRow = ledger.dimensionRows.character[characterId]
      if row and (not filter.characters or (characterRow and filter.characters[characterRow.key])) then
        visit(row, day, characterId)
      end
    end
  end
end

function API.GetRecipeOutcomes(recipeId, filter, options)
  local query, reason = outcomeQuery(recipeId, filter)
  if not query then return nil, reason end
  if options == nil then options = {} end
  if not keysAllowed(options, { buckets = true }) or
      (options.buckets ~= nil and (not integer(options.buckets, 1) or options.buckets > 200)) then
    return nil, "invalid-options"
  end
  local totals, firstDay, lastDay = { craftCount = 0 }, nil, nil
  for _, metric in ipairs(outcomeMetrics) do totals[metric .. "ObservedCount"] = 0 end
  visitOutcomes(query, function(row, day)
    firstDay, lastDay = firstDay or day, day
    totals.craftCount = totals.craftCount + row.craftCount
    for _, metric in ipairs(outcomeMetrics) do
      if row[metric] ~= nil then totals[metric] = (totals[metric] or 0) + row[metric] end
      totals[metric .. "ObservedCount"] = totals[metric .. "ObservedCount"] + row[metric .. "ObservedCount"]
    end
  end)
  local result = { totals = totals, series = {} }
  if not firstDay then return result end
  local time = query.filter.time or {}
  result.from, result.to = time.from or firstDay, time.to or (lastDay + 86400)
  result.bucketSeconds = math.max(1, math.ceil((result.to - result.from) / 86400 /
    (options.buckets or 60))) * 86400
  local buckets = {}
  visitOutcomes(query, function(row, day)
    local position = math.floor((day - result.from) / result.bucketSeconds) + 1
    buckets[position] = (buckets[position] or 0) + row.craftCount
  end)
  for position = 1, math.ceil((result.to - result.from) / result.bucketSeconds) do
    result.series[#result.series + 1] = {
      bucketStart = result.from + (position - 1) * result.bucketSeconds,
      craftCount = buckets[position] or 0,
    }
  end
  return result
end

local function returnedPage(recipeId, filter, options, kind)
  local query, reason = outcomeQuery(recipeId, filter)
  if not query then return nil, reason end
  if options == nil then options = {} end
  if not keysAllowed(options, { limit = true, cursor = true }) then return nil, "invalid-options" end
  local limit = options.limit or 50
  if not integer(limit, 1) or limit > 200 then return nil, "invalid-options" end
  local prefix = kind .. ":" .. query.signature .. "\n"
  local after
  if options.cursor ~= nil then
    if type(options.cursor) ~= "string" or options.cursor:sub(1, #prefix) ~= prefix then
      return nil, "invalid-cursor"
    end
    after = options.cursor:sub(#prefix + 1)
    if kind == "items" then
      after = tonumber(after)
      if not integer(after, 1) then return nil, "invalid-cursor" end
    elseif not after:match("^%d[%d,]*$") then return nil, "invalid-cursor" end
  end
  local index = kind == "sets" and query.ledger.returnSetIndex or query.ledger.returnQuantityIndex
  local metric = kind == "sets" and "craftCount" or "returnedQuantity"
  local selected, keys = {}, {}
  visitOutcomes(query, function(_, day, characterId)
    local bucket = index[day]
    local recipes = bucket and bucket[characterId]
    for key, row in pairs(recipes and recipes[recipeId] or {}) do
      if (after == nil or key > after) and (#keys < limit + 1 or key <= keys[#keys]) then
        if selected[key] == nil then
          keys[#keys + 1] = key
          table.sort(keys)
          if #keys > limit + 1 then
            selected[keys[#keys]] = nil
            keys[#keys] = nil
          end
          selected[key] = 0
        end
        selected[key] = selected[key] + row[metric]
      end
    end
  end)
  local result = { returns = {} }
  for position = 1, math.min(limit, #keys) do
    local key = keys[position]
    if kind == "sets" then
      local itemIds = {}
      for text in key:gmatch("[^,]+") do itemIds[#itemIds + 1] = tonumber(text) end
      result.returns[#result.returns + 1] = { itemIds = itemIds, craftCount = selected[key] }
    else
      result.returns[#result.returns + 1] = {
        item = item(query.ledger, key), returnedQuantity = selected[key],
      }
    end
  end
  if #keys > limit then result.nextCursor = prefix .. tostring(keys[limit]) end
  return result
end

function API.GetRecipeReturnSets(recipeId, filter, options)
  return returnedPage(recipeId, filter, options, "sets")
end

function API.GetRecipeReturnedReagents(recipeId, filter, options)
  return returnedPage(recipeId, filter, options, "items")
end

function API.GetReagentSummaries(options)
  if options == nil then options = {} end
  if not keysAllowed(options, { profession = true, search = true, sort = true, limit = true,
      cursor = true, items = true, excludeItems = true, character = true, time = true }) then return nil, "invalid-options" end
  local limit, sort = options.limit or 50, options.sort or "name"
  if not integer(limit, 1) or limit > 200 or
      (options.profession ~= nil and not integer(options.profession, 0)) or
      (options.search ~= nil and type(options.search) ~= "string") or
      (sort ~= "name" and sort ~= "allocated" and sort ~= "returned" and sort ~= "recipes") then
    return nil, "invalid-options"
  end
  local selections, signature = {}, { tostring(options.profession or ""), sort }
  if options.character ~= nil and (type(options.character) ~= "string" or options.character == "") then
    return nil, "invalid-options"
  end
  local filter, filterSignature = normalizeFilter({ time = options.time,
    characters = options.character and { options.character } or nil })
  if not filter then return nil, "invalid-options" end
  for _, bound in pairs(filter.time or {}) do
    if bound % 86400 ~= 0 then return nil, "invalid-options" end
  end
  signature[#signature + 1] = filterSignature
  for _, field in ipairs({ "items", "excludeItems" }) do
    local values, encoded, selected = options[field], {}, {}
    if values ~= nil then
      if type(values) ~= "table" or getmetatable(values) ~= nil then return nil, "invalid-options" end
      local count = 0
      for key, value in pairs(values) do
        if not integer(key, 1) or not integer(value, 1) then return nil, "invalid-options" end
        count = count + 1
        if not selected[value] then selected[value] = true; encoded[#encoded + 1] = value end
      end
      for index = 1, count do if values[index] == nil then return nil, "invalid-options" end end
      selections[field] = selected
    end
    table.sort(encoded)
    for index, value in ipairs(encoded) do encoded[index] = string.format("%.17g", value) end
    signature[#signature + 1] = values and ("[" .. table.concat(encoded, ",") .. "]") or "-"
  end
  local search = (options.search or ""):lower()
  local prefix = "reagents:" .. table.concat(signature, ":") .. ":" .. #search .. ":" .. search .. "\n"
  local offset = 0
  if options.cursor ~= nil then
    if type(options.cursor) ~= "string" or options.cursor:sub(1, #prefix) ~= prefix then return nil, "invalid-cursor" end
    local text = options.cursor:sub(#prefix + 1)
    if not text:match("^[1-9]%d*$") then return nil, "invalid-cursor" end
    offset = tonumber(text)
    if not integer(offset, 1) then return nil, "invalid-cursor" end
  end
  local ledger = addon.ledger
  if not ledger then return nil, "not-ready" end
  local characterId = options.character and ledger.dimensionIndex.character[options.character]
  local function inPopulation(timestamp, id)
    return (not options.character or characterId ~= nil and characterId == id) and
      (not filter.time or (not filter.time.from or timestamp >= filter.time.from) and
        (not filter.time.to or timestamp < filter.time.to))
  end
  local selected, coverage = {}, {}
  for _, row in ipairs(ledger.database.craftSeries) do
    if inPopulation(row.bucketStart, row.characterDimensionId) then
      local id = row.recipeId or 0
      local counts = coverage[id] or { crafts = 0, complete = 0 }
      counts.crafts = counts.crafts + row.craftCount
      counts.complete = counts.complete + row.resourcefulnessCompleteProcCountObservedCount
      coverage[id] = counts
    end
  end
  local function reagent(itemId, recipeId, professionId)
    if selections.items and not selections.items[itemId] or selections.excludeItems and selections.excludeItems[itemId] then return end
    local recipeRow = dimension(ledger, "recipe", recipeId)
    professionId = professionId or (recipeRow and recipeRow.professionId)
    if options.profession and options.profession ~= professionId then return end
    local identity = item(ledger, itemId)
    local name = identity and identity.name or ("Item #" .. itemId)
    if not name:lower():find(search, 1, true) then return end
    local row = selected[itemId]
    if not row then
      row = { item = identity, name = name:lower(), recipeIds = {}, professionIds = {},
        allocationObservedCount = 0, allocationUnknownCount = 0, returnObservedCount = 0,
        returnUnknownCount = 0, retainedReturned = 0, recipeCount = 0 }
      selected[itemId] = row
    end
    if recipeId and recipeId ~= 0 and not row.recipeIds[recipeId] then row.recipeCount = row.recipeCount + 1 end
    row.recipeIds[recipeId or 0] = true
    if professionId then row.professionIds[professionId] = true end
    return row
  end
  for _, fact in ipairs(ledger.database.reagents) do
    local craft = ledger.craftById[fact.craftId]
    local session = craft and dimension(ledger, "session", craft.sessionId)
    local row = craft and inPopulation(craft.timestamp, session and session.characterDimensionId) and
      reagent(fact.itemId, craft.recipeId, craft.professionId)
    if row then
      if fact.allocatedQuantity ~= nil then
        row.allocatedQuantity = (row.allocatedQuantity or 0) + fact.allocatedQuantity
        row.allocationObservedCount = row.allocationObservedCount + 1
      else row.allocationUnknownCount = row.allocationUnknownCount + 1 end
      if fact.returnedQuantity ~= nil and fact.returnedQuantity >= 0 then
        row.returnObservedCount = row.returnObservedCount + 1
        row.retainedReturned = row.retainedReturned + fact.returnedQuantity
      else row.returnUnknownCount = row.returnUnknownCount + 1 end
      if fact.quality ~= nil then
        if row.quality ~= nil and row.quality ~= fact.quality then row.conflictingQuality = true end
        row.quality = fact.quality
      end
    end
  end
  for _, fact in ipairs(ledger.database.returnedReagents) do
    local row = inPopulation(fact.bucketStart, fact.characterDimensionId) and reagent(fact.itemId, fact.recipeId)
    if row then row.returnedQuantity = (row.returnedQuantity or 0) + fact.returnedQuantity end
  end
  local order = {}
  for _, row in pairs(selected) do
    row.hasPrunedReturns = (row.returnedQuantity or 0) > row.retainedReturned
    row.allocationComplete = row.allocationObservedCount > 0 and row.allocationUnknownCount == 0 and not row.hasPrunedReturns
    row.returnComplete = row.returnUnknownCount == 0
    for recipeId in pairs(row.recipeIds) do
      local counts = coverage[recipeId]
      if not counts or counts.complete < counts.crafts then row.returnComplete = false end
    end
    if row.returnedQuantity == nil and row.returnObservedCount > 0 and row.returnComplete then row.returnedQuantity = 0 end
    if row.conflictingQuality then row.quality = nil end
    if (row.allocatedQuantity and not finite(row.allocatedQuantity)) or
        (row.returnedQuantity and not finite(row.returnedQuantity)) then return nil, "quantity-overflow" end
    order[#order + 1] = row
  end
  local metric = ({ allocated = "allocatedQuantity", returned = "returnedQuantity", recipes = "recipeCount" })[sort]
  table.sort(order, function(left, right)
    if metric and left[metric] ~= right[metric] then
      if left[metric] == nil then return false end
      if right[metric] == nil then return true end
      return left[metric] > right[metric]
    end
    if left.name ~= right.name then return left.name < right.name end
    return left.item.id < right.item.id
  end)
  if offset > #order then return nil, "invalid-cursor" end
  local result = { reagents = {}, totalCount = #order,
    totals = { allocationComplete = true, returnComplete = true } }
  for _, row in ipairs(order) do
    for _, metric in ipairs({ "allocatedQuantity", "returnedQuantity" }) do
      if row[metric] ~= nil then result.totals[metric] = (result.totals[metric] or 0) + row[metric] end
    end
    result.totals.allocationComplete = result.totals.allocationComplete and row.allocationComplete
    result.totals.returnComplete = result.totals.returnComplete and row.returnComplete
  end
  for _, metric in ipairs({ "allocatedQuantity", "returnedQuantity" }) do
    if result.totals[metric] and not finite(result.totals[metric]) then return nil, "quantity-overflow" end
  end
  for index = offset + 1, math.min(offset + limit, #order) do
    local row = order[index]
    local projected = fields(row, { "quality", "recipeCount", "allocatedQuantity", "returnedQuantity",
      "allocationObservedCount", "allocationUnknownCount", "returnObservedCount", "returnUnknownCount",
      "allocationComplete", "returnComplete", "hasPrunedReturns" })
    projected.item, projected.professions = row.item, {}
    for id in pairs(row.professionIds) do
      projected.professions[#projected.professions + 1] = profession(ledger, dimension(ledger, "profession", id))
    end
    table.sort(projected.professions, function(left, right) return left.skillLineId < right.skillLineId end)
    result.reagents[#result.reagents + 1] = projected
  end
  if offset + limit < #order then result.nextCursor = prefix .. (offset + limit) end
  return result
end

function API.GetRecipeSummaries(options)
  if options == nil then options = {} end
  if not keysAllowed(options, { limit = true, cursor = true, character = true,
      profession = true, sort = true, search = true }) then return nil, "invalid-options" end
  local limit = options.limit or 50
  if not integer(limit, 1) or limit > 200 then return nil, "invalid-options" end
  if options.character ~= nil and (type(options.character) ~= "string" or options.character == "") then
    return nil, "invalid-options"
  end
  if options.profession ~= nil and not integer(options.profession, 0) then return nil, "invalid-options" end
  local sort = options.sort or "name"
  if sort ~= "name" and sort ~= "count" and sort ~= "profession" then return nil, "invalid-options" end
  if options.search ~= nil and type(options.search) ~= "string" then return nil, "invalid-options" end
  local search = (options.search or ""):lower()
  local characterKey = options.character or ""
  local prefix = search ~= "" and ("recipe-search:" .. #search .. ":" .. search .. ":" ..
    #characterKey .. ":" .. characterKey .. ":" .. tostring(options.profession or "") .. ":" .. sort .. "\n") or ""
  local offset = 0
  if options.cursor ~= nil then
    if type(options.cursor) ~= "string" or options.cursor:sub(1, #prefix) ~= prefix then
      return nil, "invalid-cursor"
    end
    local cursor = options.cursor:sub(#prefix + 1)
    if not cursor:match("^[1-9]%d*$") then return nil, "invalid-cursor" end
    offset = tonumber(cursor)
    if not integer(offset, 1) then return nil, "invalid-cursor" end
  end
  local ledger = addon.ledger
  if not ledger then return nil, "not-ready" end
  local counts = ledger.recipeCounts
  if options.character then
    counts = {}
    local characterId = ledger.dimensionIndex.character[options.character]
    for _, row in ipairs(ledger.database.craftSeries) do
      if row.characterDimensionId == characterId and row.recipeId then
        counts[row.recipeId] = (counts[row.recipeId] or 0) + row.craftCount
      end
    end
  end
  if not ledger.recipeOrder or options.character or options.profession or sort ~= "name" or search ~= "" then
    local order = {}
    for id in pairs(counts) do
      local row = dimension(ledger, "recipe", id)
        if row and (not options.profession or row.professionId == options.profession) and
          (row.name or "Recipe #" .. row.id):lower():find(search, 1, true) then
        order[#order + 1] = id
      end
    end
    table.sort(order, function(left, right)
      if sort == "count" and counts[left] ~= counts[right] then return counts[left] > counts[right] end
      local a, b = dimension(ledger, "recipe", left), dimension(ledger, "recipe", right)
      if sort == "profession" then
        local leftProfession = dimension(ledger, "profession", a.professionId)
        local rightProfession = dimension(ledger, "profession", b.professionId)
        local leftLabel = (leftProfession and leftProfession.name or "Unknown"):lower()
        local rightLabel = (rightProfession and rightProfession.name or "Unknown"):lower()
        if leftLabel ~= rightLabel then return leftLabel < rightLabel end
      end
      local leftName = (a.name or "Recipe #" .. a.id):lower()
      local rightName = (b.name or "Recipe #" .. b.id):lower()
      if leftName ~= rightName then return leftName < rightName end
      return a.id < b.id
    end)
    if not options.character and not options.profession and sort == "name" and search == "" then ledger.recipeOrder = order end
    if options.character or options.profession or sort ~= "name" or search ~= "" then
      local result = { recipes = {} }
      if offset > #order then return nil, "invalid-cursor" end
      for index = offset + 1, math.min(offset + limit, #order) do
        local id = order[index]
        local projected = recipe(ledger, dimension(ledger, "recipe", id))
        if not projected.name then projected.name = "Recipe #" .. projected.id end
        result.recipes[#result.recipes + 1] = {
          recipe = projected, profession = projected.profession, craftCount = counts[id],
        }
      end
      if offset + limit < #order then result.nextCursor = prefix .. tostring(offset + limit) end
      return result
    end
  end
  local order = ledger.recipeOrder
  if offset > #order then return nil, "invalid-cursor" end
  local result = { recipes = {} }
  for index = offset + 1, math.min(offset + limit, #order) do
    local id = order[index]
    local projected = recipe(ledger, dimension(ledger, "recipe", id))
    if not projected.name then projected.name = "Recipe #" .. projected.id end
    result.recipes[#result.recipes + 1] = {
      recipe = projected, profession = projected.profession, craftCount = ledger.recipeCounts[id],
    }
  end
  if offset + limit < #order then result.nextCursor = tostring(offset + limit) end
  return result
end

function API.GetCharacters()
  local ledger = addon.ledger
  if not ledger then return nil, "not-ready" end
  local result = {}
  for id in pairs(ledger.seriesCharacterIds) do
    local details = character(ledger, dimension(ledger, "character", id))
    if details and details.key then
      result[#result + 1] = details
    end
  end
  table.sort(result, function(left, right) return left.key < right.key end)
  return result
end

function API.GetProfessions(characterKey)
  if characterKey ~= nil and (type(characterKey) ~= "string" or characterKey == "") then
    return nil, "invalid-filter"
  end
  local ledger = addon.ledger
  if not ledger then return nil, "not-ready" end
  local result = {}
  local characterId = characterKey and ledger.dimensionIndex.character[characterKey]
  local recipes = characterKey and (characterId and ledger.seriesRecipeIdsByCharacter[characterId] or {}) or
    ledger.seriesRecipeIds
  local seen = {}
  for id in pairs(recipes or {}) do
    local row = dimension(ledger, "recipe", id)
    local details = row and profession(ledger, dimension(ledger, "profession", row.professionId))
    if details and details.skillLineId ~= nil and not seen[details.skillLineId] then
      seen[details.skillLineId] = true
      result[#result + 1] = details
    end
  end
  table.sort(result, function(left, right) return left.skillLineId < right.skillLineId end)
  return result
end

local function requestedFacets(value)
  if value == nil then return facets end
  if type(value) ~= "table" or getmetatable(value) ~= nil then return nil end
  local count, seen = 0, {}
  for key, name in pairs(value) do
    if not integer(key, 1) or type(name) ~= "string" or not projectors[name] then return nil end
    count = count + 1
    seen[name] = true
  end
  for index = 1, count do if value[index] == nil then return nil end end
  local requested = {}
  for _, name in ipairs(facets) do
    if seen[name] then requested[#requested + 1] = name end
  end
  return requested
end

function API.GetFacets(filter, options)
  local normalized, reason = normalizeFilter(filter)
  if not normalized then return nil, reason end
  if options == nil then options = {} end
  if not keysAllowed(options, { mode = true, facets = true }) then return nil, "invalid-options" end
  local requested = requestedFacets(options.facets)
  if not requested then return nil, "invalid-options" end
  local mode = options.mode
  if mode == nil then mode = "self-excluding" end
  if mode ~= "self-excluding" and mode ~= "strict" then return nil, "invalid-options" end
  local ledger = addon.ledger
  if not ledger then return nil, "not-ready" end
  local result, seen = {}, {}
  for _, facet in ipairs(requested) do result[facet] = {}; seen[facet] = {} end
  for _, facet in ipairs(requested) do
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
  for _, facet in ipairs(requested) do
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
