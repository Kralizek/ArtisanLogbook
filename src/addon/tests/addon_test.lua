local frames, notices = {}, {}
local environment = setmetatable({}, { __index = _G })
environment._G = environment
local methods = {}

for _, name in ipairs({
  "SetSize", "SetPoint", "SetClampedToScreen", "SetMovable", "EnableMouse", "RegisterForDrag",
  "StartMoving", "StopMovingOrSizing", "SetJustifyH", "SetAutoFocus", "SetMaxLetters",
  "ClearFocus", "SetMultiLine", "SetFontObject", "SetWidth", "SetCursorPosition",
  "UpdateScrollChildRect", "SetScrollChild", "SetNormalTexture", "SetHighlightTexture",
}) do
  methods[name] = function() end
end
function methods:SetText(value) assert(type(value) == "string"); self.text = value end
function methods:GetText() return self.text or "" end
function methods:GetWidth() return 1024 end
function methods:GetHeight() return 768 end
function methods:SetScript(name, callback) self.scripts[name] = callback end
function methods:RegisterEvent(event) self.events[event] = true end
function methods:UnregisterEvent(event) self.events[event] = nil end
function methods:RegisterUnitEvent(event, unit) assert(unit == "player"); self:RegisterEvent(event) end
function methods:IsEventRegistered(event) return self.events[event] or false end
function methods:Hide() self.shown = false end
function methods:Show()
  self.shown = true
  if self.scripts.OnShow then self.scripts.OnShow(self) end
end
function methods:IsShown() return self.shown end
function methods:SetVerticalScroll(offset) self.offset = offset end
function methods:GetVerticalScroll() return self.offset or 0 end

local function object()
  return setmetatable({ scripts = {}, events = {}, shown = true }, { __index = methods })
end
function methods:CreateFontString() return object() end
environment.CreateFrame = function(kind, name, parent, template)
  local frame = object()
  frame.kind, frame.name, frame.parent = kind, name, parent
  if template == "BasicFrameTemplateWithInset" then frame.TitleText = object() end
  frames[#frames + 1] = frame
  return frame
end
environment.UIParent = object()
environment.Minimap = object()
environment.ChatFontNormal = {}
environment.UISpecialFrames = {}
environment.StaticPopupDialogs = {}
environment.SlashCmdList = {}
environment.tinsert = table.insert
environment.StaticPopup_Show = function(name) environment.popup = name end
environment.DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) notices[#notices + 1] = message end }
environment.GetServerTime = function() return 1800000000 end
environment.GetTimePreciseSec = function() return 100.5 end
environment.GetBuildInfo = function() return "12.1.0", "69933", "mock", 120100 end
environment.GetLocale = function() return "enUS" end
environment.UnitName = function() return "TestCrafter" end
environment.UnitGUID = function() return "Player-1-123" end
environment.GetRealmName = function() return "TestRealm" end
environment.C_AddOns = { GetAddOnMetadata = function() return "0.1.0-tracer" end }
environment.WOW_PROJECT_ID = 1
environment.WOW_PROJECT_MAINLINE = 1

local root = arg[1] or "."
local addon = {}
for line in io.lines(root .. "/ArtisanLogbook.toc") do
  if line:match("%.lua$") then
    local chunk = assert(loadfile(root .. "/" .. line))
    setfenv(chunk, environment)
    chunk("ArtisanLogbook", addon)
  end
end
local lifecycle = frames[1]
lifecycle.scripts.OnEvent(lifecycle, "ADDON_LOADED", "OtherAddon")
assert(addon.recorder == nil)
lifecycle.scripts.OnEvent(lifecycle, "ADDON_LOADED", "ArtisanLogbook")
assert(addon.recorder and not addon.recorder.recording)
assert(environment.ArtisanLogbookTraceDB == addon.recorder.database)
assert(addon.window and not addon.window:IsShown())
environment.SlashCmdList.ARTISANLOGBOOK("")
assert(addon.window:IsShown())
environment.SlashCmdList.ARTISANLOGBOOK("start")
environment.SlashCmdList.ARTISANLOGBOOK("mark basic craft")
addon.adapter.frame.scripts.OnEvent(addon.adapter.frame, "TRADE_SKILL_CRAFT_BEGIN", 456)
addon.adapter.frame.scripts.OnEvent(addon.adapter.frame, "TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 1 })
environment.SlashCmdList.ARTISANLOGBOOK("stop")
assert(#addon.recorder.database.records == 5)
assert(addon.recorder.database.records[2].event == "TRACE_MARK")
assert(not addon.recorder.recording)
environment.SlashCmdList.ARTISANLOGBOOK("export")
environment.SlashCmdList.ARTISANLOGBOOK("status")
assert(notices[#notices]:find("5 events", 1, true))

local function click(text)
  for _, frame in ipairs(frames) do
    if frame.kind == "Button" and frame.text == text then
      frame.scripts.OnClick(frame)
      return
    end
  end
  error("Missing button: " .. text)
end
click("Diagnostics")
click("Export")
click(">")
click("<")
click("Clear")
assert(environment.popup == "ARTISANLOGBOOK_CLEAR_TRACE")
assert(#addon.recorder.database.records == 5)
environment.StaticPopupDialogs.ARTISANLOGBOOK_CLEAR_TRACE.OnAccept()
assert(#addon.recorder.database.records == 0)
click("Start")
click("Clear")
assert(#addon.recorder.database.records == 1)
click("Stop")
assert(addon.recorder.database.records[1].sequence == 6)
addon.window.scripts.OnUpdate(addon.window, 0.6)
print("PASS TOC load order, lifecycle, slash commands, and debug UI controls (mocked)")