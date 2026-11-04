local addonName, addon = ...
local lifecycle = CreateFrame("Frame")
local loginStartedAt = GetServerTime()
local loginUptime = GetTimePreciseSec()

function addon.Notify(message)
  DEFAULT_CHAT_FRAME:AddMessage("Artisan Logbook Tracer: " .. tostring(message))
end

local function coreDiagnostics()
  if type(ArtisanLogbookAPI) ~= "table" or type(ArtisanLogbookAPI.GetDiagnostics) ~= "function" then
    return { available = false, reason = "Core diagnostics are unavailable." }
  end
  local ok, snapshot, reason = pcall(ArtisanLogbookAPI.GetDiagnostics)
  if not ok then return { available = false, reason = "Core diagnostics failed: " .. tostring(snapshot) } end
  if not snapshot then return { available = false, reason = reason or "Core diagnostics are unavailable." } end
  return { available = true, snapshot = snapshot }
end

function addon.Emit(event, ...)
  if not addon.recorder or not addon.recorder.recording then return false end
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

function addon.Start(verbose)
  if not addon.recorder then
    addon.Notify(addon.loadError or "Tracer is not initialized.")
    return
  end
  if verbose ~= nil then addon.verbose = verbose end
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
    verbose = addon.verbose == true,
    capabilities = addon.capabilities,
    coreDiagnostics = coreDiagnostics(),
  })
  addon.recorder.verbose = addon.verbose == true
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
  addon.capabilities = { flavor = "retail", events = {}, hooks = {} }
  local frame = api.CreateFrame("Frame")
  addon.eventFrame = frame
  for _, event in ipairs(events) do
    local ok
    if event:sub(1, 5) == "UNIT_" then
      ok = pcall(frame.RegisterUnitEvent, frame, event, "player")
    else
      ok = pcall(frame.RegisterEvent, frame, event)
    end
    addon.capabilities.events[event] = ok and frame:IsEventRegistered(event) == true
  end
  frame:SetScript("OnEvent", function(_, event, ...)
    addon.Emit(event, ...)
  end)
end

lifecycle:RegisterEvent("ADDON_LOADED")
lifecycle:SetScript("OnEvent", function(_, _, loadedName)
  if loadedName ~= addonName then return end
  lifecycle:UnregisterEvent("ADDON_LOADED")
  local existingDatabase = ArtisanLogbookTraceDB
  addon.recorder, addon.loadError = addon.Trace.New(existingDatabase, {
    wall = GetServerTime,
    elapsed = GetTimePreciseSec,
  }, issecretvalue)
  if not addon.recorder then
    addon.Notify(addon.loadError)
  else
    ArtisanLogbookTraceDB = addon.recorder.database
    registerEvents(_G)
    local registered, reason = ArtisanLogbookAPI.SetDiagnosticObserver(function(event, context)
      addon.Emit("CORE_CAPTURE_DECISION", event, context)
    end)
    if not registered then addon.Notify("Core diagnostic observer unavailable: " .. tostring(reason)) end
    addon.RegisterDiagnosticProbes(_G, addon.Emit, function()
      return addon.recorder ~= nil and addon.recorder.recording and addon.recorder.verbose == true
    end)
    addon.CreateTraceWindow()
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
  elseif command == "verbose" then
    addon.verbose = not addon.verbose
    addon.Notify("Verbose probes " .. (addon.verbose and "enabled." or "disabled.") ..
      " Start recording to apply the mode.")
  elseif command == "status" then
    addon.Notify(addon.recorder and (addon.recorder.recording and "Recording." or
      (addon.recorder.database.stoppedReason and
        ("Full (" .. addon.recorder.database.stoppedReason .. ").") or "Not recording.")) or
      (addon.loadError or "Tracer unavailable."))
  else
    addon.Notify(addon.loadError or
      "Use /al_trace [open|start [normal|verbose]|stop|mark <label>|verbose|status|export].")
  end
end
