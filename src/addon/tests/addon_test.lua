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
function methods:SetHeight(value) self.height = value end
function methods:GetText() return self.text or "" end
function methods:GetWidth() return 1024 end
function methods:GetHeight() return self.height or (self.kind == "ScrollFrame" and 300 or 768) end
function methods:GetStringHeight()
  local _, lineCount = (self.text or ""):gsub("\n", "")
  return math.max(14, (lineCount + 1) * 14)
end
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
environment.GetRealmID = function() return 12 end
environment.GetCurrentRegion = function() return 3 end
environment.C_AddOns = { GetAddOnMetadata = function() return "0.1.0-tracer" end }
environment.WOW_PROJECT_ID = 1
environment.WOW_PROJECT_MAINLINE = 1

local root = arg[1] or "src/ArtisanLogbook"
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
assert(addon.ledger and environment.ArtisanLogbookDB == addon.ledger.database)
assert(addon.ledger.database.schemaVersion == addon.Ledger.schemaVersion)
assert(#addon.ledger.database.dimensions.sessions == 1)
assert(addon.ledger.database.dimensions.realms[1].key == "project:1:region:3:realm:12")
assert(addon.window and not addon.window:IsShown())
environment.SlashCmdList.ARTISANLOGBOOK("")
assert(addon.window:IsShown())
environment.SlashCmdList.ARTISANLOGBOOK("start")
environment.SlashCmdList.ARTISANLOGBOOK("mark basic craft")
addon.adapter.frame.scripts.OnEvent(addon.adapter.frame, "TRADE_SKILL_CRAFT_BEGIN", 456)
addon.adapter.frame.scripts.OnEvent(addon.adapter.frame, "TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 1 })
assert(#addon.ledger.database.crafts == 1)
assert(addon.ledger.database.crafts[1].gameOperationId == 1)
assert(addon.ledger.database.crafts[1].recipeDimensionId ~= nil)
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
assert(#addon.ledger.database.crafts == 1)
local textEditBox, scrollFrame
for _, frame in ipairs(frames) do
  if frame.kind == "EditBox" and frame.parent and frame.parent.kind == "ScrollFrame" then textEditBox = frame end
  if frame.kind == "ScrollFrame" then scrollFrame = frame end
end
assert(textEditBox and scrollFrame)
textEditBox:SetText("short export")
textEditBox.scripts.OnTextChanged()
assert(textEditBox.height == scrollFrame:GetHeight())
textEditBox:SetText(string.rep("long line\n", 100))
textEditBox.scripts.OnTextChanged()
assert(textEditBox.height > scrollFrame:GetHeight())
click("Start")
click("Clear")
assert(#addon.recorder.database.records == 1)
click("Stop")
assert(addon.recorder.database.records[1].sequence == 6)
addon.window.scripts.OnUpdate(addon.window, 0.6)
print("PASS TOC load order, lifecycle, slash commands, and debug UI controls (mocked)")

local function reload(database)
  environment.ArtisanLogbookDB = database
  local reloaded = {}
  local frameStart = #frames
  for line in io.lines(root .. "/ArtisanLogbook.toc") do
    if line:match("%.lua$") then
      local chunk = assert(loadfile(root .. "/" .. line))
      setfenv(chunk, environment)
      chunk("ArtisanLogbook", reloaded)
    end
  end
  local frame = frames[frameStart + 1]
  frame.scripts.OnEvent(frame, "ADDON_LOADED", "ArtisanLogbook")
  return reloaded
end

local saved = addon.ledger.database
local reloaded = reload(saved)
assert(reloaded.ledger and not reloaded.recorder.recording)
assert(#reloaded.ledger.database.dimensions.sessions == 2)
assert(#reloaded.ledger.database.dimensions.realms == 1)
assert(#reloaded.ledger.database.dimensions.characters == 1)
reloaded.HandleRetailEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Test", 999)
reloaded.HandleRetailEvent("CRAFTING_DETAILS_UPDATE")
assert(#reloaded.ledger.database.crafts == 1)
reloaded.HandleRetailEvent("TRADE_SKILL_CRAFT_BEGIN", 456)
reloaded.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 1, quantity = 1 })
assert(#reloaded.ledger.database.crafts == 2 and reloaded.ledger.database.crafts[2].id == 2)
assert(#saved.crafts == 1)

local invalid = { schemaVersion = 999, marker = "preserved" }
assert(reload(invalid).ledger == nil and environment.ArtisanLogbookDB == invalid)
assert(invalid.marker == "preserved")
local conflicting = reloaded.ledger.database
environment.GetRealmName = function() return "Conflicting Display Name" end
local refused = reload(conflicting)
assert(refused.ledger == nil and refused.ledgerError:find("conflicting", 1, true))
assert(environment.ArtisanLogbookDB == conflicting and #conflicting.dimensions.sessions == 2)

environment.GetCurrentRegion = function() error("unavailable") end
environment.GetRealmID = nil
local unknown = reload(nil)
assert(unknown.ledger)
local realm = unknown.ledger.database.dimensions.realms[1]
assert(realm.regionId == nil and realm.gameRealmId == nil and realm.identityScope == "session")
print("PASS passive ledger capture, reload, identity fallback, and SavedVariables failure safety")
