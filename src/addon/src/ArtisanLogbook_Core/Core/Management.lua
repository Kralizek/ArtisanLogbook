local addonName, addon = ...

ArtisanLogbookManagement = {}
local management = ArtisanLogbookManagement

function management.Status()
  local ledger = addon.ledger
  if not ledger then return nil, addon.ledgerError or "not-ready" end
  local data = ledger.database
  local session = ledger.dimensionRows.session[ledger.currentSessionId]
  return {
    retentionDays = data.retentionDays,
    retainedCrafts = #data.crafts,
    dailyRows = #data.craftSeries,
    schemaVersion = data.schemaVersion,
    migratedFromSchemaVersion = ledger.migration and ledger.migration.fromSchemaVersion,
    migratedQuoteCrafts = ledger.migration and ledger.migration.quoteObservedCrafts,
    addonVersion = session and session.addonVersion,
    wowBuild = session and session.wowBuild,
    captureError = addon.ledgerCaptureError == true,
    diagnosticObserverError = addon.diagnosticObserverError == true,
    operationOwnershipUncertain = ledger.operationOwnershipUncertain == true,
    authoritativeCaptureSuspended = ledger.operationOwnershipUncertain == true or
      ledger.requestAmbiguous == true or ledger.ambiguousRecipe == true,
  }
end

function management.CurrentCharacter()
  local ledger = addon.ledger
  local session = ledger and ledger.dimensionRows.session[ledger.currentSessionId]
  local character = session and ledger.dimensionRows.character[session.characterDimensionId]
  if not character then return nil end
  return { key = character.key, name = character.name }
end

function management.RecipeOutputDiagnostics()
  local ledger = addon.ledger
  if not ledger then return nil, addon.ledgerError or "not-ready" end
  local analysis, reason = ledger:AnalyzeUnknownRecipeRepair()
  if not analysis then return nil, reason end
  return {
    relationshipCount = ledger.recipeOutputCount or 0,
    unknownCount = ledger.unknownRecipeCount or 0,
    repairableCount = analysis.repairableCount,
    ambiguousCount = analysis.ambiguousCount,
    insufficientCount = analysis.insufficientEvidenceCount,
    missingOutputCount = analysis.missingOutputCount,
    recovery = addon.lastRecoverySummary,
    verifiedRelationshipCount = addon.verifiedRecipeOutputsThisSession or 0,
    recoveryDiagnostic = addon.lastRecoveryDiagnostic,
    knowledgeDiagnostic = addon.lastRecipeOutputDiagnostic,
    maintenanceDiagnostic = addon.lastMaintenanceDiagnostic,
  }
end

function management.SetRetentionDays(days)
  if not addon.ledger then return nil, "not-ready" end
  return addon.ledger:SetRetentionDays(days)
end

function management.Prune()
  if not addon.ledger then return nil, "not-ready" end
  local removed = addon.ledger:Prune(GetServerTime())
  local count = 0
  for _ in pairs(removed) do count = count + 1 end
  return count
end

function management.Clear()
  if not addon.ledger then return nil, "not-ready" end
  return addon.ledger:ClearHistory()
end

function management.AnalyzeUnknownRecipeRepair()
  if not addon.ledger then return nil, addon.ledgerError or "not-ready" end
  local analysis, reason = addon.ledger:AnalyzeUnknownRecipeRepair()
  if not analysis then
    addon.lastMaintenanceDiagnostic = "unknown-recipe-repair analysis success=false"
    return nil, reason
  end
  addon.lastRecipeRepairAnalysis = analysis
  addon.lastMaintenanceDiagnostic = string.format(
    "unknown-recipe-repair analysis unattributed=%d repairable=%d ambiguous=%d insufficient=%d missing-output=%d",
    analysis.unattributedCount, analysis.repairableCount, analysis.ambiguousCount,
    analysis.insufficientEvidenceCount, analysis.missingOutputCount)
  return analysis
end

function management.DiscoverRecipeOutputs()
  if not addon.ledger then return nil, addon.ledgerError or "not-ready" end
  local ok, summary, reason = pcall(addon.RecoverUnknownRecipeOutputs, true)
  if not ok then
    addon.lastRecoveryDiagnostic = "recipe-output discovery success=false error=" .. tostring(summary)
    return nil, tostring(summary)
  end
  if not summary then
    addon.lastRecoveryDiagnostic = "recipe-output discovery success=false reason=" .. tostring(reason)
    return nil, reason or "recipe-output discovery unavailable"
  end
  ArtisanLogbookDB = addon.ledger.database
  return summary
end

local function performUnknownRecipeRepair(mode, outputFilter)
  local ledger = addon.ledger
  if not ledger then return nil, addon.ledgerError or "not-ready" end
  local unknownCount = ledger.unknownRecipeCount or 0
  if mode == "automatic" and unknownCount == 0 then
    addon.lastMaintenanceDiagnostic =
      "unknown-recipe-repair automatic unknown=0 repairable=0 repaired=0 ambiguous=0 insufficient=0 success=true"
    local analysis = {
      unattributedCount = 0, repairableCount = 0, ambiguousCount = 0,
      insufficientEvidenceCount = 0, missingOutputCount = 0,
    }
    addon.lastRecipeRepairAnalysis = analysis
    return { repairedCount = 0, analysis = analysis }
  end

  local analysis, reason = ledger:AnalyzeUnknownRecipeRepair(outputFilter)
  if not analysis then
    addon.lastMaintenanceDiagnostic = string.format(
      "unknown-recipe-repair %s unknown=%d success=false reason=%s",
      mode, unknownCount, tostring(reason))
    return nil, reason
  end
  local result = { analysis = analysis, repairedCount = 0 }
  addon.lastRecipeRepairAnalysis = analysis
  if analysis.repairableCount > 0 then
    addon.lastMaintenanceDiagnostic = string.format(
      "unknown-recipe-repair %s started unknown=%d repairable=%d",
      mode, analysis.unattributedCount, analysis.repairableCount)
    result, reason = ledger:RepairUnknownRecipes(outputFilter)
    if not result then
      addon.lastMaintenanceDiagnostic = string.format(
        "unknown-recipe-repair %s unknown=%d repairable=%d ambiguous=%d insufficient=%d success=false reason=%s",
        mode, analysis.unattributedCount, analysis.repairableCount,
        analysis.ambiguousCount, analysis.insufficientEvidenceCount + analysis.missingOutputCount,
        tostring(reason))
      return nil, reason
    end
  end

  ArtisanLogbookDB = ledger.database
  addon.lastMaintenanceDiagnostic = string.format(
    "unknown-recipe-repair %s unknown=%d repairable=%d repaired=%d ambiguous=%d insufficient=%d missing-output=%d success=true",
    mode, analysis.unattributedCount, analysis.repairableCount, result.repairedCount,
    analysis.ambiguousCount, analysis.insufficientEvidenceCount, analysis.missingOutputCount)
  if result.repairedCount > 0 and type(management.OnUnknownRecipesRepaired) == "function" then
    pcall(management.OnUnknownRecipesRepaired, result.repairedCount)
  end
  return result
end

function management.RepairUnknownRecipes()
  return performUnknownRecipeRepair("manual")
end

function management.AutomaticRepairUnknownRecipes()
  return performUnknownRecipeRepair("automatic")
end

function management.RepairUnknownRecipesForOutputs(outputFilter)
  return performUnknownRecipeRepair("targeted", outputFilter)
end

function management.BootstrapRecipeOutputs()
  if not addon.ledger then return nil, addon.ledgerError or "not-ready" end
  local result, reason = addon.ledger:BootstrapRecipeOutputs()
  if not result then
    addon.lastRecipeOutputDiagnostic = "recipe-output knowledge bootstrap success=false reason=" ..
      tostring(reason)
    return nil, reason
  end
  ArtisanLogbookDB = addon.ledger.database
  addon.lastRecipeOutputDiagnostic = string.format(
    "recipe-output knowledge bootstrap learned=%d existing=%d total=%d",
    result.learned, result.existing, result.relationshipCount)
  return result
end

function addon.PurgeLogbookDB()
  local ledger = addon.ledger
  local ok, reason
  if ledger then
    ok, reason = ledger:Purge()
  else
    ledger, reason = addon.Ledger.New(nil, { wall = GetServerTime })
    if ledger then
      local created, sessionId, sessionReason = pcall(addon.CreateCurrentSession, ledger)
      ok = created and sessionId ~= nil
      reason = created and sessionReason or sessionId
      if ok then
        ledger.onCraftCommitted = addon.PublishCraftCommitted
        addon.ledger = ledger
      end
    end
  end
  if ok then
    ArtisanLogbookDB = addon.ledger.database
    addon.ledgerCaptureError = nil
    addon.ledgerError = nil
    addon.lastRecipeRepairAnalysis = nil
    if type(management.OnLogbookPurged) == "function" then
      pcall(management.OnLogbookPurged)
    end
  else
    reason = "Logbook DB purge failed: " .. tostring(reason or "ledger initialization unavailable")
    addon.ledgerError = reason
  end
  return ok, reason
end

function management.PurgeLogbookDB()
  return addon.PurgeLogbookDB()
end