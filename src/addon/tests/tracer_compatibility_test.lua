local root = arg[1] or "src/ArtisanLogbook_Tracer"
local passed = 0
local function initialize(options)
  options = options or {}
  local frames, notices, hooks = {}, {}, {}
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.SlashCmdList = {}
  env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) notices[#notices + 1] = text end }
  env.GetServerTime = function() return 1800000000 end
  env.GetTimePreciseSec = function() return 12.5 end
  env.time = function() return 1800000000 end
  env.GetTime = function() return 12 end
  env.GetBuildInfo = function() return "1.60.1", "70862", "mock", 16001 end
  env.WOW_PROJECT_CAMELOT, env.WOW_PROJECT_MAINLINE = 18, 1
  env.WOW_PROJECT_ID = options.retail and 1 or 18
  if options.unrecognized then env.WOW_PROJECT_ID = 999 end
  env.GetAddOnMetadata = function(_, field)
    if field == "X-ArtisanLogbook-Flavor" then return options.packaged end
    return "0.1.0"
  end
  env.C_AddOns = { GetAddOnMetadata = env.GetAddOnMetadata }
  if options.legacy then
    env.GetServerTime, env.GetTimePreciseSec, env.C_AddOns = false, false, false
  end
  env.CreateFrame = function()
    local frame = { events = {}, scripts = {} }
    function frame:RegisterEvent(event)
      if event == "CRAFT_SHOW" or event == "TRADE_SKILL_UPDATE" then error("Unknown event " .. event) end
      self.events[event] = true
    end
    function frame:RegisterUnitEvent(event) self:RegisterEvent(event) end
    function frame:UnregisterEvent(event) self.events[event] = nil end
    function frame:IsEventRegistered(event) return self.events[event] == true end
    function frame:SetScript(event, handler) self.scripts[event] = handler end
    frames[#frames + 1] = frame
    return frame
  end
  env.ArtisanLogbookAPI = options.core
  env.hooksecurefunc = function(owner, name, callback)
    if type(owner) == "string" then callback, name = name, owner end
    hooks[name] = callback
  end
  env.DoTradeSkill = options.legacy and function() end or nil
  local addon = {}
  for _, file in ipairs({ "Capture/Trace.lua", "Compatibility.lua", "Capture/Probes.lua", "Bootstrap.lua" }) do
    local chunk = assert(loadfile(root .. "/" .. file))
    setfenv(chunk, env)("ArtisanLogbook_Tracer", addon)
  end
  addon.CreateTraceWindow = function()
    if options.brokenUI then error("Missing template") end
    addon.window = { Show = function() end, Refresh = function() end }
  end
  frames[1].scripts.OnEvent(frames[1], "ADDON_LOADED", "ArtisanLogbook_Tracer")
  return addon, env, notices, hooks
end

local function test(name, run)
  run()
  passed = passed + 1
  print("PASS " .. name)
end

test("standalone Forever records, marks, stops and exports without Core", function()
  local addon, env = initialize()
  assert(addon.recorder and not addon.recorder.recording)
  assert(env.ArtisanLogbookTraceDB == addon.recorder.database)
  assert(addon.capabilities.flavor == "forever")
  assert(not addon.capabilities.coreObserver)
  assert(not addon.capabilities.hooks.CraftRecipe)
  assert(not addon.capabilities.events.CRAFT_SHOW and addon.capabilities.unavailable.CRAFT_SHOW)
  env.SlashCmdList.ARTISANLOGBOOKTRACE("start")
  env.SlashCmdList.ARTISANLOGBOOKTRACE("mark first craft")
  addon.eventFrame.scripts.OnEvent(addon.eventFrame, "TRADE_SKILL_SHOW", nil, 42)
  env.SlashCmdList.ARTISANLOGBOOKTRACE("stop")
  local exported = assert(loadstring(assert(addon.recorder:Export())))()
  assert(exported.traceSchemaVersion == 2 and exported.traceExportVersion == 2)
  assert(#exported.records == 4)
  local metadata = exported.records[1].arguments[1]
  assert(metadata.capabilities.flavor == "forever" and not metadata.coreDiagnostics.available)
  assert(exported.records[3].arguments.n == 2 and exported.records[3].arguments[2] == 42)
  assert(exported.records[4].event == "TRACE_STOP")
  env.SlashCmdList.ARTISANLOGBOOKTRACE("export")
end)

test("Retail Core observer and diagnostics integration is preserved", function()
  local observer
  local addon = initialize({ retail = true, core = {
    SetDiagnosticObserver = function(callback) observer = callback; return true end,
    GetDiagnostics = function() return { healthy = true } end,
  } })
  assert(addon.capabilities.flavor == "retail" and addon.capabilities.coreObserver)
  addon.Start()
  observer("craft-begin", { recipeID = 123 })
  local rows = assert(loadstring(assert(addon.recorder:Export())))().records
  assert(rows[1].arguments[1].coreDiagnostics.snapshot.healthy)
  assert(rows[2].event == "CORE_CAPTURE_DECISION")
end)

test("broken Core and missing UI do not stop raw event capture", function()
  local addon, _, notices = initialize({ brokenUI = true, core = {
    SetDiagnosticObserver = function() error("broken observer") end,
    GetDiagnostics = function() error("broken diagnostics") end,
  } })
  assert(addon.recorder and not addon.capabilities.window)
  assert(not addon.capabilities.coreObserver)
  assert(#notices >= 2)
  addon.Start()
  addon.Emit("TRADE_SKILL_CLOSE")
  assert(#addon.recorder.database.records == 2)
  assert(not addon.GetCoreDiagnostics().available)
end)

test("legacy clocks, metadata and passive DoTradeSkill hook are optional", function()
  local addon, _, _, hooks = initialize({ legacy = true })
  assert(addon.capabilities.clocks.wall == "time")
  assert(addon.capabilities.clocks.elapsed == "GetTime")
  assert(addon.capabilities.hooks.DoTradeSkill)
  addon.Start()
  hooks.DoTradeSkill(7, 2, nil)
  local rows = assert(loadstring(assert(addon.recorder:Export())))().records
  assert(rows[2].event == "CALL_POST:DoTradeSkill" and rows[2].arguments.n == 3)
  assert(rows[1].timestamp == 1800000000 and rows[1].elapsed == 12)
end)

test("unknown projects remain unknown unless explicitly packaged", function()
  local addon = initialize({ unrecognized = true })
  assert(addon.capabilities.flavor == "other")
  addon = initialize({ unrecognized = true, packaged = "forever" })
  assert(addon.capabilities.flavor == "forever" and addon.capabilities.flavorSource == "package")
end)

test("partial Core API does not block initialization", function()
  local addon = initialize({ core = { GetDiagnostics = function() return {} end } })
  assert(addon.recorder and not addon.capabilities.coreObserver and addon.GetCoreDiagnostics().available)
end)

test("explicit profession probes preserve tuples and report errors/unavailability", function()
  local addon, env = initialize()
  env.GetTradeSkillSelectionIndex = function() return 7 end
  env.GetTradeSkillInfo = function(index) assert(index == 7); return "Potion", nil, 2 end
  env.GetTradeSkillNumReagents = function() return 1 end
  env.GetTradeSkillReagentInfo = function() error("data not ready") end
  env.C_TradeSkillUI = { GetRecipeInfo = function(id) return { recipeID = id } end }
  addon.Start()
  env.SlashCmdList.ARTISANLOGBOOKTRACE("probe 123")
  local found = {}
  for _, row in ipairs(addon.recorder.database.records) do
    if row.event:match("^API_PROBE:") then
      found[row.event] = assert(loadstring("return " .. row.payload))()[1]
    end
  end
  assert(found["API_PROBE:GetTradeSkillInfo"].values.n == 3)
  assert(found["API_PROBE:GetTradeSkillReagentInfo"].status == "error")
  assert(found["API_PROBE:GetTradeSkillItemLink"].status == "unavailable")
  assert(found["API_PROBE:C_TradeSkillUI.GetRecipeInfo"].values[1].recipeID == 123)
end)
print(passed .. " tracer compatibility tests passed")
