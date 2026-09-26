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
  if addon.adapter.capabilities.flavor ~= "retail" then
    addon.Notify("This tracer targets Retail only; this client is not supported.")
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
  addon.Emit("TRACE_MARK", label:sub(1, 240))
end

function addon.Emit(event, ...)
  if not addon.recorder or not addon.recorder.recording then
    return
  end
  local ok, captured, reason = pcall(addon.recorder.Capture, addon.recorder, event, ...)
  if not ok then
    addon.recorder.recording = false
    addon.recorder.database.stoppedReason = "capture-error"
    addon.Notify("Capture stopped after an error; earlier evidence is preserved.")
  elseif not captured and reason then
    addon.Notify(reason)
  end
end

lifecycle:RegisterEvent("ADDON_LOADED")
lifecycle:SetScript("OnEvent", function(_, _, loadedName)
  if loadedName ~= addonName then
    return
  end
  lifecycle:UnregisterEvent("ADDON_LOADED")
  addon.recorder, addon.loadError = addon.Trace.New(ArtisanLogbookTraceDB, {
    wall = GetServerTime,
    elapsed = GetTimePreciseSec,
  }, issecretvalue)
  if not addon.recorder then
    addon.Notify(addon.loadError)
    return
  end
  ArtisanLogbookTraceDB = addon.recorder.database
  addon.adapter = addon.CreateFlavorAdapter(_G, addon.Emit)
  addon.CreateTraceWindow()
  addon.Notify("Tracer ready (paused). Open it with the book button or /al.")
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