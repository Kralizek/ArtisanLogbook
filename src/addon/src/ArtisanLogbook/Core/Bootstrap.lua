local addonName, addon = ...
local lifecycle = CreateFrame("Frame")
local loginStartedAt = GetServerTime()
local loginUptime = GetTimePreciseSec()

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

function addon.HandleRetailEvent(event, ...)
  if addon.ledger then
    if event == "TRADE_SKILL_CRAFT_BEGIN" then
      local ok = pcall(addon.ledger.BeginCraft, addon.ledger, select(1, ...))
      if not ok then addon.ledgerCaptureError = true end
    elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
      local ok, fact = pcall(addon.ledger.RecordResult, addon.ledger, select(1, ...))
      if not ok or not fact then addon.ledgerCaptureError = true end
    elseif event == "TRADE_SKILL_CLOSE" then
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
  local version, build, buildDate, interface = GetBuildInfo()
  if addon.ledger then
    local ok, sessionId, reason = pcall(addon.ledger.CreateSession, addon.ledger, {
      addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version"),
      wowVersion = version,
      wowBuild = build,
      wowBuildDate = buildDate,
      interface = interface,
      projectId = WOW_PROJECT_ID,
      locale = GetLocale(),
      characterName = UnitName("player"),
      characterGUID = UnitGUID("player"),
      realmName = GetRealmName(),
      regionId = optionalIdentity(GetCurrentRegion),
      gameRealmId = optionalIdentity(GetRealmID),
      startedAt = loginStartedAt,
      capabilities = addon.adapter.capabilities,
    })
    if ok and sessionId then
      ArtisanLogbookDB = addon.ledger.database
      addon.ledger.onCraftCommitted = addon.PublishCraftCommitted
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
    if addon.ledgerError then
      addon.Notify("Ledger disabled: " .. addon.ledgerError)
    end
    return
  end
  ArtisanLogbookTraceDB = addon.recorder.database
  addon.CreateTraceWindow()
  if addon.ledgerError then
    addon.Notify("Ledger disabled: " .. addon.ledgerError)
  else
    addon.Notify("Ledger ready. Open the debug tracer with the book button or /al.")
  end
end)

SLASH_ARTISANLOGBOOK1 = "/al"
SLASH_ARTISANLOGBOOK2 = "/artisanlogbook"
SlashCmdList.ARTISANLOGBOOK = function(message)
  local command, argument = message:match("^%s*(%S*)%s*(.-)%s*$")
  command = command:lower()
  if command == "start" then
    addon.Start()
  elseif command == "stop" then
    addon.Stop()
  elseif command == "mark" then
    addon.Mark(argument)
  elseif command == "status" then
    if addon.recorder then
      addon.Notify(string.format("%s; %d events; %d/%d budget bytes; %s",
        addon.recorder.recording and "Recording" or "Paused", #addon.recorder.database.records,
        addon.recorder.database.bytes, addon.Trace.maxBytes,
        addon.recorder.database.stoppedReason or "no stop error"))
    else
      addon.Notify(addon.loadError or "Not initialized.")
    end
  elseif addon.window then
    addon.window:Show()
    addon.window:Refresh(command == "export")
  else
    addon.Notify(addon.loadError or "Not initialized.")
  end
end
