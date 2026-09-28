local frames, notices = {}, {}
local environment = setmetatable({}, { __index = _G })
environment._G = environment
local methods = {}
local object

for _, name in ipairs({
  "SetSize", "SetPoint", "SetClampedToScreen", "SetMovable", "EnableMouse", "RegisterForDrag",
  "StartMoving", "StopMovingOrSizing", "SetJustifyH", "SetAutoFocus", "SetMaxLetters",
  "ClearFocus", "SetMultiLine", "SetFontObject", "SetWidth", "SetCursorPosition",
  "UpdateScrollChildRect", "SetScrollChild", "SetNormalTexture", "SetHighlightTexture",
  "SetAllPoints", "SetJustifyV", "SetNumeric", "SetThickness", "SetColorTexture",
  "SetStartPoint", "SetEndPoint",
}) do
  methods[name] = function() end
end
function methods:SetEnabled(value) self.enabled = value end
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
function methods:CreateLine() return object() end

object = function()
  return setmetatable({ scripts = {}, events = {}, shown = true }, { __index = methods })
end
function methods:CreateFontString()
  local label = object()
  label.parent = self
  frames[#frames + 1] = label
  return label
end
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
environment.UIDropDownMenu_SetWidth = function() end
environment.UIDropDownMenu_SetText = function(frame, text) frame.text = text end
environment.UIDropDownMenu_Initialize = function(frame, callback) frame.initialize = callback end
environment.UIDropDownMenu_CreateInfo = function() return {} end
environment.UIDropDownMenu_AddButton = function() end
environment.date = os.date
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
local hooks = {}
environment.C_TradeSkillUI = {
  CraftRecipe = function() end,
  GetCraftingOperationInfo = function() return { concentrationCost = 81, baseSkill = 120 } end,
  GetItemReagentQualityByItemInfo = function() return 2 end,
}
environment.hooksecurefunc = function(_, name, callback) hooks[name] = callback end

local coreRoot = arg[1] or "src/ArtisanLogbook_Core"
local uiRoot = arg[2] or "src/ArtisanLogbook"
local function load(root, name)
  local namespace = {}
  for line in io.lines(root .. "/" .. name .. ".toc") do
    if line:match("%.lua$") then
      local chunk = assert(loadfile(root .. "/" .. line))
      setfenv(chunk, environment)
      chunk(name, namespace)
    end
  end
  return namespace
end
local addon = load(coreRoot, "ArtisanLogbook_Core")
local lifecycle = frames[1]
local api = environment.ArtisanLogbookAPI
assert(type(api) == "table")
assert(api.GetVersion() == 1)
local unavailable, reason = api.GetCrafts()
assert(unavailable == nil and reason == "not-ready")
local committed = {}
api.RegisterCallback("CRAFT_COMMITTED", function() error("consumer failure") end)
api.RegisterCallback("CRAFT_COMMITTED", function(craft) committed[#committed + 1] = craft end)
lifecycle.scripts.OnEvent(lifecycle, "ADDON_LOADED", "OtherAddon")
assert(addon.recorder == nil)
lifecycle.scripts.OnEvent(lifecycle, "ADDON_LOADED", "ArtisanLogbook_Core")
assert(addon.recorder and not addon.recorder.recording)
assert(environment.ArtisanLogbookTraceDB == addon.recorder.database)
assert(addon.ledger and environment.ArtisanLogbookDB == addon.ledger.database)
assert(addon.ledger.database.schemaVersion == addon.Ledger.schemaVersion)
assert(addon.ledger.database.schemaVersion == 1)
assert(addon.ledger.database.schemaIdentity == "ArtisanLogbookLedger")
assert(#addon.ledger.database.dimensions.sessions == 1)
assert(addon.ledger.database.dimensions.realms[1].key == "project:1:region:3:realm:12")
assert(addon.window and not addon.window:IsShown())
assert(not addon.productionWindow and not environment.SLASH_ARTISANLOGBOOK1)
assert(environment.SLASH_ARTISANLOGBOOKTRACE1 == "/al_trace")
environment.SlashCmdList.ARTISANLOGBOOKTRACE("")
assert(addon.window:IsShown())
addon.Start()
addon.Mark("basic craft")
assert(notices[#notices] == "Artisan Logbook: Marker: basic craft")
addon.adapter.frame.scripts.OnEvent(addon.adapter.frame, "TRADE_SKILL_CRAFT_BEGIN", 456)
addon.adapter.frame.scripts.OnEvent(addon.adapter.frame, "TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 1 })
assert(#addon.ledger.database.crafts == 1)
assert(addon.ledger.database.crafts[1].gameOperationId == 1)
assert(addon.ledger.database.crafts[1].recipeDimensionId ~= nil)
assert(#committed == 1 and committed[1].recipe.id == 456)
assert(api.GetCraft(1).recipe.id == 456 and api.GetCrafts().crafts[1].id == 1)
assert(api.GetCraftSeries().series[1].craftCount == 1)
assert(api.GetCraftSeries().series[1].recipe.id == 456)
assert(addon.ledger.database.retentionDays == 60)
local recipeFacets = api.GetFacets(nil, { facets = { "recipes" } })
assert(recipeFacets.recipes[1].value == 456 and recipeFacets.characters == nil)
assert(api.GetCapabilities().personalRequests == true)
assert(not addon.ledgerCaptureError and not addon.adapter.capabilities.captureError)
committed[1].recipe.id = 999
assert(api.GetCraft(1).recipe.id == 456)
addon.Stop()
assert(#addon.recorder.database.records == 5)
assert(addon.recorder.database.records[2].event == "TRACE_MARK")
assert(not addon.recorder.recording)
environment.SlashCmdList.ARTISANLOGBOOKTRACE("export")
assert(addon.window:IsShown())
environment.SlashCmdList.ARTISANLOGBOOKTRACE("status")
environment.SlashCmdList.ARTISANLOGBOOKTRACE("mark from slash")
environment.SlashCmdList.ARTISANLOGBOOKTRACE("stop")

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
environment.SlashCmdList.ARTISANLOGBOOKTRACE("start")
assert(addon.recorder.recording)
environment.SlashCmdList.ARTISANLOGBOOKTRACE("mark from slash")
assert(addon.recorder.database.records[#addon.recorder.database.records].event == "TRACE_MARK")
environment.SlashCmdList.ARTISANLOGBOOKTRACE("status")
assert(notices[#notices] == "Artisan Logbook: Recording.")
environment.SlashCmdList.ARTISANLOGBOOKTRACE("stop")
assert(not addon.recorder.recording)
print("PASS Core-only TOC, lifecycle, tracer slash commands and debug UI controls (mocked)")

local function reload(database)
  environment.ArtisanLogbookDB = database
  local frameStart = #frames
  local reloaded = load(coreRoot, "ArtisanLogbook_Core")
  local frame = frames[frameStart + 1]
  frame.scripts.OnEvent(frame, "ADDON_LOADED", "ArtisanLogbook_Core")
  return reloaded
end

local function loadUI()
  local frameStart = #frames
  local ui = load(uiRoot, "ArtisanLogbook")
  local frame = frames[frameStart + 1]
  frame.scripts.OnEvent(frame, "ADDON_LOADED", "ArtisanLogbook")
  return ui
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
for version = 0, 5 do
  local experimental = { schemaVersion = version, marker = "experimental" }
  local rejected = reload(experimental)
  assert(rejected.ledger == nil and environment.ArtisanLogbookDB == experimental)
  assert(experimental.schemaVersion == version and experimental.marker == "experimental")
  assert(rejected.ledgerError:find("unsupported", 1, true))
end
local missing, missingReason = environment.ArtisanLogbookAPI.GetCrafts()
assert(missing == nil and missingReason == "not-ready")
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
local batchPayloads = {}
environment.ArtisanLogbookAPI.RegisterCallback("CRAFT_COMMITTED", function(craft)
  batchPayloads[#batchPayloads + 1] = craft
end)
print("PASS passive ledger capture, reload, identity fallback, and SavedVariables failure safety")

hooks.GetCraftingOperationInfo(456, {
  { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 101 } },
}, nil, true)
hooks.CraftRecipe(456, 2, {}, nil, nil, true)
assert(not unknown.recorder.recording and #unknown.ledger.database.requests == 1)
unknown.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 1,
  concentrationSpent = 80, resourcesReturned = { { reagent = { itemID = 101 }, quantity = 1 } } })
unknown.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 2,
  concentrationSpent = 80, resourcesReturned = {} })
assert(#unknown.ledger.database.crafts == 2 and #unknown.ledger.database.reagents == 2)
assert(unknown.ledger.database.crafts[1].requestId == unknown.ledger.database.crafts[2].requestId)
assert(unknown.ledger.database.requests[1].concentrationCost == 81)
assert(unknown.ledger.database.reagents[1].allocatedQuantity == 2)
assert(unknown.ledger.database.reagents[1].quality == 2)
assert(unknown.ledger.database.reagents[1].returnedQuantity == 1)
assert(#batchPayloads == 2 and batchPayloads[1].request.id == batchPayloads[2].request.id)
assert(batchPayloads[1].reagents[1].item.id == 101 and batchPayloads[1].reagents[1].returnedQuantity == 1)
assert(batchPayloads[2].reagents[1].returnedQuantity == 0)
local daily = environment.ArtisanLogbookAPI.GetCraftSeries().series
assert(#daily == 1 and daily[1].craftCount == 2)
assert(daily[1].concentrationSpent == 160 and daily[1].concentrationSpentObservedCount == 2)
assert(batchPayloads[1].realm.identityScope == "session")
batchPayloads[1].request.allocations[1].allocatedQuantity = 999
assert(batchPayloads[2].request.allocations[1].allocatedQuantity == 2)
print("PASS passive personal request capture and shared batch allocation")

hooks.GetCraftingOperationInfo(456, {
  { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 101 } },
}, nil, true)
hooks.CraftRecipe(456, 3, {}, nil, nil, true)
local partialRequest = unknown.ledger.database.requests[2]
unknown.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 3, concentrationSpent = 80 })
unknown.HandleRetailEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-Unrelated", 999)
unknown.HandleRetailEvent("UNIT_SPELLCAST_FAILED_QUIET", "player", "Cast-Unrelated", 999)
unknown.HandleRetailEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "Cast-Unrelated", 999)
unknown.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 4, concentrationSpent = 80 })
assert(unknown.ledger.database.crafts[4].requestId == partialRequest.id)
unknown.HandleRetailEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-Queued", 456)
unknown.HandleRetailEvent("UPDATE_TRADESKILL_CAST_STOPPED", false)
assert(#unknown.ledger.database.crafts == 4 and unknown.ledger.pendingRequest ~= nil)
unknown.HandleRetailEvent("TRADE_SKILL_CLOSE")
assert(unknown.ledger.pendingRequest == nil and #unknown.ledger.database.crafts == 4)
assert(partialRequest.requestedCount == 3 and unknown.ledger.database.crafts[3].requestId == partialRequest.id)

local durableDatabase = unknown.ledger.database
unknown.Start()
unknown.Mark("stored")
assert(notices[#notices] == "Artisan Logbook: Marker: stored")
local capture = unknown.recorder.Capture
unknown.recorder.Capture = function() return nil, "capacity reached" end
unknown.Mark("not stored")
assert(notices[#notices] ~= "Artisan Logbook: Marker: not stored")
unknown.recorder.Capture = capture
unknown.Stop()
environment.StaticPopupDialogs.ARTISANLOGBOOK_CLEAR_TRACE.OnAccept()
assert(#unknown.recorder.database.records == 0)
assert(unknown.ledger.database == durableDatabase and #durableDatabase.crafts == 4)
print("PASS unrelated spell failures, partial batch, trace mark echo and clear isolation")

environment.GetCurrentRegion = function() return 3 end
environment.GetRealmID = function() return 12 end
environment.GetRealmName = function() return "TestRealm" end
environment.GetProfessions = function() return 1, 2 end
environment.GetProfessionInfo = function(index)
  return index == 1 and "Enchanting" or "Alchemy", nil, nil, nil, nil, nil,
    index == 1 and 333 or 171
end
local uiCore = reload(nil)
local uiLedger = uiCore.ledger
local savedAPI = environment.ArtisanLogbookAPI
environment.ArtisanLogbookAPI = nil
assert(not loadUI().productionWindow)
environment.ArtisanLogbookAPI = { GetVersion = function() return 2 end }
local incompatible = loadUI()
assert(not incompatible.productionWindow)
environment.ArtisanLogbookAPI = savedAPI
local savedManagement = environment.ArtisanLogbookManagement
environment.ArtisanLogbookManagement = nil
assert(not loadUI().productionWindow)
environment.ArtisanLogbookManagement = savedManagement
environment.ArtisanLogbookDB = nil
environment.ArtisanLogbookTraceDB = nil
local uiAddon = loadUI()
assert(not uiAddon.ledger and not uiAddon.recorder and not uiAddon.Ledger and not uiAddon.Trace)
local uiWindow = uiAddon.productionWindow
local getSeries = environment.ArtisanLogbookAPI.GetCraftSeries
environment.ArtisanLogbookAPI.GetCraftSeries = function(filter, options)
  assert(filter and filter.time and filter.time.from and filter.time.to,
    "UI series requests must be bounded")
  return getSeries(filter, options)
end
local currentKey = environment.ArtisanLogbookManagement.CurrentCharacter().key
local alchemy = assert(uiLedger:AddDimension("profession", "171", { skillLineId = 171, name = "Alchemy" }))
local enchanting = assert(uiLedger:AddDimension("profession", "333", { skillLineId = 333, name = "Enchanting" }))
assert(uiLedger:AddDimension("recipe", 501, { gameRecipeId = 501, name = "Zebra Brew",
  professionDimensionId = alchemy }))
assert(uiLedger:AddDimension("recipe", 502, { gameRecipeId = 502, name = "Apple Mix",
  professionDimensionId = enchanting }))
for index = 1, 12 do
  uiLedger:BeginCraft(501)
  assert(uiLedger:RecordResult({ operationID = index, quantity = 0, craftingQuality = 0,
    multicraft = 0, concentrationSpent = 0, hasIngenuityProc = false, ingenuityRefund = 9 }))
end
uiLedger:BeginCraft(502)
assert(uiLedger:RecordResult({ operationID = 13, quantity = 1 }))
assert(uiLedger:CreateSession({ startedAt = 1800000000, projectId = 1, regionId = 3,
  gameRealmId = 12, realmName = "TestRealm", characterName = "Other", characterGUID = "Player-Other" }))
uiLedger:BeginCraft(502)
assert(uiLedger:RecordResult({ operationID = 14 }))
assert(uiLedger:CreateSession({ startedAt = 1800000000, projectId = 1, regionId = 3,
  gameRealmId = 12, realmName = "TestRealm", characterName = "TestCrafter",
  characterGUID = "Player-1-123" }))

local function dropdown(parent, label)
  for _, frame in ipairs(frames) do
    if frame.parent == parent and frame.choices then
      for _, choice in ipairs(frame.choices) do
        if choice.label == label then return frame end
      end
    end
  end
  error("Missing dropdown choice: " .. label)
end
local function button(parent, title)
  for _, frame in ipairs(frames) do
    if frame.parent == parent and frame.kind == "Button" and frame.text == title then return frame end
  end
  error("Missing button: " .. title)
end
local function visibleText(part)
  for _, frame in ipairs(frames) do
    if type(frame.text) == "string" and frame.text:find(part, 1, true) then return frame.text end
  end
end
local function displayedRow(parent, predicate)
  for _, frame in ipairs(frames) do
    if frame.item and predicate(frame.item) then
      local ancestor = frame.parent
      while ancestor do
        if ancestor == parent then return frame end
        ancestor = ancestor.parent
      end
    end
  end
end

assert(not uiWindow:IsShown() and not uiCore.window:IsShown())
assert(environment.SLASH_ARTISANLOGBOOK2 == "/artisanlogbook")
environment.SlashCmdList.ARTISANLOGBOOK("anything")
assert(uiWindow:IsShown() and uiWindow.activeTab == "Overview" and not uiCore.window:IsShown())
uiWindow:Hide()
environment.SlashCmdList.ARTISANLOGBOOK("")
assert(uiWindow:IsShown())
local launcher
for _, frame in ipairs(frames) do if frame.name == "ArtisanLogbookButton" then launcher = frame end end
assert(launcher)
launcher.scripts.OnClick()
assert(not uiWindow:IsShown())
launcher.scripts.OnClick()
assert(uiWindow:IsShown())
local overview = uiWindow.pages.Overview
local chart
for _, frame in ipairs(frames) do
  if frame.parent == overview and frame.title then chart = frame end
end
assert(chart and chart.title.text:find("14 crafts", 1, true))
assert(visibleText("CRAFTS IN RANGE\n14\nWoW"))
local otherKey
for _, choice in ipairs(dropdown(overview, "Other").choices) do
  if choice.label == "Other" then otherKey = choice.value end
end
assert(otherKey)
dropdown(overview, "Alchemy"):Choose(171)
dropdown(overview, "Other"):Choose(otherKey)
local overviewProfessions = dropdown(overview, "Enchanting")
assert(overviewProfessions.value == false and overviewProfessions.text == "All")
assert(chart.title.text:find("1 crafts", 1, true))
dropdown(overview, "All"):Choose(false)
dropdown(overview, "Enchanting"):Choose(333)
assert(chart.title.text:find("2 crafts", 1, true))
dropdown(overview, "Other"):Choose(otherKey)
assert(dropdown(overview, "Enchanting").value == 333)
assert(chart.title.text:find("1 crafts", 1, true))
dropdown(overview, "90 days"):Choose(90)
assert(chart.title.text:find("1 crafts", 1, true))
uiWindow:Hide()
environment.SlashCmdList.ARTISANLOGBOOK("anything")
assert(uiWindow:IsShown() and not uiCore.window:IsShown())
environment.SlashCmdList.ARTISANLOGBOOK("debug")
assert(not uiCore.window:IsShown() and uiWindow:IsShown())
environment.SlashCmdList.ARTISANLOGBOOKTRACE("")
assert(uiCore.window:IsShown())
uiCore.window:Hide()
button(uiWindow, "Recent").scripts.OnClick()
assert(uiWindow.activeTab == "Recent")
local recent = uiWindow.pages.Recent
local recentArea
for _, frame in ipairs(frames) do if frame.parent == recent and frame.kind == "Frame" then recentArea = frame end end
local recentFirst = displayedRow(recentArea, function(item) return item.id == 14 end)
assert(recentFirst)
recentFirst.scripts.OnClick(recentFirst)
assert(uiWindow.openCraftId == 14 and uiWindow.visiblePage ~= recent)
local sharedDetail = uiWindow.visiblePage
assert(visibleText("Ingenuity proc: Unknown"))
uiWindow:Activate("Recent")
local nextButton
for _, frame in ipairs(frames) do
  if frame.parent and frame.parent.parent == recentArea and frame.text == ">" then nextButton = frame end
end
assert(nextButton and nextButton.enabled)
nextButton.scripts.OnClick()
assert(displayedRow(recentArea, function(item) return item.id == 4 end))
dropdown(recent, "Alchemy"):Choose(171)
dropdown(recent, "Other"):Choose(otherKey)
local recentProfessions = dropdown(recent, "Enchanting")
assert(recentProfessions.value == false and recentProfessions.text == "All")
assert(displayedRow(recentArea, function(item) return item.id == 14 end))
recentProfessions:Choose(333)
dropdown(recent, "All"):Choose(false)
assert(recentProfessions.value == 333 and displayedRow(recentArea, function(item) return item.id == 13 end))
uiWindow:Activate("Character")
local character = uiWindow.pages.Character
assert(dropdown(character, "TestCrafter").value == currentKey)
dropdown(character, "Other"):Choose(otherKey)
assert(dropdown(character, "Other").text == "Other")
local characterArea
for _, frame in ipairs(frames) do if frame.parent == character and frame.kind == "Frame" then characterArea = frame end end
assert(displayedRow(characterArea, function(item) return item.id == 14 end))
uiWindow:Activate("Profession")
local profession = uiWindow.pages.Profession
assert(dropdown(profession, "Enchanting").value == 333)
dropdown(profession, "Alchemy"):Choose(171)
assert(dropdown(profession, "Alchemy").value == 171)
local professionArea
for _, frame in ipairs(frames) do if frame.parent == profession and frame.kind == "Frame" then professionArea = frame end end
assert(displayedRow(professionArea, function(item) return item.id == 12 end))
dropdown(profession, "Other"):Choose(dropdown(character, "Other").value)
assert(dropdown(profession, "Enchanting").value == 333)
assert(displayedRow(professionArea, function(item) return item.id == 14 end))
dropdown(profession, "TestCrafter"):Choose(currentKey)
assert(dropdown(profession, "Enchanting").value == 333)
assert(displayedRow(professionArea, function(item) return item.id == 13 end))
uiWindow:Activate("Recipes")
local recipes = uiWindow.pages.Recipes
local catalogue
for _, frame in ipairs(frames) do if frame.parent == recipes and frame.rows then catalogue = frame end end
assert(catalogue and catalogue.rows[1].item.recipe.name == "Apple Mix")
local apple = displayedRow(recipes, function(item) return item.recipe and item.recipe.id == 502 end)
assert(apple and apple.item.craftCount == 2)
assert(displayedRow(recipes, function(item) return item.recipe and item.recipe.id == 501 end).item.craftCount == 12)
apple.scripts.OnClick(apple)
local recipePage = uiWindow.visiblePage
assert(recipePage ~= recipes and visibleText("Apple Mix  |  Enchanting"))
local recipeArea
for _, frame in ipairs(frames) do if frame.parent == recipePage and frame.kind == "Frame" then recipeArea = frame end end
local recipeCraft = displayedRow(recipeArea, function(item) return item.id == 13 end)
assert(recipeCraft)
recipeCraft.scripts.OnClick(recipeCraft)
assert(uiWindow.visiblePage == sharedDetail and uiWindow.returnPage == recipePage and uiWindow.openCraftId == 13)
uiWindow:Activate("Character")
dropdown(character, "TestCrafter"):Choose(currentKey)
local characterCraft = displayedRow(characterArea, function(item) return item.id == 12 end)
assert(characterCraft)
characterCraft.scripts.OnClick(characterCraft)
assert(uiWindow.visiblePage == sharedDetail)
uiWindow:OpenCraft(1)
assert(visibleText("Ingenuity proc: No"))
assert(visibleText("Net concentration: 0"))
assert(visibleText("Reported Ingenuity refund: 9"))
uiWindow:Activate("Recent")
dropdown(recent, "All"):Choose(false)
uiLedger:BeginCraft(502)
assert(uiLedger:RecordResult({ operationID = 15 }))
assert(displayedRow(recentArea, function(item) return item.id == 15 end))
uiLedger.wall = function() return 1800000000 - 8 * 86400 end
uiLedger:BeginCraft(501)
assert(uiLedger:RecordResult({ operationID = 16 }))
uiLedger.wall = environment.GetServerTime
uiWindow:Activate("Overview")
dropdown(overview, "All"):Choose(false)
local professionFilter = dropdown(overview, "Enchanting")
professionFilter:Choose(false)
dropdown(overview, "30 days"):Choose(30)
assert(chart.title.text:find("16 crafts", 1, true))
assert(visibleText("CRAFTS IN RANGE\n16\nWoW -1"))
uiLedger.wall = function() return 1800000000 - 40 * 86400 end
uiLedger:BeginCraft(502)
assert(uiLedger:RecordResult({ operationID = 17 }))
uiLedger.wall = environment.GetServerTime
assert(chart.title.text:find("16 crafts", 1, true))
assert(visibleText("CRAFTS IN RANGE\n16\nWoW -1"))
dropdown(overview, "90 days"):Choose(90)
assert(chart.title.text:find("17 crafts", 1, true))
assert(visibleText("CRAFTS IN RANGE\n17\nWoW -1"))
dropdown(overview, "30 days"):Choose(30)
uiWindow:Activate("Settings")
local settings = uiWindow.pages.Settings
local retentionInput
for _, frame in ipairs(frames) do
  if frame.parent == settings and frame.kind == "EditBox" then retentionInput = frame end
end
assert(retentionInput and retentionInput.text == "60" and visibleText("Portable export is not yet defined"))
retentionInput:SetText("1")
button(settings, "Save").scripts.OnClick()
assert(uiLedger.database.retentionDays == 1)
button(settings, "Prune now").scripts.OnClick()
assert(#uiLedger.database.crafts == 15)
assert(#uiLedger.database.craftSeries == 5)
button(settings, "Clear history").scripts.OnClick()
assert(environment.popup == "ARTISANLOGBOOK_CLEAR_HISTORY" and #uiLedger.database.crafts == 15)
environment.StaticPopupDialogs.ARTISANLOGBOOK_CLEAR_HISTORY.OnAccept()
assert(#uiLedger.database.crafts == 0 and #uiLedger.database.craftSeries == 0)
uiWindow:Activate("Overview")
assert(chart.title.text:find("0 crafts", 1, true))
assert(visibleText("CONCENTRATION IN RANGE\nSpent Unknown\nNet Unknown"))
uiWindow:Activate("Recipes")
assert(not displayedRow(recipes, function() return true end))
uiWindow:Activate("Recent")
assert(not displayedRow(recentArea, function() return true end))
uiWindow:Activate("Character")
assert(not displayedRow(characterArea, function() return true end))
uiWindow:Activate("Profession")
assert(not displayedRow(professionArea, function() return true end))
print("PASS production navigation, filters, paging, detail reuse, live refresh and data management (mocked)")

local invalidTrace = { traceSchemaVersion = 999 }
environment.ArtisanLogbookTraceDB = invalidTrace
local noTracer = reload(nil)
assert(noTracer.ledger and noTracer.recorder == nil and not noTracer.productionWindow)
local noTracerUI = loadUI()
environment.SlashCmdList.ARTISANLOGBOOK("")
assert(noTracerUI.productionWindow:IsShown() and environment.ArtisanLogbookTraceDB == invalidTrace)
print("PASS production UI remains available when diagnostic trace storage is refused")
