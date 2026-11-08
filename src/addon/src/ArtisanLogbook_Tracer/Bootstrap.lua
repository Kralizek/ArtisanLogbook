local addonName, addon = ...
local lifecycle = CreateFrame("Frame")
local wallClock = GetServerTime or time
local elapsedClock = GetTimePreciseSec or GetTime
local loginStartedAt = wallClock and wallClock()
local loginUptime = elapsedClock and elapsedClock()

function addon.Notify(message)
  local text = "Artisan Logbook Tracer: " .. tostring(message)
  if DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
    DEFAULT_CHAT_FRAME:AddMessage(text)
  elseif type(print) == "function" then
    print(text)
  end
end

function addon.Emit(event, ...)
  if not addon.recorder or not addon.recorder.recording then return false end
  local ok, captured, reason = pcall(addon.recorder.Capture, addon.recorder, event, ...)
  if not ok then
    local _, failure = addon.recorder:Fail(captured)
    addon.Notify(failure)
    return false
  elseif not captured then
    if reason then addon.Notify(reason) end
    return false
  end
  return true
end

function addon.GetTraceMetadata()
  local version, build, buildDate, interface
  if type(GetBuildInfo) == "function" then
    local ok
    ok, version, build, buildDate, interface = pcall(GetBuildInfo)
    if not ok then addon.Notify("GetBuildInfo failed: " .. tostring(version)); version = nil end
  end
  return {
    addonVersion = addon.GetMetadata("Version"),
    version = version,
    build = build,
    buildDate = buildDate,
    interface = interface,
    projectID = WOW_PROJECT_ID,
    locale = addon.ReadOptional(_G, "GetLocale"),
    character = addon.ReadOptional(_G, "UnitName", "player"),
    characterGUID = addon.ReadOptional(_G, "UnitGUID", "player"),
    realm = addon.ReadOptional(_G, "GetRealmName"),
    flavor = addon.capabilities.flavor,
    loginStartedAt = loginStartedAt,
    loginUptime = loginUptime,
    verbose = addon.verbose == true,
    capabilities = addon.capabilities,
    coreDiagnostics = addon.GetCoreDiagnostics(),
  }
end

function addon.Start(verbose)
  if not addon.recorder then
    addon.Notify(addon.loadError or "Tracer is not initialized.")
    return
  end
  if addon.recorder.recording then addon.Notify("Already recording."); return end
  if verbose ~= nil then addon.verbose = verbose end
  local ok, reason = addon.recorder:Start(addon.GetTraceMetadata())
  addon.Notify(ok and "Recording raw events until explicitly stopped." or reason)
end

function addon.Stop()
  if addon.recorder then
    local ok, reason = addon.recorder:Stop()
    addon.Notify(ok and "Recording stopped; automatic resumption disabled." or reason)
  end
end

function addon.GetTraceStatus()
  local recorder = addon.recorder
  if not recorder then return addon.loadError or "Tracer unavailable." end
  local database = recorder.database
  local status = string.format("%s | %s | %s | %d events | %.0f KiB estimated",
    recorder.recording and "Recording" or "Stopped", database.recordingMode,
    addon.ReadOptional(_G, "UnitName", "player") or "Character unavailable",
    #database.records, database.bytes / 1024)
  if database.stoppedReason == "capture-error" then
    status = status .. "\nCapture error; automatic resumption disabled. See chat for details."
  elseif database.bytes >= addon.Trace.largeTraceBytes then
    status = status .. "\nLarge trace: memory and save/load times may increase; recording is not capped."
  end
  return status
end

function addon.Mark(label)
  if not addon.recorder or not addon.recorder.recording then
    addon.Notify("Start recording before adding a marker.")
    return
  end
  local marker = tostring(label or ""):sub(1, 240)
  if addon.Emit("TRACE_MARK", marker) then addon.Notify("Marker: " .. marker) end
end

local function registerEvents(api)
  local events = {
    "TRADE_SKILL_CRAFT_BEGIN",
    "TRADE_SKILL_ITEM_CRAFTED_RESULT",
    "TRADE_SKILL_CURRENCY_REWARD_RESULT",
    "UPDATE_TRADESKILL_CAST_STOPPED",
    "TRADE_SKILL_SHOW",
    "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_CLOSE",
    "TRADE_SKILL_UPDATE",
    "TRADE_SKILL_DETAILS_UPDATE",
    "TRADE_SKILL_ITEM_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED",
    "CRAFT_SHOW",
    "CRAFT_UPDATE",
    "CRAFT_CLOSE",
    "CHAT_MSG_LOOT",
    "BAG_UPDATE",
    "BAG_UPDATE_DELAYED",
    "CRAFTING_DETAILS_UPDATE",
    "PLAYER_EQUIPMENT_CHANGED",
    "UNIT_AURA",
    "GET_ITEM_INFO_RECEIVED",
    "UNIT_SPELLCAST_SENT",
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_FAILED_QUIET",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_CHANNEL_STOP",
    "CURRENCY_DISPLAY_UPDATE",
    "UI_ERROR_MESSAGE",
    "PLAYER_LOGOUT",
  }
  local flavor, flavorSource = addon.DetectClientFlavor(api)
  addon.capabilities = { flavor = flavor, flavorSource = flavorSource, events = {}, hooks = {},
    unavailable = {}, apis = {}, clocks = {
      wall = GetServerTime and "GetServerTime" or "time",
      elapsed = GetTimePreciseSec and "GetTimePreciseSec" or "GetTime",
    } }
  for _, name in ipairs({ "GetBuildInfo", "GetLocale", "UnitName", "UnitGUID", "GetRealmName",
    "GetServerTime", "time", "GetTimePreciseSec", "GetTime", "issecretvalue", "GetAddOnMetadata",
    "CreateFrame", "hooksecurefunc" }) do
    addon.capabilities.apis[name] = type(api[name]) == "function"
  end
  addon.capabilities.apis["C_AddOns.GetAddOnMetadata"] =
    type(api.C_AddOns) == "table" and type(api.C_AddOns.GetAddOnMetadata) == "function"
  local frame = api.CreateFrame("Frame")
  addon.eventFrame = frame
  for _, event in ipairs(events) do
    local ok, registered = pcall(function()
      if event:sub(1, 5) == "UNIT_" and type(frame.RegisterUnitEvent) == "function" then
        frame:RegisterUnitEvent(event, "player")
      else
        frame:RegisterEvent(event)
      end
      return frame:IsEventRegistered(event) == true
    end)
    addon.capabilities.events[event] = ok and registered == true
    if not ok then addon.capabilities.unavailable[event] = tostring(registered) end
  end
  frame:SetScript("OnEvent", function(_, event, ...)
    local captured = addon.Emit(event, ...)
    if captured and event == "PLAYER_LOGOUT" then
      addon.Emit("TRACE_SEGMENT_END", {
        logicalSessionID = addon.recorder.database.logicalSessionID,
        segmentID = addon.recorder.segmentID,
        reason = "PLAYER_LOGOUT",
      })
    end
  end)
end

lifecycle:RegisterEvent("ADDON_LOADED")
lifecycle:SetScript("OnEvent", function(_, event, loadedName)
  if event == "ADDON_LOADED" then
    if loadedName ~= addonName then return end
    lifecycle:UnregisterEvent("ADDON_LOADED")
    lifecycle:RegisterEvent("PLAYER_LOGIN")
    return
  end
  lifecycle:UnregisterEvent("PLAYER_LOGIN")
  local existingDatabase = ArtisanLogbookTraceDB
  if type(wallClock) ~= "function" or type(elapsedClock) ~= "function" then
    addon.loadError = "Required clocks unavailable (GetServerTime/time and GetTimePreciseSec/GetTime)."
    addon.Notify(addon.loadError)
    return
  end
  registerEvents(_G)
  local registered, reason = addon.RegisterCoreObserver()
  addon.capabilities.coreObserver = registered
  if not registered then addon.Notify("Core diagnostic observer unavailable: " .. tostring(reason)) end
  local probesOK, probeError = pcall(addon.RegisterDiagnosticProbes, _G, addon.Emit, function()
    return addon.recorder ~= nil and addon.recorder.recording and addon.recorder.verbose == true
  end)
  if not probesOK then
    addon.capabilities.unavailable.probes = tostring(probeError)
    addon.Notify("Diagnostic probes unavailable; raw events remain enabled: " .. tostring(probeError))
  end
  addon.verbose = type(existingDatabase) == "table" and existingDatabase.recordingMode == "verbose"
  addon.recorder, addon.loadError = addon.Trace.New(existingDatabase, {
    wall = wallClock,
    elapsed = elapsedClock,
  }, issecretvalue, addon.GetTraceMetadata())
  if not addon.recorder then
    addon.Notify(addon.loadError)
  else
    ArtisanLogbookTraceDB = addon.recorder.database
    addon.verbose = addon.recorder.verbose
    if addon.loadError then
      addon.Notify(addon.loadError)
    elseif addon.recorder.recording then
      addon.Notify("Automatically resumed " .. addon.recorder.database.recordingMode .. " recording.")
    end
    local ok, windowError = pcall(addon.CreateTraceWindow)
    addon.capabilities.window = ok
    if not ok then
      addon.window = nil
      addon.Notify("Tracer UI unavailable; slash recording and SavedVariables export still work: " ..
        tostring(windowError))
    end
  end
end)

SLASH_ARTISANLOGBOOKTRACE1 = "/al_trace"
SlashCmdList.ARTISANLOGBOOKTRACE = function(message)
  local command, argument = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
  command = command:lower()
  if command == "" or command == "open" or command == "export" then
    if addon.window then
      addon.window:Show()
      addon.window:Refresh(command == "export" or argument == "export")
    else
      addon.Notify(addon.loadError or "Tracer window is unavailable.")
    end
  elseif command == "start" then
    if argument == "verbose" then
      addon.Start(true)
    elseif argument == "normal" then
      addon.Start(false)
    else
      addon.Start()
    end
  elseif command == "stop" then
    addon.Stop()
  elseif command == "mark" then
    addon.Mark(argument)
  elseif command == "probe" then
    if addon.recorder and addon.recorder.recording then
      local ok, reason = pcall(addon.ProbeProfession, _G, addon.Emit, tonumber(argument))
      if not ok then
        addon.Emit("API_PROBE_ERROR", tostring(reason))
        addon.Notify("Profession probe failed; raw capture remains enabled: " .. tostring(reason))
      end
    else
      addon.Notify("Start recording before probing profession metadata.")
    end
  elseif command == "verbose" then
    addon.verbose = not addon.verbose
    addon.Notify("Verbose probes " .. (addon.verbose and "enabled." or "disabled.") ..
      " Start recording to apply the mode.")
  elseif command == "status" then
    addon.Notify(addon.GetTraceStatus())
  else
    addon.Notify(addon.loadError or
      "Use /al_trace [open|start [normal|verbose]|stop|mark <label>|probe [recipeID]|verbose|status|export].")
  end
end
