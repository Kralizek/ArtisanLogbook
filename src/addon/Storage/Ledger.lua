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

local function copyValue(value, copies)
  if type(value) ~= "table" then
    return value
  end
  copies = copies or {}
  if copies[value] then
    return copies[value]
  end
  local result = {}
  copies[value] = result
  for key, child in pairs(value) do
    result[copyValue(key, copies)] = copyValue(child, copies)
  end
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

local function ensureTable(parent, key, label)
  if parent[key] == nil then
    parent[key] = {}
  elseif type(parent[key]) ~= "table" then
    return nil, label .. " must be a table"
  end
  return parent[key]
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
  local crafts, reason = ensureTable(data, "crafts", "crafts")
  if not crafts then return nil, reason end
  local reagents
  reagents, reason = ensureTable(data, "reagents", "reagents")
  if not reagents then return nil, reason end
  local allDimensions
  allDimensions, reason = ensureTable(data, "dimensions", "dimensions")
  if not allDimensions then return nil, reason end
  local counters
  counters, reason = ensureTable(data, "nextDimensionId", "nextDimensionId")
  if not counters then return nil, reason end

  for kind, collection in pairs(dimensions) do
    local rows
    rows, reason = ensureTable(allDimensions, collection, "dimensions." .. collection)
    if not rows then return nil, reason end
    local nextId = counters[kind]
    if nextId == nil then
      counters[kind] = maximumId(rows, "id") + 1
    elseif not isInteger(nextId) then
      return nil, "nextDimensionId." .. kind .. " must be a positive integer"
    end
  end

  if data.nextCraftId == nil then
    data.nextCraftId = maximumId(crafts, "id") + 1
  elseif not isInteger(data.nextCraftId) then
    return nil, "nextCraftId must be a positive integer"
  end
  data.retentionDays = data.retentionDays or Ledger.retentionDays
  data.maxCrafts = data.maxCrafts or Ledger.maxCrafts
  data.schemaVersion = 1
  return data
end

local migrations = { [0] = migrateZero }

local function validateDatabase(data)
  if type(data.crafts) ~= "table" or type(data.reagents) ~= "table" or
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

  local craftIds = {}
  for _, craft in ipairs(data.crafts) do
    if type(craft) ~= "table" or not isInteger(craft.id) or craftIds[craft.id] then
      return nil, "craft facts contain an invalid or duplicate ID"
    end
    craftIds[craft.id] = true
  end
  for _, reagent in ipairs(data.reagents) do
    if type(reagent) ~= "table" or not isInteger(reagent.craftId) or not craftIds[reagent.craftId] then
      return nil, "reagent fact references a missing craft"
    end
  end

  for kind, collection in pairs(dimensions) do
    local rows = data.dimensions[collection]
    if type(rows) ~= "table" or not isInteger(data.nextDimensionId[kind]) or
        data.nextDimensionId[kind] <= maximumId(rows, "id") then
      return nil, "dimension collection or counter is invalid for " .. kind
    end
    local seenIds, seenKeys = {}, {}
    for _, row in ipairs(rows) do
      if type(row) ~= "table" or not isInteger(row.id) or type(row.key) ~= "string" or
          seenIds[row.id] or seenKeys[row.key] then
        return nil, "dimension rows are invalid for " .. kind
      end
      seenIds[row.id] = true
      seenKeys[row.key] = true
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
  return function() return 0 end
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

function Ledger.New(database, clock, options)
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
    operationIndex = {},
  }, {
    __index = Ledger,
  })
  for kind, collection in pairs(dimensions) do
    local index = {}
    self.dimensionIndex[kind] = index
    for _, row in ipairs(data.dimensions[collection]) do
      index[row.key] = row.id
    end
  end
  for _, craft in ipairs(data.crafts) do
    adjustOperationIndex(self, craft, 1)
  end
  self:Prune(self.wall())
  return self
end

function Ledger:AddDimension(kind, key, attributes)
  local collection = dimensions[kind]
  if not collection or (type(key) ~= "string" and type(key) ~= "number") then
    return nil, "dimension kind or key is invalid"
  end
  if attributes ~= nil and type(attributes) ~= "table" then
    return nil, "dimension attributes must be a table"
  end
  key = tostring(key)
  local existing = self.dimensionIndex[kind][key]
  if existing then
    return existing
  end

  local expansionId = attributes and attributes.expansionDimensionId
  if expansionId ~= nil then
    if kind ~= "profession" and kind ~= "recipe" and kind ~= "item" then
      return nil, "this dimension cannot reference an expansion"
    end
    local found = false
    for _, row in ipairs(self.database.dimensions.expansions) do
      if row.id == expansionId then found = true; break end
    end
    if not isInteger(expansionId) or not found then
      return nil, "expansion reference does not exist"
    end
  end

  local row = copyValue(attributes or {})
  row.id = self.database.nextDimensionId[kind]
  row.key = key
  self.database.nextDimensionId[kind] = row.id + 1
  self.database.dimensions[collection][#self.database.dimensions[collection] + 1] = row
  self.dimensionIndex[kind][key] = row.id
  return row.id
end

function Ledger:CreateSession(metadata)
  metadata = metadata or {}
  local realmId
  if metadata.realmName ~= nil then
    realmId = self:AddDimension("realm", metadata.realmName, { name = metadata.realmName })
  end
  local characterId
  if metadata.characterGUID ~= nil or metadata.characterName ~= nil then
    local characterKey = metadata.characterGUID or
      tostring(metadata.characterName) .. "@" .. tostring(metadata.realmName or "")
    characterId = self:AddDimension("character", characterKey, {
      guid = metadata.characterGUID,
      name = metadata.characterName,
      realmDimensionId = realmId,
    })
  end

  local nextId = self.database.nextDimensionId.session
  local sessionId = self:AddDimension("session", "session-" .. tostring(nextId), {
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

  local data = self.database
  local craft = {
    id = data.nextCraftId,
    timestamp = self.wall(),
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
  if recipeId and not ambiguousRecipe and craft.gameOperationId and craft.gameOperationId > 0 and
      not operationIdSeen(self, craft.gameOperationId) then
    craft.recipeDimensionId = self:AddDimension("recipe", recipeId, { gameRecipeId = recipeId })
  end
  if isGameId(result.itemID) then
    craft.outputItemDimensionId = self:AddDimension("item", result.itemID, { gameItemId = result.itemID })
  end

  data.nextCraftId = craft.id + 1
  data.crafts[#data.crafts + 1] = craft
  adjustOperationIndex(self, craft, 1)

  if type(result.resourcesReturned) == "table" then
    for _, returned in ipairs(result.resourcesReturned) do
      local reagent = type(returned) == "table" and returned.reagent or nil
      local itemId = type(reagent) == "table" and reagent.itemID or nil
      local quantity = type(returned) == "table" and observedNumber(returned.quantity) or nil
      if isGameId(itemId) and quantity ~= nil then
        local itemDimensionId = self:AddDimension("item", itemId, { gameItemId = itemId })
        data.reagents[#data.reagents + 1] = {
          craftId = craft.id,
          itemDimensionId = itemDimensionId,
          returnedQuantity = quantity,
        }
      end
    end
  end

  self:Prune(craft.timestamp)
  return craft
end

function Ledger:Prune(now)
  now = observedNumber(now) or self.wall()
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
    while #data.crafts > data.maxCrafts do
      local craft = table.remove(data.crafts, 1)
      removed[craft.id] = true
      removedCrafts[craft.id] = craft
    end
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