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
    addonVersion = session and session.addonVersion,
    wowBuild = session and session.wowBuild,
    captureError = addon.ledgerCaptureError == true,
  }
end

function management.CurrentCharacter()
  local ledger = addon.ledger
  local session = ledger and ledger.dimensionRows.session[ledger.currentSessionId]
  local character = session and ledger.dimensionRows.character[session.characterDimensionId]
  if not character then return nil end
  return { key = character.key, name = character.name }
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