local _, addon = ...

local Ledger = {}
Ledger.schemaVersion = 1
Ledger.schemaIdentity = "ArtisanLogbookLedger"
Ledger.retentionDays = 60

local maxInteger = 9007199254740991
local seriesMetrics = { "outputQuantity", "multicraftBonus", "concentrationSpent",
  "ingenuityProcCount", "ingenuityRefund" }

local function isFinite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local dimensions = {
  realm = "realms",
  character = "characters",
  profession = "professions",
  recipe = "recipes",
  item = "items",
  session = "sessions",
  expansion = "expansions",
}

local filterAttributes = {
  session = { "characterDimensionId", "realmDimensionId" },
  recipe = { "gameRecipeId", "professionDimensionId", "expansionDimensionId" },
  profession = { "skillLineId" },
}

local function isInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge and
    value ~= -math.huge and value >= 1 and value <= maxInteger and value % 1 == 0
end

local function isCount(value)
  return value == 0 or isInteger(value)
end

local function canAllocate(value)
  return isInteger(value) and value < maxInteger
end

local function isGameId(value)
  return type(value) == "number" and value == value and value ~= math.huge and
    value ~= -math.huge and value >= 0 and value % 1 == 0
end

local function copyValue(value, copies, depth)
  local kind = type(value)
  if kind ~= "table" and kind ~= "nil" and kind ~= "string" and kind ~= "boolean" and
      kind ~= "number" then error("unsupported persisted value") end
  if kind == "number" and (value ~= value or value == math.huge or value == -math.huge) then
    error("non-finite persisted value")
  end
  if type(value) ~= "table" then
    return value
  end
  depth = (depth or 0) + 1
  if depth > 32 or getmetatable(value) ~= nil then error("invalid persisted table") end
  copies = copies or {}
  if copies[value] then error("cyclic persisted table") end
  local result = {}
  copies[value] = true
  for key, child in pairs(value) do
    if type(key) ~= "string" and type(key) ~= "number" then error("invalid persisted key") end
    result[copyValue(key)] = copyValue(child, copies, depth)
  end
  copies[value] = nil
  return result
end

local function emptyDatabase()
  local data = {
    schemaVersion = Ledger.schemaVersion,
    schemaIdentity = Ledger.schemaIdentity,
    nextCraftId = 1,
    nextRequestId = 1,
    crafts = {},
    craftSeries = {},
    requests = {},
    reagents = {},
    dimensions = {},
    nextDimensionId = {},
    retentionDays = Ledger.retentionDays,
  }
  for kind, collection in pairs(dimensions) do
    data.dimensions[collection] = {}
    data.nextDimensionId[kind] = 1
  end
  return data
end

local function isArray(rows)
  if type(rows) ~= "table" then return false end
  local count = 0
  for key in pairs(rows) do
    if not isInteger(key) then return false end
    count = count + 1
  end
  for index = 1, count do
    if type(rows[index]) ~= "table" then return false end
  end
  return true
end

local function maximumId(rows, field)
  local highest = 0
  for _, row in ipairs(rows) do
    if type(row) == "table" and isInteger(row[field]) and row[field] > highest then
      highest = row[field]
    end
  end
  return highest
end

local references = {
  series = { characterDimensionId = "character", recipeDimensionId = "recipe" },
  craft = { sessionDimensionId = "session", recipeDimensionId = "recipe", requestId = "request",
    outputItemDimensionId = "item", professionDimensionId = "profession" },
  request = { sessionDimensionId = "session", recipeDimensionId = "recipe" },
  allocation = { itemDimensionId = "item" },
  reagent = { craftId = "craft", itemDimensionId = "item" },
  character = { realmDimensionId = "realm" },
  session = { characterDimensionId = "character", realmDimensionId = "realm" },
  recipe = { expansionDimensionId = "expansion", professionDimensionId = "profession" },
  item = { expansionDimensionId = "expansion" },
  profession = { expansionDimensionId = "expansion" },
}

local function validateReferences(kind, row, ids)
  for field in pairs(row) do
    if type(field) == "string" and (field:match("DimensionId$") or field == "introducedInExpansionId") and
        not (references[kind] or {})[field] then
      return nil, "unsupported reference: " .. kind .. "." .. field
    end
  end
  for field, target in pairs(references[kind] or {}) do
    local value = row[field]
    if value ~= nil and (not isInteger(value) or not ids[target][value]) then
      return nil, kind .. "." .. field .. " references a missing " .. target
    end
  end
  return true
end

local function seriesGroup(index, bucketStart, characterId)
  local bucket = index[bucketStart]
  if not bucket then
    bucket = {}
    index[bucketStart] = bucket
  end
  local key = characterId or 0
  if not bucket[key] then bucket[key] = {} end
  return bucket[key]
end

local function seriesMeasurement(craft, metric)
  if metric == "ingenuityProcCount" or metric == "ingenuityRefund" then
    if craft.hasIngenuityProc == false then return 0 end
    if craft.hasIngenuityProc ~= true then return nil end
    if metric == "ingenuityProcCount" then return 1 end
  end
  return craft[metric]
end

local function accumulateMetrics(row, existing, craft)
  for _, metric in ipairs(seriesMetrics) do
    local coverage = metric .. "ObservedCount"
    row[coverage] = existing and existing[coverage] or 0
    row[metric] = existing and existing[metric] or nil
    local value = seriesMeasurement(craft, metric)
    if value ~= nil then
      if not isFinite(value) then return nil, "invalid craft metric: " .. metric end
      if not isCount(row[coverage]) or row[coverage] >= maxInteger then
        return nil, "craft series coverage overflow: " .. metric
      end
      if metric == "ingenuityProcCount" and
          (not isCount(row[metric] or 0) or (row[metric] or 0) > maxInteger - value) then
        return nil, "craft series proc count overflow"
      end
      row[metric] = (row[metric] or 0) + value
      row[coverage] = row[coverage] + 1
      if not isFinite(row[metric]) then return nil, "craft series sum overflow: " .. metric end
    end
  end
  return true
end

local function stageSeries(index, sessions, craft)
  local bucketStart = math.floor(craft.timestamp / 86400) * 86400
  if not isFinite(bucketStart) then return nil, "invalid craft series bucket" end
  local session = sessions[craft.sessionDimensionId]
  local characterId = session and session.characterDimensionId
  local bucket = index[bucketStart]
  local group = bucket and bucket[characterId or 0]
  local key = craft.recipeDimensionId or 0
  local existing = group and group[key]
  if existing and (not isInteger(existing.craftCount) or existing.craftCount >= maxInteger) then
    return nil, "craft series count overflow"
  end
  local row = {
    bucketStart = bucketStart,
    characterDimensionId = characterId,
    recipeDimensionId = craft.recipeDimensionId,
    craftCount = (existing and existing.craftCount or 0) + 1,
  }
  local ok, reason = accumulateMetrics(row, existing, craft)
  if not ok then return nil, reason end
  return {
    row = row, existing = existing, bucketStart = bucketStart,
    characterDimensionId = characterId, key = key,
  }
end

local function commitStagedSeries(data, index, staged)
  if staged.existing then
    for field in pairs(staged.existing) do staged.existing[field] = nil end
    for field, value in pairs(staged.row) do staged.existing[field] = value end
  else
    local group = seriesGroup(index, staged.bucketStart, staged.characterDimensionId)
    data.craftSeries[#data.craftSeries + 1] = staged.row
    group[staged.key] = staged.row
  end
end

local function validateDatabase(data)
  if data.schemaVersion ~= Ledger.schemaVersion or data.schemaIdentity ~= Ledger.schemaIdentity then
    return nil, "unsupported ledger schema"
  end
  if not isArray(data.crafts) or not isArray(data.reagents) or not isArray(data.requests) or
      type(data.dimensions) ~= "table" or type(data.nextDimensionId) ~= "table" then
    return nil, "ledger collections are invalid"
  end
  if not isInteger(data.nextCraftId) or data.nextCraftId <= maximumId(data.crafts, "id") then
    return nil, "nextCraftId would reuse an existing craft ID"
  end
  if not isInteger(data.nextRequestId) or data.nextRequestId <= maximumId(data.requests, "id") then
    return nil, "nextRequestId would reuse an existing request ID"
  end
  if not isInteger(data.retentionDays) then
    return nil, "retentionDays must be a positive integer"
  end
  if data.maxCrafts ~= nil then
    return nil, "schema 1 does not support maxCrafts"
  end

  local ids = { craft = {}, request = {} }
  for _, craft in ipairs(data.crafts) do
    if not isInteger(craft.id) or ids.craft[craft.id] or not isFinite(craft.timestamp) or
        craft.sessionDimensionId == nil then
      return nil, "craft facts contain an invalid or duplicate ID"
    end
    for _, field in ipairs({ "gameOperationId", "outputQuality", "outputItemLevel", "outputQuantity",
      "multicraftBonus", "concentrationSpent", "concentrationCurrencyId", "ingenuityRefund" }) do
      if craft[field] ~= nil and not isFinite(craft[field]) then
        return nil, "invalid craft measurement: " .. field
      end
    end
    if craft.hasIngenuityProc ~= nil and type(craft.hasIngenuityProc) ~= "boolean" then
      return nil, "invalid craft boolean: hasIngenuityProc"
    end
    ids.craft[craft.id] = true
  end

  for kind, collection in pairs(dimensions) do
    local rows = data.dimensions[collection]
    if not isArray(rows) or not isInteger(data.nextDimensionId[kind]) or
        data.nextDimensionId[kind] <= maximumId(rows, "id") then
      return nil, "dimension collection or counter is invalid for " .. kind
    end
    local seenIds, seenKeys = {}, {}
    ids[kind] = seenIds
    for _, row in ipairs(rows) do
      if type(row) ~= "table" or not isInteger(row.id) or type(row.key) ~= "string" or
          seenIds[row.id] or seenKeys[row.key] then
        return nil, "dimension rows are invalid for " .. kind
      end
      seenIds[row.id] = true
      seenKeys[row.key] = true
    end
  end
  for _, request in ipairs(data.requests) do
    if not isInteger(request.id) or ids.request[request.id] or not isFinite(request.timestamp) or
        request.sessionDimensionId == nil or request.recipeDimensionId == nil or
        not isInteger(request.requestedCount) or type(request.useConcentration) ~= "boolean" then
      return nil, "request facts contain an invalid or duplicate ID"
    end
    ids.request[request.id] = request
    for _, field in ipairs({ "concentrationCost", "baseSkill", "baseDifficulty", "craftingQuality" }) do
      if request[field] ~= nil and not isFinite(request[field]) then
        return nil, "invalid request quote: " .. field
      end
    end
    if request.allocations ~= nil and not isArray(request.allocations) then
      return nil, "request allocations are invalid"
    end
  end
  for _, request in ipairs(data.requests) do
    local ok, reason = validateReferences("request", request, ids)
    if not ok then return nil, reason end
    for _, allocation in ipairs(request.allocations or {}) do
      if not isInteger(allocation.dataSlotIndex) or not isInteger(allocation.allocatedQuantity) or
          allocation.itemDimensionId == nil or
          (allocation.quality ~= nil and not isGameId(allocation.quality)) then
        return nil, "request allocation is invalid"
      end
      ok, reason = validateReferences("allocation", allocation, ids)
      if not ok then return nil, reason end
    end
  end
  local linkedCounts = {}
  for _, craft in ipairs(data.crafts) do
    local ok, reason = validateReferences("craft", craft, ids)
    if not ok then return nil, reason end
    if craft.requestId then
      local request = ids.request[craft.requestId]
      if request.sessionDimensionId ~= craft.sessionDimensionId or
          request.recipeDimensionId ~= craft.recipeDimensionId then
        return nil, "craft.requestId conflicts with request context"
      end
      linkedCounts[request.id] = (linkedCounts[request.id] or 0) + 1
      if linkedCounts[request.id] > request.requestedCount then
        return nil, "craft.requestId exceeds requested count"
      end
    end
  end
  for _, reagent in ipairs(data.reagents) do
    if reagent.craftId == nil or reagent.itemDimensionId == nil then
      return nil, "reagent fact requires craft and item references"
    end
    local ok, reason = validateReferences("reagent", reagent, ids)
    if not ok then return nil, reason end
    if (reagent.dataSlotIndex ~= nil and not isInteger(reagent.dataSlotIndex)) or
        (reagent.allocatedQuantity ~= nil and not isInteger(reagent.allocatedQuantity)) or
        (reagent.returnedQuantity ~= nil and not isFinite(reagent.returnedQuantity)) then
      return nil, "invalid reagent allocation or measurement"
    end
  end
  for kind, collection in pairs(dimensions) do
    for _, row in ipairs(data.dimensions[collection]) do
      local ok, reason = validateReferences(kind, row, ids)
      if not ok then return nil, reason end
    end
  end
  if not isArray(data.craftSeries) then return nil, "craftSeries must be a dense array" end
  local seen = {}
  for _, row in ipairs(data.craftSeries) do
    local ok, reason = validateReferences("series", row, ids)
    if not ok then return nil, reason end
    if not isFinite(row.bucketStart) or row.bucketStart % 86400 ~= 0 or
        not isInteger(row.craftCount) then
      return nil, "invalid craft series bucket or count"
    end
    local group = seriesGroup(seen, row.bucketStart, row.characterDimensionId)
    local key = row.recipeDimensionId or 0
    if group[key] then return nil, "duplicate craft series grain" end
    group[key] = true
    for _, metric in ipairs(seriesMetrics) do
      local count = row[metric .. "ObservedCount"]
      if not isCount(count) or count > row.craftCount or
          (count == 0 and row[metric] ~= nil) or
          (count > 0 and not isFinite(row[metric])) then
        return nil, "invalid craft series coverage or sum: " .. metric
      end
    end
    if row.ingenuityProcCount ~= nil and
        (not isCount(row.ingenuityProcCount) or
          row.ingenuityProcCount > row.ingenuityProcCountObservedCount) then
      return nil, "invalid craft series proc count"
    end
    if row.ingenuityRefundObservedCount > row.ingenuityProcCountObservedCount or
        row.ingenuityRefundObservedCount <
          row.ingenuityProcCountObservedCount - (row.ingenuityProcCount or 0) then
      return nil, "craft series refund coverage conflicts with proc coverage"
    end
    if row.ingenuityProcCount == 0 and row.ingenuityRefund ~= nil and row.ingenuityRefund ~= 0 then
      return nil, "craft series refund without an observed proc"
    end
  end
  return true
end

local function nowFunction(clock)
  if clock and type(clock.wall) == "function" then
    return clock.wall
  end
  if type(time) == "function" then
    return time
  end
  return function() return nil end
end

local function adjustOperationIndex(ledger, craft, change)
  local sessionId = craft.sessionDimensionId
  local operationId = craft.gameOperationId
  if sessionId == nil or type(operationId) ~= "number" or operationId <= 0 then
    return
  end
  local sessionIndex = ledger.operationIndex[sessionId]
  if not sessionIndex then
    sessionIndex = {}
    ledger.operationIndex[sessionId] = sessionIndex
  end
  local count = (sessionIndex[operationId] or 0) + change
  if count > 0 then
    sessionIndex[operationId] = count
  else
    sessionIndex[operationId] = nil
    if next(sessionIndex) == nil then
      ledger.operationIndex[sessionId] = nil
    end
  end
end

local function appendIdentity(index, identity, craftId)
  if identity == nil then return end
  local ids = index[identity]
  if not ids then
    ids = {}
    index[identity] = ids
  end
  ids[#ids + 1] = craftId
end

local function indexCraftDimensions(ledger, craft)
  local rows = ledger.dimensionRows
  local session = rows.session[craft.sessionDimensionId]
  local character = session and rows.character[session.characterDimensionId]
  local realm = session and rows.realm[session.realmDimensionId]
  local recipe = rows.recipe[craft.recipeDimensionId]
  local profession = rows.profession[craft.professionDimensionId or
    (recipe and recipe.professionDimensionId)]
  local expansion = recipe and rows.expansion[recipe.expansionDimensionId]
  appendIdentity(ledger.craftIdsByCharacter, character and character.key, craft.id)
  appendIdentity(ledger.craftIdsByRealm, realm and realm.key, craft.id)
  appendIdentity(ledger.craftIdsByRecipe,
    recipe and type(recipe.gameRecipeId) == "number" and recipe.gameRecipeId or nil, craft.id)
  appendIdentity(ledger.craftIdsByProfession,
    profession and type(profession.skillLineId) == "number" and profession.skillLineId or nil, craft.id)
  appendIdentity(ledger.craftIdsByExpansion, expansion and expansion.key, craft.id)
end

function Ledger:RebuildFilterIndexes()
  self.craftIdsByCharacter = {}
  self.craftIdsByRealm = {}
  self.craftIdsByRecipe = {}
  self.craftIdsByProfession = {}
  self.craftIdsByExpansion = {}
  for _, id in ipairs(self.craftIds) do
    indexCraftDimensions(self, self.craftById[id])
  end
end

local function earlierCraft(ledger, leftId, rightId)
  local left, right = ledger.craftById[leftId], ledger.craftById[rightId]
  if left.timestamp == right.timestamp then return leftId < rightId end
  return left.timestamp < right.timestamp
end

function Ledger:RebuildIndexes()
  self.dimensionIndex, self.dimensionRows = {}, {}
  for kind, collection in pairs(dimensions) do
    self.dimensionIndex[kind], self.dimensionRows[kind] = {}, {}
    for _, row in ipairs(self.database.dimensions[collection]) do
      self.dimensionIndex[kind][row.key] = row.id
      self.dimensionRows[kind][row.id] = row
    end
  end
  self.seriesByKey = {}
  for _, row in ipairs(self.database.craftSeries) do
    local group = seriesGroup(self.seriesByKey, row.bucketStart, row.characterDimensionId)
    group[row.recipeDimensionId or 0] = row
  end
  self.craftById, self.requestById, self.reagentsByCraftId = {}, {}, {}
  self.craftIds, self.craftIdsByTime, self.operationIndex = {}, {}, {}
  for _, request in ipairs(self.database.requests) do self.requestById[request.id] = request end
  for _, craft in ipairs(self.database.crafts) do
    self.craftById[craft.id] = craft
    self.reagentsByCraftId[craft.id] = {}
    self.craftIds[#self.craftIds + 1] = craft.id
    self.craftIdsByTime[#self.craftIdsByTime + 1] = craft.id
    adjustOperationIndex(self, craft, 1)
  end
  for _, reagent in ipairs(self.database.reagents) do
    local rows = self.reagentsByCraftId[reagent.craftId]
    rows[#rows + 1] = reagent
  end
  table.sort(self.craftIds)
  table.sort(self.craftIdsByTime, function(left, right) return earlierCraft(self, left, right) end)
  self:RebuildFilterIndexes()
end

local function appendCraftIndexes(ledger, craft, reagents)
  ledger.craftById[craft.id] = craft
  ledger.reagentsByCraftId[craft.id] = reagents
  ledger.craftIds[#ledger.craftIds + 1] = craft.id
  local times = ledger.craftIdsByTime
  if #times == 0 or earlierCraft(ledger, times[#times], craft.id) then
    times[#times + 1] = craft.id
  else
    local low, high = 1, #times
    while low <= high do
      local middle = math.floor((low + high) / 2)
      if earlierCraft(ledger, times[middle], craft.id) then low = middle + 1
      else high = middle - 1 end
    end
    table.insert(times, low, craft.id)
  end
  indexCraftDimensions(ledger, craft)
  adjustOperationIndex(ledger, craft, 1)
end

local function openDatabase(database, clock, options)
  local data
  if database == nil then
    data = emptyDatabase()
  elseif type(database) ~= "table" then
    return nil, "ledger SavedVariables must be a table"
  else
    data = copyValue(database)
  end

  local valid, reason = validateDatabase(data)
  if not valid then
    return nil, "ledger data refused: " .. reason
  end
  if options then
    if options.maxCrafts ~= nil then
      return nil, "ledger options refused: schema 1 does not support maxCrafts"
    end
    if options.retentionDays ~= nil then data.retentionDays = options.retentionDays end
    valid, reason = validateDatabase(data)
    if not valid then
      return nil, "ledger options refused: " .. reason
    end
  end

  local self = setmetatable({
    database = data,
    wall = nowFunction(clock),
  }, {
    __index = Ledger,
  })
  self:Prune(self.wall())
  self:RebuildIndexes()
  return self
end

function Ledger.New(database, clock, options)
  local ok, ledger, reason = pcall(openDatabase, database, clock, options)
  if not ok then return nil, "ledger data refused: " .. tostring(ledger) end
  return ledger, reason
end

local function enrich(target, attributes)
  local changed = false
  for field, value in pairs(attributes) do
    if target[field] == nil then
      target[field] = copyValue(value)
      changed = true
    elseif type(target[field]) == "table" and type(value) == "table" then
      local ok, reason, nestedChanged = enrich(target[field], value)
      if not ok then return nil, reason end
      changed = changed or nestedChanged
    elseif target[field] ~= value then
      return nil, "conflicting dimension attribute: " .. tostring(field)
    end
  end
  return true, nil, changed
end

local function dimensionStage(ledger)
  -- Overlay only touched dimensions; capture never copies or scans historical facts.
  local staged = { rows = {}, keys = {}, nextIds = {}, changes = {} }
  for kind in pairs(dimensions) do
    staged.rows[kind] = setmetatable({}, { __index = ledger.dimensionRows[kind] })
    staged.keys[kind] = setmetatable({}, { __index = ledger.dimensionIndex[kind] })
    staged.nextIds[kind] = ledger.database.nextDimensionId[kind]
  end
  return staged
end

local function stageDimension(staged, kind, key, attributes)
  local collection = dimensions[kind]
  if not collection or (type(key) ~= "string" and type(key) ~= "number") then
    return nil, "dimension kind or key is invalid"
  end
  if attributes ~= nil and type(attributes) ~= "table" then
    return nil, "dimension attributes must be a table"
  end
  local copied, safeAttributes = pcall(copyValue, attributes or {})
  if not copied then return nil, tostring(safeAttributes) end
  key = tostring(key)
  local existingId = staged.keys[kind][key]
  local existing = staged.rows[kind][existingId]
  if not existing and not canAllocate(staged.nextIds[kind]) then
    return nil, "dimension ID capacity exhausted: " .. kind
  end
  local row = existing and copyValue(existing) or {
    id = staged.nextIds[kind], key = key,
  }
  local ok, reason, changed = enrich(row, safeAttributes)
  if not ok then return nil, reason end
  ok, reason = validateReferences(kind, row, staged.rows)
  if not ok then return nil, reason end
  if not existing or changed then
    staged.changes[#staged.changes + 1] = { kind = kind, row = row }
    staged.rows[kind][row.id] = row
    staged.keys[kind][key] = row.id
  end
  if not existing then staged.nextIds[kind] = row.id + 1 end
  return row.id
end

local function commitDimensions(ledger, staged)
  local filtersChanged = false
  for _, change in ipairs(staged.changes) do
    local kind, row = change.kind, change.row
    local existing = ledger.dimensionRows[kind][row.id]
    if existing then
      for _, field in ipairs(filterAttributes[kind] or {}) do
        if existing[field] ~= row[field] then filtersChanged = true end
      end
      for field, value in pairs(row) do existing[field] = value end
    else
      local rows = ledger.database.dimensions[dimensions[kind]]
      rows[#rows + 1] = row
      ledger.dimensionIndex[kind][row.key] = row.id
      ledger.dimensionRows[kind][row.id] = row
    end
  end
  for kind, nextId in pairs(staged.nextIds) do ledger.database.nextDimensionId[kind] = nextId end
  if filtersChanged then ledger:RebuildFilterIndexes() end
end

function Ledger:AddDimension(kind, key, attributes)
  local staged = dimensionStage(self)
  local id, reason = stageDimension(staged, kind, key, attributes)
  if not id then return nil, reason end
  commitDimensions(self, staged)
  return id
end

local function createSession(self, metadata)
  metadata = metadata or {}
  if type(metadata) ~= "table" then return nil, "session metadata must be a table" end
  local staged = dimensionStage(self)
  local nextId = self.database.nextDimensionId.session
  if not canAllocate(nextId) then return nil, "session ID capacity exhausted" end
  local sessionKey = string.format("%.0f", nextId)
  local realmKey = "unresolved:session:" .. sessionKey
  local identityScope = "session"
  if isGameId(metadata.projectId) and metadata.projectId > 0 and
      isGameId(metadata.regionId) and metadata.regionId > 0 and
      isGameId(metadata.gameRealmId) and metadata.gameRealmId > 0 then
    realmKey = string.format("project:%d:region:%d:realm:%d",
      metadata.projectId, metadata.regionId, metadata.gameRealmId)
    identityScope = "runtime"
  end
  local realmId
  local reason
  if metadata.realmName ~= nil or metadata.gameRealmId ~= nil then
    realmId, reason = stageDimension(staged, "realm", realmKey, {
      name = metadata.realmName, gameRealmId = metadata.gameRealmId,
      regionId = metadata.regionId, projectId = metadata.projectId, identityScope = identityScope,
    })
    if not realmId then return nil, reason end
  end
  local characterId
  if metadata.characterGUID ~= nil or metadata.characterName ~= nil then
    local characterKey = realmKey .. (metadata.characterGUID and ":guid:" .. metadata.characterGUID or
      ":name:" .. metadata.characterName)
    characterId, reason = stageDimension(staged, "character", characterKey, {
      guid = metadata.characterGUID,
      name = metadata.characterName,
      realmDimensionId = realmId,
    })
    if not characterId then return nil, reason end
  end

  local sessionId
  sessionId, reason = stageDimension(staged, "session", "session-" .. sessionKey, {
    startedAt = metadata.startedAt or self.wall(),
    addonVersion = metadata.addonVersion,
    wowVersion = metadata.wowVersion,
    wowBuild = metadata.wowBuild,
    wowBuildDate = metadata.wowBuildDate,
    interface = metadata.interface,
    projectId = metadata.projectId,
    locale = metadata.locale,
    characterDimensionId = characterId,
    realmDimensionId = realmId,
    capabilities = copyValue(metadata.capabilities or {}),
  })
  if not sessionId then return nil, reason end
  commitDimensions(self, staged)
  self.currentSessionId = sessionId
  self.pendingRecipeId = nil
  self.ambiguousRecipe = nil
  self.pendingRequest = nil
  self.requestAmbiguous = nil
  return sessionId
end

function Ledger:CreateSession(metadata)
  local ok, sessionId, reason = pcall(createSession, self, metadata)
  if not ok then return nil, tostring(sessionId) end
  return sessionId, reason
end

function Ledger:BeginCraft(recipeId)
  if self.ambiguousRecipe then
    return
  end
  if self.pendingRecipeId then
    self.pendingRecipeId = nil
    self.ambiguousRecipe = true
    return
  end
  if isGameId(recipeId) then
    self.pendingRecipeId = recipeId
  else
    self.pendingRecipeId = nil
  end
end

local function observedNumber(value)
  if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
    return value
  end
  return nil
end

function Ledger:SubmitCraft(recipeId, requestedCount, useConcentration, quote, selections)
  if not self.currentSessionId or not isGameId(recipeId) or not isInteger(requestedCount) or
      type(useConcentration) ~= "boolean" then
    return nil, "personal craft submission is incomplete"
  end
  if not canAllocate(self.database.nextRequestId) then return nil, "request ID capacity exhausted" end
  if quote ~= nil and type(quote) ~= "table" then return nil, "quote is invalid" end
  if selections ~= nil and not isArray(selections) then return nil, "allocations are invalid" end
  local copied, snapshot = pcall(copyValue, { selections = selections })
  local timestamp = observedNumber(self.wall())
  if not copied or timestamp == nil then return nil, "request snapshot or timestamp is unavailable" end
  local staged = dimensionStage(self)
  local recipeDimensionId, reason = stageDimension(staged, "recipe", recipeId, { gameRecipeId = recipeId })
  if not recipeDimensionId then return nil, reason end
  local request = {
    id = self.database.nextRequestId,
    timestamp = timestamp,
    sessionDimensionId = self.currentSessionId,
    recipeDimensionId = recipeDimensionId,
    requestedCount = requestedCount,
    useConcentration = useConcentration,
  }
  for _, field in ipairs({ "concentrationCost", "baseSkill", "baseDifficulty", "craftingQuality" }) do
    request[field] = quote and observedNumber(quote[field]) or nil
  end
  if snapshot.selections then
    local allocations = {}
    for _, selection in ipairs(snapshot.selections) do
      local itemId = type(selection.reagent) == "table" and selection.reagent.itemID or nil
      if isInteger(selection.dataSlotIndex) and isGameId(itemId) and itemId > 0 and
          isInteger(selection.quantity) then
        local itemDimensionId
        itemDimensionId, reason = stageDimension(staged, "item", itemId, { gameItemId = itemId })
        if not itemDimensionId then return nil, reason end
        allocations[#allocations + 1] = {
          dataSlotIndex = selection.dataSlotIndex,
          itemDimensionId = itemDimensionId,
          allocatedQuantity = selection.quantity,
          quality = isGameId(selection.quality) and selection.quality or nil,
        }
      end
    end
    if #allocations > 0 then request.allocations = allocations end
  end
  commitDimensions(self, staged)
  self.database.nextRequestId = request.id + 1
  self.database.requests[#self.database.requests + 1] = request
  self.requestById[request.id] = request
  if self.pendingRequest then self.requestAmbiguous = true end
  self.pendingRequest = self.requestAmbiguous and nil or { id = request.id, remaining = requestedCount }
  return request
end

function Ledger:CancelCraft()
  self.pendingRequest = nil
  self.requestAmbiguous = nil
  self.pendingRecipeId = nil
  self.ambiguousRecipe = nil
end

function Ledger:InvalidateCraft()
  if self.pendingRequest then
    self.pendingRequest = nil
    self.requestAmbiguous = true
  end
end

local function operationIdSeen(ledger, operationId)
  if operationId == nil or operationId <= 0 then
    return false
  end
  local sessionIndex = ledger.operationIndex[ledger.currentSessionId]
  return sessionIndex ~= nil and (sessionIndex[operationId] or 0) > 0
end

function Ledger:RecordResult(result)
  if type(result) ~= "table" then
    return nil, "craft result must be a table"
  end
  if not self.currentSessionId then
    return nil, "no ledger session is active"
  end
  if not canAllocate(self.database.nextCraftId) then return nil, "craft ID capacity exhausted" end
  local copied, snapshot = pcall(copyValue, result)
  local timestamp = observedNumber(self.wall())
  if not copied or timestamp == nil then
    return nil, "result snapshot or timestamp is unavailable"
  end
  result = snapshot

  local data = self.database
  local stagedDimensions = dimensionStage(self)
  local craft = {
    id = data.nextCraftId,
    timestamp = timestamp,
    sessionDimensionId = self.currentSessionId,
    gameOperationId = observedNumber(result.operationID),
    outputQuality = observedNumber(result.craftingQuality),
    outputItemLevel = observedNumber(result.itemLevel),
    outputQuantity = observedNumber(result.quantity),
    multicraftBonus = observedNumber(result.multicraft),
    concentrationSpent = observedNumber(result.concentrationSpent),
    concentrationCurrencyId = observedNumber(result.concentrationCurrencyID),
    ingenuityRefund = observedNumber(result.ingenuityRefund),
  }
  if type(result.hasIngenuityProc) == "boolean" then
    craft.hasIngenuityProc = result.hasIngenuityProc
  end

  local pending = self.pendingRequest
  local request
  if pending and not self.requestAmbiguous then
    request = self.requestById[pending.id]
    if request then
      craft.requestId = request.id
      craft.recipeDimensionId = request.recipeDimensionId
    end
  end

  local recipeId = self.pendingRecipeId
  local ambiguousRecipe = self.ambiguousRecipe
  local reason
  if not craft.recipeDimensionId and not self.requestAmbiguous and recipeId and not ambiguousRecipe and
      craft.gameOperationId and craft.gameOperationId > 0 and
      not operationIdSeen(self, craft.gameOperationId) then
    craft.recipeDimensionId, reason =
      stageDimension(stagedDimensions, "recipe", recipeId, { gameRecipeId = recipeId })
    if not craft.recipeDimensionId then return nil, reason end
  end

  -- Stage the aggregate first. Any handled failure must leave correlation,
  -- dimensions, facts, and the persisted series untouched.
  local stagedSeries
  stagedSeries, reason = stageSeries(self.seriesByKey, self.dimensionRows.session, craft)
  if not stagedSeries then return nil, reason end

  if isGameId(result.itemID) then
    craft.outputItemDimensionId, reason =
      stageDimension(stagedDimensions, "item", result.itemID, { gameItemId = result.itemID })
    if not craft.outputItemDimensionId then return nil, reason end
  end

  local reagentFacts = {}
  local allocationsByItem = {}
  local allocatedFactsByItem = {}
  if request and request.allocations then
    for _, allocation in ipairs(request.allocations) do
      reagentFacts[#reagentFacts + 1] = {
        craftId = craft.id,
        itemDimensionId = allocation.itemDimensionId,
        dataSlotIndex = allocation.dataSlotIndex,
        quality = allocation.quality,
        allocatedQuantity = allocation.allocatedQuantity,
        returnedQuantity = type(result.resourcesReturned) == "table" and 0 or nil,
      }
      local itemId = allocation.itemDimensionId
      allocatedFactsByItem[itemId] = allocatedFactsByItem[itemId] or {}
      allocatedFactsByItem[itemId][#allocatedFactsByItem[itemId] + 1] = reagentFacts[#reagentFacts]
      if allocationsByItem[itemId] == nil then
        allocationsByItem[itemId] = reagentFacts[#reagentFacts]
      else
        allocationsByItem[itemId] = false
      end
    end
  end
  if type(result.resourcesReturned) == "table" then
    for _, returned in ipairs(result.resourcesReturned) do
      local reagent = type(returned) == "table" and returned.reagent or nil
      local itemId = type(reagent) == "table" and reagent.itemID or nil
      local quantity = type(returned) == "table" and observedNumber(returned.quantity) or nil
      if isGameId(itemId) and quantity ~= nil then
        local itemDimensionId
        itemDimensionId, reason = stageDimension(stagedDimensions, "item", itemId, { gameItemId = itemId })
        if not itemDimensionId then return nil, reason end
        local matched = allocationsByItem[itemDimensionId]
        if matched then
          matched.returnedQuantity = matched.returnedQuantity + quantity
          if not isFinite(matched.returnedQuantity) then return nil, "reagent return sum overflow" end
        else
          if allocatedFactsByItem[itemDimensionId] then
            for _, allocated in ipairs(allocatedFactsByItem[itemDimensionId]) do
              allocated.returnedQuantity = nil
            end
          end
          reagentFacts[#reagentFacts + 1] = {
            craftId = craft.id,
            itemDimensionId = itemDimensionId,
            returnedQuantity = quantity,
          }
        end
      end
    end
  end

  commitDimensions(self, stagedDimensions)
  commitStagedSeries(data, self.seriesByKey, stagedSeries)
  self.pendingRecipeId = nil
  self.ambiguousRecipe = nil
  data.nextCraftId = craft.id + 1
  data.crafts[#data.crafts + 1] = craft
  if pending and request then
    pending.remaining = pending.remaining - 1
    if pending.remaining == 0 then self.pendingRequest = nil end
  end
  for _, reagent in ipairs(reagentFacts) do data.reagents[#data.reagents + 1] = reagent end
  appendCraftIndexes(self, craft, reagentFacts)
  if self.onCraftCommitted then pcall(self.onCraftCommitted, self, craft) end
  return craft
end

function Ledger:Prune(now)
  now = observedNumber(now) or observedNumber(self.wall())
  if now == nil then return {} end
  local data = self.database
  local cutoff = now - data.retentionDays * 86400
  local removed = {}
  local retained = {}
  for _, craft in ipairs(data.crafts) do
    if type(craft.timestamp) == "number" and craft.timestamp < cutoff then
      removed[craft.id] = true
    else
      retained[#retained + 1] = craft
    end
  end
  data.crafts = retained

  if next(removed) then
    local keptReagents = {}
    for _, reagent in ipairs(data.reagents) do
      if not removed[reagent.craftId] then
        keptReagents[#keptReagents + 1] = reagent
      end
    end
    data.reagents = keptReagents
  end
  local referenced = {}
  for _, craft in ipairs(data.crafts) do
    if craft.requestId then referenced[craft.requestId] = true end
  end
  local keptRequests = {}
  for _, request in ipairs(data.requests) do
    if referenced[request.id] or request.timestamp >= cutoff then
      keptRequests[#keptRequests + 1] = request
    end
  end
  data.requests = keptRequests
  if self.craftById then self:RebuildIndexes() end
  return removed
end

addon.Ledger = Ledger