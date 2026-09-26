local _, addon = ...

local Ledger = {}
Ledger.schemaVersion = 1
Ledger.retentionDays = 180
Ledger.maxCrafts = 50000

local dimensions = {
  realm = "realms",
  character = "characters",
  profession = "professions",
  recipe = "recipes",
  item = "items",
  session = "sessions",
  expansion = "expansions",
}

local function isInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge and
    value ~= -math.huge and value >= 1 and value % 1 == 0
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
    nextCraftId = 1,
    crafts = {},
    reagents = {},
    dimensions = {},
    nextDimensionId = {},
    retentionDays = Ledger.retentionDays,
    maxCrafts = Ledger.maxCrafts,
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

local function migrateZero(data)
  if data.retentionDays == nil then data.retentionDays = Ledger.retentionDays end
  if data.maxCrafts == nil then data.maxCrafts = Ledger.maxCrafts end
  data.schemaVersion = 1
  return data
end

local migrations = { [0] = migrateZero }

local references = {
  craft = { sessionDimensionId = "session", recipeDimensionId = "recipe",
    outputItemDimensionId = "item", professionDimensionId = "profession" },
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

local function validateDatabase(data)
  if not isArray(data.crafts) or not isArray(data.reagents) or
      type(data.dimensions) ~= "table" or type(data.nextDimensionId) ~= "table" then
    return nil, "ledger collections are invalid"
  end
  if not isInteger(data.nextCraftId) or data.nextCraftId <= maximumId(data.crafts, "id") then
    return nil, "nextCraftId would reuse an existing craft ID"
  end
  if type(data.retentionDays) ~= "number" or data.retentionDays < 1 or
      data.retentionDays % 1 ~= 0 then
    return nil, "retentionDays must be a positive integer"
  end
  if not isInteger(data.maxCrafts) then
    return nil, "maxCrafts must be a positive integer"
  end

  local ids = { craft = {} }
  for _, craft in ipairs(data.crafts) do
    if not isInteger(craft.id) or ids.craft[craft.id] or type(craft.timestamp) ~= "number" or
        craft.sessionDimensionId == nil then
      return nil, "craft facts contain an invalid or duplicate ID"
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
  for _, craft in ipairs(data.crafts) do
    local ok, reason = validateReferences("craft", craft, ids)
    if not ok then return nil, reason end
  end
  for _, reagent in ipairs(data.reagents) do
    if reagent.craftId == nil or reagent.itemDimensionId == nil then
      return nil, "reagent fact requires craft and item references"
    end
    local ok, reason = validateReferences("reagent", reagent, ids)
    if not ok then return nil, reason end
  end
  for kind, collection in pairs(dimensions) do
    for _, row in ipairs(data.dimensions[collection]) do
      local ok, reason = validateReferences(kind, row, ids)
      if not ok then return nil, reason end
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

local function openDatabase(database, clock, options)
  local data
  if database == nil then
    data = emptyDatabase()
  elseif type(database) ~= "table" then
    return nil, "ledger SavedVariables must be a table"
  else
    data = copyValue(database)
    local version = data.schemaVersion
    if not isInteger(version) and version ~= 0 then
      return nil, "ledger schema version is missing or invalid"
    end
    if version > Ledger.schemaVersion then
      return nil, "ledger schema is newer than this addon supports"
    end
    while version < Ledger.schemaVersion do
      local migrate = migrations[version]
      if not migrate then
        return nil, "no migration is available for ledger schema " .. tostring(version)
      end
      local migrated, reason = migrate(data)
      if not migrated then
        return nil, "ledger migration failed: " .. reason
      end
      data = migrated
      version = data.schemaVersion
    end
  end

  local valid, reason = validateDatabase(data)
  if not valid then
    return nil, "ledger data refused: " .. reason
  end
  if options then
    if options.retentionDays ~= nil then data.retentionDays = options.retentionDays end
    if options.maxCrafts ~= nil then data.maxCrafts = options.maxCrafts end
    valid, reason = validateDatabase(data)
    if not valid then
      return nil, "ledger options refused: " .. reason
    end
  end

  local self = setmetatable({
    database = data,
    wall = nowFunction(clock),
    dimensionIndex = {},
    dimensionRows = {},
    operationIndex = {},
  }, {
    __index = Ledger,
  })
  for kind, collection in pairs(dimensions) do
    local index = {}
    self.dimensionIndex[kind] = index
    self.dimensionRows[kind] = {}
    for _, row in ipairs(data.dimensions[collection]) do
      index[row.key] = row.id
      self.dimensionRows[kind][row.id] = row
    end
  end
  for _, craft in ipairs(data.crafts) do
    adjustOperationIndex(self, craft, 1)
  end
  self:Prune(self.wall())
  return self
end

function Ledger.New(database, clock, options)
  local ok, ledger, reason = pcall(openDatabase, database, clock, options)
  if not ok then return nil, "ledger data refused: " .. tostring(ledger) end
  return ledger, reason
end

local function enrich(target, attributes)
  for field, value in pairs(attributes) do
    if target[field] == nil then
      target[field] = copyValue(value)
    elseif type(target[field]) == "table" and type(value) == "table" then
      local ok, reason = enrich(target[field], value)
      if not ok then return nil, reason end
    elseif target[field] ~= value then
      return nil, "conflicting dimension attribute: " .. tostring(field)
    end
  end
  return true
end

function Ledger:AddDimension(kind, key, attributes)
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
  local existingId = self.dimensionIndex[kind][key]
  local existing = self.dimensionRows[kind][existingId]
  local row = existing and copyValue(existing) or {
    id = self.database.nextDimensionId[kind], key = key,
  }
  local ok, reason = enrich(row, safeAttributes)
  if not ok then return nil, reason end
  ok, reason = validateReferences(kind, row, self.dimensionRows)
  if not ok then return nil, reason end

  if existing then
    for field, value in pairs(row) do existing[field] = value end
    return existing.id
  end
  self.database.nextDimensionId[kind] = row.id + 1
  self.database.dimensions[collection][#self.database.dimensions[collection] + 1] = row
  self.dimensionIndex[kind][key] = row.id
  self.dimensionRows[kind][row.id] = row
  return row.id
end

function Ledger:CreateSession(metadata)
  metadata = metadata or {}
  local nextId = self.database.nextDimensionId.session
  local realmKey = "unresolved:session:" .. tostring(nextId)
  local identityScope = "session"
  if isInteger(metadata.projectId) and isInteger(metadata.regionId) and isInteger(metadata.gameRealmId) then
    realmKey = string.format("project:%d:region:%d:realm:%d",
      metadata.projectId, metadata.regionId, metadata.gameRealmId)
    identityScope = "runtime"
  end
  local realmId
  local reason
  if metadata.realmName ~= nil or metadata.gameRealmId ~= nil then
    realmId, reason = self:AddDimension("realm", realmKey, {
      name = metadata.realmName, gameRealmId = metadata.gameRealmId,
      regionId = metadata.regionId, projectId = metadata.projectId, identityScope = identityScope,
    })
    if not realmId then return nil, reason end
  end
  local characterId
  if metadata.characterGUID ~= nil or metadata.characterName ~= nil then
    local characterKey = realmKey .. (metadata.characterGUID and ":guid:" .. metadata.characterGUID or
      ":name:" .. metadata.characterName)
    characterId, reason = self:AddDimension("character", characterKey, {
      guid = metadata.characterGUID,
      name = metadata.characterName,
      realmDimensionId = realmId,
    })
    if not characterId then return nil, reason end
  end

  local sessionId
  sessionId, reason = self:AddDimension("session", "session-" .. tostring(nextId), {
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
  self.currentSessionId = sessionId
  self.pendingRecipeId = nil
  self.ambiguousRecipe = nil
  return sessionId
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

local function operationIdSeen(ledger, operationId)
  if operationId == nil or operationId <= 0 then
    return false
  end
  local sessionIndex = ledger.operationIndex[ledger.currentSessionId]
  return sessionIndex ~= nil and (sessionIndex[operationId] or 0) > 0
end

function Ledger:RecordResult(result)
  if type(result) ~= "table" then
    self.pendingRecipeId = nil
    self.ambiguousRecipe = nil
    return nil, "craft result must be a table"
  end
  if not self.currentSessionId then
    self.pendingRecipeId = nil
    self.ambiguousRecipe = nil
    return nil, "no ledger session is active"
  end
  local copied, snapshot = pcall(copyValue, result)
  local timestamp = observedNumber(self.wall())
  if not copied or timestamp == nil then
    self.pendingRecipeId, self.ambiguousRecipe = nil, nil
    return nil, "result snapshot or timestamp is unavailable"
  end
  result = snapshot

  local data = self.database
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

  local recipeId = self.pendingRecipeId
  self.pendingRecipeId = nil
  local ambiguousRecipe = self.ambiguousRecipe
  self.ambiguousRecipe = nil
  local reason
  if recipeId and not ambiguousRecipe and craft.gameOperationId and craft.gameOperationId > 0 and
      not operationIdSeen(self, craft.gameOperationId) then
    craft.recipeDimensionId, reason = self:AddDimension("recipe", recipeId, { gameRecipeId = recipeId })
    if not craft.recipeDimensionId then return nil, reason end
  end
  if isGameId(result.itemID) then
    craft.outputItemDimensionId, reason = self:AddDimension("item", result.itemID, { gameItemId = result.itemID })
    if not craft.outputItemDimensionId then return nil, reason end
  end

  local reagentFacts = {}
  if type(result.resourcesReturned) == "table" then
    for _, returned in ipairs(result.resourcesReturned) do
      local reagent = type(returned) == "table" and returned.reagent or nil
      local itemId = type(reagent) == "table" and reagent.itemID or nil
      local quantity = type(returned) == "table" and observedNumber(returned.quantity) or nil
      if isGameId(itemId) and quantity ~= nil then
        local itemDimensionId
        itemDimensionId, reason = self:AddDimension("item", itemId, { gameItemId = itemId })
        if not itemDimensionId then return nil, reason end
        reagentFacts[#reagentFacts + 1] = {
          craftId = craft.id,
          itemDimensionId = itemDimensionId,
          returnedQuantity = quantity,
        }
      end
    end
  end

  data.nextCraftId = craft.id + 1
  data.crafts[#data.crafts + 1] = craft
  adjustOperationIndex(self, craft, 1)
  for _, reagent in ipairs(reagentFacts) do data.reagents[#data.reagents + 1] = reagent end
  self:Prune(craft.timestamp)
  return craft
end

function Ledger:Prune(now)
  now = observedNumber(now) or observedNumber(self.wall())
  if now == nil then return {} end
  local data = self.database
  local cutoff = now - data.retentionDays * 86400
  local removed = {}
  local removedCrafts = {}
  local retained = {}
  for _, craft in ipairs(data.crafts) do
    if type(craft.timestamp) == "number" and craft.timestamp < cutoff then
      removed[craft.id] = true
      removedCrafts[craft.id] = craft
    else
      retained[#retained + 1] = craft
    end
  end
  data.crafts = retained

  if #data.crafts > data.maxCrafts then
    table.sort(data.crafts, function(left, right)
      local leftTime = observedNumber(left.timestamp) or -math.huge
      local rightTime = observedNumber(right.timestamp) or -math.huge
      if leftTime == rightTime then return left.id < right.id end
      return leftTime < rightTime
    end)
    local excess = #data.crafts - data.maxCrafts
    local kept = {}
    for index, craft in ipairs(data.crafts) do
      if index <= excess then
        removed[craft.id] = true
        removedCrafts[craft.id] = craft
      else
        kept[#kept + 1] = craft
      end
    end
    data.crafts = kept
    table.sort(data.crafts, function(left, right) return left.id < right.id end)
  end

  if next(removed) then
    for _, craft in pairs(removedCrafts) do
      adjustOperationIndex(self, craft, -1)
    end
    local keptReagents = {}
    for _, reagent in ipairs(data.reagents) do
      if not removed[reagent.craftId] then
        keptReagents[#keptReagents + 1] = reagent
      end
    end
    data.reagents = keptReagents
  end
  return removed
end

addon.Ledger = Ledger