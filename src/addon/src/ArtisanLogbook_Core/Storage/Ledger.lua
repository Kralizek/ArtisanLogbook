local _, addon = ...

local Ledger = {}
Ledger.schemaVersion = 4
Ledger.schemaIdentity = "ArtisanLogbookLedger"
Ledger.retentionDays = 60
Ledger.recentOperationLimit = 64

local maxInteger = 9007199254740991
local legacySeriesMetrics = { "outputQuantity", "multicraftBonus", "concentrationSpent",
  "ingenuityProcCount", "ingenuityRefund", "multicraftProcCount", "resourcefulnessProcCount",
  "resourcefulnessCompleteProcCount" }
local seriesMetrics = { "outputQuantity", "multicraftBonus", "concentrationSpent",
  "ingenuityProcCount", "ingenuityRefund", "multicraftProcCount", "resourcefulnessProcCount",
  "resourcefulnessCompleteProcCount", "resourcefulnessAuthoritativeProcCount" }
local procMetrics = { "ingenuityProcCount", "multicraftProcCount", "resourcefulnessProcCount",
  "resourcefulnessCompleteProcCount", "resourcefulnessAuthoritativeProcCount" }
local schema2SeriesCounts = { "quoteObservedCount", "inputCompleteCount", "matchedCraftCount" }
local seriesCounts = { "quoteObservedCount", "inputCompleteCount", "matchedCraftCount",
  "grossRequirementsCompleteCount" }
local outcomeMetrics = { "multicraftProcCount", "resourcefulnessProcCount", "resourcefulnessCompleteProcCount" }
local outcomeSources = { native = true, partial = true, unverified = true }
-- Integer measures on reagentSeries rows; returnedQuantity may hold legacy fractional sums.
local reagentCounts = { "allocatedQuantity", "allocationCount", "matchedCraftCount",
  "matchedAllocatedQuantity", "matchedReturnedQuantity", "matchedReturnCount" }

local function isFinite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local dimensions = {
  realm = "realms",
  character = "characters",
  session = "sessions",
  expansion = "expansions",
}

local naturalDimensions = { profession = "professions", recipe = "recipes", item = "items" }

local filterAttributes = {
  session = { "characterDimensionId", "realmDimensionId" },
  recipe = { "professionId", "expansionDimensionId" },
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
    nextConfigurationKey = 1,
    crafts = {},
    craftSeries = {},
    resourcefulnessSets = {},
    reagentSeries = {},
    reagentRequirementSeries = {},
    firstCraftRewards = {},
    configurations = {},
    recipeOutputs = {},
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
  for _, collection in pairs(naturalDimensions) do data.dimensions[collection] = {} end
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

local function isDenseList(rows)
  if type(rows) ~= "table" then return false end
  local count, maximum = 0, 0
  for key in pairs(rows) do
    if not isInteger(key) then return false end
    count, maximum = count + 1, math.max(maximum, key)
  end
  return count == maximum
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

local contextKinds = { personal = true, order = true, public = true, guild = true,
  ["personal-order"] = true, patron = true, unknown = true }
local observationCollections = { "crafts", "requests", "craftSeries", "resourcefulnessSets", "reagentSeries",
  "reagentRequirementSeries", "firstCraftRewards" }

local function encodeObservation(value)
  if type(value) == "number" then
    if not isFinite(value) then error("invalid observation number") end
    return "n" .. string.format("%.17g", value) .. ";"
  elseif type(value) == "boolean" then return value and "t" or "f"
  elseif type(value) == "string" then return "s" .. #value .. ":" .. value
  elseif type(value) ~= "table" or getmetatable(value) then error("invalid observation value") end
  local keys, parts = {}, { "{" }
  for key in pairs(value) do
    if type(key) ~= "string" and type(key) ~= "number" then error("invalid observation key") end
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = encodeObservation(key)
    parts[#parts + 1] = encodeObservation(value[key])
  end
  parts[#parts + 1] = "}"
  return table.concat(parts)
end

local statShape = { rating = "number", ratingPct = "number", bonusRatingPct = "number" }
local configurationShape = { scope = "string", statsCoverage = "string", equipmentCoverage = "string",
  buffsCoverage = "string", finishingCoverage = "string", recipeLevel = "number", useConcentration = "boolean",
  buffListVersion = "id", stats = { baseSkill = "number", bonusSkill = "number", baseDifficulty = "number",
    bonusDifficulty = "number", craftingQuality = "number", concentrationCost = "number", ingenuityRefund = "number",
    lowerSkillThreshold = "number", upperSkillTreshold = "number", multicraft = statShape,
    resourcefulness = statShape, ingenuity = statShape, craftingSpeed = statShape },
  equipment = { list = { slot = "id", itemID = "id", guid = "string", itemString = "string", empty = "boolean" }, key = "slot" },
  buffs = { list = { spellID = "id", applications = "count" }, key = "spellID" },
  finishingReagents = { list = { itemID = "id", quantity = "id" }, key = "itemID" } }
local observationShape = { context = { kind = "string", source = "string", isRecraft = "boolean" },
  configuration = configurationShape, configurationUnavailableReason = "string" }
local conditionFields = { "stats", "equipment", "buffs", "finishingReagents", "useConcentration", "recipeLevel" }
local evidenceFields = { "statsCoverage", "equipmentCoverage", "buffsCoverage", "finishingCoverage", "buffListVersion" }
local observationFields = { "craftType", "isRecraft", "contextSource", "configurationKey", "configurationScope",
  "statsCoverage", "equipmentCoverage", "buffsCoverage", "finishingCoverage", "buffListVersion", "configurationUnavailableReason" }

local function copyObservation(source, target)
  for _, field in ipairs(observationFields) do target[field] = source[field] end
  return target
end

function Ledger.SplitObservation(observation)
  if not observation then return {}, nil end
  local context, configuration = observation.context, observation.configuration
  local record = { craftType = context.kind, isRecraft = context.isRecraft, contextSource = context.source,
    configurationUnavailableReason = observation.configurationUnavailableReason }
  if not configuration then return record, nil end
  record.configurationScope = configuration.scope
  for _, field in ipairs(evidenceFields) do record[field] = configuration[field] end
  local conditions = {}
  for _, field in ipairs(conditionFields) do conditions[field] = copyValue(configuration[field]) end
  return record, next(conditions) and conditions or nil
end

local function matchesShape(value, shape)
  if shape == "id" then return isInteger(value) end
  if shape == "count" then return isCount(value) end
  if shape == "number" then return isFinite(value) end
  if shape == "string" then return type(value) == "string" and #value > 0 end
  if shape == "boolean" then return type(value) == "boolean" end
  if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
  if shape.list then
    if not isDenseList(value) then return false end
    local previous = 0
    for _, entry in ipairs(value) do
      if not matchesShape(entry, shape.list) or not isInteger(entry[shape.key]) or entry[shape.key] <= previous then return false end
      previous = entry[shape.key]
    end
    return true
  end
  for key, child in pairs(value) do
    if not shape[key] or not matchesShape(child, shape[key]) then return false end
  end
  return true
end

local function validateObservation(observation)
  if not matchesShape(observation, observationShape) or type(observation.context) ~= "table" or
      not contextKinds[observation.context.kind] or
      (observation.context.isRecraft ~= nil and type(observation.context.isRecraft) ~= "boolean") or
      (observation.configuration ~= nil and type(observation.configuration) ~= "table") then
    return nil, "invalid crafting observation"
  end
  local context, configuration = observation.context, observation.configuration
  if context.source ~= nil and context.source ~= "submitted-call" and context.source ~= "claimed-order" then
    return nil, "invalid context provenance"
  end
  local missing = observation.configurationUnavailableReason
  if missing ~= nil and (configuration or (missing ~= "unavailable" and missing ~= "changed" and missing ~= "batch-unobserved")) then
    return nil, "invalid configuration coverage"
  end
  if configuration then
    if configuration.scope ~= "request" and configuration.scope ~= "attempt-start" then return nil, "invalid configuration scope" end
    for field, available in pairs({ statsCoverage = "reported", equipmentCoverage = "observed",
        buffsCoverage = "supported-list", finishingCoverage = "submitted" }) do
      local coverage = configuration[field]
      if coverage ~= nil and coverage ~= available and coverage ~= "partial" and coverage ~= "unavailable" then
        return nil, "invalid configuration field coverage"
      end
    end
  end
  return true
end

local conditionsShape = {}
for _, field in ipairs(conditionFields) do conditionsShape[field] = configurationShape[field] end
local recordShape = { craftType = "string", isRecraft = "boolean", contextSource = "string", configurationKey = "id",
  configurationScope = "string", configurationUnavailableReason = "string" }
for _, field in ipairs(evidenceFields) do recordShape[field] = configurationShape[field] end

local function configurationSignature(conditions)
  if not matchesShape(conditions, conditionsShape) or next(conditions) == nil then
    return nil, "invalid configuration conditions"
  end
  local ok, signature = pcall(encodeObservation, conditions)
  if not ok then return nil, signature end
  return signature
end

local function stageObservation(ledger, observation)
  if observation == nil then return {} end
  local valid, reason = validateObservation(observation)
  if not valid then return nil, nil, reason end
  local record, conditions = Ledger.SplitObservation(observation)
  if not conditions then return record end
  local signature = assert(configurationSignature(conditions))
  local existing = ledger.configurationIndex[signature]
  if existing then record.configurationKey = existing; return record end
  local key = ledger.database.nextConfigurationKey
  if not canAllocate(key) then return nil, nil, "configuration ID precision exhausted" end
  record.configurationKey = key
  return record, { signature = signature, row = conditions }
end

local function commitConfiguration(ledger, key, staged)
  if not staged then return end
  ledger.database.configurations[key] = staged.row
  ledger.database.nextConfigurationKey = key + 1
  ledger.configurationIndex[staged.signature] = key
end

local function grainKey(recipeId, observation)
  local parts, present = {}, false
  for _, field in ipairs(observationFields) do
    local value = observation and observation[field]
    if value ~= nil then present = true end
    parts[#parts + 1] = value == nil and "-" or encodeObservation(value)
  end
  if not present then return recipeId or 0 end
  return string.format("%.17g:", recipeId or 0) .. table.concat(parts, "|")
end

local function storedObservation(data, row, evidenceOnly)
  if not row then return nil end
  if next(copyObservation(row, {})) == nil then return nil end
  local configuration
  if not evidenceOnly then configuration = copyValue(data.configurations[row.configurationKey]) end
  if row.configurationScope then
    configuration = configuration or {}
    configuration.scope = row.configurationScope
    for _, field in ipairs(evidenceFields) do configuration[field] = row[field] end
  end
  return { context = { kind = row.craftType or "unknown", isRecraft = row.isRecraft, source = row.contextSource },
    configuration = configuration, configurationUnavailableReason = row.configurationUnavailableReason }
end

Ledger.GrainKey = grainKey
Ledger.CopyObservation = copyValue

local references = {
  series = { characterDimensionId = "character", recipeId = "recipe" },
  returnedReagent = { characterDimensionId = "character", recipeId = "recipe", itemId = "item" },
  reward = { characterDimensionId = "character", recipeId = "recipe", itemId = "item" },
  craft = { sessionId = "session", recipeId = "recipe", requestId = "request",
    outputItemId = "item", professionId = "profession" },
  request = { sessionId = "session", recipeId = "recipe" },
  allocation = { itemId = "item" },
  reagent = { craftId = "craft", itemId = "item" },
  character = { realmDimensionId = "realm" },
  session = { characterDimensionId = "character", realmDimensionId = "realm" },
  recipe = { expansionDimensionId = "expansion", professionId = "profession" },
  item = { expansionDimensionId = "expansion" },
  profession = { expansionDimensionId = "expansion" },
}

local function validateReferences(kind, row, ids)
  if naturalDimensions[kind] and row.name ~= nil and
      (type(row.name) ~= "string" or row.name == "") then
    return nil, "invalid " .. kind .. ".name"
  end
  for field in pairs(row) do
    if type(field) == "string" and (field:match("DimensionId$") or field:match("Id$") or
      field == "introducedInExpansionId") and field ~= "id" and
      field ~= "gameOperationId" and field ~= "concentrationCurrencyId" and
      field ~= "gameRealmId" and field ~= "projectId" and field ~= "regionId" and
        not (references[kind] or {})[field] then
      return nil, "unsupported reference: " .. kind .. "." .. field
    end
  end
  for field, target in pairs(references[kind] or {}) do
    local value = row[field]
    if value ~= nil and (not (naturalDimensions[target] and isGameId(value) or isInteger(value)) or
      not ids[target][value]) then
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

local function indexSeriesChoices(ledger, characterId, recipeId)
  if characterId then ledger.seriesCharacterIds[characterId] = true end
  if recipeId then
    ledger.seriesRecipeIds[recipeId] = true
    local key = characterId or 0
    local recipes = ledger.seriesRecipeIdsByCharacter[key]
    if not recipes then
      recipes = {}
      ledger.seriesRecipeIdsByCharacter[key] = recipes
    end
    recipes[recipeId] = true
  end
end

-- A matched craft knows every recipe input and its complete return set.
local function isMatched(craft)
  return craft.inputComplete == true and craft.outcomeSource == "native" and
    craft.materialsSavingsEligible ~= false
end

local function seriesCount(craft, field)
  if field == "quoteObservedCount" then return craft.quoteObserved == true and 1 or 0 end
  if field == "inputCompleteCount" then return craft.inputComplete == true and 1 or 0 end
  if field == "grossRequirementsCompleteCount" then return craft.grossRequirementsComplete == true and 1 or 0 end
  return isMatched(craft) and 1 or 0
end

local function seriesMeasurement(craft, metric)
  if metric == "resourcefulnessAuthoritativeProcCount" then
    if craft.outcomeSource ~= "native" then return nil end
    return craft.hasResourcefulnessProc and 1 or 0
  end
  if metric == "resourcefulnessCompleteProcCount" then
    if craft.resourcefulnessComplete ~= true then return nil end
    return craft.hasResourcefulnessProc and 1 or 0
  end
  if metric == "multicraftProcCount" then
    if craft.multicraftBonus == nil then return nil end
    return craft.multicraftBonus > 0 and 1 or 0
  end
  if metric == "resourcefulnessProcCount" then
    if craft.hasResourcefulnessProc == nil then return nil end
    return craft.hasResourcefulnessProc and 1 or 0
  end
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
      if metric:match("ProcCount$") and
          (not isCount(row[metric] or 0) or (row[metric] or 0) > maxInteger - value) then
        return nil, "craft series proc count overflow"
      end
      row[metric] = (row[metric] or 0) + value
      row[coverage] = row[coverage] + 1
      if not isFinite(row[metric]) then return nil, "craft series sum overflow: " .. metric end
    end
  end
  for _, field in ipairs(seriesCounts) do
    local previous = existing and existing[field] or 0
    if not isCount(previous) or previous >= maxInteger then
      return nil, "craft series count overflow: " .. field
    end
    row[field] = previous + seriesCount(craft, field)
  end
  return true
end

local function stageSeries(index, sessions, craft)
  local bucketStart = math.floor(craft.timestamp / 86400) * 86400
  if not isFinite(bucketStart) then return nil, "invalid craft series bucket" end
  local session = sessions[craft.sessionId]
  local characterId = session and session.characterDimensionId
  local bucket = index[bucketStart]
  local group = bucket and bucket[characterId or 0]
  local key = grainKey(craft.recipeId, craft)
  local existing = group and group[key]
  if existing and (not isInteger(existing.craftCount) or existing.craftCount >= maxInteger) then
    return nil, "craft series count overflow"
  end
  local row = {
    bucketStart = bucketStart,
    characterDimensionId = characterId,
    recipeId = craft.recipeId,
    craftCount = (existing and existing.craftCount or 0) + 1,
  }
  copyObservation(craft, row)
  local ok, reason = accumulateMetrics(row, existing, craft)
  if not ok then return nil, reason end
  return {
    row = row, existing = existing, bucketStart = bucketStart,
    characterDimensionId = characterId, key = key,
  }
end

local function commitStagedSeries(data, index, days, staged)
  if staged.existing then
    for field in pairs(staged.existing) do staged.existing[field] = nil end
    for field, value in pairs(staged.row) do staged.existing[field] = value end
  else
    if not index[staged.bucketStart] then
      local first, last = 1, #days + 1
      while first < last do
        local middle = math.floor((first + last) / 2)
        if days[middle] < staged.bucketStart then first = middle + 1 else last = middle end
      end
      table.insert(days, first, staged.bucketStart)
    end
    local group = seriesGroup(index, staged.bucketStart, staged.characterDimensionId)
    data.craftSeries[#data.craftSeries + 1] = staged.row
    group[staged.key] = staged.row
  end
end

local function validateDatabase(data, version)
  version = version or Ledger.schemaVersion
  local v2, v3 = version >= 2, version >= 3
  if data.schemaVersion ~= version or data.schemaIdentity ~= Ledger.schemaIdentity then
    return nil, "unsupported ledger schema"
  end
  if data.observations ~= nil or data.nextObservationKey ~= nil then return nil, "unreleased observation layout is unsupported" end
  if version < 4 and (data.configurations ~= nil or data.nextConfigurationKey ~= nil) then
    return nil, "legacy schema has configuration fields"
  end
  if version < 4 then
    for _, collection in ipairs(observationCollections) do
      for _, row in ipairs(data[collection] or {}) do
        if next(copyObservation(row, {})) ~= nil then return nil, "legacy facts have configuration evidence" end
      end
    end
  end
  if v2 and data.outcomeVersion ~= nil then return nil, "schema 2+ does not support outcomeVersion" end
  if version >= 4 then
    if type(data.configurations) ~= "table" then
      return nil, "invalid configurations"
    end
    local seen, highest = {}, 0
    for key, conditions in pairs(data.configurations) do
      if not isInteger(key) then return nil, "invalid configuration key" end
      highest = math.max(highest, key)
      local signature, reason = configurationSignature(conditions)
      if not signature then return nil, reason end
      if seen[signature] then return nil, "duplicate configuration" end
      seen[signature] = true
    end
    if not isInteger(data.nextConfigurationKey) or data.nextConfigurationKey <= highest then
      return nil, "nextConfigurationKey would reuse an existing configuration key"
    end
    for _, collection in ipairs(observationCollections) do
      for _, row in ipairs(data[collection] or {}) do
        if not matchesShape(copyObservation(row, {}), recordShape) then return nil, "invalid fact observation" end
        if row.observationKey ~= nil then return nil, "unreleased observation reference is unsupported" end
        if row.configurationKey ~= nil and (not isInteger(row.configurationKey) or not data.configurations[row.configurationKey] or
            row.configurationScope == nil) then
          return nil, "missing configuration or scope"
        end
        for _, field in ipairs(evidenceFields) do
          if row[field] ~= nil and row.configurationScope == nil then return nil, "configuration coverage requires scope" end
        end
        local observation = storedObservation(data, row, true)
        if observation then
          local valid, reason = validateObservation(observation)
          if not valid then return nil, reason end
        end
      end
    end
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
        craft.sessionId == nil then
      return nil, "craft facts contain an invalid or duplicate ID"
    end
    for _, field in ipairs({ "gameOperationId", "outputQuality", "outputItemLevel", "outputQuantity",
      "multicraftBonus", "concentrationSpent", "concentrationCurrencyId", "ingenuityRefund" }) do
      if craft[field] ~= nil and not isFinite(craft[field]) then
        return nil, "invalid craft measurement: " .. field
      end
    end
    for _, field in ipairs({ "hasIngenuityProc", "hasResourcefulnessProc", "resourcefulnessComplete" }) do
      if craft[field] ~= nil and type(craft[field]) ~= "boolean" then
        return nil, "invalid craft boolean: " .. field
      end
    end
    if craft.resourcefulnessComplete ~= nil and
        (craft.resourcefulnessComplete ~= true or craft.hasResourcefulnessProc == nil) then
      return nil, "complete Resourcefulness observation requires an outcome"
    end
    if not v2 and (craft.outcomeSource ~= nil or craft.quoteObserved ~= nil or craft.inputComplete ~= nil) then
      return nil, "schema 1 craft has schema 2 provenance"
    end
    if not v3 and (craft.reagentRequirements ~= nil or craft.grossRequirementsComplete ~= nil or
        craft.materialsSavingsEligible ~= nil or craft.requirementObservation ~= nil) then
      return nil, "pre-schema-3 craft has schema 3 input evidence"
    end
    if v3 and craft.grossRequirementsComplete ~= nil and type(craft.grossRequirementsComplete) ~= "boolean" then
      return nil, "invalid gross requirement completeness"
    end
    if v3 and craft.materialsSavingsEligible ~= nil and type(craft.materialsSavingsEligible) ~= "boolean" then
      return nil, "invalid material savings eligibility"
    end
    if v3 and craft.reagentRequirements ~= nil and not isArray(craft.reagentRequirements) then
      return nil, "invalid craft reagent requirements"
    end
    if craft.requirementObservation ~= nil and (craft.requirementObservation ~= "result" or
        craft.requestId ~= nil or craft.recipeId == nil or #(craft.reagentRequirements or {}) == 0 or
        craft.inputComplete ~= nil or craft.materialsSavingsEligible ~= nil or craft.grossRequirementsComplete ~= nil) then
      return nil, "invalid independent schematic observation"
    end
    if craft.requestCorrelationReason ~= nil and (not v3 or craft.requestId ~= nil or not ({
        ["observed-operation"] = true, ["ownership-quarantine"] = true, ["conflicting-begin"] = true,
        ["ambiguous-context"] = true, ["nonprimary-result"] = true,
      })[craft.requestCorrelationReason]) then
      return nil, "invalid request correlation diagnostic"
    end
    if v3 then
      local slots = {}
      for _, requirement in ipairs(craft.reagentRequirements or {}) do
        if not isInteger(requirement.dataSlotIndex) or slots[requirement.dataSlotIndex] or
            not isDenseList(requirement.candidateItemIDs) or #requirement.candidateItemIDs < 1 or
            not isInteger(requirement.requiredQuantity) or requirement.source ~= "schematic" then
          return nil, "invalid craft reagent requirement"
        end
        slots[requirement.dataSlotIndex] = true
        local previous
        for _, itemId in ipairs(requirement.candidateItemIDs) do
          if not isGameId(itemId) or itemId == 0 or (previous and itemId <= previous) or
              not data.dimensions.items[itemId] then
            return nil, "invalid craft reagent requirement candidate"
          end
          previous = itemId
        end
      end
      if craft.inputComplete == true and #(craft.reagentRequirements or {}) > 0 then
        return nil, "complete exact inputs conflict with an alternative requirement"
      end
      if craft.grossRequirementsComplete == true and craft.requestId == nil then
        return nil, "gross recipe requirements require a correlated submission"
      end
    end
    if craft.outcomeSource ~= nil and not outcomeSources[craft.outcomeSource] then
      return nil, "invalid craft outcome source"
    end
    if (craft.outcomeSource == "native") ~= (craft.outcomeSource ~= nil and craft.resourcefulnessComplete == true) or
        ((craft.outcomeSource == "partial" or craft.outcomeSource == "unverified") and
          craft.hasResourcefulnessProc == false) then
      return nil, "craft outcome source conflicts with its observation"
    end
    for _, field in ipairs({ "quoteObserved", "inputComplete" }) do
      if craft[field] ~= nil and (craft[field] ~= true or craft.requestId == nil) then
        return nil, "craft input observation requires a request"
      end
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
  for kind, collection in pairs(naturalDimensions) do
    local rows = data.dimensions[collection]
    if type(rows) ~= "table" or data.nextDimensionId[kind] ~= nil then
      return nil, "natural ID collection is invalid for " .. kind
    end
    ids[kind] = {}
    for id, row in pairs(rows) do
      if not isGameId(id) or type(row) ~= "table" or row.id ~= id or row.key ~= nil or
          row.gameRecipeId ~= nil or row.gameItemId ~= nil or row.skillLineId ~= nil then
        return nil, "natural ID row is invalid for " .. kind
      end
      ids[kind][id] = true
    end
  end
  if type(data.recipeOutputs) ~= "table" then
    return nil, "recipeOutputs must be a recipe-to-item set map"
  end
  for recipeId, outputs in pairs(data.recipeOutputs) do
    if not isGameId(recipeId) or not ids.recipe[recipeId] or type(outputs) ~= "table" then
      return nil, "recipeOutputs contains an invalid recipe identity"
    end
    for outputItemId, observed in pairs(outputs) do
      if not isGameId(outputItemId) or not ids.item[outputItemId] or observed ~= true then
        return nil, "recipeOutputs contains an invalid output relationship"
      end
    end
  end
  for _, request in ipairs(data.requests) do
    if not isInteger(request.id) or ids.request[request.id] or not isFinite(request.timestamp) or
        request.sessionId == nil or request.recipeId == nil or
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
    if (request.fixedReagents ~= nil and (not v2 or not isArray(request.fixedReagents))) or
        (request.inputComplete ~= nil and (not v2 or request.inputComplete ~= true)) then
      return nil, "request recipe inputs are invalid"
    end
    if not v3 and (request.requirements ~= nil or request.grossRequirementsComplete ~= nil) then
      return nil, "pre-schema-3 request has schema 3 input evidence"
    end
    if v3 and ((request.requirements ~= nil and not isArray(request.requirements)) or
        (request.grossRequirementsComplete ~= nil and request.grossRequirementsComplete ~= true)) then
      return nil, "request gross requirements are invalid"
    end
    if v3 and request.materialsSavingsEligible ~= nil and request.materialsSavingsEligible ~= false then
      return nil, "invalid request material ownership evidence"
    end
  end
  for _, request in ipairs(data.requests) do
    local ok, reason = validateReferences("request", request, ids)
    if not ok then return nil, reason end
    for _, allocation in ipairs(request.allocations or {}) do
      if not isInteger(allocation.dataSlotIndex) or not isInteger(allocation.allocatedQuantity) or
          allocation.itemId == nil or
          (allocation.inputTotalComplete ~= nil and (not v2 or
            (not v3 and allocation.inputTotalComplete ~= true) or
            (v3 and type(allocation.inputTotalComplete) ~= "boolean"))) or
          (allocation.quality ~= nil and not isGameId(allocation.quality)) then
        return nil, "request allocation is invalid"
      end
      ok, reason = validateReferences("allocation", allocation, ids)
      if not ok then return nil, reason end
    end
    for _, fixed in ipairs(request.fixedReagents or {}) do
      if not isInteger(fixed.dataSlotIndex) or not isInteger(fixed.requiredQuantity) or fixed.itemId == nil or
          (fixed.inputTotalComplete ~= nil and (not v2 or
            (not v3 and fixed.inputTotalComplete ~= true) or (v3 and type(fixed.inputTotalComplete) ~= "boolean"))) then
        return nil, "request fixed reagent is invalid"
      end
      ok, reason = validateReferences("allocation", fixed, ids)
      if not ok then return nil, reason end
    end
    local requirementSlots = {}
    for _, requirement in ipairs(request.requirements or {}) do
      if not isInteger(requirement.dataSlotIndex) or requirementSlots[requirement.dataSlotIndex] or
          type(requirement.candidateItemIDs) ~= "table" or not isDenseList(requirement.candidateItemIDs) or
          #requirement.candidateItemIDs < 1 or
          (requirement.source == "schematic" and not isInteger(requirement.requiredQuantity)) or
          (requirement.requiredQuantity ~= nil and not isInteger(requirement.requiredQuantity)) or
          (requirement.source ~= "schematic" and requirement.source ~= "unknown") then
        return nil, "request reagent requirement is invalid"
      end
      requirementSlots[requirement.dataSlotIndex] = true
      local previous
      for _, itemId in ipairs(requirement.candidateItemIDs) do
        if not isGameId(itemId) or itemId == 0 or (previous and itemId <= previous) or not ids.item[itemId] then
          return nil, "request requirement candidate is invalid"
        end
        previous = itemId
      end
    end
    if request.inputComplete == true and #(request.requirements or {}) > 0 then
      return nil, "complete exact inputs conflict with alternative requirements"
    end
  end
  local linkedCounts = {}
  for _, craft in ipairs(data.crafts) do
    local ok, reason = validateReferences("craft", craft, ids)
    if not ok then return nil, reason end
    if craft.requestId then
      local request = ids.request[craft.requestId]
      if request.sessionId ~= craft.sessionId or
          request.recipeId ~= craft.recipeId then
        return nil, "craft.requestId conflicts with request context"
      end
      if (craft.quoteObserved and #(request.allocations or {}) == 0) or
          (craft.inputComplete and request.inputComplete ~= true) then
        return nil, "craft input observation conflicts with its request"
      end
      linkedCounts[request.id] = (linkedCounts[request.id] or 0) + 1
      if linkedCounts[request.id] > request.requestedCount then
        return nil, "craft.requestId exceeds requested count"
      end
    end
  end
  for _, reagent in ipairs(data.reagents) do
    if reagent.craftId == nil or reagent.itemId == nil then
      return nil, "reagent fact requires craft and item references"
    end
    local ok, reason = validateReferences("reagent", reagent, ids)
    if not ok then return nil, reason end
    if (reagent.dataSlotIndex ~= nil and not isInteger(reagent.dataSlotIndex)) or
        (reagent.allocatedQuantity ~= nil and not isInteger(reagent.allocatedQuantity)) or
        (reagent.returnedQuantity ~= nil and not isFinite(reagent.returnedQuantity)) or
        (reagent.inputTotalComplete ~= nil and
          (not v2 or type(reagent.inputTotalComplete) ~= "boolean" or reagent.allocatedQuantity == nil)) or
        (reagent.fixed ~= nil and (not v2 or reagent.fixed ~= true or reagent.allocatedQuantity == nil)) then
      return nil, "invalid reagent allocation or measurement"
    end
  end
  for kind, collection in pairs(dimensions) do
    for _, row in ipairs(data.dimensions[collection]) do
      local ok, reason = validateReferences(kind, row, ids)
      if not ok then return nil, reason end
    end
  end
  for kind, collection in pairs(naturalDimensions) do
    for _, row in pairs(data.dimensions[collection]) do
      local ok, reason = validateReferences(kind, row, ids)
      if not ok then return nil, reason end
    end
  end
  if not isArray(data.craftSeries) then return nil, "craftSeries must be a dense array" end
  local metrics = v2 and seriesMetrics or legacySeriesMetrics
  local seen = {}
  for _, row in ipairs(data.craftSeries) do
    local ok, reason = validateReferences("series", row, ids)
    if not ok then return nil, reason end
    if not isFinite(row.bucketStart) or row.bucketStart % 86400 ~= 0 or
        not isInteger(row.craftCount) then
      return nil, "invalid craft series bucket or count"
    end
    local group = seriesGroup(seen, row.bucketStart, row.characterDimensionId)
    local key = grainKey(row.recipeId, row)
    if group[key] then return nil, "duplicate craft series grain" end
    group[key] = true
    for _, metric in ipairs(metrics) do
      local count = row[metric .. "ObservedCount"]
      if not isCount(count) or count > row.craftCount or
          (count == 0 and row[metric] ~= nil) or
          (count > 0 and not isFinite(row[metric])) then
        return nil, "invalid craft series coverage or sum: " .. metric
      end
    end
    for _, metric in ipairs(procMetrics) do
      if row[metric] ~= nil and
          (not isCount(row[metric]) or row[metric] > row[metric .. "ObservedCount"]) then
        return nil, "invalid craft series proc count"
      end
    end
    if row.resourcefulnessCompleteProcCountObservedCount > row.resourcefulnessProcCountObservedCount or
        (row.resourcefulnessCompleteProcCount or 0) > (row.resourcefulnessProcCount or 0) or
        row.resourcefulnessCompleteProcCountObservedCount - (row.resourcefulnessCompleteProcCount or 0) >
          row.resourcefulnessProcCountObservedCount - (row.resourcefulnessProcCount or 0) then
      return nil, "complete Resourcefulness coverage conflicts with proc coverage"
    end
    if v2 then
      if row.resourcefulnessAuthoritativeProcCountObservedCount > row.resourcefulnessCompleteProcCountObservedCount or
          (row.resourcefulnessAuthoritativeProcCount or 0) > (row.resourcefulnessCompleteProcCount or 0) or
          row.resourcefulnessAuthoritativeProcCountObservedCount - (row.resourcefulnessAuthoritativeProcCount or 0) >
            row.resourcefulnessCompleteProcCountObservedCount - (row.resourcefulnessCompleteProcCount or 0) then
        return nil, "authoritative Resourcefulness coverage conflicts with complete coverage"
      end
      for _, field in ipairs(v3 and seriesCounts or schema2SeriesCounts) do
        if not isCount(row[field]) or row[field] > row.craftCount then
          return nil, "invalid craft series count: " .. field
        end
      end
      if row.matchedCraftCount > row.inputCompleteCount or
          row.matchedCraftCount > row.resourcefulnessAuthoritativeProcCountObservedCount then
        return nil, "matched crafts exceed complete input or authoritative return coverage"
      end
    else
      for _, field in ipairs(schema2SeriesCounts) do
        if row[field] ~= nil or row.resourcefulnessAuthoritativeProcCountObservedCount ~= nil then
          return nil, "schema 1 series has schema 2 measures"
        end
      end
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

local function returnGroup(index, day, characterId, recipeId, observation)
  local recipes = seriesGroup(index, day, characterId)
  local key = grainKey(recipeId, observation)
  if not recipes[key] then recipes[key] = {} end
  return recipes[key]
end

local function returnIndex(rows, field)
  local index = {}
  for _, row in ipairs(rows) do
    returnGroup(index, row.bucketStart, row.characterDimensionId, row.recipeId, row)[row[field]] = row
  end
  return index
end

local function canonicalReturns(quantities)
  local ids, encoded = {}, {}
  for itemId, quantity in pairs(quantities) do
    if quantity > 0 then ids[#ids + 1] = itemId end
  end
  if #ids > 1 then table.sort(ids) end
  for _, itemId in ipairs(ids) do encoded[#encoded + 1] = string.format("%.0f", itemId) end
  return table.concat(encoded, ",")
end

local function candidateKey(itemIds)
  local ids = {}
  for _, itemId in ipairs(itemIds) do ids[#ids + 1] = itemId end
  table.sort(ids)
  local encoded = {}
  for _, itemId in ipairs(ids) do encoded[#encoded + 1] = string.format("%.0f", itemId) end
  return table.concat(encoded, ",")
end

local function dayOf(timestamp)
  return math.floor(timestamp / 86400) * 86400
end

-- Integer measures stay exact. Returned quantities can be legacy fractional sums, so a
-- positive amount must still visibly increase the stored value.
local function addMeasures(row, delta)
  for field, amount in pairs(delta) do
    local previous = row[field] or 0
    if field == "returnedQuantity" then
      local sum = previous + amount
      if not isFinite(previous) or previous < 0 or not isFinite(amount) or amount <= 0 or
          not isFinite(sum) or sum <= previous or (previous > 0 and sum <= amount) or
          (isCount(previous) and isCount(amount) and previous > maxInteger - amount) then
        return nil, "aggregate overflow: " .. field
      end
      row[field] = sum
    elseif not isCount(previous) or not isCount(amount) or previous > maxInteger - amount then
      return nil, "aggregate overflow: " .. field
    else
      row[field] = previous + amount
    end
  end
  return true
end

local function stageGrain(index, day, characterId, recipeId, field, key, delta, observation)
  local bucket = index[day]
  local recipes = bucket and bucket[characterId or 0]
  local group = recipes and recipes[grainKey(recipeId, observation)]
  local existing = group and group[key]
  local row = { bucketStart = day, characterDimensionId = characterId, recipeId = recipeId, [field] = key }
  copyObservation(observation or {}, row)
  if existing then
    for name, value in pairs(existing) do row[name] = value end
  end
  local ok, reason = addMeasures(row, delta)
  if not ok then return nil, reason end
  return { existing = existing, row = row, field = field }
end

local function commitGrains(rows, index, staged)
  for _, change in ipairs(staged) do
    local row = change.row
    if change.existing then
      for key, value in pairs(row) do change.existing[key] = value end
    else
      rows[#rows + 1] = row
      returnGroup(index, row.bucketStart, row.characterDimensionId, row.recipeId, row)[row[change.field]] = row
    end
  end
end

-- Consolidates retained reagent facts by item: duplicate allocation slots add together and
-- slot-level return attribution is never needed.
local function craftItems(rows)
  local items = {}
  for _, row in ipairs(rows) do
    local item = items[row.itemId]
    if not item then
      item = {}
      items[row.itemId] = item
    end
    if row.allocatedQuantity ~= nil then
      item.allocated = (item.allocated or 0) + row.allocatedQuantity
      if row.inputTotalComplete == false then item.incomplete = true end
      if not isCount(item.allocated) then return nil, "reagent allocation sum overflow" end
    end
    if isInteger(row.itemId) and isFinite(row.returnedQuantity) and row.returnedQuantity > 0 then
      item.returned = (item.returned or 0) + row.returnedQuantity
      if not isFinite(item.returned) then return nil, "reagent return sum overflow" end
    end
  end
  return items
end

local function craftDeltas(craft, items)
  local result = { reagents = {}, requirements = {} }
  local requirementGroups = {}
  for _, requirement in ipairs(craft.reagentRequirements or {}) do
    local key = candidateKey(requirement.candidateItemIDs)
    local group = requirementGroups[key]
    if not group then group = { requiredQuantity = 0 }; requirementGroups[key] = group end
    group.requiredQuantity = group.requiredQuantity + requirement.requiredQuantity
    if not isCount(group.requiredQuantity) then return nil, "reagent requirement sum overflow" end
  end
  for key, requirement in pairs(requirementGroups) do
    result.requirements[#result.requirements + 1] = { key = key,
      delta = { requirementCraftCount = 1, requiredQuantity = requirement.requiredQuantity,
        resultObservationCount = craft.requirementObservation == "result" and 1 or nil } }
  end
  if craft.hasResourcefulnessProc == true and craft.resourcefulnessComplete == true then
    local quantities = {}
    for itemId, item in pairs(items) do quantities[itemId] = item.returned end
    local key = canonicalReturns(quantities)
    if key == "" then return nil, "observed return has no items" end
    result.set = { key = key, delta = { craftCount = 1,
      authoritativeCraftCount = craft.outcomeSource == "native" and 1 or nil } }
  end
  local matched = craft.outcomeSource == "native" and craft.materialsSavingsEligible ~= false
  for itemId, item in pairs(items) do
    local delta = { returnedQuantity = item.returned }
    if item.allocated then
      delta.allocatedQuantity, delta.allocationCount = item.allocated, 1
      if matched and not item.incomplete then
        delta.matchedCraftCount, delta.matchedAllocatedQuantity = 1, item.allocated
        delta.matchedReturnedQuantity = item.returned or 0
        delta.matchedReturnCount = (item.returned or 0) > 0 and 1 or 0
      end
    end
    if next(delta) then result.reagents[#result.reagents + 1] = { itemId = itemId, delta = delta } end
  end
  return result
end

local function stageOutcomes(setIndex, reagentIndex, requirementIndex, craft, characterId, items)
  local deltas, reason = craftDeltas(craft, items)
  if not deltas then return nil, reason end
  local day = dayOf(craft.timestamp)
  local staged = { sets = {}, reagents = {}, requirements = {} }
  if deltas.set then
    staged.sets[1], reason = stageGrain(setIndex, day, characterId, craft.recipeId,
      "returnedItemSet", deltas.set.key, deltas.set.delta, craft)
    if not staged.sets[1] then return nil, reason end
  end
  for _, entry in ipairs(deltas.reagents) do
    local change
    change, reason = stageGrain(reagentIndex, day, characterId, craft.recipeId, "itemId", entry.itemId, entry.delta,
      craft)
    if not change then return nil, reason end
    staged.reagents[#staged.reagents + 1] = change
  end
  for _, entry in ipairs(deltas.requirements) do
    local change
    change, reason = stageGrain(requirementIndex, day, characterId, craft.recipeId,
      "candidateKey", entry.key, entry.delta, craft)
    if not change then return nil, reason end
    staged.requirements[#staged.requirements + 1] = change
  end
  return staged
end

local function quantitiesFromFacts(rows, fractionalOnly)
  local quantities = {}
  for _, row in ipairs(rows) do
    if isInteger(row.itemId) and isFinite(row.returnedQuantity) and row.returnedQuantity > 0 and
        (not fractionalOnly or not isInteger(row.returnedQuantity)) then
      quantities[row.itemId] = (quantities[row.itemId] or 0) + row.returnedQuantity
    end
  end
  return quantities
end

local function validateReagentMeasures(row, parent)
  if row.returnedQuantity ~= nil and (not isFinite(row.returnedQuantity) or row.returnedQuantity <= 0) then
    return nil, "invalid returned quantity"
  end
  for _, field in ipairs(reagentCounts) do
    if row[field] ~= nil and not isCount(row[field]) then return nil, "invalid reagent measure: " .. field end
  end
  if (row.allocationCount == nil) ~= (row.allocatedQuantity == nil) or
      (row.allocationCount ~= nil and (row.allocationCount < 1 or row.allocationCount > parent.craftCount or
        row.allocatedQuantity < row.allocationCount)) then
    return nil, "invalid reagent allocation coverage"
  end
  local matched = row.matchedCraftCount
  if matched == nil then
    if row.matchedAllocatedQuantity ~= nil or row.matchedReturnedQuantity ~= nil or row.matchedReturnCount ~= nil then
      return nil, "matched reagent measures require a matched craft count"
    end
  elseif matched < 1 or matched > (row.allocationCount or 0) or
      matched > parent.resourcefulnessAuthoritativeProcCountObservedCount or
      row.matchedAllocatedQuantity == nil or row.matchedAllocatedQuantity < matched or
      row.matchedAllocatedQuantity > row.allocatedQuantity or row.matchedReturnedQuantity == nil or
      row.matchedReturnedQuantity > (row.returnedQuantity or 0) or row.matchedReturnCount == nil or
      row.matchedReturnCount > matched or (row.matchedReturnCount > 0) ~= (row.matchedReturnedQuantity > 0) then
    return nil, "invalid matched reagent measures"
  end
  if row.returnedQuantity == nil and row.allocationCount == nil then
    return nil, "reagent aggregate has no measure"
  end
  return true
end

local function validateOutcomes(data, version)
  version = version or Ledger.schemaVersion
  local v2, v3 = version >= 2, version >= 3
  local quantities = v2 and data.reagentSeries or data.returnedReagents
  if (not v2 and data.outcomeVersion ~= 2) or not isArray(data.resourcefulnessSets) or
      not isArray(quantities) or (v2 and (data.returnedReagents ~= nil or not isArray(data.firstCraftRewards))) or
      (v3 and not isArray(data.reagentRequirementSeries)) or
      (not v3 and data.reagentRequirementSeries ~= nil) then
    return nil, "invalid outcome collections"
  end
  local daily = {}
  for _, row in ipairs(data.craftSeries) do
    seriesGroup(daily, row.bucketStart, row.characterDimensionId)[grainKey(row.recipeId, row)] = row
  end
  local ids = { character = {}, recipe = data.dimensions.recipes, item = data.dimensions.items }
  for _, row in ipairs(data.dimensions.characters) do ids.character[row.id] = true end
  local completeTotals, authoritativeTotals = {}, {}
  local specs = { { data.resourcefulnessSets, "returnedItemSet", "series" },
    { quantities, "itemId", "returnedReagent" } }
  if v2 then specs[3] = { data.firstCraftRewards, "itemId", "reward" } end
  for _, spec in ipairs(specs) do
    local seen = {}
    for _, row in ipairs(spec[1]) do
      local ok, reason = validateReferences(spec[3], row, ids)
      if not ok then return nil, reason end
      if not isFinite(row.bucketStart) or row.bucketStart % 86400 ~= 0 then
        return nil, "invalid returned aggregate bucket"
      end
      local bucket = daily[row.bucketStart]
      local recipes = bucket and bucket[row.characterDimensionId or 0]
      local parent = recipes and recipes[grainKey(row.recipeId, row)]
      if not parent and spec[3] ~= "reward" then return nil, "returned aggregate has no daily grain" end
      local key = row[spec[2]]
      if spec[2] == "returnedItemSet" then
        if not isInteger(row.craftCount) or
            (row.authoritativeCraftCount ~= nil and (not v2 or not isInteger(row.authoritativeCraftCount) or
              row.authoritativeCraftCount > row.craftCount)) then
          return nil, "invalid returned aggregate measure"
        end
        if type(key) ~= "string" or key == "" then return nil, "invalid returned item set" end
        local items = {}
        for text in key:gmatch("[^,]+") do
          local itemId = tonumber(text)
          if not isInteger(itemId) or not ids.item[itemId] then return nil, "invalid returned item" end
          items[itemId] = 1
        end
        if canonicalReturns(items) ~= key then return nil, "noncanonical returned item set" end
        completeTotals[parent] = (completeTotals[parent] or 0) + row.craftCount
        authoritativeTotals[parent] = (authoritativeTotals[parent] or 0) + (row.authoritativeCraftCount or 0)
      elseif not (v2 and isGameId(key) and key > 0 or isInteger(key)) then
        return nil, "invalid returned item"
      elseif spec[3] == "reward" then
        local covered = row.quantityObservedCount
        if not isInteger(row.rewardCount) or not isCount(covered) or covered > row.rewardCount or
            (covered == 0) ~= (row.quantity == nil) or (row.quantity ~= nil and not isCount(row.quantity)) then
          return nil, "invalid first-craft reward measure"
        end
      elseif v2 then
        ok, reason = validateReagentMeasures(row, parent)
        if not ok then return nil, reason end
      elseif not isFinite(row.returnedQuantity) or row.returnedQuantity <= 0 then
        return nil, "invalid returned aggregate measure"
      end
      local grain = returnGroup(seen, row.bucketStart, row.characterDimensionId, row.recipeId, row)
      if grain[key] then return nil, "duplicate returned aggregate grain" end
      grain[key] = true
    end
  end
  for _, row in ipairs(data.craftSeries) do
    if (completeTotals[row] or 0) ~= (row.resourcefulnessCompleteProcCount or 0) or
        (v2 and (authoritativeTotals[row] or 0) ~= (row.resourcefulnessAuthoritativeProcCount or 0)) then
      return nil, "returned sets conflict with proc count"
    end
  end
  if v3 then
    local requirements = {}
    for _, row in ipairs(data.reagentRequirementSeries) do
      if not isFinite(row.bucketStart) or row.bucketStart % 86400 ~= 0 or
          type(row.candidateKey) ~= "string" or row.candidateKey == "" or
          not isInteger(row.requirementCraftCount) or row.requirementCraftCount < 1 or
          not isInteger(row.requiredQuantity) or row.requiredQuantity < row.requirementCraftCount or
          (row.resultObservationCount ~= nil and (not isCount(row.resultObservationCount) or
            row.resultObservationCount > row.requirementCraftCount)) then
        return nil, "invalid reagent requirement aggregate"
      end
      local key, previous = {}, nil
      for text in row.candidateKey:gmatch("[^,]+") do
        if not text:match("^[1-9]%d*$") then return nil, "invalid reagent requirement identity" end
        local itemId = tonumber(text)
        if not isGameId(itemId) or (previous and itemId <= previous) or not data.dimensions.items[itemId] then
          return nil, "invalid reagent requirement candidate"
        end
        previous = itemId
        key[#key + 1] = text
      end
      if #key < 1 or table.concat(key, ",") ~= row.candidateKey then
        return nil, "invalid reagent requirement family"
      end
      local parent = daily[row.bucketStart] and daily[row.bucketStart][row.characterDimensionId or 0] and
        daily[row.bucketStart][row.characterDimensionId or 0][grainKey(row.recipeId, row)]
      local familyDay = seriesGroup(requirements, row.bucketStart, row.characterDimensionId)
      local grain = familyDay[grainKey(row.recipeId, row)]
      if not grain then grain = {}; familyDay[grainKey(row.recipeId, row)] = grain end
      if not parent or row.requirementCraftCount > parent.craftCount or grain[row.candidateKey] then
        return nil, "reagent requirement aggregate has an invalid grain"
      end
      grain[row.candidateKey] = row
    end
  end
  return true
end

local function upgradeOutcomes(data)
  if data.outcomeVersion ~= nil and data.outcomeVersion ~= 1 then return true end
  local priorOutcomes = data.outcomeVersion == 1
  if not priorOutcomes and (data.resourcefulnessSets ~= nil or data.returnedReagents ~= nil) then
    return nil, "unversioned outcome collections"
  end
  if priorOutcomes and (not isArray(data.resourcefulnessSets) or not isArray(data.returnedReagents)) then
    return nil, "invalid prior outcome collections"
  end
  data.outcomeVersion, data.resourcefulnessSets = 2, {}
  data.returnedReagents = priorOutcomes and data.returnedReagents or {}
  local daily, sessions, facts = {}, {}, {}
  for _, row in ipairs(data.craftSeries or {}) do
    seriesGroup(daily, row.bucketStart, row.characterDimensionId)[row.recipeId or 0] = row
    for _, metric in ipairs(outcomeMetrics) do
      if not priorOutcomes and (row[metric] ~= nil or row[metric .. "ObservedCount"] ~= nil) then
        return nil, "unversioned outcome measures"
      end
      if priorOutcomes and metric == "resourcefulnessProcCount" then
        row[metric .. "ObservedCount"] = row[metric] or 0
        if row[metric] == 0 then row[metric] = nil end
      else
        row[metric], row[metric .. "ObservedCount"] = nil, 0
      end
    end
  end
  for _, session in ipairs(data.dimensions.sessions) do sessions[session.id] = session end
  for _, reagent in ipairs(data.reagents) do
    local rows = facts[reagent.craftId] or {}
    rows[#rows + 1] = reagent
    facts[reagent.craftId] = rows
  end
  local quantityIndex = returnIndex(data.returnedReagents, "itemId")
  for _, craft in ipairs(data.crafts) do
    if not priorOutcomes and craft.hasResourcefulnessProc ~= nil then return nil, "unversioned outcome observation" end
    local countedPositive = priorOutcomes and craft.hasResourcefulnessProc == true
    local reagentFacts = facts[craft.id] or {}
    local quantities = quantitiesFromFacts(reagentFacts)
    craft.hasResourcefulnessProc = (countedPositive or next(quantities) ~= nil) and true or nil
    craft.resourcefulnessComplete = nil
    local session = sessions[craft.sessionId]
    local characterId = session and session.characterDimensionId
    local bucket = daily[math.floor(craft.timestamp / 86400) * 86400]
    local group = bucket and bucket[characterId or 0]
    local row = group and group[craft.recipeId or 0]
    if not row then return nil, "legacy craft has no daily grain" end
    for _, metric in ipairs(outcomeMetrics) do
      local value = seriesMeasurement(craft, metric)
      if value ~= nil and not (countedPositive and metric == "resourcefulnessProcCount") then
        row[metric] = (row[metric] or 0) + value
        row[metric .. "ObservedCount"] = row[metric .. "ObservedCount"] + 1
      end
    end
    local legacyQuantities = priorOutcomes and quantitiesFromFacts(reagentFacts, true) or quantities
    local staged = {}
    for itemId, quantity in pairs(legacyQuantities) do
      local change, reason = stageGrain(quantityIndex, dayOf(craft.timestamp), characterId, craft.recipeId,
        "itemId", itemId, { returnedQuantity = quantity })
      if not change then return nil, reason end
      staged[#staged + 1] = change
    end
    commitGrains(data.returnedReagents, quantityIndex, staged)
  end
  for _, row in ipairs(data.craftSeries) do
    if row.multicraftBonusObservedCount == 1 and row.multicraftProcCountObservedCount == 0 then
      row.multicraftProcCount = row.multicraftBonus > 0 and 1 or 0
      row.multicraftProcCountObservedCount = 1
    end
  end
  return true
end

-- Converts a validated schema-1 copy in place. Existing aggregates are preserved verbatim;
-- retained details contribute only input measurements that schema 1 never aggregated.
local function migrateFromV1(data)
  if data.reagentSeries ~= nil or data.firstCraftRewards ~= nil then
    return nil, "schema 1 data contains schema 2 collections"
  end
  if data.recipeOutputs == nil then data.recipeOutputs = {} end
  local ok, reason = upgradeOutcomes(data)
  if not ok then return nil, reason end
  ok, reason = validateDatabase(data, 1)
  if not ok then return nil, reason end
  ok, reason = validateOutcomes(data, 1)
  if not ok then return nil, reason end

  local reagentSeries = {}
  for index, row in ipairs(data.returnedReagents) do
    reagentSeries[index] = { bucketStart = row.bucketStart, characterDimensionId = row.characterDimensionId,
      recipeId = row.recipeId, itemId = row.itemId, returnedQuantity = row.returnedQuantity }
  end
  data.schemaVersion, data.outcomeVersion, data.returnedReagents = 2, nil, nil
  data.reagentSeries, data.firstCraftRewards = reagentSeries, {}
  local daily, sessions, facts = {}, {}, {}
  for _, row in ipairs(data.craftSeries) do
    row.resourcefulnessAuthoritativeProcCountObservedCount = 0
    row.quoteObservedCount, row.inputCompleteCount, row.matchedCraftCount = 0, 0, 0
    seriesGroup(daily, row.bucketStart, row.characterDimensionId)[row.recipeId or 0] = row
  end
  for _, session in ipairs(data.dimensions.sessions) do sessions[session.id] = session end
  for _, reagent in ipairs(data.reagents) do
    local rows = facts[reagent.craftId]
    if not rows then
      rows = {}
      facts[reagent.craftId] = rows
    end
    rows[#rows + 1] = reagent
  end
  local requests = {}
  for _, request in ipairs(data.requests) do requests[request.id] = request end
  local reagentIndex = returnIndex(reagentSeries, "itemId")
  -- Schema 1 never stored a recipe input snapshot, so no craft gains inputComplete.
  local report = { quoteObservedCrafts = 0, allocatedCrafts = 0, ungroupedCrafts = 0 }
  for _, craft in ipairs(data.crafts) do
    local items
    items, reason = craftItems(facts[craft.id] or {})
    if not items then return nil, reason end
    local session = sessions[craft.sessionId]
    local characterId = session and session.characterDimensionId
    local bucket = daily[dayOf(craft.timestamp)]
    local group = bucket and bucket[characterId or 0]
    local parent = group and group[craft.recipeId or 0]
    local request = craft.requestId and requests[craft.requestId]
    local staged = {}
    for itemId, item in pairs(items) do
      if item.allocated then
        local change
        change, reason = stageGrain(reagentIndex, dayOf(craft.timestamp), characterId, craft.recipeId,
          "itemId", itemId, { allocatedQuantity = item.allocated, allocationCount = 1 })
        if not change then return nil, reason end
        staged[#staged + 1] = change
      end
    end
    if #staged > 0 and not parent then
      report.ungroupedCrafts = report.ungroupedCrafts + 1
    elseif #staged > 0 then
      commitGrains(reagentSeries, reagentIndex, staged)
      report.allocatedCrafts = report.allocatedCrafts + 1
      if request and #(request.allocations or {}) > 0 then
        craft.quoteObserved = true
        parent.quoteObservedCount = parent.quoteObservedCount + 1
        report.quoteObservedCrafts = report.quoteObservedCrafts + 1
      end
    end
  end
  return report
end

local function migrateFromV2(data)
  if data.reagentRequirementSeries ~= nil then
    return nil, "schema 2 data contains schema 3 requirement aggregates"
  end
  local ok, reason = validateDatabase(data, 2)
  if not ok then return nil, reason end
  ok, reason = validateOutcomes(data, 2)
  if not ok then return nil, reason end
  data.schemaVersion = 3
  data.reagentRequirementSeries = {}
  for _, row in ipairs(data.craftSeries) do row.grossRequirementsCompleteCount = 0 end
  return { recoverableFamilyRequirements = 0, ambiguousHistoricalRequirements = "not persisted in schema 2" }
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
  local sessionId = craft.sessionId
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
  local session = rows.session[craft.sessionId]
  local character = session and rows.character[session.characterDimensionId]
  local realm = session and rows.realm[session.realmDimensionId]
  local recipe = rows.recipe[craft.recipeId]
  local profession = rows.profession[craft.professionId or (recipe and recipe.professionId)]
  local expansion = recipe and rows.expansion[recipe.expansionDimensionId]
  appendIdentity(ledger.craftIdsByCharacter, character and character.key, craft.id)
  appendIdentity(ledger.craftIdsByRealm, realm and realm.key, craft.id)
  appendIdentity(ledger.craftIdsByRecipe, craft.recipeId, craft.id)
  appendIdentity(ledger.craftIdsByProfession,
    profession and profession.id or nil, craft.id)
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

local function buildRecipeOutputIndex(recipeOutputs)
  local recipesByOutput, relationshipCount = {}, 0
  for recipeId, outputs in pairs(recipeOutputs) do
    for outputItemId, observed in pairs(outputs) do
      if observed then
        local recipes = recipesByOutput[outputItemId]
        if not recipes then
          recipes = {}
          recipesByOutput[outputItemId] = recipes
        end
        recipes[recipeId] = true
        relationshipCount = relationshipCount + 1
      end
    end
  end
  return recipesByOutput, relationshipCount
end

function Ledger:RebuildIndexes()
  self.recipeOrder = nil
  self.configurationIndex = {}
  for key, conditions in pairs(self.database.configurations) do
    self.configurationIndex[assert(configurationSignature(conditions))] = key
  end
  self.returnSetIndex = returnIndex(self.database.resourcefulnessSets, "returnedItemSet")
  self.reagentIndex = returnIndex(self.database.reagentSeries, "itemId")
  self.requirementIndex = returnIndex(self.database.reagentRequirementSeries, "candidateKey")
  self.rewardIndex = returnIndex(self.database.firstCraftRewards, "itemId")
  self.dimensionIndex, self.dimensionRows = {}, {}
  for kind, collection in pairs(dimensions) do
    self.dimensionIndex[kind], self.dimensionRows[kind] = {}, {}
    for _, row in ipairs(self.database.dimensions[collection]) do
      self.dimensionIndex[kind][row.key] = row.id
      self.dimensionRows[kind][row.id] = row
    end
  end
  for kind, collection in pairs(naturalDimensions) do
    self.dimensionRows[kind] = self.database.dimensions[collection]
  end
  self.seriesByKey, self.recipeCounts, self.seriesDays = {}, {}, {}
  self.seriesCharacterIds, self.seriesRecipeIds, self.seriesRecipeIdsByCharacter = {}, {}, {}
  self.recipeIdsByOutputItemId, self.recipeOutputCount =
    buildRecipeOutputIndex(self.database.recipeOutputs)
  for _, row in ipairs(self.database.craftSeries) do
    if not self.seriesByKey[row.bucketStart] then
      self.seriesDays[#self.seriesDays + 1] = row.bucketStart
    end
    local group = seriesGroup(self.seriesByKey, row.bucketStart, row.characterDimensionId)
    group[grainKey(row.recipeId, row)] = row
    indexSeriesChoices(self, row.characterDimensionId, row.recipeId)
    if row.recipeId then
      self.recipeCounts[row.recipeId] = (self.recipeCounts[row.recipeId] or 0) + row.craftCount
    end
  end
  table.sort(self.seriesDays)
  self.craftById, self.requestById, self.reagentsByCraftId = {}, {}, {}
  self.craftIds, self.craftIdsByTime, self.operationIndex = {}, {}, {}
  self.unknownRecipeCount = 0
  self.unknownRecipeCraftIds, self.unknownCraftIdsByOutput = {}, {}
  for _, request in ipairs(self.database.requests) do self.requestById[request.id] = request end
  for _, craft in ipairs(self.database.crafts) do
    if craft.recipeId == nil then
      self.unknownRecipeCount = self.unknownRecipeCount + 1
      self.unknownRecipeCraftIds[#self.unknownRecipeCraftIds + 1] = craft.id
      if craft.outputItemId ~= nil then
        local craftIds = self.unknownCraftIdsByOutput[craft.outputItemId]
        if not craftIds then
          craftIds = {}
          self.unknownCraftIdsByOutput[craft.outputItemId] = craftIds
        end
        craftIds[#craftIds + 1] = craft.id
      end
    end
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
  if craft.recipeId == nil then
    ledger.unknownRecipeCount = ledger.unknownRecipeCount + 1
    ledger.unknownRecipeCraftIds[#ledger.unknownRecipeCraftIds + 1] = craft.id
    if craft.outputItemId ~= nil then
      local craftIds = ledger.unknownCraftIdsByOutput[craft.outputItemId]
      if not craftIds then
        craftIds = {}
        ledger.unknownCraftIdsByOutput[craft.outputItemId] = craftIds
      end
      craftIds[#craftIds + 1] = craft.id
    end
  end
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

function Ledger:LearnRecipeOutputs(observations)
  if not isArray(observations) then return nil, "recipe-output observations must be an array" end
  local copied, staged = pcall(copyValue, self.database.recipeOutputs)
  if not copied then return nil, tostring(staged) end
  local learned = 0
  for _, observation in ipairs(observations) do
    local recipeId, outputItemId = observation.recipeId, observation.outputItemId
    if not isGameId(recipeId) or not isGameId(outputItemId) or
        not self.dimensionRows.recipe[recipeId] or not self.dimensionRows.item[outputItemId] then
      return nil, "recipe-output observation references an unknown natural identity"
    end
    local outputs = staged[recipeId]
    if not outputs then
      outputs = {}
      staged[recipeId] = outputs
    end
    if not outputs[outputItemId] then
      outputs[outputItemId] = true
      learned = learned + 1
    end
  end
  if learned > 0 then
    self.database.recipeOutputs = staged
    self.recipeIdsByOutputItemId, self.recipeOutputCount = buildRecipeOutputIndex(staged)
  end
  return learned
end

function Ledger:LearnRecipeOutput(recipeId, outputItemId)
  local learned, reason = self:LearnRecipeOutputs({ {
    recipeId = recipeId,
    outputItemId = outputItemId,
  } })
  if learned == nil then return nil, reason end
  return learned > 0
end

function Ledger:BootstrapRecipeOutputs()
  local outputsByRecipe, observations = {}, {}
  local existingCount = self.recipeOutputCount
  for _, craft in ipairs(self.database.crafts) do
    if craft.recipeId ~= nil and craft.outputItemId ~= nil then
      local outputs = outputsByRecipe[craft.recipeId]
      if not outputs then
        outputs = {}
        outputsByRecipe[craft.recipeId] = outputs
      end
      outputs[craft.outputItemId] = true
    end
  end
  local recipeIds = {}
  for recipeId in pairs(outputsByRecipe) do recipeIds[#recipeIds + 1] = recipeId end
  table.sort(recipeIds)
  for _, recipeId in ipairs(recipeIds) do
    local outputIds = {}
    for outputItemId in pairs(outputsByRecipe[recipeId]) do outputIds[#outputIds + 1] = outputItemId end
    table.sort(outputIds)
    for _, outputItemId in ipairs(outputIds) do
      observations[#observations + 1] = { recipeId = recipeId, outputItemId = outputItemId }
    end
  end
  local learned, reason = self:LearnRecipeOutputs(observations)
  if learned == nil then return nil, reason end
  return { learned = learned, existing = existingCount, relationshipCount = self.recipeOutputCount }
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
  if data.schemaIdentity ~= Ledger.schemaIdentity or
      (data.schemaVersion ~= 1 and data.schemaVersion ~= 2 and data.schemaVersion ~= 3 and
        data.schemaVersion ~= Ledger.schemaVersion) then
    return nil, "ledger data refused: unsupported ledger schema"
  end
  local migration
  if data.schemaVersion == 1 then
    local report, migrationReason = migrateFromV1(data)
    if not report then
      return nil, "ledger data refused: schema 1 migration failed (saved data unchanged): " ..
        tostring(migrationReason)
    end
    migration = report
    migration.fromSchemaVersion = 1
  end
  if data.schemaVersion == 2 then
    local report, migrationReason = migrateFromV2(data)
    if not report then
      return nil, "ledger data refused: schema 2 migration failed (saved data unchanged): " ..
        tostring(migrationReason)
    end
    migration = migration or report
    migration.toSchemaVersion = 3
    if migration.fromSchemaVersion == nil then migration.fromSchemaVersion = 2 end
    for field, value in pairs(report) do migration[field] = value end
  end
  if data.schemaVersion == 3 then
    local valid, reason = validateDatabase(data, 3)
    if valid then valid, reason = validateOutcomes(data, 3) end
    if not valid then return nil, "ledger data refused: schema 3 migration failed: " .. tostring(reason) end
    data.schemaVersion, data.configurations, data.nextConfigurationKey = 4, {}, 1
    migration = migration or { fromSchemaVersion = 3 }
    migration.toSchemaVersion = 4
  end
  local valid, reason = validateDatabase(data)
  if not valid then
    return nil, "ledger data refused: " .. reason
  end
  valid, reason = validateOutcomes(data)
  if not valid then return nil, "ledger data refused: " .. reason end
  if options then
    if options.maxCrafts ~= nil then
      return nil, "ledger options refused: schema 3 does not support maxCrafts"
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
    migration = migration,
    observedOperationIds = {},
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
  for kind in pairs(naturalDimensions) do
    staged.rows[kind] = setmetatable({}, { __index = ledger.dimensionRows[kind] })
  end
  return staged
end

local function stageDimension(staged, kind, key, attributes)
  local collection = dimensions[kind] or naturalDimensions[kind]
  if not collection or (type(key) ~= "string" and type(key) ~= "number") then
    return nil, "dimension kind or key is invalid"
  end
  if naturalDimensions[kind] and not isGameId(key) then
    return nil, "natural dimension key is invalid"
  end
  if attributes ~= nil and type(attributes) ~= "table" then
    return nil, "dimension attributes must be a table"
  end
  local copied, safeAttributes = pcall(copyValue, attributes or {})
  if not copied then return nil, tostring(safeAttributes) end
  local natural = naturalDimensions[kind] ~= nil
  key = natural and key or (isFinite(key) and key % 1 == 0 and string.format("%.0f", key) or tostring(key))
  local existingId = natural and key or staged.keys[kind][key]
  local existing = staged.rows[kind][existingId]
  if not existing and not natural and not canAllocate(staged.nextIds[kind]) then
    return nil, "dimension ID capacity exhausted: " .. kind
  end
  local row = existing and copyValue(existing) or { id = natural and key or staged.nextIds[kind] }
  if not natural then row.key = key end
  local ok, reason, changed = enrich(row, safeAttributes)
  if not ok then return nil, reason end
  ok, reason = validateReferences(kind, row, staged.rows)
  if not ok then return nil, reason end
  if not existing or changed then
    staged.changes[#staged.changes + 1] = { kind = kind, row = row }
    staged.rows[kind][row.id] = row
    if not natural then staged.keys[kind][key] = row.id end
  end
  if not existing and not natural then staged.nextIds[kind] = row.id + 1 end
  return row.id
end

local function commitDimensions(ledger, staged)
  local filtersChanged = false
  for _, change in ipairs(staged.changes) do
    local kind, row = change.kind, change.row
    if kind == "recipe" then ledger.recipeOrder = nil end
    local existing = ledger.dimensionRows[kind][row.id]
    if existing then
      for _, field in ipairs(filterAttributes[kind] or {}) do
        if existing[field] ~= row[field] then filtersChanged = true end
      end
      for field, value in pairs(row) do existing[field] = value end
    else
      local rows = ledger.database.dimensions[dimensions[kind] or naturalDimensions[kind]]
      if naturalDimensions[kind] then rows[row.id] = row else rows[#rows + 1] = row end
      if not naturalDimensions[kind] then ledger.dimensionIndex[kind][row.key] = row.id end
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
      classFile = metadata.characterClassFile,
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
  self.pendingOrderRequest = nil
  self.requestAmbiguous = nil
  self.operationKind = nil
  self.operationObservation = nil
  self.attemptObservation, self.configurationChanged = nil, nil
  self.nonpersonalOperationOutstanding = nil
  self.observedOperationIds = {}
  self.operationOwnershipUncertain = nil
  self.recentOperations, self.recentOperationOrder = {}, {}
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
    local request = self.pendingRequest and self.requestById[self.pendingRequest.id]
    if request and not self.operationOwnershipUncertain and not self.requestAmbiguous and
        self.pendingRecipeId == recipeId and request.recipeId == recipeId then
      return
    end
    self.pendingRecipeId = nil
    self.ambiguousRecipe = true
    if self.pendingOrderRequest then
      self.pendingOrderRequest = nil
      self.operationOwnershipUncertain = true
    end
    return
  end
  if isGameId(recipeId) then
    self.pendingRecipeId = recipeId
  else
    self.pendingRecipeId = nil
  end
end

function Ledger:ObserveAttempt(recipeId, observation)
  local pending = self.pendingRequest or self.pendingOrderRequest
  local request = pending and self.requestById[pending.id]
  if not request or request.recipeId ~= recipeId or self.operationOwnershipUncertain or
      self.requestAmbiguous or self.ambiguousRecipe or not validateObservation(observation) then return end
  if self.attemptObservation and self.attemptObservation.requestId == request.id and
      self.attemptObservation.remaining == pending.remaining then return end
  self.attemptObservation = { requestId = request.id, remaining = pending.remaining, observation = copyValue(observation) }
  self.configurationChanged = nil
end

function Ledger:ConfigurationChanged()
  if self.pendingRequest or self.pendingOrderRequest then self.configurationChanged = true end
end

local function observedNumber(value)
  if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
    return value
  end
  return nil
end

function Ledger:SubmitCraft(recipeId, requestedCount, useConcentration, quote, selections, inputs,
  materialsSavingsEligible, observation)
  if not self.currentSessionId or not isGameId(recipeId) or not isInteger(requestedCount) or
      type(useConcentration) ~= "boolean" then
    return nil, "personal craft submission is incomplete"
  end
  if not canAllocate(self.database.nextRequestId) then return nil, "request ID capacity exhausted" end
  if quote ~= nil and type(quote) ~= "table" then return nil, "quote is invalid" end
  if selections ~= nil and not isArray(selections) then return nil, "allocations are invalid" end
  if inputs ~= nil and type(inputs) ~= "table" then return nil, "recipe inputs are invalid" end
  if materialsSavingsEligible ~= nil and type(materialsSavingsEligible) ~= "boolean" then
    return nil, "material savings eligibility is invalid"
  end
  local copied, snapshot = pcall(copyValue, { selections = selections, inputs = inputs })
  local timestamp = observedNumber(self.wall())
  if not copied or timestamp == nil then return nil, "request snapshot or timestamp is unavailable" end
  local staged = dimensionStage(self)
  local observedRecipeId, reason = stageDimension(staged, "recipe", recipeId)
  if not observedRecipeId then return nil, reason end
  local request = {
    id = self.database.nextRequestId,
    timestamp = timestamp,
    sessionId = self.currentSessionId,
    recipeId = observedRecipeId,
    requestedCount = requestedCount,
    useConcentration = useConcentration,
  }
  if materialsSavingsEligible == false then request.materialsSavingsEligible = false end
  for _, field in ipairs({ "concentrationCost", "baseSkill", "baseDifficulty", "craftingQuality" }) do
    request[field] = quote and observedNumber(quote[field]) or nil
  end
  local allocations, selectionsComplete = {}, true
  for _, selection in ipairs(snapshot.selections or {}) do
    local itemId = type(selection) == "table" and type(selection.reagent) == "table" and selection.reagent.itemID or nil
    if type(selection) == "table" and isInteger(selection.dataSlotIndex) and isGameId(itemId) and itemId > 0 and
        isInteger(selection.quantity) then
      local observedItemId
      observedItemId, reason = stageDimension(staged, "item", itemId)
      if not observedItemId then return nil, reason end
      allocations[#allocations + 1] = {
        dataSlotIndex = selection.dataSlotIndex,
        itemId = observedItemId,
        allocatedQuantity = selection.quantity,
        quality = isGameId(selection.quality) and selection.quality or nil,
      }
    elseif type(selection) ~= "table" or selection.quantity ~= 0 then
      selectionsComplete = false
    end
  end
  if #allocations > 0 then request.allocations = allocations end
  local recipeInputs = snapshot.inputs
  if recipeInputs then
    local evidenced = recipeInputs.evidenceVersion == 1 and isArray(recipeInputs.completeItemIDs)
    local grossEvidence = recipeInputs.grossRequirementsComplete == true
    local completeItems = {}
    if evidenced and selectionsComplete then
      for _, item in ipairs(recipeInputs.completeItemIDs) do
        local itemId = item.itemID
        if not isInteger(itemId) then evidenced = false; break end
        completeItems[itemId] = true
      end
    end
    if recipeInputs.requirements ~= nil and not isArray(recipeInputs.requirements) then
      evidenced, grossEvidence = false, false
    end
    if recipeInputs.fixed ~= nil and not isArray(recipeInputs.fixed) then
      evidenced, grossEvidence = false, false
    end
    local requirements = {}
    for _, requirement in ipairs(type(recipeInputs.requirements) == "table" and recipeInputs.requirements or {}) do
      if type(requirement) == "table" and isInteger(requirement.dataSlotIndex) and
          isDenseList(requirement.candidateItemIDs) and isInteger(requirement.requiredQuantity) and
          (requirement.source == "schematic" or requirement.source == "unknown") then
        local candidateItemIDs, previous, candidatesValid = {}, nil, true
        for _, itemId in ipairs(requirement.candidateItemIDs) do
          local observedItemId
          if not isInteger(itemId) or (previous and itemId <= previous) then
            evidenced, grossEvidence, candidatesValid = false, false, false
            break
          end
          observedItemId, reason = stageDimension(staged, "item", itemId)
          if not observedItemId then return nil, reason end
          candidateItemIDs[#candidateItemIDs + 1] = observedItemId
          previous = itemId
        end
        if candidatesValid and #candidateItemIDs > 0 then
          requirements[#requirements + 1] = { dataSlotIndex = requirement.dataSlotIndex,
            candidateItemIDs = candidateItemIDs, requiredQuantity = requirement.requiredQuantity,
            source = requirement.source }
        else
          evidenced, grossEvidence = false, false
        end
      else
        evidenced, grossEvidence = false, false
      end
    end
    local complete = evidenced and recipeInputs.complete == true and selectionsComplete and
      isArray(recipeInputs.fixed or {})
    local fixedReagents = {}
    for _, fixed in ipairs(type(recipeInputs.fixed) == "table" and recipeInputs.fixed or {}) do
      if type(fixed) == "table" and isInteger(fixed.dataSlotIndex) and isInteger(fixed.itemID) and
          isInteger(fixed.quantity) then
        local observedItemId
        observedItemId, reason = stageDimension(staged, "item", fixed.itemID)
        if not observedItemId then return nil, reason end
        fixedReagents[#fixedReagents + 1] = { dataSlotIndex = fixed.dataSlotIndex, itemId = observedItemId,
          requiredQuantity = fixed.quantity }
      else
        complete = false
        grossEvidence = false
      end
    end
    if #fixedReagents > 0 then request.fixedReagents = fixedReagents end
    if #requirements > 0 then request.requirements = requirements end
    if evidenced and grossEvidence then
      request.grossRequirementsComplete = true
    end
    for _, allocation in ipairs(allocations) do
      allocation.inputTotalComplete = evidenced and completeItems[allocation.itemId] == true or false
      if not allocation.inputTotalComplete then complete = false end
    end
    for _, fixed in ipairs(fixedReagents) do
      fixed.inputTotalComplete = evidenced and completeItems[fixed.itemId] == true or false
      if not fixed.inputTotalComplete then complete = false end
    end
    if complete then request.inputComplete = true end
  end
  local captured, stagedConfiguration, observationReason = stageObservation(self, observation)
  if observationReason then return nil, observationReason end
  copyObservation(captured, request)
  commitDimensions(self, staged)
  commitConfiguration(self, captured.configurationKey, stagedConfiguration)
  self.database.nextRequestId = request.id + 1
  self.database.requests[#self.database.requests + 1] = request
  self.requestById[request.id] = request
  if self.pendingRequest or self.nonpersonalOperationOutstanding then self.operationOwnershipUncertain = true end
  self.nonpersonalOperationOutstanding = nil
  self.pendingRecipeId = nil
  self.ambiguousRecipe = nil
  self.operationKind = "CraftRecipe"
  self.operationObservation = nil
  self.attemptObservation, self.configurationChanged = nil, nil
  if materialsSavingsEligible == false then
    self.pendingRequest = nil
    self.pendingOrderRequest = self.requestAmbiguous and nil or { id = request.id, remaining = requestedCount }
    self.nonpersonalOperationOutstanding = true
  else
    self.pendingOrderRequest = nil
    self.pendingRequest = self.requestAmbiguous and nil or { id = request.id, remaining = requestedCount }
  end
  return request
end

function Ledger:CancelCraft()
  self.attemptObservation, self.configurationChanged = nil, nil
  if self.pendingRequest or self.pendingOrderRequest or self.nonpersonalOperationOutstanding then
    self.operationOwnershipUncertain = true
  end
  self.nonpersonalOperationOutstanding = nil
  self.pendingRequest = nil
  self.pendingOrderRequest = nil
  self.requestAmbiguous = nil
  self.pendingRecipeId = nil
  self.ambiguousRecipe = nil
  self.operationKind = nil
  self.operationObservation = nil
end

-- Non-personal crafting calls (orders, enchants, salvage, recrafts) cannot reuse a personal
-- request. The call name also selects how their result callbacks are classified.
function Ledger:InvalidateCraft(operationKind, observation)
  self.attemptObservation, self.configurationChanged = nil, nil
  if self.nonpersonalOperationOutstanding then
    self.operationOwnershipUncertain = true
  end
  if self.pendingRequest then
    self.operationOwnershipUncertain = true
    self.pendingRequest = nil
    self.requestAmbiguous = true
  end
  if self.pendingOrderRequest then
    self.operationOwnershipUncertain = true
    self.pendingOrderRequest = nil
  end
  self.operationKind = type(operationKind) == "string" and operationKind or nil
  self.operationObservation = observation and validateObservation(observation) and copyValue(observation) or nil
  self.nonpersonalOperationOutstanding = self.operationKind ~= nil or nil
end

local function operationIdSeen(ledger, operationId)
  if operationId == nil or operationId <= 0 then
    return false
  end
  local sessionIndex = ledger.operationIndex[ledger.currentSessionId]
  return sessionIndex ~= nil and (sessionIndex[operationId] or 0) > 0
end

-- Normalizes resourcesReturned once. On a validated primary result, nil and {} are complete
-- negatives. Malformed lists keep provable positives but never claim a complete set or false.
-- Callbacks whose attempt boundary is unverified (salvage) only contribute positives.
local function normalizeReturns(value, primary)
  local result = { quantities = {}, complete = false }
  if value == nil then
    if primary then
      result.complete, result.proc, result.source = true, false, "native"
    else
      result.source = "unverified"
    end
    return result
  end
  local complete = primary and isArray(value)
  if type(value) == "table" then
    for _, entry in pairs(value) do
      local reagent = type(entry) == "table" and entry.reagent or nil
      local itemId = type(reagent) == "table" and reagent.itemID or nil
      local quantity = type(entry) == "table" and entry.quantity or nil
      if not isInteger(itemId) or not isCount(quantity) then complete = false end
      if isInteger(itemId) and isFinite(quantity) and quantity > 0 then
        local previous = result.quantities[itemId] or 0
        local total = previous + quantity
        if not isFinite(total) or total <= previous or
            (isCount(previous) and isCount(quantity) and previous > maxInteger - quantity) then
          return nil, "reagent return sum overflow"
        end
        result.quantities[itemId] = total
      end
    end
  else
    complete = false
  end
  result.complete = complete
  if complete then
    result.source, result.proc = "native", next(result.quantities) ~= nil
  else
    result.source = primary and "partial" or "unverified"
    result.proc = next(result.quantities) ~= nil or nil
  end
  return result
end

-- Bounded runtime memory of this session's committed operation IDs, used only to attach
-- first-craft rewards to their parent result.
local function rememberOperation(ledger, craft)
  local operationId = craft.gameOperationId
  if not operationId or operationId <= 0 then return end
  local recent, order = ledger.recentOperations, ledger.recentOperationOrder
  if not recent then
    recent, order = {}, {}
    ledger.recentOperations, ledger.recentOperationOrder = recent, order
  end
  if recent[operationId] ~= nil then
    recent[operationId] = false
    return
  end
  recent[operationId] = craft.id
  order[#order + 1] = operationId
  if #order > Ledger.recentOperationLimit then recent[table.remove(order, 1)] = nil end
end

-- A first-craft reward is a child of an attempt, not another attempt: it never creates a
-- craft, consumes a request position, or touches recipe correlation.
local function recordReward(ledger, result, timestamp)
  if not isInteger(result.itemID) then return nil, "first-craft reward has no item" end
  local operationId = observedNumber(result.operationID)
  local parentId = operationId and operationId > 0 and ledger.recentOperations and
    ledger.recentOperations[operationId]
  local parent = parentId and ledger.craftById[parentId] or nil
  local session = ledger.dimensionRows.session[ledger.currentSessionId]
  local staged = dimensionStage(ledger)
  local itemId, reason = stageDimension(staged, "item", result.itemID)
  if not itemId then return nil, reason end
  local quantity = isCount(result.quantity) and result.quantity or nil
  local change
  change, reason = stageGrain(ledger.rewardIndex, dayOf(timestamp), session and session.characterDimensionId,
    parent and parent.recipeId, "itemId", itemId,
    { rewardCount = 1, quantity = quantity, quantityObservedCount = quantity and 1 or 0 },
    parent)
  if not change then return nil, reason end
  commitDimensions(ledger, staged)
  commitGrains(ledger.database.firstCraftRewards, ledger.rewardIndex, { change })
  return { firstCraftReward = true, itemId = itemId, quantity = quantity,
    recipeId = parent and parent.recipeId, parentCraftId = parent and parent.id }, "first-craft-reward"
end

function Ledger:RecordResult(result, expectedRequirements)
  if type(result) ~= "table" then
    return nil, "craft result must be a table"
  end
  if not self.currentSessionId then
    return nil, "no ledger session is active"
  end
  local copied, snapshot = pcall(copyValue, result)
  local timestamp = observedNumber(self.wall())
  if not copied or timestamp == nil then
    return nil, "result snapshot or timestamp is unavailable"
  end
  result = snapshot
  if result.firstCraftReward == true then return recordReward(self, result, timestamp) end
  if not canAllocate(self.database.nextCraftId) then return nil, "craft ID capacity exhausted" end

  local data = self.database
  local stagedDimensions = dimensionStage(self)
  local craft = {
    id = data.nextCraftId,
    timestamp = timestamp,
    sessionId = self.currentSessionId,
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
  local primaryKinds = { CraftRecipe = true, CraftEnchant = true, RecraftRecipe = true, RecraftRecipeForOrder = true }
  local observation = result.operationID and self.observedOperationIds[result.operationID]
  local pendingOwnerState = self.pendingRequest or self.pendingOrderRequest
  local pendingOwner = pendingOwnerState and self.requestById[pendingOwnerState.id]
  local seen = observation and (observation.consumed or not pendingOwner or observation.requestId ~= pendingOwner.id)
  local contradictoryBegin = pendingOwner and self.pendingRecipeId and self.pendingRecipeId ~= pendingOwner.recipeId
  local validPrimary = isGameId(result.operationID) and result.operationID > 0 and
    isGameId(result.itemID) and result.itemID > 0 and isGameId(result.quantity) and result.quantity > 0 and
    result.bonusCraft ~= true
  local eligible = validPrimary and not seen and not self.requestAmbiguous and not self.ambiguousRecipe and
    not self.operationOwnershipUncertain and not contradictoryBegin
  local primary = eligible and primaryKinds[self.operationKind] == true
  local returns, returnReason = normalizeReturns(result.resourcesReturned, primary)
  if not returns then return nil, returnReason end
  craft.outcomeSource = returns.source
  craft.hasResourcefulnessProc = returns.proc
  craft.resourcefulnessComplete = returns.complete or nil

  local pending = self.pendingRequest or self.pendingOrderRequest
  local request = pending and self.requestById[pending.id]
  if request and primary then
    craft.requestId = request.id
    craft.recipeId = request.recipeId
    craft.reagentRequirements = copyValue(request.requirements or {})
    craft.grossRequirementsComplete = request.grossRequirementsComplete == true
    craft.materialsSavingsEligible = request.materialsSavingsEligible ~= false
  else
    request = nil
    if pendingOwner or self.operationOwnershipUncertain or self.requestAmbiguous or self.ambiguousRecipe then
      craft.requestCorrelationReason = seen and "observed-operation" or
        self.operationOwnershipUncertain and "ownership-quarantine" or
        contradictoryBegin and "conflicting-begin" or
        (self.requestAmbiguous or self.ambiguousRecipe) and "ambiguous-context" or "nonprimary-result"
    end
  end

  local recipeId = self.pendingRecipeId
  local ambiguousRecipe = self.ambiguousRecipe
  local reason
  if not craft.recipeId and eligible and not self.requestAmbiguous and
      recipeId and not ambiguousRecipe and
      craft.gameOperationId and craft.gameOperationId > 0 and
      not operationIdSeen(self, craft.gameOperationId) then
    craft.recipeId, reason = stageDimension(stagedDimensions, "recipe", recipeId)
    if not craft.recipeId then return nil, reason end
  end

  if not request and validPrimary and not seen and self.operationKind == "CraftRecipe" and
      not self.nonpersonalOperationOutstanding and
      type(expectedRequirements) == "table" and expectedRequirements.observation == "result" then
    local candidates = self.recipeIdsByOutputItemId[result.itemID]
    local onlyRecipe = candidates and next(candidates)
    if onlyRecipe and next(candidates, onlyRecipe) == nil and not craft.recipeId then
      craft.recipeId = onlyRecipe
    end
    if craft.recipeId == onlyRecipe and type(expectedRequirements) == "table" and
        expectedRequirements.recipeId == onlyRecipe and expectedRequirements.observation == "result" and
        isArray(expectedRequirements.requirements) then
      local copiedEvidence, evidence = pcall(copyValue, expectedRequirements.requirements)
      local requirements, slots = {}, {}
      if copiedEvidence then
        for _, requirement in ipairs(evidence) do
          local valid = isInteger(requirement.dataSlotIndex) and not slots[requirement.dataSlotIndex] and
            isInteger(requirement.requiredQuantity) and requirement.source == "schematic" and
            isDenseList(requirement.candidateItemIDs) and #requirement.candidateItemIDs > 0
          local previous
          for _, itemId in ipairs(valid and requirement.candidateItemIDs or {}) do
            if not isInteger(itemId) or (previous and itemId <= previous) then valid = false; break end
            previous = itemId
          end
          if valid then
            for _, itemId in ipairs(requirement.candidateItemIDs) do
              local observedItemId
              observedItemId, reason = stageDimension(stagedDimensions, "item", itemId)
              if not observedItemId then return nil, reason end
            end
            slots[requirement.dataSlotIndex] = true
            requirements[#requirements + 1] = requirement
          end
        end
      end
      if #requirements > 0 then
        craft.reagentRequirements = requirements
        craft.requirementObservation = "result"
      end
    end
  end

  -- Stage everything first. Any handled failure must leave correlation,
  -- dimensions, facts, and the persisted aggregates untouched.
  if isGameId(result.itemID) then
    craft.outputItemId, reason = stageDimension(stagedDimensions, "item", result.itemID)
    if not craft.outputItemId then return nil, reason end
  end

  local reagentFacts, slotCounts = {}, {}
  for _, allocation in ipairs(request and request.allocations or {}) do
    reagentFacts[#reagentFacts + 1] = {
      craftId = craft.id,
      itemId = allocation.itemId,
      dataSlotIndex = allocation.dataSlotIndex,
      quality = allocation.quality,
      allocatedQuantity = allocation.allocatedQuantity,
      inputTotalComplete = allocation.inputTotalComplete == true,
    }
    slotCounts[allocation.itemId] = (slotCounts[allocation.itemId] or 0) + 1
  end
  for _, fixed in ipairs(request and request.fixedReagents or {}) do
    reagentFacts[#reagentFacts + 1] = {
      craftId = craft.id,
      itemId = fixed.itemId,
      dataSlotIndex = fixed.dataSlotIndex,
      allocatedQuantity = fixed.requiredQuantity,
      inputTotalComplete = fixed.inputTotalComplete == true,
      fixed = true,
    }
    slotCounts[fixed.itemId] = (slotCounts[fixed.itemId] or 0) + 1
  end
  if returns.complete then
    -- The whole returned set is known, so a lone slot owns its item's return. Duplicate
    -- slots share an item total that is only attributable at craft x item grain.
    for _, fact in ipairs(reagentFacts) do
      local returned = returns.quantities[fact.itemId] or 0
      if slotCounts[fact.itemId] == 1 or returned == 0 then fact.returnedQuantity = returned end
    end
  end
  -- A return outside the known inputs never changes the outcome; it only disproves a
  -- claim that the recipe input snapshot was complete.
  local inputComplete = request ~= nil and request.inputComplete == true
  for itemId, quantity in pairs(returns.quantities) do
    local observedItemId
    observedItemId, reason = stageDimension(stagedDimensions, "item", itemId)
    if not observedItemId then return nil, reason end
    if not slotCounts[itemId] then inputComplete = false end
    if not returns.complete or slotCounts[itemId] ~= 1 then
      reagentFacts[#reagentFacts + 1] = { craftId = craft.id, itemId = observedItemId, returnedQuantity = quantity }
    end
  end
  craft.quoteObserved = request ~= nil and #(request.allocations or {}) > 0 or nil
  craft.inputComplete = inputComplete or nil

  local craftObservation = primary and (request and storedObservation(data, request) or self.operationObservation) or nil
  if craftObservation and request then
    local attempt = self.attemptObservation
    if attempt and attempt.requestId == request.id and attempt.remaining == pending.remaining then
      craftObservation = attempt.observation
    elseif pending.remaining < request.requestedCount then
      craftObservation = { context = craftObservation.context, configurationUnavailableReason = "batch-unobserved" }
    end
    if self.configurationChanged then
      craftObservation = { context = craftObservation.context, configurationUnavailableReason = "changed" }
    end
  end
  local captured, stagedConfiguration, observationReason = stageObservation(self, craftObservation)
  if observationReason then return nil, observationReason end
  copyObservation(captured, craft)
  local stagedSeries
  stagedSeries, reason = stageSeries(self.seriesByKey, self.dimensionRows.session, craft)
  if not stagedSeries then return nil, reason end
  local items
  items, reason = craftItems(reagentFacts)
  if not items then return nil, reason end
  local stagedOutcomes
  stagedOutcomes, reason = stageOutcomes(self.returnSetIndex, self.reagentIndex, self.requirementIndex,
    craft, stagedSeries.characterDimensionId, items)
  if not stagedOutcomes then return nil, reason end
  commitDimensions(self, stagedDimensions)
  commitConfiguration(self, captured.configurationKey, stagedConfiguration)
  commitStagedSeries(data, self.seriesByKey, self.seriesDays, stagedSeries)
  commitGrains(data.resourcefulnessSets, self.returnSetIndex, stagedOutcomes.sets)
  commitGrains(data.reagentSeries, self.reagentIndex, stagedOutcomes.reagents)
  commitGrains(data.reagentRequirementSeries, self.requirementIndex, stagedOutcomes.requirements)
  indexSeriesChoices(self, stagedSeries.characterDimensionId, craft.recipeId)
  if craft.recipeId then
    if not self.recipeCounts[craft.recipeId] then self.recipeOrder = nil end
    self.recipeCounts[craft.recipeId] = (self.recipeCounts[craft.recipeId] or 0) + 1
  end
  if eligible then
    self.pendingRecipeId = nil
    self.ambiguousRecipe = nil
    if primary then self.operationObservation = nil end
  end
  data.nextCraftId = craft.id + 1
  data.crafts[#data.crafts + 1] = craft
  if pending and request then
    self.attemptObservation, self.configurationChanged = nil, nil
    pending.remaining = pending.remaining - 1
    if pending.remaining == 0 then
      if self.pendingRequest == pending then self.pendingRequest = nil end
      if self.pendingOrderRequest == pending then
        self.pendingOrderRequest = nil
        self.nonpersonalOperationOutstanding = nil
      end
    end
  end
  if validPrimary and not seen and (self.operationOwnershipUncertain or contradictoryBegin) and pending then
    self.pendingRequest = nil
    self.pendingOrderRequest = nil
    self.requestAmbiguous = true
    self.operationOwnershipUncertain = true
  end
  if isGameId(result.operationID) and result.operationID > 0 then
    if not observation then
      self.observedOperationIds[result.operationID] = {
        requestId = pendingOwner and pendingOwner.id,
        consumed = validPrimary,
      }
    elseif validPrimary and not seen then
      observation.consumed = true
    end
  end
  for _, reagent in ipairs(reagentFacts) do data.reagents[#data.reagents + 1] = reagent end
  appendCraftIndexes(self, craft, reagentFacts)
  rememberOperation(self, craft)
  local learnedOutput = false
  if eligible and craft.recipeId ~= nil and craft.outputItemId ~= nil then
    learnedOutput = self:LearnRecipeOutput(craft.recipeId, craft.outputItemId) == true
  end
  if self.onCraftCommitted then pcall(self.onCraftCommitted, self, craft) end
  if learnedOutput and self.onRecipeOutputKnowledgeChanged then
    pcall(self.onRecipeOutputKnowledgeChanged, self, craft.outputItemId, "craft")
  end
  return self.craftById[craft.id] or craft
end

function Ledger:AnalyzeUnknownRecipeRepair(outputFilter)
  local analysis = {
    unattributedCount = self.unknownRecipeCount,
    repairableCount = 0,
    ambiguousCount = 0,
    missingOutputCount = 0,
    insufficientEvidenceCount = 0,
    repairs = {},
    ambiguous = {},
  }
  local candidateCraftIds = self.unknownRecipeCraftIds
  if outputFilter ~= nil then
    if type(outputFilter) ~= "table" then return nil, "invalid-output-filter" end
    candidateCraftIds = {}
    for outputItemId in pairs(outputFilter) do
      if not isGameId(outputItemId) then return nil, "invalid-output-filter" end
      for _, craftId in ipairs(self.unknownCraftIdsByOutput[outputItemId] or {}) do
        candidateCraftIds[#candidateCraftIds + 1] = craftId
      end
    end
    table.sort(candidateCraftIds)
  end
  for _, craftId in ipairs(candidateCraftIds) do
    local craft = self.craftById[craftId]
    if craft.recipeId == nil then
      if craft.outputItemId == nil then
        analysis.missingOutputCount = analysis.missingOutputCount + 1
      else
        local recipes = self.recipeIdsByOutputItemId[craft.outputItemId]
        local candidates, candidateCount = {}, 0
        for recipeId in pairs(recipes or {}) do
          candidateCount = candidateCount + 1
          candidates[#candidates + 1] = recipeId
        end
        if candidateCount == 1 then
          analysis.repairableCount = analysis.repairableCount + 1
          analysis.repairs[#analysis.repairs + 1] = {
            craftId = craft.id,
            outputItemId = craft.outputItemId,
            recipeId = candidates[1],
          }
        elseif candidateCount > 1 then
          table.sort(candidates)
          analysis.ambiguousCount = analysis.ambiguousCount + 1
          analysis.ambiguous[#analysis.ambiguous + 1] = {
            craftId = craft.id,
            outputItemId = craft.outputItemId,
            recipeIds = candidates,
          }
        else
          analysis.insufficientEvidenceCount = analysis.insufficientEvidenceCount + 1
        end
      end
    end
  end
  return analysis
end

local function seriesRowsByGrain(rows)
  local index = {}
  for _, row in ipairs(rows) do
    local group = seriesGroup(index, row.bucketStart, row.characterDimensionId)
    group[grainKey(row.recipeId, row)] = row
  end
  return index
end

local function moveSeriesMetric(source, target, craft, metric)
  local value = seriesMeasurement(craft, metric)
  if value == nil then return true end
  local coverage = metric .. "ObservedCount"
  local sourceCoverage = source[coverage]
  local sourceValue = source[metric] or 0
  if not isCount(sourceCoverage) or sourceCoverage < 1 or not isFinite(sourceValue) then
    return nil, "unknown craft series contribution is inconsistent: " .. metric
  end
  source[coverage] = sourceCoverage - 1
  if source[coverage] == 0 then
    source[metric] = nil
  else
    source[metric] = sourceValue - value
    if not isFinite(source[metric]) then return nil, "invalid source series sum: " .. metric end
  end

  local targetCoverage = target[coverage]
  if not isCount(targetCoverage) or targetCoverage >= maxInteger then
    return nil, "craft series coverage overflow: " .. metric
  end
  local targetValue = target[metric] or 0
  if not isFinite(targetValue) then return nil, "invalid target series sum: " .. metric end
  target[metric] = targetValue + value
  target[coverage] = targetCoverage + 1
  if not isFinite(target[metric]) then return nil, "craft series sum overflow: " .. metric end
  return true
end

local function moveCraftSeriesContribution(index, rows, craft, characterId, recipeId, removed)
  local bucketStart = math.floor(craft.timestamp / 86400) * 86400
  local bucket = index[bucketStart]
  local group = bucket and bucket[characterId or 0]
  local sourceKey, targetKey = grainKey(nil, craft), grainKey(recipeId, craft)
  local source = group and group[sourceKey]
  if not source or source.craftCount < 1 then
    return nil, "unknown craft series grain is missing"
  end
  local target = group and group[targetKey]
  if target and target.craftCount >= maxInteger then
    return nil, "craft series count overflow"
  end

  source.craftCount = source.craftCount - 1
  if target then
    target.craftCount = target.craftCount + 1
  else
    target = {
      bucketStart = bucketStart,
      characterDimensionId = characterId,
      recipeId = recipeId,
      craftCount = 1,
    }
    copyObservation(craft, target)
    for _, metric in ipairs(seriesMetrics) do
      target[metric .. "ObservedCount"] = 0
    end
    for _, field in ipairs(seriesCounts) do target[field] = 0 end
    group = group or seriesGroup(index, bucketStart, characterId)
    group[targetKey] = target
    rows[#rows + 1] = target
  end

  for _, metric in ipairs(seriesMetrics) do
    local ok, reason = moveSeriesMetric(source, target, craft, metric)
    if not ok then return nil, reason end
  end
  for _, field in ipairs(seriesCounts) do
    local value = seriesCount(craft, field)
    if source[field] < value or target[field] > maxInteger - value then
      return nil, "unknown craft series contribution is inconsistent: " .. field
    end
    source[field], target[field] = source[field] - value, target[field] + value
  end
  if source.craftCount == 0 then
    removed[source] = true
    group[sourceKey] = nil
  end
  return true
end

-- Subtracts one craft's measures from its unattributed grain and adds them to the same key
-- under the repaired recipe. Emptied source rows are removed once after all repairs.
local function moveGrain(index, rows, day, characterId, recipeId, field, key, delta, removed, observation)
  local group = returnGroup(index, day, characterId, nil, observation)
  local source = group[key]
  if not source then return nil, "missing aggregate contribution" end
  for name, amount in pairs(delta) do
    if source[name] == nil or source[name] < amount then
      return nil, "missing aggregate contribution: " .. name
    end
  end
  local change, reason = stageGrain(index, day, characterId, recipeId, field, key, delta, observation)
  if not change then return nil, reason end
  for name, amount in pairs(delta) do source[name] = source[name] - amount end
  if source.returnedQuantity ~= nil and source.returnedQuantity <= 0 then source.returnedQuantity = nil end
  if source.authoritativeCraftCount == 0 then source.authoritativeCraftCount = nil end
  if source.allocationCount == 0 then source.allocationCount, source.allocatedQuantity = nil, nil end
  if source.matchedCraftCount == 0 then
    source.matchedCraftCount, source.matchedAllocatedQuantity = nil, nil
    source.matchedReturnedQuantity, source.matchedReturnCount = nil, nil
  end
  if (field == "returnedItemSet" and source.craftCount == 0) or
      (field == "itemId" and source.returnedQuantity == nil and source.allocationCount == nil) then
    group[key] = nil
    removed[source] = true
  end
  commitGrains(rows, index, { change })
  return true
end

local function withoutRemoved(rows, removed)
  local kept = {}
  for _, row in ipairs(rows) do
    if not removed[row] then kept[#kept + 1] = row end
  end
  return kept
end

function Ledger:RepairUnknownRecipes(outputFilter)
  local analysis, reason = self:AnalyzeUnknownRecipeRepair(outputFilter)
  if not analysis then return nil, reason end
  if analysis.repairableCount == 0 then
    return { analysis = analysis, repairedCount = 0 }
  end

  local copied, stagedData = pcall(copyValue, self.database)
  if not copied then return nil, tostring(stagedData) end
  local repairsById = {}
  for _, repair in ipairs(analysis.repairs) do repairsById[repair.craftId] = repair end

  local seriesIndex = seriesRowsByGrain(stagedData.craftSeries)
  local setIndex = returnIndex(stagedData.resourcefulnessSets, "returnedItemSet")
  local reagentIndex = returnIndex(stagedData.reagentSeries, "itemId")
  local requirementIndex = returnIndex(stagedData.reagentRequirementSeries, "candidateKey")
  local removed = {}
  local sessions = {}
  for _, session in ipairs(stagedData.dimensions.sessions) do sessions[session.id] = session end
  local recipes = {}
  for _, recipe in pairs(stagedData.dimensions.recipes) do recipes[recipe.id] = recipe end
  for _, craft in ipairs(stagedData.crafts) do
    local repair = repairsById[craft.id]
    if repair then
      if craft.recipeId ~= nil or craft.outputItemId ~= repair.outputItemId or
          not recipes[repair.recipeId] then
        return nil, "repair plan no longer matches validated ledger facts"
      end
      local session = sessions[craft.sessionId]
      local characterId = session and session.characterDimensionId
      local ok
      ok, reason = moveCraftSeriesContribution(seriesIndex, stagedData.craftSeries,
        craft, characterId, repair.recipeId, removed)
      if not ok then return nil, reason end
      local items, deltas
      items, reason = craftItems(self.reagentsByCraftId[craft.id] or {})
      if not items then return nil, reason end
      deltas, reason = craftDeltas(craft, items)
      if not deltas then return nil, reason end
      local day = dayOf(craft.timestamp)
      if deltas.set then
        ok, reason = moveGrain(setIndex, stagedData.resourcefulnessSets, day, characterId, repair.recipeId,
          "returnedItemSet", deltas.set.key, deltas.set.delta, removed, craft)
        if not ok then return nil, reason end
      end
      for _, entry in ipairs(deltas.reagents) do
        ok, reason = moveGrain(reagentIndex, stagedData.reagentSeries, day, characterId, repair.recipeId,
          "itemId", entry.itemId, entry.delta, removed, craft)
        if not ok then return nil, reason end
      end
      for _, entry in ipairs(deltas.requirements) do
        ok, reason = moveGrain(requirementIndex, stagedData.reagentRequirementSeries, day, characterId, repair.recipeId,
          "candidateKey", entry.key, entry.delta, removed, craft)
        if not ok then return nil, reason end
      end
      craft.recipeId = repair.recipeId
    end
  end
  stagedData.craftSeries = withoutRemoved(stagedData.craftSeries, removed)
  stagedData.resourcefulnessSets = withoutRemoved(stagedData.resourcefulnessSets, removed)
  stagedData.reagentSeries = withoutRemoved(stagedData.reagentSeries, removed)
  stagedData.reagentRequirementSeries = withoutRemoved(stagedData.reagentRequirementSeries, removed)

  local valid
  valid, reason = validateDatabase(stagedData)
  if not valid then return nil, "repair validation failed: " .. tostring(reason) end
  valid, reason = validateOutcomes(stagedData)
  if not valid then return nil, "repair validation failed: " .. tostring(reason) end

  local stagedLedger = {}
  for key, value in pairs(self) do stagedLedger[key] = value end
  stagedLedger.database = stagedData
  setmetatable(stagedLedger, { __index = Ledger })
  local rebuilt, rebuildReason = pcall(Ledger.RebuildIndexes, stagedLedger)
  if not rebuilt then return nil, "repair index staging failed: " .. tostring(rebuildReason) end

  local oldKeys = {}
  for key in pairs(self) do oldKeys[#oldKeys + 1] = key end
  for _, key in ipairs(oldKeys) do self[key] = nil end
  for key, value in pairs(stagedLedger) do self[key] = value end
  return { analysis = analysis, repairedCount = analysis.repairableCount }
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
  local configurations = {}
  for _, collection in ipairs(observationCollections) do
    for _, row in ipairs(data[collection]) do
      if row.configurationKey then configurations[row.configurationKey] = true end
    end
  end
  for key in pairs(data.configurations) do
    if not configurations[key] then data.configurations[key] = nil end
  end
  if self.craftById then self:RebuildIndexes() end
  return removed
end

function Ledger:SetRetentionDays(days)
  if not isInteger(days) then return nil, "retention must be a positive integer" end
  self.database.retentionDays = days
  return true
end

function Ledger:ClearHistory()
  self:CancelCraft()
  self.database.crafts = {}
  self.database.requests = {}
  self.database.reagents = {}
  self.database.craftSeries = {}
  self.database.resourcefulnessSets = {}
  self.database.reagentSeries = {}
  self.database.reagentRequirementSeries = {}
  self.database.firstCraftRewards = {}
  self.database.configurations = {}
  self.pendingRequest, self.pendingRecipeId = nil, nil
  self.requestAmbiguous, self.ambiguousRecipe = nil, nil
  self:RebuildIndexes()
  return true
end

function Ledger:Purge()
  local session = self.dimensionRows.session[self.currentSessionId]
  if not session then return nil, "no ledger session is active" end
  local character = self.dimensionRows.character[session.characterDimensionId]
  local realm = self.dimensionRows.realm[session.realmDimensionId]
  local clean, reason = Ledger.New(nil, { wall = self.wall })
  if not clean then return nil, reason end
  local sessionId
  sessionId, reason = clean:CreateSession({
    addonVersion = session.addonVersion, wowVersion = session.wowVersion,
    wowBuild = session.wowBuild, wowBuildDate = session.wowBuildDate,
    interface = session.interface, projectId = session.projectId, locale = session.locale,
    characterName = character and character.name, characterGUID = character and character.guid,
    realmName = realm and realm.name, regionId = realm and realm.regionId,
    gameRealmId = realm and realm.gameRealmId, capabilities = session.capabilities,
  })
  if not sessionId then return nil, reason end
  self.database = clean.database
  self.migration = nil
  self:RebuildIndexes()
  self.currentSessionId = sessionId
  self:CancelCraft()
  for _, observation in pairs(self.observedOperationIds) do observation.consumed = true end
  return true
end

addon.Ledger = Ledger