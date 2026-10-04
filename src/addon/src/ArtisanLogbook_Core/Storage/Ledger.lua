local _, addon = ...

local Ledger = {}
Ledger.schemaVersion = 1
Ledger.schemaIdentity = "ArtisanLogbookLedger"
Ledger.retentionDays = 60

local maxInteger = 9007199254740991
local seriesMetrics = { "outputQuantity", "multicraftBonus", "concentrationSpent",
  "ingenuityProcCount", "ingenuityRefund", "multicraftProcCount", "resourcefulnessProcCount" }
local outcomeMetrics = { "multicraftProcCount", "resourcefulnessProcCount" }

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
    crafts = {},
    craftSeries = {},
    outcomeVersion = 1,
    resourcefulnessSets = {},
    returnedReagents = {},
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
  series = { characterDimensionId = "character", recipeId = "recipe" },
  returnedReagent = { characterDimensionId = "character", recipeId = "recipe", itemId = "item" },
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

local function seriesMeasurement(craft, metric)
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
  return true
end

local function stageSeries(index, sessions, craft)
  local bucketStart = math.floor(craft.timestamp / 86400) * 86400
  if not isFinite(bucketStart) then return nil, "invalid craft series bucket" end
  local session = sessions[craft.sessionId]
  local characterId = session and session.characterDimensionId
  local bucket = index[bucketStart]
  local group = bucket and bucket[characterId or 0]
  local key = craft.recipeId or 0
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
        craft.sessionId == nil then
      return nil, "craft facts contain an invalid or duplicate ID"
    end
    for _, field in ipairs({ "gameOperationId", "outputQuality", "outputItemLevel", "outputQuantity",
      "multicraftBonus", "concentrationSpent", "concentrationCurrencyId", "ingenuityRefund" }) do
      if craft[field] ~= nil and not isFinite(craft[field]) then
        return nil, "invalid craft measurement: " .. field
      end
    end
    for _, field in ipairs({ "hasIngenuityProc", "hasResourcefulnessProc" }) do
      if craft[field] ~= nil and type(craft[field]) ~= "boolean" then
        return nil, "invalid craft boolean: " .. field
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
  end
  for _, request in ipairs(data.requests) do
    local ok, reason = validateReferences("request", request, ids)
    if not ok then return nil, reason end
    for _, allocation in ipairs(request.allocations or {}) do
      if not isInteger(allocation.dataSlotIndex) or not isInteger(allocation.allocatedQuantity) or
          allocation.itemId == nil or
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
      if request.sessionId ~= craft.sessionId or
          request.recipeId ~= craft.recipeId then
        return nil, "craft.requestId conflicts with request context"
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
  for kind, collection in pairs(naturalDimensions) do
    for _, row in pairs(data.dimensions[collection]) do
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
    local key = row.recipeId or 0
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
    for _, metric in ipairs({ "ingenuityProcCount", "multicraftProcCount", "resourcefulnessProcCount" }) do
      if row[metric] ~= nil and
          (not isCount(row[metric]) or row[metric] > row[metric .. "ObservedCount"]) then
        return nil, "invalid craft series proc count"
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

local function returnGroup(index, day, characterId, recipeId)
  local recipes = seriesGroup(index, day, characterId)
  local key = recipeId or 0
  if not recipes[key] then recipes[key] = {} end
  return recipes[key]
end

local function returnIndex(rows, field)
  local index = {}
  for _, row in ipairs(rows) do
    returnGroup(index, row.bucketStart, row.characterDimensionId, row.recipeId)[row[field]] = row
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

local function stageReturnRow(index, craft, characterId, field, key, metric, amount)
  local day = math.floor(craft.timestamp / 86400) * 86400
  local bucket = index[day]
  local recipes = bucket and bucket[characterId or 0]
  local group = recipes and recipes[craft.recipeId or 0]
  local existing = group and group[key]
  local previous = existing and existing[metric] or 0
  if not isCount(previous) or not isCount(amount) or previous > maxInteger - amount then
    return nil, "returned aggregate overflow: " .. metric
  end
  return { existing = existing, row = {
    bucketStart = day, characterDimensionId = characterId, recipeId = craft.recipeId,
    [field] = key, [metric] = previous + amount,
  } }
end

local function commitReturnRows(rows, index, field, staged)
  for _, change in ipairs(staged) do
    local row = change.row
    if change.existing then
      for key, value in pairs(row) do change.existing[key] = value end
    else
      rows[#rows + 1] = row
      returnGroup(index, row.bucketStart, row.characterDimensionId, row.recipeId)[row[field]] = row
    end
  end
end

local function stageReturns(setIndex, quantityIndex, craft, characterId, quantities)
  local sets, reagents = {}, {}
  if craft.hasResourcefulnessProc == true then
    local key = canonicalReturns(quantities)
    if key == "" then return nil, "observed return has no items" end
    local staged, reason = stageReturnRow(setIndex, craft, characterId,
      "returnedItemSet", key, "craftCount", 1)
    if not staged then return nil, reason end
    sets[1] = staged
  end
  for itemId, quantity in pairs(quantities) do
    if quantity > 0 then
      local staged, reason = stageReturnRow(quantityIndex, craft, characterId,
        "itemId", itemId, "returnedQuantity", quantity)
      if not staged then return nil, reason end
      reagents[#reagents + 1] = staged
    end
  end
  return { sets = sets, reagents = reagents }
end

local function quantitiesFromFacts(rows)
  local quantities = {}
  for _, row in ipairs(rows) do
    if isInteger(row.itemId) and isInteger(row.returnedQuantity) then
      quantities[row.itemId] = (quantities[row.itemId] or 0) + row.returnedQuantity
    end
  end
  return quantities
end

local function validateReturns(data)
  if data.outcomeVersion ~= 1 or not isArray(data.resourcefulnessSets) or
      not isArray(data.returnedReagents) then return nil, "invalid outcome collections" end
  local daily = {}
  for _, row in ipairs(data.craftSeries) do
    seriesGroup(daily, row.bucketStart, row.characterDimensionId)[row.recipeId or 0] = row
  end
  local ids = { character = {}, recipe = data.dimensions.recipes, item = data.dimensions.items }
  for _, row in ipairs(data.dimensions.characters) do ids.character[row.id] = true end
  local totals = {}
  for _, spec in ipairs({ { data.resourcefulnessSets, "returnedItemSet", "craftCount", "series" },
      { data.returnedReagents, "itemId", "returnedQuantity", "returnedReagent" } }) do
    local seen = {}
    for _, row in ipairs(spec[1]) do
      local ok, reason = validateReferences(spec[4], row, ids)
      if not ok then return nil, reason end
      if not isFinite(row.bucketStart) or row.bucketStart % 86400 ~= 0 or
          not isInteger(row[spec[3]]) then return nil, "invalid returned aggregate measure" end
      local bucket = daily[row.bucketStart]
      local recipes = bucket and bucket[row.characterDimensionId or 0]
      local parent = recipes and recipes[row.recipeId or 0]
      if not parent then return nil, "returned aggregate has no daily grain" end
      local key = row[spec[2]]
      if spec[2] == "returnedItemSet" then
        if type(key) ~= "string" or key == "" then return nil, "invalid returned item set" end
        local quantities = {}
        for text in key:gmatch("[^,]+") do
          local itemId = tonumber(text)
          if not isInteger(itemId) or not ids.item[itemId] then return nil, "invalid returned item" end
          quantities[itemId] = 1
        end
        if canonicalReturns(quantities) ~= key then return nil, "noncanonical returned item set" end
        totals[parent] = (totals[parent] or 0) + row.craftCount
      elseif not isInteger(key) then return nil, "invalid returned item" end
      local grain = returnGroup(seen, row.bucketStart, row.characterDimensionId, row.recipeId)
      if grain[key] then return nil, "duplicate returned aggregate grain" end
      grain[key] = true
    end
  end
  for _, row in ipairs(data.craftSeries) do
    if (totals[row] or 0) ~= (row.resourcefulnessProcCount or 0) then
      return nil, "returned sets conflict with proc count"
    end
  end
  return true
end

local function upgradeOutcomes(data)
  if data.outcomeVersion ~= nil then return true end
  if data.resourcefulnessSets ~= nil or data.returnedReagents ~= nil then
    return nil, "unversioned outcome collections"
  end
  data.outcomeVersion, data.resourcefulnessSets, data.returnedReagents = 1, {}, {}
  local daily, sessions, facts = {}, {}, {}
  for _, row in ipairs(data.craftSeries or {}) do
    seriesGroup(daily, row.bucketStart, row.characterDimensionId)[row.recipeId or 0] = row
    for _, metric in ipairs(outcomeMetrics) do
      if row[metric] ~= nil or row[metric .. "ObservedCount"] ~= nil then
        return nil, "unversioned outcome measures"
      end
      row[metric .. "ObservedCount"] = 0
    end
  end
  for _, session in ipairs(data.dimensions.sessions) do sessions[session.id] = session end
  for _, reagent in ipairs(data.reagents) do
    local rows = facts[reagent.craftId] or {}
    rows[#rows + 1] = reagent
    facts[reagent.craftId] = rows
  end
  local setIndex, quantityIndex, retainedMulti = {}, {}, {}
  for _, craft in ipairs(data.crafts) do
    if craft.hasResourcefulnessProc ~= nil then return nil, "unversioned outcome observation" end
    local reagentFacts = facts[craft.id] or {}
    local quantities = quantitiesFromFacts(reagentFacts)
    if next(quantities) then craft.hasResourcefulnessProc = true
    else
      for _, reagent in ipairs(reagentFacts) do
        if reagent.returnedQuantity == 0 then craft.hasResourcefulnessProc = false; break end
      end
    end
    local session = sessions[craft.sessionId]
    local characterId = session and session.characterDimensionId
    local bucket = daily[math.floor(craft.timestamp / 86400) * 86400]
    local group = bucket and bucket[characterId or 0]
    local row = group and group[craft.recipeId or 0]
    if not row then return nil, "legacy craft has no daily grain" end
    if craft.multicraftBonus ~= nil then
      retainedMulti[row] = (retainedMulti[row] or 0) + craft.multicraftBonus
    end
    for _, metric in ipairs(outcomeMetrics) do
      local value = seriesMeasurement(craft, metric)
      if value ~= nil then
        row[metric] = (row[metric] or 0) + value
        row[metric .. "ObservedCount"] = row[metric .. "ObservedCount"] + 1
      end
    end
    local staged, reason = stageReturns(setIndex, quantityIndex, craft, characterId, quantities)
    if not staged then return nil, reason end
    commitReturnRows(data.resourcefulnessSets, setIndex, "returnedItemSet", staged.sets)
    commitReturnRows(data.returnedReagents, quantityIndex, "itemId", staged.reagents)
  end
  for _, row in ipairs(data.craftSeries) do
    local remaining = row.multicraftBonusObservedCount - row.multicraftProcCountObservedCount
    if remaining == 1 then
      local bonus = row.multicraftBonus - (retainedMulti[row] or 0)
      row.multicraftProcCount = (row.multicraftProcCount or 0) + (bonus > 0 and 1 or 0)
      row.multicraftProcCountObservedCount = row.multicraftProcCountObservedCount + 1
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
  self.returnSetIndex = returnIndex(self.database.resourcefulnessSets, "returnedItemSet")
  self.returnQuantityIndex = returnIndex(self.database.returnedReagents, "itemId")
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
    group[row.recipeId or 0] = row
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
  if data.schemaVersion ~= Ledger.schemaVersion or data.schemaIdentity ~= Ledger.schemaIdentity then
    return nil, "ledger data refused: unsupported ledger schema"
  end
  if data.recipeOutputs == nil then data.recipeOutputs = {} end

  local upgraded, upgradeReason = upgradeOutcomes(data)
  if not upgraded then return nil, "ledger data refused: " .. upgradeReason end
  local valid, reason = validateDatabase(data)
  if not valid then
    return nil, "ledger data refused: " .. reason
  end
  valid, reason = validateReturns(data)
  if not valid then return nil, "ledger data refused: " .. reason end
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
  for _, field in ipairs({ "concentrationCost", "baseSkill", "baseDifficulty", "craftingQuality" }) do
    request[field] = quote and observedNumber(quote[field]) or nil
  end
  if snapshot.selections then
    local allocations = {}
    for _, selection in ipairs(snapshot.selections) do
      local itemId = type(selection.reagent) == "table" and selection.reagent.itemID or nil
      if isInteger(selection.dataSlotIndex) and isGameId(itemId) and itemId > 0 and
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
      end
    end
    if #allocations > 0 then request.allocations = allocations end
  end
  commitDimensions(self, staged)
  self.database.nextRequestId = request.id + 1
  self.database.requests[#self.database.requests + 1] = request
  self.requestById[request.id] = request
  self.pendingRecipeId = nil
  self.ambiguousRecipe = nil
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
  local returnedQuantities, completeReturns = {}, isArray(result.resourcesReturned)
  if completeReturns then
    for _, returned in ipairs(result.resourcesReturned) do
      local itemId = type(returned.reagent) == "table" and returned.reagent.itemID
      if not isInteger(itemId) or not isCount(returned.quantity) then
        completeReturns = false
      else
        local total = (returnedQuantities[itemId] or 0) + returned.quantity
        if not isCount(total) then return nil, "reagent return sum overflow" end
        returnedQuantities[itemId] = total
      end
    end
  end
  if completeReturns then craft.hasResourcefulnessProc = canonicalReturns(returnedQuantities) ~= "" end

  local pending = self.pendingRequest
  local request = pending and self.requestById[pending.id]
  local supersededRequest = request and self.pendingRecipeId and
    self.pendingRecipeId ~= request.recipeId
  if request and not self.requestAmbiguous and not supersededRequest then
    craft.requestId = request.id
    craft.recipeId = request.recipeId
  else
    request = nil
  end

  local recipeId = self.pendingRecipeId
  local ambiguousRecipe = self.ambiguousRecipe
  local reason
  if not craft.recipeId and not self.requestAmbiguous and
      recipeId and not ambiguousRecipe and
      craft.gameOperationId and craft.gameOperationId > 0 and
      not operationIdSeen(self, craft.gameOperationId) then
    craft.recipeId, reason = stageDimension(stagedDimensions, "recipe", recipeId)
    if not craft.recipeId then return nil, reason end
  end

  -- Stage the aggregate first. Any handled failure must leave correlation,
  -- dimensions, facts, and the persisted series untouched.
  local stagedSeries
  stagedSeries, reason = stageSeries(self.seriesByKey, self.dimensionRows.session, craft)
  if not stagedSeries then return nil, reason end

  if isGameId(result.itemID) then
    craft.outputItemId, reason = stageDimension(stagedDimensions, "item", result.itemID)
    if not craft.outputItemId then return nil, reason end
  end

  local reagentFacts = {}
  local allocationsByItem = {}
  local allocatedFactsByItem = {}
  if request and request.allocations then
    for _, allocation in ipairs(request.allocations) do
      reagentFacts[#reagentFacts + 1] = {
        craftId = craft.id,
        itemId = allocation.itemId,
        dataSlotIndex = allocation.dataSlotIndex,
        quality = allocation.quality,
        allocatedQuantity = allocation.allocatedQuantity,
        returnedQuantity = type(result.resourcesReturned) == "table" and 0 or nil,
      }
      local itemId = allocation.itemId
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
        local observedItemId
        observedItemId, reason = stageDimension(stagedDimensions, "item", itemId)
        if not observedItemId then return nil, reason end
        local matched = allocationsByItem[observedItemId]
        if matched then
          matched.returnedQuantity = matched.returnedQuantity + quantity
          if not isFinite(matched.returnedQuantity) then return nil, "reagent return sum overflow" end
        else
          if allocatedFactsByItem[observedItemId] then
            for _, allocated in ipairs(allocatedFactsByItem[observedItemId]) do
              allocated.returnedQuantity = nil
            end
          end
          reagentFacts[#reagentFacts + 1] = {
            craftId = craft.id,
            itemId = observedItemId,
            returnedQuantity = quantity,
          }
        end
      end
    end
  end

  local stagedReturns
  returnedQuantities = quantitiesFromFacts(reagentFacts)
  stagedReturns, reason = stageReturns(self.returnSetIndex, self.returnQuantityIndex,
    craft, stagedSeries.characterDimensionId, returnedQuantities)
  if not stagedReturns then return nil, reason end
  commitDimensions(self, stagedDimensions)
  commitStagedSeries(data, self.seriesByKey, self.seriesDays, stagedSeries)
  commitReturnRows(data.resourcefulnessSets, self.returnSetIndex, "returnedItemSet", stagedReturns.sets)
  commitReturnRows(data.returnedReagents, self.returnQuantityIndex, "itemId", stagedReturns.reagents)
  indexSeriesChoices(self, stagedSeries.characterDimensionId, craft.recipeId)
  if craft.recipeId then
    if not self.recipeCounts[craft.recipeId] then self.recipeOrder = nil end
    self.recipeCounts[craft.recipeId] = (self.recipeCounts[craft.recipeId] or 0) + 1
  end
  self.pendingRecipeId = nil
  self.ambiguousRecipe = nil
  data.nextCraftId = craft.id + 1
  data.crafts[#data.crafts + 1] = craft
  if supersededRequest then
    -- TRADE_SKILL_CRAFT_BEGIN is authoritative for the result being committed.
    -- A different recipe means an older incomplete batch/request can no longer
    -- own this result; retire it instead of poisoning subsequent attribution.
    self.pendingRequest = nil
  elseif pending and request then
    pending.remaining = pending.remaining - 1
    if pending.remaining == 0 then self.pendingRequest = nil end
  end
  for _, reagent in ipairs(reagentFacts) do data.reagents[#data.reagents + 1] = reagent end
  appendCraftIndexes(self, craft, reagentFacts)
  local learnedOutput = false
  if craft.recipeId ~= nil and craft.outputItemId ~= nil then
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
    group[row.recipeId or 0] = row
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

local function moveCraftSeriesContribution(index, rows, craft, characterId, recipeId)
  local bucketStart = math.floor(craft.timestamp / 86400) * 86400
  local bucket = index[bucketStart]
  local group = bucket and bucket[characterId or 0]
  local source = group and group[0]
  if not source or source.craftCount < 1 then
    return nil, "unknown craft series grain is missing"
  end
  local target = group and group[recipeId]
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
    for _, metric in ipairs(seriesMetrics) do
      target[metric .. "ObservedCount"] = 0
    end
    group = group or seriesGroup(index, bucketStart, characterId)
    group[recipeId] = target
    rows[#rows + 1] = target
  end

  for _, metric in ipairs(seriesMetrics) do
    local ok, reason = moveSeriesMetric(source, target, craft, metric)
    if not ok then return nil, reason end
  end
  if source.craftCount == 0 then
    for indexInRows, row in ipairs(rows) do
      if row == source then table.remove(rows, indexInRows); break end
    end
    group[0] = nil
  end
  return true
end

local function moveReturnContribution(rows, index, craft, characterId, recipeId, field, key, metric, amount)
  local day = math.floor(craft.timestamp / 86400) * 86400
  local group = returnGroup(index, day, characterId, nil)
  local source = group[key]
  if not source or source[metric] < amount then return nil, "missing returned aggregate contribution" end
  local targetCraft = { timestamp = craft.timestamp, recipeId = recipeId }
  local staged, reason = stageReturnRow(index, targetCraft, characterId, field, key, metric, amount)
  if not staged then return nil, reason end
  source[metric] = source[metric] - amount
  if source[metric] == 0 then
    group[key] = nil
    for position, row in ipairs(rows) do
      if row == source then table.remove(rows, position); break end
    end
  end
  commitReturnRows(rows, index, field, { staged })
  return true
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
  local quantityIndex = returnIndex(stagedData.returnedReagents, "itemId")
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
        craft, characterId, repair.recipeId)
      if not ok then return nil, reason end
      local quantities = quantitiesFromFacts(self.reagentsByCraftId[craft.id] or {})
      if craft.hasResourcefulnessProc == true then
        ok, reason = moveReturnContribution(stagedData.resourcefulnessSets, setIndex,
          craft, characterId, repair.recipeId, "returnedItemSet", canonicalReturns(quantities), "craftCount", 1)
        if not ok then return nil, reason end
      end
      for itemId, quantity in pairs(quantities) do
        ok, reason = moveReturnContribution(stagedData.returnedReagents, quantityIndex,
          craft, characterId, repair.recipeId, "itemId", itemId, "returnedQuantity", quantity)
        if not ok then return nil, reason end
      end
      craft.recipeId = repair.recipeId
    end
  end

  local valid
  valid, reason = validateDatabase(stagedData)
  if not valid then return nil, "repair validation failed: " .. tostring(reason) end
  valid, reason = validateReturns(stagedData)
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
  if self.craftById then self:RebuildIndexes() end
  return removed
end

function Ledger:SetRetentionDays(days)
  if not isInteger(days) then return nil, "retention must be a positive integer" end
  self.database.retentionDays = days
  return true
end

function Ledger:ClearHistory()
  self.database.crafts = {}
  self.database.requests = {}
  self.database.reagents = {}
  self.database.craftSeries = {}
  self.database.resourcefulnessSets = {}
  self.database.returnedReagents = {}
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
  self:RebuildIndexes()
  self.currentSessionId = sessionId
  self:CancelCraft()
  return true
end

addon.Ledger = Ledger