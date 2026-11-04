local addonName, addon = ...
local lifecycle = CreateFrame("Frame")
local loginStartedAt = GetServerTime()
local professionRecipeListSignature
local professionRecipeListSettled = false

function addon.ObserveDiagnostic(event, context)
  local observer = addon.diagnosticObserver
  if type(observer) ~= "function" then return end
  local snapshot = {}
  if type(context) == "table" then
    for key, value in pairs(context) do
      local valueType = type(value)
      if type(key) == "string" and
          (valueType == "string" or valueType == "number" or valueType == "boolean") then
        snapshot[key] = value
      end
    end
  end
  local ok = pcall(observer, event, snapshot)
  if not ok then
    addon.diagnosticObserver = nil
    addon.diagnosticObserverError = true
  end
end

local function readable(value)
  if type(issecretvalue) == "function" and issecretvalue(value) then return false end
  if type(value) == "table" and type(canaccesstable) == "function" then
    return canaccesstable(value)
  end
  return true
end

local function validId(value)
  return readable(value) and type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0
end

local function displayName(value)
  return readable(value) and type(value) == "string" and value ~= "" and value ~= "Unknown" and value or nil
end

local function query(method, ...)
  if type(method) ~= "function" then return nil end
  local ok, result = pcall(method, ...)
  if not ok or not readable(result) then return nil end
  return result
end

local function recipeOutputs(recipeId)
  local tradeSkill = C_TradeSkillUI
  if type(tradeSkill) ~= "table" then return end
  local schematic = query(tradeSkill.GetRecipeSchematic, recipeId, false)
  if type(schematic) ~= "table" or not validId(schematic.recipeID) or
      schematic.recipeID ~= recipeId then return end
  local outputs = {}
  if validId(schematic.outputItemID) then outputs[schematic.outputItemID] = true end
  local qualities = query(tradeSkill.GetRecipeQualityItemIDs, recipeId)
  for _, itemId in ipairs(type(qualities) == "table" and qualities or {}) do
    if validId(itemId) then outputs[itemId] = true end
  end
  return outputs
end

local function appendRecipeOutputs(observations, recipeId, outputs)
  for itemId in pairs(outputs or {}) do
    if addon.ledger:AddDimension("item", itemId) then
      observations[#observations + 1] = { recipeId = recipeId, outputItemId = itemId }
    end
  end
end

function addon.RecoverUnknownRecipeOutputs(deferRepair)
  local ledger = addon.ledger
  if not ledger then return nil, "not-ready" end
  addon.lastRecoveryDiagnostic = nil
  local summary = { unknownCount = ledger.unknownRecipeCount, candidateCount = 0,
    verifiedCount = 0, unavailableCount = 0, unconfirmedCount = 0, learnedCount = 0 }
  local outputsByName = {}
  for outputItemId in pairs(ledger.unknownCraftIdsByOutput) do
    if not ledger.recipeIdsByOutputItemId[outputItemId] then
      local item = ledger.dimensionRows.item[outputItemId]
      local name = item and displayName(item.name)
      if name then
        outputsByName[name] = outputsByName[name] or {}
        outputsByName[name][outputItemId] = true
      end
    end
  end
  local observations = {}
  if next(outputsByName) then
    for recipeId, recipe in pairs(ledger.dimensionRows.recipe) do
      local wanted = recipe.name and outputsByName[recipe.name]
      if wanted then
        summary.candidateCount = summary.candidateCount + 1
        local outputs = query(recipeOutputs, recipeId)
        local confirmed = false
        for outputItemId in pairs(outputs or {}) do
          if wanted[outputItemId] then confirmed = true end
        end
        if confirmed then
          summary.verifiedCount = summary.verifiedCount + 1
          appendRecipeOutputs(observations, recipeId, outputs)
        elseif not outputs or not next(outputs) then
          summary.unavailableCount = summary.unavailableCount + 1
        else
          summary.unconfirmedCount = summary.unconfirmedCount + 1
        end
      end
    end
  end
  if #observations > 0 then
    local learned, reason = addon.LearnRecipeOutputs(observations, "retail-candidate", deferRepair)
    if learned == nil then return nil, reason end
    summary.learnedCount = learned
  end
  addon.lastRecoverySummary = summary
  return summary
end

function addon.EnrichRecipe(recipeId, deferKnowledge)
  if not addon.ledger or not validId(recipeId) then return end
  local tradeSkill = C_TradeSkillUI
  if type(tradeSkill) ~= "table" then return end
  local info = query(tradeSkill.GetRecipeInfo, recipeId)
  local profession = query(tradeSkill.GetProfessionInfoByRecipeID, recipeId)
  local attributes = {}
  if type(info) == "table" and info.recipeID == recipeId then
    attributes.name = displayName(info.name)
    if info.supportsQualities == true and validId(info.maxQuality) then
      attributes.maxQuality = info.maxQuality
    end
  end
  if type(profession) == "table" then
    local skillLineId = validId(profession.parentProfessionID) and profession.parentProfessionID or
      profession.professionID
    if validId(skillLineId) then
      local name = skillLineId == profession.parentProfessionID and profession.parentProfessionName or
        profession.professionName
      if not displayName(name) then
        local details = query(tradeSkill.GetProfessionInfoBySkillLineID, skillLineId)
        if type(details) == "table" then name = details.professionName end
      end
      local professionId = addon.ledger:AddDimension("profession", skillLineId,
        { name = displayName(name) })
      if professionId then attributes.professionId = professionId end
    end
    local childId = profession.professionID
    if validId(profession.parentProfessionID) and validId(childId) and
        childId ~= profession.parentProfessionID then
      local child = query(tradeSkill.GetProfessionInfoBySkillLineID, childId)
      if type(child) == "table" and child.professionID == childId and
          (child.parentProfessionID == nil or
            child.parentProfessionID == profession.parentProfessionID) and
          displayName(child.expansionName) then
        attributes.expansionDimensionId = addon.ledger:AddDimension("expansion",
          "skillLine:" .. childId, { name = child.expansionName })
      end
    end
  end
  local recipeDimensionId = addon.ledger:AddDimension("recipe", recipeId, attributes)
  local outputs = query(recipeOutputs, recipeId)
  if recipeDimensionId and outputs and next(outputs) then
    local observations = {}
    appendRecipeOutputs(observations, recipeId, outputs)
    if not deferKnowledge then addon.LearnRecipeOutputs(observations, "retail-api") end
    return observations
  end
end

function addon.LearnRecipeOutputs(observations, source, deferRepair)
  local ledger = addon.ledger
  if not ledger then return nil, addon.ledgerError or "not-ready" end
  local changedByOutput = {}
  for _, observation in ipairs(observations) do
    local existing = ledger.database.recipeOutputs[observation.recipeId]
    if not (existing and existing[observation.outputItemId]) then
      changedByOutput[observation.outputItemId] = true
    end
  end
  local learned, reason = ledger:LearnRecipeOutputs(observations)
  if learned == nil then return nil, reason end
  addon.verifiedRecipeOutputsThisSession = (addon.verifiedRecipeOutputsThisSession or 0) + learned
  local outputIds = {}
  for outputItemId in pairs(changedByOutput) do outputIds[#outputIds + 1] = outputItemId end
  table.sort(outputIds)
  local repairOutputs = {}
  for _, outputItemId in ipairs(outputIds) do
    addon.OnRecipeOutputKnowledgeChanged(ledger, outputItemId, source, true)
    local recipes = ledger.recipeIdsByOutputItemId[outputItemId]
    local firstRecipe = recipes and next(recipes)
    if firstRecipe and next(recipes, firstRecipe) == nil and
        #(ledger.unknownCraftIdsByOutput[outputItemId] or {}) > 0 then
      repairOutputs[outputItemId] = true
    end
  end
  if not deferRepair and next(repairOutputs) then
    local result, repairReason = ArtisanLogbookManagement.RepairUnknownRecipesForOutputs(repairOutputs)
    if not result then
      addon.lastRecipeOutputDiagnostic = "recipe-output knowledge targeted-repair success=false reason=" ..
        tostring(repairReason)
    end
  end
  return learned
end

function addon.OnRecipeOutputKnowledgeChanged(ledger, outputItemId, source, deferRepair)
  if ledger ~= addon.ledger then return end
  local recipes = ledger.recipeIdsByOutputItemId[outputItemId]
  local recipeCount = 0
  for _ in pairs(recipes or {}) do recipeCount = recipeCount + 1 end
  addon.lastRecipeOutputDiagnostic = string.format(
    "recipe-output knowledge changed output=%d candidates=%d source=%s",
    outputItemId, recipeCount, source or "unknown")
  if deferRepair or recipeCount ~= 1 or #(ledger.unknownCraftIdsByOutput[outputItemId] or {}) == 0 then return end
  local result, reason = ArtisanLogbookManagement.RepairUnknownRecipesForOutputs({
    [outputItemId] = true,
  })
  if not result then
    addon.lastRecipeOutputDiagnostic = string.format(
      "recipe-output knowledge changed output=%d candidates=%d source=%s targeted-repair success=false reason=%s",
      outputItemId, recipeCount, source or "unknown", tostring(reason))
  end
end

function addon.EnrichItem(itemId)
  if not addon.ledger or not validId(itemId) then return end
  local name = query(GetItemInfo, itemId)
  if displayName(name) then
    addon.ledger:AddDimension("item", itemId, { name = name })
  end
end

local function tryEnrich(method, ...)
  pcall(method, ...)
end

local function enrichProfession(event)
  local tradeSkill = C_TradeSkillUI
  if type(tradeSkill) ~= "table" then return end
  if query(tradeSkill.IsDataSourceChanging) == true or query(tradeSkill.IsTradeSkillReady) == false then
    professionRecipeListSignature, professionRecipeListSettled = nil, false
    return
  end
  local visible = query(tradeSkill.GetAllRecipeIDs)
  if type(visible) ~= "table" then return end
  local visibleIds, seen = {}, {}
  for _, recipeId in ipairs(visible) do
    if validId(recipeId) and not seen[recipeId] then
      visibleIds[#visibleIds + 1] = recipeId
      seen[recipeId] = true
    end
  end
  table.sort(visibleIds)
  local signature = table.concat(visibleIds, ",")
  if signature == professionRecipeListSignature and
      (event == "TRADE_SKILL_SHOW" or professionRecipeListSettled) then return end
  professionRecipeListSignature = signature
  professionRecipeListSettled = event == "TRADE_SKILL_LIST_UPDATE"
  local observations = {}
  for _, recipeId in ipairs(visibleIds) do
    local outputs = query(addon.EnrichRecipe, recipeId, true)
    for _, observation in ipairs(outputs or {}) do observations[#observations + 1] = observation end
  end
  if #observations > 0 then
    local learned, reason = addon.LearnRecipeOutputs(observations, "retail-api")
    if learned == nil then
      addon.lastRecipeOutputDiagnostic = "recipe-output knowledge profession-enrichment success=false reason=" ..
        tostring(reason)
    end
  end
  seen = {}
  for _, observation in ipairs(observations) do
    local item = addon.ledger.dimensionRows.item[observation.outputItemId]
    if item and not item.name and not seen[item.id] then
      seen[item.id] = true
      tryEnrich(addon.EnrichItem, item.id)
    end
  end
end

function addon.HandleRetailEvent(event, ...)
  if addon.ledger then
    if event == "TRADE_SKILL_CRAFT_BEGIN" then
      local recipeId = select(1, ...)
      local ok = pcall(addon.ledger.BeginCraft, addon.ledger, recipeId)
      if not ok then addon.ledgerCaptureError = true end
      addon.ObserveDiagnostic("craft-begin", {
        recipeId = recipeId,
        accepted = ok and addon.ledger.pendingRecipeId == recipeId and not addon.ledger.ambiguousRecipe,
        correlationReason = addon.ledger.pendingSalvage and "pending-salvage" or
          addon.ledger.ambiguousRecipe and "ambiguous-begin" or
          addon.ledger.operationOwnershipUncertain and "ownership-uncertain" or nil,
      })
      tryEnrich(addon.EnrichRecipe, select(1, ...))
    elseif event == "CRAFT_ATTEMPT_OBSERVATION" then
      local recipeId, observation = ...
      local previous = addon.ledger.attemptObservation
      local ok = pcall(addon.ledger.ObserveAttempt, addon.ledger, recipeId, observation)
      if not ok then addon.ledgerCaptureError = true end
      local attempt = addon.ledger.attemptObservation
      addon.ObserveDiagnostic("attempt-observation", {
        recipeId = recipeId,
        accepted = ok and attempt ~= previous,
        requestId = attempt and attempt.requestId,
      })
    elseif event == "CRAFT_CONFIGURATION_CHECK" then
      local ok = pcall(addon.ledger.ConfigurationChanged, addon.ledger, select(1, ...))
      if not ok then addon.ledgerCaptureError = true end
    elseif event == "CRAFTING_DETAILS_UPDATE" then
      tryEnrich(addon.EnrichRecipe, addon.ledger.pendingRecipeId)
    elseif event == "UNIT_SPELLCAST_START" then
      local unit, castGUID, spellId = ...
      local pending = addon.ledger.pendingRequest or addon.ledger.pendingOrderRequest
      local request = pending and addon.ledger.requestById[pending.id] or addon.ledger.pendingSalvage
      if unit == "player" and request and request.recipeId == spellId then addon.craftCastGUID = castGUID end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET" then
      local unit, castGUID = ...
      if unit == "player" and castGUID ~= nil and castGUID == addon.craftCastGUID then
        addon.ledger:CancelCraft()
        addon.craftCastGUID = nil
      end
    elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
      local result = select(1, ...)
      local salvage = addon.ledger.pendingSalvage
      if type(result) == "table" then tryEnrich(addon.EnrichItem, result.itemID) end
      local pending = addon.ledger.pendingRequest or addon.ledger.pendingOrderRequest
      local request = pending and addon.ledger.requestById[pending.id]
      local recipe = request and addon.ledger.dimensionRows.recipe[request.recipeId]
      tryEnrich(addon.EnrichRecipe, recipe and recipe.id or addon.ledger.pendingRecipeId)
      local expected
      if type(result) == "table" and validId(result.itemID) and
          addon.ledger.operationKind == "CraftRecipe" and
          not addon.ledger.nonpersonalOperationOutstanding and
          (not request or addon.ledger.operationOwnershipUncertain or addon.ledger.requestAmbiguous or
            addon.ledger.ambiguousRecipe or (addon.ledger.pendingRecipeId and
              addon.ledger.pendingRecipeId ~= request.recipeId)) and
          type(addon.adapter.SnapshotExpectedRequirements) == "function" then
        local candidates = addon.ledger.recipeIdsByOutputItemId[result.itemID]
        local onlyRecipe = candidates and next(candidates)
        if onlyRecipe and next(candidates, onlyRecipe) == nil then
          expected = query(addon.adapter.SnapshotExpectedRequirements, onlyRecipe) or
            { recipeId = onlyRecipe, requirements = {}, observation = "result" }
        end
      end
      local ok, fact, reason = pcall(addon.ledger.RecordResult, addon.ledger, result, expected)
      if not ok or not fact then addon.ledgerCaptureError = true end
      addon.ObserveDiagnostic("craft-result", {
        operationID = type(result) == "table" and result.operationID or nil,
        accepted = ok and fact ~= nil,
        craftId = type(fact) == "table" and fact.id or nil,
        recipeId = type(fact) == "table" and fact.recipeId or nil,
        correlationReason = type(fact) == "table" and fact.requestCorrelationReason or nil,
        reason = ok and reason or tostring(fact),
      })
      if fact and fact.firstCraftReward then
        tryEnrich(addon.EnrichItem, fact.itemId)
      elseif fact then
        if fact.requestId or (salvage and not addon.ledger.pendingSalvage) then addon.craftCastGUID = nil end
        tryEnrich(addon.EnrichRecipe, fact.recipeId)
        for _, reagent in ipairs(addon.ledger.reagentsByCraftId[fact.id] or {}) do
          tryEnrich(addon.EnrichItem, reagent.itemId)
        end
      end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
      local itemId, succeeded = ...
      local item = addon.ledger.dimensionRows.item[itemId]
      if succeeded ~= false and item and not item.name then
        tryEnrich(addon.EnrichItem, itemId)
      end
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" then
      tryEnrich(enrichProfession, event)
    elseif event == "TRADE_SKILL_CLOSE" then
      addon.craftCastGUID = nil
      professionRecipeListSignature, professionRecipeListSettled = nil, false
      addon.ledger:CancelCraft()
    end
  end
end

function addon.SubmitCraft(recipeId, count, concentration, quote, selections, inputs, materialsSavingsEligible, observation)
  if addon.ledger then
    local ok, request, reason = pcall(addon.ledger.SubmitCraft, addon.ledger,
      recipeId, count, concentration, quote, selections, inputs, materialsSavingsEligible, observation)
    if not ok then reason, request = tostring(request), nil end
    if not ok or not request then
      addon.ledgerCaptureError = true
      addon.ledger:InvalidateCraft()
    end
    addon.ObserveDiagnostic("craft-submission", {
      operation = "CraftRecipe",
      recipeId = recipeId,
      count = count,
      accepted = ok and request ~= nil,
      requestId = type(request) == "table" and request.id or nil,
      reason = reason,
    })
    if request then
      tryEnrich(addon.EnrichRecipe, recipeId)
      for _, allocation in ipairs(request.allocations or {}) do
        tryEnrich(addon.EnrichItem, allocation.itemId)
      end
      for _, fixed in ipairs(request.fixedReagents or {}) do
        tryEnrich(addon.EnrichItem, fixed.itemId)
      end
    end
  end
end

function addon.InvalidateCraft(operationKind, observation, recipeId, count, capture)
  if not addon.ledger then return end
  if operationKind == "CraftSalvage" then
    addon.craftCastGUID = nil
    local ok, submitted, reason = pcall(addon.ledger.SubmitSalvage, addon.ledger, recipeId, count, capture)
    if not ok or not submitted then
      addon.ledgerCaptureError = true
      addon.ledger:InvalidateCraft(operationKind)
    end
    addon.ObserveDiagnostic("craft-submission", {
      operation = operationKind,
      recipeId = recipeId,
      count = count,
      accepted = ok and submitted == true,
      reason = ok and reason or tostring(submitted),
    })
  else
    addon.ledger:InvalidateCraft(operationKind, observation)
    addon.ObserveDiagnostic("craft-submission", { operation = operationKind, accepted = true })
  end
end

local function optionalIdentity(api)
  if type(api) ~= "function" then return nil end
  local ok, value = pcall(api)
  if ok and type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0 then
    return value
  end
end

function addon.CreateCurrentSession(ledger, startedAt)
  local version, build, buildDate, interface = GetBuildInfo()
  local classFile = type(UnitClass) == "function" and select(2, UnitClass("player")) or nil
  return ledger:CreateSession({
    addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version"),
    wowVersion = version,
    wowBuild = build,
    wowBuildDate = buildDate,
    interface = interface,
    projectId = WOW_PROJECT_ID,
    locale = GetLocale(),
    characterName = UnitName("player"),
    characterGUID = UnitGUID("player"),
    characterClassFile = classFile,
    realmName = GetRealmName(),
    regionId = optionalIdentity(GetCurrentRegion),
    gameRealmId = optionalIdentity(GetRealmID),
    startedAt = startedAt or GetServerTime(),
    capabilities = addon.adapter.capabilities,
  })
end

lifecycle:RegisterEvent("ADDON_LOADED")
lifecycle:SetScript("OnEvent", function(_, _, loadedName)
  if loadedName ~= addonName then
    return
  end
  lifecycle:UnregisterEvent("ADDON_LOADED")
  addon.ledger, addon.ledgerError = addon.Ledger.New(ArtisanLogbookDB, {
    wall = GetServerTime,
  })
  addon.adapter = addon.CreateFlavorAdapter(_G, addon.HandleRetailEvent,
    addon.SubmitCraft, addon.InvalidateCraft)
  if addon.ledger then
    local ok, sessionId, reason = pcall(addon.CreateCurrentSession, addon.ledger, loginStartedAt)
    if ok and sessionId then
      ArtisanLogbookDB = addon.ledger.database
      addon.ledger.onCraftCommitted = addon.PublishCraftCommitted
      addon.ledger.onRecipeOutputKnowledgeChanged = addon.OnRecipeOutputKnowledgeChanged
      local bootstrapOk, knowledge, bootstrapReason = pcall(
        ArtisanLogbookManagement.BootstrapRecipeOutputs)
      if not bootstrapOk then
        addon.lastRecipeOutputDiagnostic =
          "recipe-output knowledge bootstrap success=false error=" .. tostring(knowledge)
      elseif not knowledge then
        addon.lastRecipeOutputDiagnostic =
          "recipe-output knowledge bootstrap success=false reason=" .. tostring(bootstrapReason)
      end
      ArtisanLogbookDB = addon.ledger.database
      local repairOk, result, reason = pcall(
        ArtisanLogbookManagement.AutomaticRepairUnknownRecipes)
      if not repairOk then
        addon.lastMaintenanceDiagnostic = "unknown-recipe-repair automatic success=false error=" ..
          tostring(result)
      elseif not result then
        addon.lastMaintenanceDiagnostic = "unknown-recipe-repair automatic success=false reason=" ..
          tostring(reason)
      end
      local recoveryOk, recovery = pcall(addon.RecoverUnknownRecipeOutputs)
      if not recoveryOk or not recovery then
        addon.lastRecoveryDiagnostic = "unknown-recipe discovery startup unavailable"
      end
    else
      addon.ledgerError = tostring(ok and reason or sessionId)
      addon.ledger = nil
    end
  end
  if addon.ledgerError then
    DEFAULT_CHAT_FRAME:AddMessage("Artisan Logbook: Ledger disabled: " .. addon.ledgerError)
  end
end)
