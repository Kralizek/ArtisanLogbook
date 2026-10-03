local addonName, addon = ...
local lifecycle = CreateFrame("Frame")
local loginStartedAt = GetServerTime()
local loginUptime = GetTimePreciseSec()
local professionRecipeListSignature
local professionRecipeListSettled = false

function addon.Notify(message)
  DEFAULT_CHAT_FRAME:AddMessage("Artisan Logbook: " .. message)
end

function addon.Start()
  if not addon.recorder then
    addon.Notify(addon.loadError or "Tracer is not initialized.")
    return
  end
  local version, build, buildDate, interface = GetBuildInfo()
  local ok, reason = addon.recorder:Start({
    addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version"),
    version = version,
    build = build,
    buildDate = buildDate,
    interface = interface,
    projectID = WOW_PROJECT_ID,
    locale = GetLocale(),
    character = UnitName("player"),
    characterGUID = UnitGUID("player"),
    realm = GetRealmName(),
    loginStartedAt = loginStartedAt,
    loginUptime = loginUptime,
    capabilities = addon.adapter.capabilities,
  })
  addon.Notify(ok and "Recording raw events." or reason)
end

function addon.Stop()
  if addon.recorder then
    addon.recorder:Stop()
    addon.Notify("Recording stopped.")
  end
end

function addon.Mark(label)
  if not addon.recorder or not addon.recorder.recording then
    addon.Notify("Start recording before adding a marker.")
    return
  end
  local marker = label:sub(1, 240)
  if addon.Emit("TRACE_MARK", marker) then
    addon.Notify("Marker: " .. marker)
  end
end

function addon.Emit(event, ...)
  if not addon.recorder or not addon.recorder.recording then
    return false
  end
  local ok, captured, reason = pcall(addon.recorder.Capture, addon.recorder, event, ...)
  if not ok then
    addon.recorder.recording = false
    addon.recorder.database.stoppedReason = "capture-error"
    addon.Notify("Capture stopped after an error; earlier evidence is preserved.")
    return false
  elseif not captured then
    if reason then addon.Notify(reason) end
    return false
  end
  return true
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
      local ok = pcall(addon.ledger.BeginCraft, addon.ledger, select(1, ...))
      if not ok then addon.ledgerCaptureError = true end
      tryEnrich(addon.EnrichRecipe, select(1, ...))
    elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
      local result = select(1, ...)
      if type(result) == "table" then tryEnrich(addon.EnrichItem, result.itemID) end
      local pending = addon.ledger.pendingRequest
      local request = pending and addon.ledger.requestById[pending.id]
      local recipe = request and addon.ledger.dimensionRows.recipe[request.recipeId]
      tryEnrich(addon.EnrichRecipe, recipe and recipe.id or addon.ledger.pendingRecipeId)
      local ok, fact = pcall(addon.ledger.RecordResult, addon.ledger, select(1, ...))
      if not ok or not fact then addon.ledgerCaptureError = true end
      if fact then
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
    elseif event == "CRAFTING_DETAILS_UPDATE" then
      tryEnrich(addon.EnrichRecipe, addon.ledger.pendingRecipeId)
    elseif event == "TRADE_SKILL_CLOSE" then
      professionRecipeListSignature, professionRecipeListSettled = nil, false
      addon.ledger:CancelCraft()
    end
  end
  addon.Emit(event, ...)
end

function addon.SubmitCraft(recipeId, count, concentration, quote, selections)
  if addon.ledger then
    local ok, request = pcall(addon.ledger.SubmitCraft, addon.ledger,
      recipeId, count, concentration, quote, selections)
    if not ok or not request then addon.ledgerCaptureError = true end
    if request then
      tryEnrich(addon.EnrichRecipe, recipeId)
      for _, allocation in ipairs(request.allocations or {}) do
        tryEnrich(addon.EnrichItem, allocation.itemId)
      end
    end
  end
end

function addon.InvalidateCraft()
  if addon.ledger then addon.ledger:InvalidateCraft() end
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
  addon.adapter = addon.CreateFlavorAdapter(_G, addon.HandleRetailEvent, function()
    return addon.recorder ~= nil and addon.recorder.recording
  end, addon.SubmitCraft, addon.InvalidateCraft)
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
  addon.recorder, addon.loadError = addon.Trace.New(ArtisanLogbookTraceDB, {
    wall = GetServerTime,
    elapsed = GetTimePreciseSec,
  }, issecretvalue)
  if not addon.recorder then
    addon.Notify(addon.loadError)
  else
    ArtisanLogbookTraceDB = addon.recorder.database
    addon.CreateTraceWindow()
  end
  if addon.ledgerError then
    addon.Notify("Ledger disabled: " .. addon.ledgerError)
  end
end)

SLASH_ARTISANLOGBOOKTRACE1 = "/al_trace"
SlashCmdList.ARTISANLOGBOOKTRACE = function(message)
  local command, argument = message:match("^%s*(%S*)%s*(.-)%s*$")
  command = command:lower()
  if (command == "" or command == "open" or command == "export") and addon.window then
    addon.window:Show()
    addon.window:Refresh(command == "export" or argument == "export")
  elseif command == "start" then
    addon.Start()
  elseif command == "stop" then
    addon.Stop()
  elseif command == "mark" then
    addon.Mark(argument)
  elseif command == "status" then
    addon.Notify(addon.recorder and (addon.recorder.recording and "Recording." or "Not recording.") or
      (addon.loadError or "Tracer unavailable."))
  else
    addon.Notify(addon.loadError or "Use /al_trace [open|start|stop|mark <label>|status|export].")
  end
end
