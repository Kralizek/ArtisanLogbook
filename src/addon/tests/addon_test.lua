local frames, notices = {}, {}
local function rowCount(rows)
  local count = 0
  for _ in pairs(rows) do count = count + 1 end
  return count
end
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
  "SetStartPoint", "SetEndPoint", "SetWordWrap", "SetMaxLines",
  "SetFrameStrata", "RegisterForClicks", "ClearAllPoints", "SetTexture", "SetTexCoord",
  "LockHighlight", "UnlockHighlight", "SetToplevel", "Raise", "SetAtlas",
  "SetTextColor", "AddMaskTexture", "SetScale", "SetShadowOffset", "SetBlendMode",
  "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor",
  "SetPropagateMouseClicks",
}) do
  methods[name] = function() end
end
function methods:SetSize(width, height) self.width, self.height = width, height end
function methods:SetWidth(width) self.width = width end
function methods:SetTexture(texture) self.texture = texture end
function methods:SetAtlas(atlas) self.atlas = atlas end
function methods:SetAllPoints(relative) self.allPoints = relative or self.parent end
function methods:SetColorTexture(...) self.color = { ... } end
function methods:SetAlpha(alpha) self.alpha = alpha end
function methods:SetTextColor(...) self.textColor = { ... } end
function methods:SetPoint(point, relative, relativePoint, x, y)
  if type(relative) == "number" then
    x, y, relative, relativePoint = relative, relativePoint, nil, nil
  end
  self.point, self.relative, self.relativePoint = point, relative, relativePoint
  self.x, self.y = x, y
  self.anchors = self.anchors or {}
  self.anchors[point] = { relative = relative, relativePoint = relativePoint, x = x, y = y }
end
function methods:ClearAllPoints() self.anchors = {} end
function methods:SetEnabled(value) self.enabled = value end
function methods:SetChecked(value) self.checked = value end
function methods:GetChecked() return self.checked end
function methods:SetText(value) assert(type(value) == "string"); self.text = value end
function methods:SetHeight(value) self.height = value end
function methods:GetText() return self.text or "" end
function methods:GetParent() return self.parent end
function methods:GetScript(name) return self.scripts[name] end
function methods:GetWidth() return self.width or 1024 end
function methods:GetHeight() return self.height or (self.kind == "ScrollFrame" and 300 or 768) end
function methods:GetCenter() return 500, 500 end
function methods:GetEffectiveScale() return 1 end
function methods:GetNormalTexture() return object() end
function methods:GetStringHeight()
  local _, lineCount = (self.text or ""):gsub("\n", "")
  return math.max(14, (lineCount + 1) * 14)
end
function methods:SetScript(name, callback) self.scripts[name] = callback end
function methods:HookScript(name, callback) self.scripts[name] = callback end
function methods:RegisterEvent(event) self.events[event] = true end
function methods:UnregisterEvent(event) self.events[event] = nil end
function methods:RegisterUnitEvent(event, unit) assert(unit == "player"); self:RegisterEvent(event) end
function methods:IsEventRegistered(event) return self.events[event] or false end
function methods:Hide()
  local shown = self.shown
  self.shown = false
  if shown and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function methods:SetShown(value) self.shown = value end
function methods:Show()
  self.shown = true
  if self.scripts.OnShow then self.scripts.OnShow(self) end
end
function methods:IsShown() return self.shown end
function methods:SetVerticalScroll(offset) self.offset = offset end
function methods:GetVerticalScroll() return self.offset or 0 end
function methods:CreateLine() return object() end
function methods:CreateTexture()
  local texture = object()
  texture.parent = self
  frames[#frames + 1] = texture
  return texture
end
function methods:CreateMaskTexture() return object() end

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
  frame.kind, frame.name, frame.parent, frame.template = kind, name, parent, template
  if template == "BasicFrameTemplateWithInset" then frame.TitleText = object() end
  if template == "TabSystemButtonArtTemplate" then
    frame.Text = object()
    frame.HandleRotation = function(self) self.rotated = self.isTabOnTop end
    frame.SetTabSelected = function(self, selected) self.isSelected = selected end
  end
  frames[#frames + 1] = frame
  return frame
end
environment.UIParent = object()
environment.Minimap = object()
environment.Minimap:SetSize(140, 140)
environment.GetCursorPosition = function() return 600, 500 end
environment.ChatFontNormal = {}
environment.UISpecialFrames = {}
environment.StaticPopupDialogs = {}
environment.SlashCmdList = {}
environment.tinsert = table.insert
environment.StaticPopup_Show = function(name) environment.popup = name end
environment.UIDropDownMenu_SetWidth = function(frame, width)
  frame.middleWidth = width
  frame:SetWidth(width + 50)
end
environment.UIDropDownMenu_JustifyText = function(frame, alignment) frame.textAlignment = alignment end
environment.UIDropDownMenu_SetText = function(frame, text) frame.text = text end
environment.UIDropDownMenu_Initialize = function(frame, callback) frame.initialize = callback end
environment.UIDropDownMenu_CreateInfo = function() return {} end
environment.UIDropDownMenu_AddButton = function() end
environment.GameTooltip = { SetOwner = function() end,
  SetText = function(self, text) self.text, self.lines = text, {} end,
  SetItemByID = function(self, itemId) self.itemId, self.lines = itemId, {} end,
  AddLine = function(self, text) self.lines[#self.lines + 1] = text end,
  Show = function() end, Hide = function() end }
environment.date = os.date
environment.DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) notices[#notices + 1] = message end }
environment.GetServerTime = function() return 1800000000 end
environment.GetTimePreciseSec = function() return 100.5 end
environment.GetBuildInfo = function() return "12.1.0", "69933", "mock", 120100 end
environment.GetLocale = function() return "enUS" end
environment.UnitName = function() return "TestCrafter" end
environment.UnitGUID = function() return "Player-1-123" end
environment.UnitClass = function() return nil, "MAGE", 8 end
environment.GetRealmName = function() return "TestRealm" end
environment.GetRealmID = function() return 12 end
environment.GetCurrentRegion = function() return 3 end
environment.C_AddOns = { GetAddOnMetadata = function() return "0.1.0-tracer" end }
environment.RAID_CLASS_COLORS = { MAGE = { r = .2, g = .5, b = 1, colorStr = "ff3399ff" } }
environment.GetItemIcon = function() return "Interface\\Icons\\INV_Misc_Gem_01" end
environment.WOW_PROJECT_ID = 1
environment.WOW_PROJECT_MAINLINE = 1
local hooks = {}
environment.C_TradeSkillUI = {
  CraftRecipe = function() end,
  GetCraftingOperationInfo = function() return { concentrationCost = 81, baseSkill = 120 } end,
  GetItemReagentQualityByItemInfo = function() return 2 end,
  GetRecipeItemQualityInfo = function(recipeID, quality)
    if recipeID == 42 then return { icon = "Quality-" .. quality } end
    if recipeID == 99 then error("quality data unavailable") end
  end,
}
environment.hooksecurefunc = function(_, name, callback) hooks[name] = callback end

local coreRoot = arg[1] or "src/ArtisanLogbook_Core"
local uiRoot = arg[2] or "src/ArtisanLogbook"
local function load(root, name, afterFile)
  local namespace = {}
  for line in io.lines(root .. "/" .. name .. ".toc") do
    if line:match("%.lua$") then
      local chunk = assert(loadfile(root .. "/" .. line))
      setfenv(chunk, environment)
      chunk(name, namespace)
      if afterFile then afterFile(line, namespace) end
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
assert(addon.ledger.database.dimensions.characters[1].classFile == "MAGE")
assert(api.GetCharacters()[1] == nil)
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
assert(addon.ledger.database.crafts[1].recipeId == 456)
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
click("Clear Trace")
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
local savedRecords = addon.recorder.database.records
local exportRecords = {}
for index = 1, 25 do
  exportRecords[index] = { sequence = index, timestamp = 1800000000, elapsed = index,
    event = "TRACE_MARK", payload = "{}" }
end
addon.recorder.database.records = exportRecords
local function displayedExport()
  return assert(loadstring(textEditBox:GetText()))()
end
environment.SlashCmdList.ARTISANLOGBOOKTRACE("export")
assert(#displayedExport().records == 25 and displayedExport().totalRecords == 25)
click(">")
assert(#displayedExport().records == 10 and displayedExport().records[1].sequence == 1)
click(">")
assert(#displayedExport().records == 10 and displayedExport().records[1].sequence == 11)
click(">")
assert(#displayedExport().records == 5 and displayedExport().records[1].sequence == 21)
click("Export")
assert(#displayedExport().records == 25 and displayedExport().records[25].sequence == 25)
addon.recorder.database.records = savedRecords
click("Export")
assert(#displayedExport().records == 0)
print("PASS complete trace export and optional paged fallback")
textEditBox:SetText("short export")
textEditBox.scripts.OnTextChanged()
assert(textEditBox.height == scrollFrame:GetHeight())
textEditBox:SetText(string.rep("long line\n", 100))
textEditBox.scripts.OnTextChanged()
assert(textEditBox.height > scrollFrame:GetHeight())
click("Start")
click("Clear Trace")
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

local function reload(database, afterFile)
  environment.ArtisanLogbookDB = database
  local frameStart = #frames
  local reloaded = load(coreRoot, "ArtisanLogbook_Core", afterFile)
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

local maintenance = reload(nil)
maintenance.HandleRetailEvent("TRADE_SKILL_CRAFT_BEGIN", 9901)
maintenance.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 1, itemID = 9902 })
maintenance.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 2, itemID = 9902 })
local maintenanceDatabase = maintenance.ledger.database
local repairButton
for _, frame in ipairs(frames) do
  if frame.parent == maintenance.window and frame.kind == "Button" and
      frame.text == "Repair unknown recipes" then repairButton = frame end
end
assert(repairButton and maintenance.ledger.database.crafts[2].recipeId == nil)
repairButton.scripts.OnClick(repairButton)
assert(environment.popup == "ARTISANLOGBOOK_REPAIR_UNKNOWN_RECIPES")
assert(maintenance.ledger.database == maintenanceDatabase and
  maintenance.ledger.database.crafts[2].recipeId == nil)
local repairDialog = environment.StaticPopupDialogs.ARTISANLOGBOOK_REPAIR_UNKNOWN_RECIPES
assert(repairDialog.text:find("1 can be uniquely attributed", 1, true))
assert(repairDialog.button1 == "Repair 1 crafts")
repairDialog.OnAccept()
assert(maintenance.ledger.database ~= maintenanceDatabase)
assert(environment.ArtisanLogbookDB == maintenance.ledger.database)
assert(maintenance.ledger.database.crafts[2].recipeId == 9901)
assert(maintenance.lastMaintenanceDiagnostic:find("success=true", 1, true))
assert(notices[#notices]:find("Repaired 1 crafts and reconciled affected aggregates. 0 ambiguous and 0 without sufficient evidence remain.", 1, true))
maintenance.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 3, itemID = 9903 })
maintenanceDatabase = maintenance.ledger.database
environment.popup = nil
repairButton.scripts.OnClick(repairButton)
assert(environment.popup == nil and maintenance.ledger.database == maintenanceDatabase)
print("PASS confirmed offline recipe repair preview and no-evidence no-write flow")

local function startupDatabase(knownOutput, unknownOutputs, competingRecipe)
  local source = assert(maintenance.Ledger.New(nil, { wall = function() return 1800000000 end }))
  assert(source:CreateSession({ startedAt = 1800000000, characterName = "Startup Crafter",
    realmName = "Startup Realm", capabilities = {} }))
  local operationId = 1
  if knownOutput then
    source:BeginCraft(9910)
    assert(source:RecordResult({ operationID = operationId, itemID = knownOutput, quantity = 2 }))
    operationId = operationId + 1
  end
  if competingRecipe then
    source:BeginCraft(competingRecipe)
    assert(source:RecordResult({ operationID = operationId, itemID = knownOutput, quantity = 1 }))
    operationId = operationId + 1
  end
  for _, output in ipairs(unknownOutputs) do
    source:BeginCraft(nil)
    assert(source:RecordResult({ operationID = operationId, itemID = output, quantity = 3 }))
    operationId = operationId + 1
  end
  return source.database
end

local automaticDatabase = startupDatabase(9920, { 9920, 9921 })
automaticDatabase.recipeOutputs = nil
local noticesBeforeAutomatic = #notices
local automatic = reload(automaticDatabase)
assert(automatic.ledger and automatic.ledger.unknownRecipeCount == 1)
assert(automatic.ledger.craftById[2].recipeId == 9910 and
  automatic.ledger.craftById[3].recipeId == nil)
assert(#automatic.ledger.craftIdsByRecipe[9910] == 2 and automatic.ledger.recipeCounts[9910] == 2)
assert(environment.ArtisanLogbookDB == automatic.ledger.database and
  environment.ArtisanLogbookDB ~= automaticDatabase)
assert(automatic.lastMaintenanceDiagnostic:find("automatic unknown=2 repairable=1 repaired=1", 1, true))
assert(automatic.lastRecipeOutputDiagnostic:find("bootstrap learned=1 existing=0 total=1", 1, true))
for index = noticesBeforeAutomatic + 1, #notices do
  assert(notices[index]:find("Automatically repaired", 1, true) == nil)
end
local automaticSeries = automatic.ledger.database.craftSeries
local repairedSeriesCount, unknownSeriesCount = 0, 0
for _, row in ipairs(automaticSeries) do
  if row.recipeId == 9910 then repairedSeriesCount = row.craftCount end
  if row.recipeId == nil then unknownSeriesCount = row.craftCount end
end
assert(repairedSeriesCount == 2 and unknownSeriesCount == 1)
assert(environment.ArtisanLogbookAPI.GetCraft(2).recipe.id == 9910)
print("PASS Core startup repairs unique historical evidence and rebuilds runtime indexes")

local ambiguousDatabase = startupDatabase(9925, { 9925, 9926 }, 9912)
local ambiguousStartup = reload(ambiguousDatabase)
assert(ambiguousStartup.ledger and ambiguousStartup.ledger.unknownRecipeCount == 2)
assert(ambiguousStartup.ledger.craftById[3].recipeId == nil and
  ambiguousStartup.ledger.craftById[4].recipeId == nil)
assert(ambiguousStartup.lastMaintenanceDiagnostic:find("ambiguous=1 insufficient=1", 1, true))
print("PASS Core startup leaves ambiguous and unsupported crafts Unknown")

local noUnknownDatabase = startupDatabase(9922, {})
local noOpDatabaseAtMaintenance
local noUnknown = reload(noUnknownDatabase, function(file, namespace)
  if file == "Core/Management.lua" then
    local automaticRepair = environment.ArtisanLogbookManagement.AutomaticRepairUnknownRecipes
    environment.ArtisanLogbookManagement.AutomaticRepairUnknownRecipes = function()
      noOpDatabaseAtMaintenance = namespace.ledger.database
      return automaticRepair()
    end
  end
end)
assert(noUnknown.ledger.unknownRecipeCount == 0)
assert(noUnknown.ledger.database == noOpDatabaseAtMaintenance)
assert(environment.ArtisanLogbookDB == noUnknown.ledger.database)
print("PASS Core startup skips repair without retained Unknown crafts")

local unsupportedDatabase = startupDatabase(nil, { 9923 })
local unsupportedOriginalCraft = unsupportedDatabase.crafts[1]
local unsupportedAtMaintenance
local unsupported = reload(unsupportedDatabase, function(file, namespace)
  if file == "Core/Management.lua" then
    local automaticRepair = environment.ArtisanLogbookManagement.AutomaticRepairUnknownRecipes
    environment.ArtisanLogbookManagement.AutomaticRepairUnknownRecipes = function()
      unsupportedAtMaintenance = namespace.ledger.database
      return automaticRepair()
    end
  end
end)
assert(unsupported.ledger and unsupported.ledger.unknownRecipeCount == 1)
assert(unsupported.ledger.database == unsupportedAtMaintenance)
assert(environment.ArtisanLogbookDB == unsupported.ledger.database)
assert(unsupported.ledger.database.crafts[1].recipeId == nil and
  unsupportedOriginalCraft.recipeId == nil)
assert(unsupported.lastMaintenanceDiagnostic:find("automatic unknown=1 repairable=0", 1, true))
unsupported.ledger:BeginCraft(9911)
assert(unsupported.ledger:RecordResult({ operationID = 2, itemID = 9923, quantity = 1 }))
assert(unsupported.ledger.unknownRecipeCount == 0)
assert(unsupported.ledger.craftById[1].recipeId == 9911)
assert(unsupported.lastRecipeOutputDiagnostic:find("targeted-repair", 1, true) == nil)
assert(unsupported.lastMaintenanceDiagnostic:find("targeted unknown=1 repairable=1 repaired=1", 1, true))
local improved = reload(unsupported.ledger.database)
assert(improved.ledger.unknownRecipeCount == 0 and improved.ledger.craftById[1].recipeId == 9911)
assert(environment.ArtisanLogbookDB == improved.ledger.database)
print("PASS startup leaves unsupported Unknowns and repairs them after evidence improves")

local failureDatabase = startupDatabase(9924, { 9924 })
local failureDatabaseAtRepair
local failingAutomatic = reload(failureDatabase, function(file, namespace)
  if file == "Storage/Ledger.lua" then
    namespace.Ledger.RepairUnknownRecipes = function(ledger)
      failureDatabaseAtRepair = ledger.database
      error("injected automatic repair failure")
    end
  end
end)
assert(failingAutomatic.ledger and failingAutomatic.ledger.unknownRecipeCount == 1)
assert(failingAutomatic.ledger.database == failureDatabaseAtRepair and
  environment.ArtisanLogbookDB == failureDatabaseAtRepair)
assert(failingAutomatic.ledger.database.crafts[2].recipeId == nil)
assert(failingAutomatic.lastMaintenanceDiagnostic:find("automatic success=false error=", 1, true))
assert(failingAutomatic.recorder)
print("PASS automatic repair failure leaves Core and original loaded ledger available")

do
  local previousSchematic = environment.C_TradeSkillUI.GetRecipeSchematic
  local previousQualities = environment.C_TradeSkillUI.GetRecipeQualityItemIDs
  local previousIds = environment.C_TradeSkillUI.GetAllRecipeIDs
  local previousReady = environment.C_TradeSkillUI.IsTradeSkillReady
  local previousChanging = environment.C_TradeSkillUI.IsDataSourceChanging
  local previousInfo = environment.C_TradeSkillUI.GetRecipeInfo
  local function candidateDatabase(recipes, outputs)
    local database = startupDatabase(nil, outputs or { 243807 })
    local name = "Gleeful Glamour - Lightforged Draenei"
    for _, item in pairs(database.dimensions.items) do item.name = name end
    local source = assert(maintenance.Ledger.New(database))
    for _, recipeId in ipairs(recipes or { 1236472 }) do
      source:AddDimension("recipe", recipeId, { name = name })
    end
    return source.database
  end
  local queries = 0
  environment.C_TradeSkillUI.GetRecipeSchematic = function(recipeId, isRecraft)
    queries = queries + 1
    assert(recipeId == 1236472 and isRecraft == false)
    return nil
  end
  local noticeCount = #notices
  local unavailableCore = reload(candidateDatabase())
  assert(unavailableCore.ledger.unknownRecipeCount == 1)
  assert(unavailableCore.ledger.recipeOutputCount == 0)
  assert(queries == 1 and #notices == noticeCount)
  assert(environment.ArtisanLogbookAPI.GetCraft(1).recipe == nil)

  environment.C_TradeSkillUI.GetRecipeSchematic = function(recipeId, isRecraft)
    queries = queries + 1
    assert(recipeId == 1236472 and isRecraft == false)
    return { recipeID = recipeId, outputItemID = 243807 }
  end
  local confirmed = reload(candidateDatabase())
  assert(queries == 2 and #notices == noticeCount)
  assert(confirmed.ledger.unknownRecipeCount == 0)
  assert(confirmed.ledger.database.recipeOutputs[1236472][243807])
  assert(confirmed.ledger.craftById[1].recipeId == 1236472)
  assert(confirmed.ledger.craftById[1].requestId == nil)
  assert(confirmed.ledger.database.schemaVersion == 1)
  local reloadedKnowledge = reload(confirmed.ledger.database)
  assert(queries == 2 and reloadedKnowledge.ledger.database.recipeOutputs[1236472][243807])
  print("PASS candidate confirmation, silence, schema v1 and durable reload")

  queries = 0
  environment.C_TradeSkillUI.GetRecipeSchematic = function(recipeId)
    queries = queries + 1
    return { recipeID = recipeId, outputItemID = 999999 }
  end
  local disproved = reload(candidateDatabase())
  assert(disproved.ledger.unknownRecipeCount == 1 and disproved.ledger.recipeOutputCount == 0)
  assert(disproved.lastRecoverySummary.unconfirmedCount == 1)
  assert(disproved.ledger.dimensionRows.item[999999] == nil)
  local noCandidate = reload(candidateDatabase({}))
  local differentName = candidateDatabase()
  differentName.dimensions.recipes[1236472].name = "gleeful glamour - lightforged draenei"
  reload(differentName)
  local knownMapping = candidateDatabase()
  knownMapping.recipeOutputs[1236472] = { [243807] = true }
  local known = reload(knownMapping)
  assert(known.ledger.unknownRecipeCount == 0)
  assert(noCandidate.ledger.unknownRecipeCount == 1 and queries == 1)
  print("PASS disproved, absent and nonexact candidates; known mappings skip discovery queries")

  local results = { [1236472] = 243807, [1236473] = 999999 }
  environment.C_TradeSkillUI.GetRecipeSchematic = function(recipeId)
    queries = queries + 1
    return { recipeID = recipeId, outputItemID = results[recipeId] }
  end
  local single = reload(candidateDatabase({ 1236472, 1236473 }))
  assert(single.ledger.craftById[1].recipeId == 1236472)
  assert(single.ledger.database.recipeOutputs[1236473] == nil)
  assert(single.lastRecoverySummary.candidateCount == 2 and single.lastRecoverySummary.verifiedCount == 1)
  results[1236473] = 243807
  local shared = reload(candidateDatabase({ 1236472, 1236473 }))
  assert(shared.ledger.recipeOutputCount == 2 and shared.ledger.unknownRecipeCount == 1)
  assert(shared.ledger:AnalyzeUnknownRecipeRepair().ambiguousCount == 1)
  assert(shared.lastRecoverySummary.verifiedCount == 2)
  print("PASS all name candidates verified before shared-output ambiguity is evaluated")

  environment.C_TradeSkillUI.GetRecipeQualityItemIDs = function(recipeId)
    assert(recipeId == 1236472)
    return { 243807, 243808, 243808, 0, -1 }
  end
  local targetedCalls = 0
  local multiple = reload(candidateDatabase(nil, { 243807, 243808 }), function(file)
    if file == "Core/Management.lua" then
      local original = environment.ArtisanLogbookManagement.RepairUnknownRecipesForOutputs
      environment.ArtisanLogbookManagement.RepairUnknownRecipesForOutputs = function(filter)
        targetedCalls = targetedCalls + 1
        assert(filter[243807] and filter[243808])
        return original(filter)
      end
    end
  end)
  assert(multiple.ledger.recipeOutputCount == 2 and multiple.ledger.unknownRecipeCount == 0)
  assert(targetedCalls == 1)
  environment.C_TradeSkillUI.GetRecipeQualityItemIDs = previousQualities
  print("PASS multiple authoritative outputs deduplicate and use one staged targeted repair")

  queries = 0
  environment.C_TradeSkillUI.GetRecipeSchematic = function()
    queries = queries + 1
    error("metadata unavailable")
  end
  local manual = reload(candidateDatabase())
  local beforeManual = manual.Trace.Serialize(manual.ledger.database)
  local analysis = assert(environment.ArtisanLogbookManagement.AnalyzeUnknownRecipeRepair())
  assert(queries == 2 and analysis.recovery.candidateCount == 1 and analysis.recovery.unavailableCount == 1)
  assert(analysis.repairableCount == 0 and analysis.insufficientEvidenceCount == 1)
  assert(manual.Trace.Serialize(manual.ledger.database) == beforeManual)
  assert(manual.recorder and not manual.ledgerError and #notices == noticeCount)
  local manualButton
  for _, frame in ipairs(frames) do
    if frame.parent == manual.window and frame.text == "Repair unknown recipes" then manualButton = frame end
  end
  environment.C_TradeSkillUI.GetRecipeSchematic = function(recipeId)
    queries = queries + 1
    return { recipeID = recipeId, outputItemID = 243807 }
  end
  environment.popup = nil
  manualButton.scripts.OnClick()
  assert(environment.popup == "ARTISANLOGBOOK_REPAIR_UNKNOWN_RECIPES" and queries == 3)
  assert(manual.ledger.craftById[1].recipeId == nil and manual.ledger.unknownRecipeCount == 1)
  assert(manual.ledger.database.recipeOutputs[1236472][243807])
  local canceledDatabase = manual.ledger.database
  local diagnostics = assert(environment.ArtisanLogbookManagement.RecipeOutputDiagnostics())
  assert(diagnostics.recovery.verifiedCount == 1 and diagnostics.verifiedRelationshipCount == 1)
  environment.StaticPopupDialogs.ARTISANLOGBOOK_REPAIR_UNKNOWN_RECIPES.OnAccept()
  assert(manual.ledger.craftById[1].recipeId == 1236472 and queries == 3)
  assert(canceledDatabase.crafts[1].recipeId == nil)
  local canceledReload = reload(canceledDatabase)
  assert(canceledReload.ledger.craftById[1].recipeId == 1236472 and queries == 3)
  print("PASS manual verification previews before repair; unresolved is read-only; canceled knowledge survives reload")

  noticeCount = #notices
  local metadataReady = false
  local queriesByRecipe = {}
  environment.C_TradeSkillUI.GetRecipeSchematic = function(recipeId)
    queriesByRecipe[recipeId] = (queriesByRecipe[recipeId] or 0) + 1
    if metadataReady then return { recipeID = recipeId, outputItemID = results[recipeId] } end
  end
  environment.C_TradeSkillUI.GetRecipeInfo = function(recipeId) return { recipeID = recipeId } end
  local eventsCore = reload(candidateDatabase())
  local currentIds = { 7654321 }
  environment.C_TradeSkillUI.GetAllRecipeIDs = function() return currentIds end
  environment.C_TradeSkillUI.IsTradeSkillReady = function() return true end
  environment.C_TradeSkillUI.IsDataSourceChanging = function() return false end
  eventsCore.HandleRetailEvent("TRADE_SKILL_SHOW")
  eventsCore.HandleRetailEvent("TRADE_SKILL_LIST_UPDATE")
  for index = 1, 20 do
    eventsCore.HandleRetailEvent("TRADE_SKILL_LIST_UPDATE")
    eventsCore.HandleRetailEvent("TRADE_SKILL_SHOW")
    eventsCore.HandleRetailEvent("CRAFTING_DETAILS_UPDATE")
  end
  assert(queriesByRecipe[1236472] == 1 and queriesByRecipe[7654321] == 2)
  assert(eventsCore.ledger.unknownRecipeCount == 1)
  eventsCore.HandleRetailEvent("TRADE_SKILL_CLOSE")
  currentIds = { 1236472, 1236472 }
  metadataReady = true
  environment.C_TradeSkillUI.IsTradeSkillReady = function() return false end
  eventsCore.HandleRetailEvent("TRADE_SKILL_SHOW")
  assert(queriesByRecipe[1236472] == 1)
  environment.C_TradeSkillUI.IsTradeSkillReady = function() return true end
  environment.C_TradeSkillUI.IsDataSourceChanging = function() return true end
  eventsCore.HandleRetailEvent("TRADE_SKILL_LIST_UPDATE")
  assert(queriesByRecipe[1236472] == 1)
  environment.C_TradeSkillUI.IsDataSourceChanging = function() return false end
  eventsCore.HandleRetailEvent("TRADE_SKILL_LIST_UPDATE")
  assert(queriesByRecipe[1236472] == 2 and eventsCore.ledger.craftById[1].recipeId == 1236472)
  eventsCore.HandleRetailEvent("TRADE_SKILL_LIST_UPDATE")
  assert(queriesByRecipe[1236472] == 2 and #notices == noticeCount)
  assert(not eventsCore.ledgerCaptureError and not eventsCore.adapter.capabilities.captureError)
  metadataReady = false
  local changingCore = reload(candidateDatabase())
  changingCore.HandleRetailEvent("TRADE_SKILL_LIST_UPDATE")
  assert(changingCore.ledger.unknownRecipeCount == 1 and queriesByRecipe[1236472] == 4)
  environment.C_TradeSkillUI.IsDataSourceChanging = function() return true end
  changingCore.HandleRetailEvent("TRADE_SKILL_LIST_UPDATE")
  metadataReady = true
  environment.C_TradeSkillUI.IsDataSourceChanging = function() return false end
  changingCore.HandleRetailEvent("TRADE_SKILL_LIST_UPDATE")
  assert(changingCore.ledger.unknownRecipeCount == 0 and queriesByRecipe[1236472] == 5)
  environment.C_TradeSkillUI.GetAllRecipeIDs = function() return nil end
  changingCore.HandleRetailEvent("TRADE_SKILL_SHOW")
  changingCore.HandleRetailEvent("TRADE_SKILL_LIST_UPDATE")
  assert(queriesByRecipe[1236472] == 5)
  environment.C_TradeSkillUI.GetAllRecipeIDs = previousIds
  environment.C_TradeSkillUI.IsTradeSkillReady = previousReady
  environment.C_TradeSkillUI.IsDataSourceChanging = previousChanging
  environment.C_TradeSkillUI.GetRecipeInfo = previousInfo
  print("PASS profession-scoped ready events heal without reload; duplicate and irrelevant events stop querying")

  environment.C_TradeSkillUI.GetRecipeSchematic = nil
  local absentApi = reload(candidateDatabase())
  assert(absentApi.ledger.unknownRecipeCount == 1 and absentApi.lastRecoverySummary.unavailableCount == 1)
  assert(absentApi.recorder and environment.ArtisanLogbookAPI.GetCraft(1))
  local previousSecret, previousAccessible = environment.issecretvalue, environment.canaccesstable
  environment.issecretvalue = function(value) return value == 243807 end
  environment.C_TradeSkillUI.GetRecipeSchematic = function(recipeId)
    return { recipeID = recipeId, outputItemID = 243807 }
  end
  local secret = reload(candidateDatabase())
  assert(secret.ledger.unknownRecipeCount == 1 and secret.ledger.recipeOutputCount == 0)
  environment.issecretvalue = previousSecret
  local forbidden = setmetatable({}, { __index = function() error("forbidden access") end })
  environment.canaccesstable = function(value) return value ~= forbidden end
  environment.C_TradeSkillUI.GetRecipeSchematic = function() return forbidden end
  local inaccessible = reload(candidateDatabase())
  assert(inaccessible.ledger.unknownRecipeCount == 1 and inaccessible.ledger.recipeOutputCount == 0)
  environment.canaccesstable = previousAccessible
  environment.C_TradeSkillUI.GetRecipeSchematic = function() return { recipeID = 7654321, outputItemID = 243807 } end
  local wrongIdentity = reload(candidateDatabase())
  assert(wrongIdentity.ledger.unknownRecipeCount == 1 and wrongIdentity.ledger.recipeOutputCount == 0)
  assert(#notices == noticeCount)
  print("PASS secret, inaccessible and mismatched metadata cannot become durable evidence")

  local large = assert(maintenance.Ledger.New(startupDatabase(9920, {}), {
    wall = function() return 1800000000 end,
  }))
  assert(large:CreateSession({ startedAt = 1800000000, characterName = "Startup Crafter",
    realmName = "Startup Realm", capabilities = {} }))
  for recipeId = 2000000, 2001999 do large:AddDimension("recipe", recipeId, { name = "Unrelated " .. recipeId }) end
  for operationId = 2, 2000 do
    large:BeginCraft(9910)
    assert(large:RecordResult({ operationID = operationId, itemID = 9920, quantity = 1 }))
  end
  for index = 1, 14 do
    local outputId = 3000000 + index
    large:BeginCraft(nil)
    assert(large:RecordResult({ operationID = 2000 + index, itemID = outputId, quantity = 2 }))
    large:AddDimension("item", outputId, { name = "Missing " .. index })
    if index <= 9 then large:AddDimension("recipe", 4000000 + index, { name = "Missing " .. index }) end
  end
  local candidateQueries, enumerationQueries, infoQueries = 0, 0, 0
  environment.C_TradeSkillUI.GetRecipeSchematic = function(recipeId)
    candidateQueries = candidateQueries + 1
    assert(recipeId > 4000000 and recipeId <= 4000009)
    if recipeId <= 4000003 then return { recipeID = recipeId, outputItemID = recipeId - 1000000 } end
  end
  environment.C_TradeSkillUI.GetAllRecipeIDs = function() enumerationQueries = enumerationQueries + 1; return {} end
  environment.C_TradeSkillUI.GetRecipeInfo = function() infoQueries = infoQueries + 1 end
  local started = os.clock()
  local bounded = reload(large.database)
  assert(candidateQueries == 9 and enumerationQueries == 0 and infoQueries == 0)
  assert(bounded.lastRecoverySummary.candidateCount == 9 and bounded.lastRecoverySummary.verifiedCount == 3)
  assert(bounded.ledger.unknownRecipeCount == 11 and bounded.ledger.recipeOutputCount == 4)
  assert(bounded.ledger.database.schemaVersion == 1 and #notices == noticeCount)
  print(string.format("PASS bounded startup: 2010 recipe dimensions, 2000 good crafts, 14 Unknowns, 9 queries (%.3fs mocked full load)", os.clock() - started))
  environment.C_TradeSkillUI.GetRecipeSchematic = previousSchematic
  environment.C_TradeSkillUI.GetAllRecipeIDs = previousIds
  environment.C_TradeSkillUI.GetRecipeInfo = previousInfo
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
local UI = uiAddon.UI
local paperProbe = environment.CreateFrame("Frame", nil, environment.UIParent)
local paperSurface = UI.Surface(paperProbe, true)
assert(paperSurface.color[4] == 1 and paperSurface.allPoints == paperProbe)
assert(paperSurface.grain.allPoints == paperProbe)
assert(paperSurface.grain.texture == "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal")
assert(paperSurface.grain.alpha == .16)
assert(UI.Number(34766) == "34.8k" and UI.Number(1200000) == "1.2M")
assert(UI.Number(0) == "0" and UI.Number(nil) == "-" and UI.Number(34766, true) == "34766")
assert(UI.Number(999999) == "1M" and UI.Number(999999999) == "1B")
assert(UI.Amount(34766, false) == "34.8k" and UI.Amount(34766, true) == "34.8k")
assert(UI.Amount(260, false) == "260" and UI.Amount(0, false) == "-" and UI.Amount(0, true) == "0")
assert(UI.AmountTooltip(260, false):find("total may be higher", 1, true))
assert(UI.AmountTooltip(260, true) == "260")
local logbookColumns = UI.HistoryColumns(732, "Logbook")
for _, column in ipairs(logbookColumns) do assert(column.title ~= "When") end
local hasSixtyDays = false
for _, range in ipairs(UI.ranges) do if range.value == 60 then hasSixtyDays = true end end
assert(hasSixtyDays)
local highlightProbe = UI.ScrollList(paperProbe, 0, 0, 220, 120,
  { { title = "Highlights", width = 196, activity = true, extrasOnly = true } }, function() end)
highlightProbe:Append({ { concentrationSpent = 42, multicraftBonus = 5 } })
assert(highlightProbe.rows[1].indicators[1].label.text == "" and highlightProbe.rows[1].indicators[2].label.text == "")
highlightProbe:Reset(); highlightProbe:Append({ { multicraftBonus = 5 } })
assert(highlightProbe.rows[1].indicators[1].label.text == "")
highlightProbe.rows[1].indicators[1].scripts.OnEnter(highlightProbe.rows[1].indicators[1])
assert(environment.GameTooltip.text == "Multicraft: produced 5 additional items")
local smallCatalogue = environment.CreateFrame("Frame", nil, paperProbe)
UI.CataloguePage(smallCatalogue, 732, 576, function() end)
assert(smallCatalogue.filters:GetHeight() == 46 and smallCatalogue.searchInput.y == -16)
local itemProbe = UI.ItemCell(paperProbe, 0, 200)
itemProbe:Update({ id = 123, name = "Potion" })
itemProbe.scripts.OnEnter(itemProbe)
assert(environment.GameTooltip.itemId == 123 and environment.GameTooltip.lines[1] == "Item ID: 123")
local nativeItemTooltip = environment.GameTooltip.SetItemByID
environment.GameTooltip.SetItemByID = nil
itemProbe.scripts.OnEnter(itemProbe)
assert(environment.GameTooltip.text == "Potion")
environment.GameTooltip.SetItemByID = nativeItemTooltip
local procCases = {
  { craftCount = 20, resourcefulnessProcCount = 5, resourcefulnessProcCountObservedCount = 20, expected = "25.0%" },
  { craftCount = 20, resourcefulnessProcCount = 0, resourcefulnessProcCountObservedCount = 20, expected = "0.0%" },
  { craftCount = 1, resourcefulnessProcCount = 1, resourcefulnessProcCountObservedCount = 1, expected = "100.0%" },
  { craftCount = 30, resourcefulnessProcCount = 8, resourcefulnessProcCountObservedCount = 8, expected = "8 procs" },
  { craftCount = 30, resourcefulnessProcCountObservedCount = 0, expected = "-" },
}
for _, totals in ipairs(procCases) do assert(UI.ProcValue(totals, "resourcefulnessProcCount") == totals.expected) end
assert(UI.ProcTooltip(procCases[3], "resourcefulnessProcCount"):find("1 proc / 1 craft", 1, true))
assert(UI.ProcTooltip(procCases[4], "resourcefulnessProcCount"):find("22 crafts have no return outcome", 1, true))
assert(UI.Percent(1, 3) == "33.3%" and UI.Percent(1, 0) == "-")
local filterProbe = UI.FilterBar(paperProbe, 700, 0)
local filterChanges = 0
local periodProbe = filterProbe:Period({ days = 30 }, function() filterChanges = filterChanges + 1 end)
periodProbe:Choose("custom")
assert(filterProbe:GetHeight() == 92 and periodProbe:Time().from < periodProbe:Time().to)
periodProbe:Choose(1)
assert(filterProbe:GetHeight() == 46 and periodProbe:Time().to - periodProbe:Time().from == 86400)
periodProbe:Choose(60)
assert(periodProbe:Time().to - periodProbe:Time().from == 60 * 86400)
local searchProbe = filterProbe:Search(function(value) filterProbe.search = value end)
searchProbe:SetText("Potion"); searchProbe.searchButton.scripts.OnClick()
assert(filterProbe.search == "Potion")
searchProbe.clearButton.scripts.OnClick()
assert(filterProbe.search == "")
assert(searchProbe.searchButton.template == "UIPanelButtonTemplate" and searchProbe.clearButton.template == "UIPanelButtonTemplate")
local tabsProbe = UI.TabbedContent(paperProbe, 700, 400, -100, { "Overview", "Craft History" })
tabsProbe:Select("Craft History")
assert(tabsProbe.views["Craft History"]:IsShown() and not tabsProbe.views.Overview:IsShown())
local chartProbe = UI.Chart(paperProbe, 0, 0, 600)
chartProbe:Render({ { bucketStart = 0, craftCount = 34766 } }, 0, 86400)
assert(not chartProbe.plot:IsShown() and chartProbe.empty.text == "34.8k crafts on 01 Jan")
chartProbe:Render({ { bucketStart = 0, craftCount = 1 } }, 0, 86400)
assert(chartProbe.total.text == "1 craft" and chartProbe.empty.text == "1 craft on 01 Jan")
chartProbe:Render({ { bucketStart = 0, craftCount = 2 } }, 0, 7 * 86400)
assert(chartProbe.plot:IsShown() and chartProbe.bars[1]:GetWidth() <= 28)
chartProbe:Layout(130)
chartProbe:Render({ { bucketStart = 0, craftCount = 2 } }, 0, 7 * 86400)
assert(chartProbe.bars[1]:GetHeight() <= chartProbe.plot:GetHeight() and chartProbe.start.y == -102)
local selectorProbe = UI.Selector(paperProbe, 20, -40, 160, { { label = "All", value = false } }, function() end, "Character")
assert(selectorProbe.x + selectorProbe:GetWidth() == 180)
assert(selectorProbe.textAlignment == "LEFT" and selectorProbe.caption.parent == selectorProbe)
assert(selectorProbe.caption.x == 15 and selectorProbe.caption.y == 13)
local darkProbe = environment.CreateFrame("Frame", nil, environment.UIParent)
UI.Surface(darkProbe, false)
local darkHeading = UI.Section(darkProbe, "Reagents returned", 0, 0, 300)
assert(darkHeading.textColor[1] == .94 and darkHeading.textColor[2] == .82)
local sectionProbe = UI.Section(paperProbe, "Most-crafted recipes", 0, -416, 600)
local sectionRule = frames[#frames]
assert(sectionRule:GetHeight() == 1)
assert(sectionRule.anchors.TOPLEFT.relative == sectionProbe and sectionRule.anchors.TOPLEFT.relativePoint == "BOTTOMLEFT")
assert(sectionRule.anchors.TOPRIGHT.relative == sectionProbe and sectionRule.anchors.TOPRIGHT.relativePoint == "BOTTOMRIGHT")
assert(sectionRule.anchors.TOPLEFT.y == -1 and sectionRule.anchors.TOPRIGHT.y == -1)
sectionProbe:ClearAllPoints(); sectionProbe:SetPoint("TOPLEFT", 20, -350); sectionProbe:SetWidth(420)
assert(sectionRule.anchors.TOPLEFT.relative.x == 20 and sectionRule.anchors.TOPLEFT.relative.y == -350)
assert(sectionRule.anchors.TOPRIGHT.relative:GetWidth() == 420)
assert(#UI.Pins() == 0)
for index = 1, 5 do assert(UI.TogglePin({ id = index, name = "Recipe " .. (6 - index) })) end
assert(UI.Pins()[1].id == 5 and UI.Pins()[5].id == 1)
local pinned, pinReason = UI.TogglePin({ id = 6, name = "Sixth" })
assert(not pinned and pinReason == "Five recipes are already pinned")
assert(not UI.TogglePin({ id = 0 / 0 }) and not UI.TogglePin({ id = math.huge }))
assert(UI.IsPinned(1) and not UI.IsPinned(6))
local reloadedUI = {}
local reloadComponents = assert(loadfile(uiRoot .. "/UI/Components.lua"))
setfenv(reloadComponents, environment)
reloadComponents("ArtisanLogbook", reloadedUI)
assert(#reloadedUI.UI.Pins() == 5 and reloadedUI.UI.IsPinned(1))
for index = 1, 5 do assert(UI.TogglePin({ id = index })) end
assert(#UI.Pins() == 0 and not uiAddon.ledger)
assert(UI.ReturnQuantity(0, 5, 0) == "-" and UI.ReturnQuantity(0, 5, 5) == "0")
assert(UI.ReturnQuantity(7, 5, 0) == "7" and UI.ReturnQuantity(nil) == "Unavailable")
print("PASS UI-owned alphabetical pins, five-pin limit and reload persistence")
assert(UI.Elide("Silvermoon Health Potion", 10) == "Silvermoon...")
assert(UI.Elide("caf\195\169 noir", 4) == "caf\195\169...")
assert(UI.CraftOutput({ recipe = { name = "Potion" }, outputItem = { name = "Potion" } }) == "")
assert(UI.CraftOutput({ recipe = { name = "Potion" }, outputItem = { name = "Vial" } }) == "Vial")
assert(UI.ClassColor("MAGE") == environment.RAID_CLASS_COLORS.MAGE and UI.ClassColor(nil) == nil)
assert(UI.CharacterName({ name = "TestCrafter", classFile = "MAGE" }) == "|cff3399ffTestCrafter|r")
assert(UI.CharacterName({ name = "Other" }) == "Other")
local parchmentMage = UI.ReadableColor(UI.ClassColor("MAGE"), paperProbe)
assert(parchmentMage.b < UI.ClassColor("MAGE").b and parchmentMage.r < parchmentMage.b)
assert(UI.ReadableColor(UI.ClassColor("MAGE"), darkProbe) == UI.ClassColor("MAGE"))
assert(UI.CharacterName({ name = "TestCrafter", classFile = "MAGE" }, paperProbe) ==
  "|c" .. parchmentMage.colorStr .. "TestCrafter|r")
local whiteInk = UI.ReadableColor({ r = 1, g = 1, b = 1 }, paperProbe)
assert(whiteInk.r < .26 and whiteInk.r == whiteInk.g and whiteInk.g == whiteInk.b)
assert(UI.QualityAtlas(42, 2, 3) == "Quality-2" and UI.QualityAtlas(99, 2, 5) == nil)
assert(UI.QualityAtlas(42, 0, 5) == nil and UI.QualityAtlas(42, 2, nil) == nil)
local activity = UI.Activity({ recipe = { id = 42, name = "Crushing", maxQuality = 3 },
  outputItem = { id = 42, name = "Gemdust" }, outputQuantity = 12, outputQuality = 2,
  concentrationSpent = 397, multicraftBonus = 11, hasIngenuityProc = true,
  ingenuityRefund = 180, reagents = { { item = { name = "Azeroot" }, returnedQuantity = 4 } } })
assert(#activity == 6 and activity[1].atlas == "Quality-2")
assert(activity[2].tooltip:find("Gemdust", 1, true) and
  activity[4].tooltip == "Multicraft: produced 11 additional items" and
  activity[6].tooltip:find("Azeroot: 4 returned (quantity used unavailable)", 1, true))
assert(#UI.Activity({ recipe = { name = "Potion", maxQuality = 5 },
  outputItem = { name = "Potion" }, outputQuality = 0, multicraftBonus = 0,
  concentrationSpent = 0, reagents = {} }) == 0)
assert(#UI.CraftHighlights({ concentrationSpent = 0, multicraftBonus = 0,
  hasIngenuityProc = false, reagents = { { returnedQuantity = 0 } } }) == 0)
local highlights = table.concat(UI.CraftHighlights({ concentrationSpent = 323,
  multicraftBonus = 4, hasIngenuityProc = true, ingenuityRefund = 162,
  reagents = { { returnedQuantity = 4 }, { returnedQuantity = 0 } } }), "; ")
assert(highlights == "Concentration 323; Multicraft +4; Ingenuity +162; Reagents returned: 4")
assert(UI.ReagentDescription({ item = { name = "Azeroot" }, allocatedQuantity = 5,
  returnedQuantity = 1 }) == "Azeroot: 5 used, 1 returned")
assert(UI.ReagentDescription({ item = { name = "Azeroot" }, returnedQuantity = 4 }) ==
  "Azeroot: 4 returned (quantity used unavailable)")
assert(UI.ReagentDescription({ item = { id = 100 }, allocatedQuantity = 2 }) == "#100: 2 used")
local longName = "Silvermoon Health Potion of the Long Night"
local sampleTable = UI.ScrollList(environment.CreateFrame("Frame"), 0, 0, 140, 140,
  { { title = "Recipe", width = 116, value = function(row) return row.name end } }, function() end)
sampleTable:Append({ { name = longName } })
assert(sampleTable.rows[1].cells[1].label.text ~= longName)
assert(sampleTable.rows[1].cells[1].label.text:sub(-3) == "...")
assert(sampleTable.rows[1].cells[1].label.height == 20)
sampleTable.rows[1].scripts.OnEnter(sampleTable.rows[1])
assert(environment.GameTooltip.text == "Artisan Logbook")
sampleTable:Reset()
assert(sampleTable.empty:IsShown() and not sampleTable.rows[1]:IsShown())
local getSeries = environment.ArtisanLogbookAPI.GetCraftSeries
environment.ArtisanLogbookAPI.GetCraftSeries = function(filter, options)
  assert(filter and filter.time and filter.time.from and filter.time.to,
    "UI series requests must be bounded")
  return getSeries(filter, options)
end
local currentKey = environment.ArtisanLogbookManagement.CurrentCharacter().key
local alchemy = assert(uiLedger:AddDimension("profession", 171, { name = "Alchemy" }))
local enchanting = assert(uiLedger:AddDimension("profession", 333, { name = "Enchanting" }))
assert(uiLedger:AddDimension("recipe", 501, { name = "Zebra Brew", professionId = alchemy }))
assert(uiLedger:AddDimension("recipe", 502, { name = "Apple Mix", professionId = enchanting }))
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
    local ancestor = frame.parent
    while ancestor and ancestor ~= parent do ancestor = ancestor.parent end
    if ancestor == parent and frame.choices then
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
assert(uiWindow.pages.Logbook and uiWindow.pages.Recipes and uiWindow.pages.Settings)
assert(uiWindow.pages.Overview and uiWindow.pages.Character and uiWindow.pages.Profession and uiWindow.pages.Recipe)
uiWindow:Hide()
environment.SlashCmdList.ARTISANLOGBOOK("")
assert(uiWindow:IsShown())
local launcher
for _, frame in ipairs(frames) do if frame.name == "ArtisanLogbookButton" then launcher = frame end end
assert(launcher)
assert(launcher.parent == environment.UIParent and launcher.relative == environment.Minimap)
assert(launcher.x > 0 and launcher.y > 0 and type(environment.ArtisanLogbookUISettings) == "table")
local launcherBorder
for _, frame in ipairs(frames) do
  if frame.parent == launcher and frame.texture == "Interface\\Minimap\\MiniMap-TrackingBorder" then
    launcherBorder = frame
  end
end
assert(launcherBorder and launcherBorder.point == "TOPLEFT" and launcherBorder.relative == launcher)
assert(launcherBorder.relativePoint == "TOPLEFT" and launcherBorder.x == 0 and launcherBorder.y == 0)
local initialRadius = math.sqrt(launcher.x ^ 2 + launcher.y ^ 2)
assert(math.abs(initialRadius - 72) < 0.01)
launcher.scripts.OnDragStart(launcher)
assert(launcher.scripts.OnUpdate)
launcher.scripts.OnUpdate(launcher)
launcher.scripts.OnDragStop(launcher)
assert(environment.ArtisanLogbookUISettings.minimapAngle == 0 and launcher.scripts.OnUpdate == nil)
assert(math.abs(launcher.x - 72) < 0.01 and math.abs(launcher.y) < 0.01)
launcher.scripts.OnClick()
assert(not uiWindow:IsShown())
launcher.scripts.OnClick()
assert(uiWindow:IsShown())
local overview = uiWindow.pages.Overview
local chart = overview.chart
assert(chart and chart.title.text == "Craft activity" and chart.total.text == "14 crafts")
assert(#chart.axisLabels == 3 and chart.axisLabels[1].text == "0")
assert(tonumber(chart.axisLabels[3].text) > 0 and #chart.dateLabels == 2)
assert(chart.dateLabels[1]:IsShown() and chart.dateLabels[1].text ~= "")
assert(uiWindow.pages.Recipe.tabs.Overview and uiWindow.navItems[1]:GetHeight() == 24)
assert(uiWindow.pages.Recipe.tabs.Overview.template == "TabSystemButtonArtTemplate")
assert(uiWindow.pages.Recipe.tabs.Overview.rotated)
assert(not overview.history and not uiWindow.pages.Logbook.chart)
uiWindow:Activate("Logbook")
local logbook = uiWindow.pages.Logbook
local history
for _, frame in ipairs(frames) do if frame.parent == logbook and frame.scroll then history = frame end end
assert(history and #history.items == 14 and history.scroll:GetHeight() > 0)
local otherKey
for _, choice in ipairs(dropdown(logbook, "Other").choices) do
  if choice.label == "Other" then otherKey = choice.value end
end
assert(otherKey)
dropdown(logbook, "Alchemy"):Choose(171)
dropdown(logbook, "Other"):Choose(otherKey)
local logbookProfessions = dropdown(logbook, "Enchanting")
assert(logbookProfessions.value == false and logbookProfessions.text == "All")
assert(#history.items == 1 and history.items[1].id == 14)
logbookProfessions:Choose(333)
assert(#history.items == 1 and history.items[1].profession.skillLineId == 333)
dropdown(logbook, "30 days"):Choose(30)
assert(#history.items == 1 and history.scroll:GetVerticalScroll() == 0)
uiWindow:Hide()
environment.SlashCmdList.ARTISANLOGBOOK("anything")
assert(uiWindow:IsShown() and not uiCore.window:IsShown())
environment.SlashCmdList.ARTISANLOGBOOK("debug")
assert(not uiCore.window:IsShown() and uiWindow:IsShown())
environment.SlashCmdList.ARTISANLOGBOOKTRACE("")
assert(uiCore.window:IsShown())
uiCore.window:Hide()
local recentFirst = displayedRow(logbook, function(item) return item.id == 14 end)
assert(recentFirst)
recentFirst.scripts.OnClick(recentFirst)
assert(uiWindow.openCraftId == 14 and uiWindow.visiblePage ~= logbook)
local sharedDetail = uiWindow.visiblePage
assert(visibleText("Quantity:") and not visibleText("Ingenuity proc: Unknown"))
button(sharedDetail, "Close").scripts.OnClick()
assert(uiWindow.visiblePage == logbook and logbook:IsShown() and not sharedDetail:IsShown())
recentFirst.scripts.OnClick(recentFirst)
uiWindow:OpenCraft(13)
button(sharedDetail, "Close").scripts.OnClick()
assert(uiWindow.visiblePage == logbook and logbook:IsShown() and not sharedDetail:IsShown())
uiWindow:Activate("Recipes")
local recipes = uiWindow.pages.Recipes
local catalogue
for _, frame in ipairs(frames) do if frame.parent == recipes and frame.scroll then catalogue = frame end end
assert(catalogue and catalogue.items[1].recipe.name == "Zebra Brew")
local apple = displayedRow(recipes, function(item) return item.recipe and item.recipe.id == 502 end)
assert(apple and apple.item.craftCount == 2)
assert(displayedRow(recipes, function(item) return item.recipe and item.recipe.id == 501 end).item.craftCount == 12)
dropdown(recipes, "Most crafted"):Choose("count")
assert(catalogue.items[1].recipe.name == "Zebra Brew")
dropdown(recipes, "Recipe name"):Choose("name")
dropdown(recipes, "Other"):Choose(otherKey)
assert(#catalogue.items == 1 and catalogue.items[1].recipe.id == 502)
dropdown(recipes, "Enchanting"):Choose(333)
assert(#catalogue.items == 1)
dropdown(recipes, "All"):Choose(false)
assert(#catalogue.items == 2)
apple = displayedRow(recipes, function(item) return item.recipe and item.recipe.id == 502 end)
apple.scripts.OnClick(apple)
local recipePage = uiWindow.visiblePage
local function assertRecipesSelected()
  local found = false
  for _, item in ipairs(uiWindow.navItems) do
    if item:IsShown() and not item.entry.identity then
      local selected = item.entry.page == "Recipes"
      assert(item.selection:IsShown() == selected, "Recipe Detail must keep Recipes selected")
      found = found or selected
    end
  end
  assert(found)
end
assert(not UI.IsPinned(502))
assertRecipesSelected()
assert(recipePage ~= recipes and visibleText("Apple Mix") and visibleText("Enchanting"))
assert(recipePage.tabs[recipePage.activeView].selected)
assert(recipePage.history.rows[1].cells[3].column.title == "When")
assert(recipePage.history.rows[1].cells[3].label.text == UI.DateTime(recipePage.history.items[1].timestamp))
assert(recipePage.history.rows[1].widgets[1].column.title == "Result")
assert(recipePage.history.rows[1].activity.extrasOnly)
local recipeCraft = displayedRow(recipePage, function(item) return item.id == 13 end)
assert(recipeCraft)
recipeCraft.scripts.OnClick(recipeCraft)
assert(uiWindow.visiblePage == sharedDetail and uiWindow.returnPage == recipePage and uiWindow.openCraftId == 13)
button(sharedDetail, "Close").scripts.OnClick()
assert(uiWindow.visiblePage == recipePage and recipePage:IsShown() and not sharedDetail:IsShown())
assertRecipesSelected()
uiWindow:Activate("Logbook")
dropdown(logbook, "TestCrafter"):Choose(currentKey)
local characterCraft = displayedRow(logbook, function(item) return item.id == 12 end)
assert(characterCraft)
characterCraft.scripts.OnClick(characterCraft)
assert(uiWindow.visiblePage == sharedDetail)
uiWindow:OpenCraft(1)
assert(not visibleText("Ingenuity proc: No"))
assert(not visibleText("Net concentration: 0"))
assert(not visibleText("Reported Ingenuity refund: 9"))
uiWindow:Activate("Logbook")
dropdown(logbook, "All"):Choose(false)
uiLedger:BeginCraft(502)
uiWindow:Hide()
local noticeCount = #notices
assert(uiLedger:RecordResult({ operationID = 15 }))
assert(#notices == noticeCount + 1 and notices[#notices] ==
  "|cffffd100Artisan Logbook:|r Crafted Unknown item from Apple Mix")
noticeCount = #notices
local cachedItemLink = "|cff1eff00|Hitem:123|h[Potion]|h|r"
environment.C_Item = { GetItemInfo = function(id)
  assert(id == 123)
  return "Potion", cachedItemLink
end }
uiAddon.NotifyCraft({ outputItem = { id = 123, name = "Potion" }, outputQuantity = 3,
  recipe = { name = "Potion recipe" },
  multicraftBonus = 2, hasIngenuityProc = true, ingenuityRefund = 10,
  reagents = { { returnedQuantity = 3 } } })
assert(#notices == noticeCount + 1 and notices[#notices] ==
  "|cffffd100Artisan Logbook:|r Crafted " .. cachedItemLink ..
  "x3 from Potion recipe (Multicraft +2; Ingenuity +10; Reagents returned: 3)")
environment.C_Item.GetItemInfo = function() return nil end
uiAddon.NotifyCraft({ outputItem = { id = 123, name = "Potion" }, outputQuantity = 1,
  recipe = { name = "Potion recipe" } })
assert(notices[#notices] ==
  "|cffffd100Artisan Logbook:|r Crafted |Hitem:123|h[Potion]|hx1 from Potion recipe")
environment.C_Item = nil
uiWindow:Show()
assert(displayedRow(logbook, function(item) return item.id == 15 end))
uiLedger.wall = function() return 1800000000 - 8 * 86400 end
uiLedger:BeginCraft(501)
assert(uiLedger:RecordResult({ operationID = 16 }))
uiLedger.wall = environment.GetServerTime
uiWindow:Activate("Logbook")
dropdown(logbook, "All"):Choose(false)
local professionFilter = dropdown(logbook, "Enchanting")
professionFilter:Choose(false)
dropdown(logbook, "30 days"):Choose(30)
assert(#history.items == 16)
dropdown(logbook, "7 days"):Choose(7)
assert(#history.items == 15)
dropdown(logbook, "Today"):Choose(1)
assert(#history.items == 15)
local today = math.floor(environment.GetServerTime() / 86400) * 86400
local from, to = uiAddon.UI.Range(environment.GetServerTime(), 1)
assert(from == today and to == today + 86400)
dropdown(logbook, "30 days"):Choose(30)
uiLedger.wall = function() return 1800000000 - 40 * 86400 end
uiLedger:BeginCraft(502)
assert(uiLedger:RecordResult({ operationID = 17 }))
uiLedger.wall = environment.GetServerTime
assert(#history.items == 16)
dropdown(logbook, "90 days"):Choose(90)
assert(#history.items == 17)
dropdown(logbook, "30 days"):Choose(30)
uiWindow:Activate("Settings")
uiWindow:Activate("Character", { key = currentKey, name = "TestCrafter" })
assert(#uiWindow.pages.Character.professionSlots == 2)
assert(uiWindow.pages.Character.professionSlots[1].entry.details and uiWindow.pages.Character.professionSlots[2].entry.details)
uiWindow:Activate("Settings")
local settings = uiWindow.pages.Settings
local retentionInput
for _, frame in ipairs(frames) do
  if frame.parent == settings and frame.kind == "EditBox" then retentionInput = frame end
end
assert(retentionInput and retentionInput.text == "60" and visibleText("Craft history: 17 crafts"))
retentionInput:SetText("1")
button(settings, "Save").scripts.OnClick()
assert(uiLedger.database.retentionDays == 1)
assert(not pcall(button, settings, "Prune now"))
assert(environment.ArtisanLogbookManagement.Prune())
assert(#uiLedger.database.crafts == 15)
assert(#uiLedger.database.craftSeries == 5)
assert(not pcall(button, settings, "Clear history"))
assert(environment.ArtisanLogbookManagement.Clear())
assert(#uiLedger.database.crafts == 0 and #uiLedger.database.craftSeries == 0)
uiWindow.pages.Logbook.dirty = true
uiWindow:Activate("Logbook")
uiWindow.pages.Overview.dirty = true
uiWindow:Activate("Overview")
assert(chart.total.text:find("0 crafts", 1, true))
assert(chart.empty:IsShown() and history.empty:IsShown())
uiWindow.pages.Recipes.dirty = true
uiWindow:Activate("Recipes")
assert(not displayedRow(recipes, function() return true end))
assert(catalogue.empty:IsShown())
for index = 1, 45 do
  uiLedger:BeginCraft(501)
  assert(uiLedger:RecordResult({ operationID = 1000 + index }))
end
uiWindow:Activate("Logbook")
assert(#history.items == 40)
history.scroll:SetVerticalScroll(10000)
history.scroll.scripts.OnVerticalScroll(history.scroll)
assert(#history.items == 45)
history.scroll.scripts.OnVerticalScroll(history.scroll)
assert(#history.items == 45)
history.scroll:SetVerticalScroll(210)
uiWindow:Activate("Overview")
dropdown(overview.content, "7 days"):Choose(7)
uiWindow:Activate("Logbook")
assert(#history.items == 45 and history.scroll:GetVerticalScroll() == 210)
assert(dropdown(logbook, "30 days").value == 30)
uiWindow:OpenCraft(history.items[1].id)
uiWindow.escapeFrame:Hide()
assert(uiWindow:IsShown() and not uiWindow.craftDetailWindow:IsShown())
assert(uiWindow.visiblePage == logbook and #history.items == 45 and history.scroll:GetVerticalScroll() == 210)
uiWindow.escapeFrame:Hide()
assert(not uiWindow:IsShown() and not uiWindow.modalShade:IsShown())
uiWindow:Show()
assert(history.scroll:GetVerticalScroll() == 210)
local characterPage, professionPage = uiWindow.pages.Character, uiWindow.pages.Profession
uiWindow:Activate("Character", { key = currentKey, name = "TestCrafter", classFile = "MAGE" })
assert(characterPage.chart.total.text == "45 crafts" and #characterPage.professionSlots == 2)
assert(characterPage.professionSlots[1].entry.details.skillLineId == 171)
assert(characterPage.professionSlots[2].entry.details == nil)
assert(characterPage.professionSlots[1]:IsShown() and not characterPage.professionSlots[2]:IsShown())
assert(not characterPage.professionSlots[1].label:IsShown())
characterPage.professionSlots[1].scripts.OnEnter(characterPage.professionSlots[1])
assert(environment.GameTooltip.text == "Alchemy")
dropdown(characterPage.content, "7 days"):Choose(7)
assert(characterPage.scroll == nil and characterPage.tabbed)
characterPage.tabbed:Select("Craft History")
characterPage.history.scroll:SetVerticalScroll(85)
uiWindow:Activate("Character", { key = "missing", name = "Missing" })
assert(characterPage.chart.total.text == "0 crafts")
assert(characterPage.professionSlots[1].entry.details == nil and characterPage.professionSlots[2].entry.details == nil)
uiWindow:Activate("Character", { key = currentKey, name = "TestCrafter" })
assert(dropdown(characterPage.content, "7 days").value == 7 and characterPage.history.scroll:GetVerticalScroll() == 85)
assert(characterPage.tabbed.activeView == "Craft History")
uiWindow:Activate("Profession", { skillLineId = 171, name = "Alchemy" })
assert(professionPage.chart.total.text == "45 crafts" and #professionPage.history.items == 40)
professionPage.history.scroll:SetVerticalScroll(95)
uiWindow:OpenCraft(professionPage.history.items[1].id)
uiWindow.craftDetailWindow:Hide()
assert(uiWindow.visiblePage == professionPage and professionPage.history.scroll:GetVerticalScroll() == 95)
uiWindow:Activate("Recipes")
dropdown(recipes, "Profession"):Choose("profession")
assert(catalogue.items[1].profession.name == "Alchemy")
uiWindow:OpenRecipe(catalogue.items[1].recipe)
button(uiWindow.pages.Recipe.content, "Pin recipe").scripts.OnClick()
local pinNav
for _, item in ipairs(uiWindow.navItems) do
  if item:IsShown() and item.entry.page == "Recipe" and item.entry.identity.id == 501 then pinNav = item end
end
assert(pinNav and UI.IsPinned(501))
assertRecipesSelected()
uiWindow:Activate("Recipes")
dropdown(recipes, "All"):Choose(otherKey)
assert(#catalogue.items == 0)
pinNav.scripts.OnClick(pinNav)
assert(uiWindow.activeTab == "Recipe" and uiWindow.pages.Recipe.recipe.id == 501)
assertRecipesSelected()
button(uiWindow.pages.Recipe.content, "Unpin recipe").scripts.OnClick()
assert(not UI.IsPinned(501))
assertRecipesSelected()
uiWindow:Activate("Overview")
while overview.summary.scripts.OnUpdate do overview.summary.scripts.OnUpdate(overview.summary) end
assert(overview.summary.tiles[5].note.text == "")
uiWindow:Activate("Logbook")
print("PASS sidebar destinations, independent filters, list preservation, pins and modal Escape")
local present = environment.GetServerTime
environment.GetServerTime = function() return 1800000000 + 40 * 86400 end
dropdown(logbook, "30 days"):Choose(30)
assert(#history.items == 0 and history.scroll:GetVerticalScroll() == 0)
environment.GetServerTime = present
print("PASS unified Logbook, Recipes, filters, scrolling, detail and Settings (mocked)")

do
  local core = reload(nil)
  local ledger = core.ledger
  local api = environment.ArtisanLogbookAPI
  local now = environment.GetServerTime()
  local professions = {
    { id = 171, name = "Alchemy", days = 0 },
    { id = 164, name = "Blacksmithing", days = 45 },
    { id = 129, name = "First Aid", days = 0 },
    { id = 185, name = "Cooking", days = 0 },
    { id = 356, name = "Fishing", days = 0 },
    { id = 794, name = "Archaeology", days = 0 },
  }
  for index, profession in ipairs(professions) do
    local professionId = assert(ledger:AddDimension("profession", profession.id, { name = profession.name }))
    local recipeId = 9500 + index
    assert(ledger:AddDimension("recipe", recipeId, { name = profession.name .. " recipe", professionId = professionId }))
    ledger.wall = function() return now - profession.days * 86400 end
    ledger:BeginCraft(recipeId)
    assert(ledger:RecordResult({ operationID = index, quantity = 1 }))
  end
  ledger.wall = environment.GetServerTime
  local character = api.GetCharacters()[1]
  assert(#api.GetProfessions(character.key) == 6)
  local ui = loadUI()
  local window, page = ui.productionWindow, ui.productionWindow.pages.Character
  window:Show()
  window:Activate("Character", character)
  local function assertPrimarySlots()
    assert(#page.professionSlots == 2)
    local first = page.professionSlots[1].entry.details
    local second = page.professionSlots[2].entry.details
    assert(first and second, "Both recorded primary professions must remain visible")
    assert(first.skillLineId == 164 and second.skillLineId == 171,
      "Slots must use stable all-history primary professions, excluding secondary professions")
    assert(page.professionSlots[1]:IsShown() and page.professionSlots[2]:IsShown())
    assert(not page.professionSlots[1].label:IsShown() and not page.professionSlots[2].label:IsShown())
  end
  assertPrimarySlots()
  assert(page.summary.totals.craftCount == 5 and #page.topRecipes.items == 5)
  dropdown(page.content, "90 days"):Choose(90)
  assertPrimarySlots()
  assert(page.chart.total.text == "6 crafts" and page.summary.totals.craftCount == 6)
  assert(page.craftBreakdown:IsShown() and page.craftBreakdown.text:find("Alchemy 1", 1, true))
  assert(page.craftBreakdown.text:find("Blacksmithing 1", 1, true))
  dropdown(page.content, "Today"):Choose(1)
  assertPrimarySlots()
  assert(page.chart.total.text == "5 crafts" and page.summary.totals.craftCount == 5)
  for _, row in ipairs(page.topRecipes.items) do assert(row.recipe.id ~= 9502) end
  dropdown(page.content, "7 days"):Choose(7)
  dropdown(page.content, "Alchemy"):Choose(171)
  assertPrimarySlots()
  assert(page.summary.totals.craftCount == 1 and #page.topRecipes.items == 1)
  assert(not page.craftBreakdown:IsShown() and not page.craftBreakdownHover:IsShown())
  page.history.scroll:SetVerticalScroll(85)
  window:Activate("Character", { key = "missing", name = "Missing" })
  assert(not page.professionSlots[1].entry.details and not page.professionSlots[2].entry.details)
  assert(not page.professionSlots[1]:IsShown() and not page.professionSlots[2]:IsShown())
  window:Activate("Character", character)
  assertPrimarySlots()
  assert(dropdown(page.content, "7 days").value == 7 and dropdown(page.content, "Alchemy").value == 171)
  assert(page.history.scroll:GetVerticalScroll() == 85)
  assert(ledger:Prune(now + 400 * 86400))
  assert(#api.GetCrafts().crafts == 0)
  local serverTime = environment.GetServerTime
  environment.GetServerTime = function() return now + 400 * 86400 end
  dropdown(page.content, "Today"):Choose(1)
  assertPrimarySlots()
  assert(page.chart.total.text == "0 crafts" and #page.topRecipes.items == 0)
  environment.GetServerTime = serverTime
  local tailoring = assert(ledger:AddDimension("profession", 197, { name = "Tailoring" }))
  assert(ledger:AddDimension("recipe", 9507, { name = "Tailoring recipe", professionId = tailoring }))
  ledger:BeginCraft(9507)
  assert(ledger:RecordResult({ operationID = 7, quantity = 1 }))
  assert(#api.GetProfessions(character.key) == 7)
  assertPrimarySlots()
  page.professionSlots[1].scripts.OnClick(page.professionSlots[1])
  assert(window.activeTab == "Profession" and window.identity.skillLineId == 164)
  window:Hide()
  print("PASS character primary professions survive period/profession filters, state restoration and detail pruning")
end

  do
    local core = reload(nil)
    local ledger = core.ledger
    for index = 1, 45 do
      ledger:AddDimension("recipe", 9600 + index, { name = string.format("Recipe %02d", index) })
      ledger:BeginCraft(9600 + index)
      assert(ledger:RecordResult({ operationID = index }))
    end
    local ui = loadUI()
    local window = ui.productionWindow
    window:Show(); window:Activate("Recipes")
    local page = window.pages.Recipes
    assert(#page.catalogue.items == 40)
    page.searchInput:SetText("Recipe 45")
    page.searchInput.scripts.OnTextChanged(page.searchInput)
    page.catalogue:LoadNext()
    assert(#page.catalogue.items == 45)
    page.searchInput.scripts.OnUpdate(page.searchInput, .3)
    assert(#page.catalogue.items == 1 and page.catalogue.items[1].recipe.id == 9645)
    window:Activate("Overview"); window:Activate("Recipes")
    assert(page.searchInput:GetText() == "Recipe 45" and #page.catalogue.items == 1)
    page.searchInput:SetText("")
    page.searchInput.scripts.OnTextChanged(page.searchInput)
    page.searchInput.scripts.OnEnterPressed(page.searchInput)
    assert(#page.catalogue.items == 40 and not page.searchInput.scripts.OnUpdate)
    window:Hide()
    print("PASS recipe search spans lazy pages and survives navigation")
  end

do
  local core = reload(nil)
  local ledger = core.ledger
  for index = 1, 85 do
    ledger:AddDimension("recipe", 9650 + index, { name = string.format("Recipe %02d", index) })
    local count = index == 1 and 44 or index == 2 and 19 or 1
    for craftIndex = 1, count do
      ledger:BeginCraft(9650 + index)
      assert(ledger:RecordResult({ operationID = index * 100 + craftIndex }))
    end
  end
  local ui = loadUI()
  local window = ui.productionWindow
  window:Show()
  for _, destination in ipairs({ "Overview", "Recipes" }) do
    window:Activate(destination)
    local page = window.pages[destination]
    local list = page.topRecipes or page.catalogue
    assert(#list.items == 40 and list.items[1].craftCount == 44 and list.items[2].craftCount == 19)
    list.scroll.SetVerticalScroll = function(self, offset)
      local changed = offset ~= self:GetVerticalScroll()
      methods.SetVerticalScroll(self, offset)
      if changed then self.scripts.OnVerticalScroll(self, offset) end
    end
    list.child.SetHeight = function(self, value)
      methods.SetHeight(self, value)
      local maximum = math.max(0, value - list.scroll:GetHeight())
      if list.scroll:GetVerticalScroll() > maximum then list.scroll:SetVerticalScroll(maximum) end
    end
    list.scroll:SetVerticalScroll(180)
    local items = list.items
    list.worker.scripts.OnUpdate(list.worker)
    assert(#list.items == 40, destination .. ": enrichment must not load a page during repaint")
    assert(list.items == items and list.scroll:GetVerticalScroll() == 180)
    for index, row in ipairs(list.rows) do
      if row.item then assert(row.item == list.items[index]) end
    end
    list:LoadNext()
    assert(#list.items == 80)
    list:LoadNext()
    assert(#list.items == 85 and list.finish:IsShown())
    local childHeight = list.child:GetHeight()
    while list.worker.scripts.OnUpdate do list.worker.scripts.OnUpdate(list.worker) end
    assert(#list.items == 85 and list.items == items and list.finish:IsShown())
    assert(list.child:GetHeight() == childHeight and list.scroll:GetVerticalScroll() == 180)
    local seen = {}
    for index, row in ipairs(list.items) do
      assert(not seen[row.recipe.id], destination .. ": duplicate recipe")
      seen[row.recipe.id] = true
      assert(row.totals.craftCount == row.craftCount and list.rows[index].item == row)
      assert(list.rows[index].cells[2].label.text == ui.UI.Number(row.craftCount))
      if index > 1 then assert(list.items[index - 1].craftCount >= row.craftCount) end
    end
  end
  window:Hide()
  print("PASS most-crafted ordering survives enrichment and native scroll callbacks across pages")
end

do
  local core = reload(nil)
  local ledger = core.ledger
  for _, recipeId in ipairs({ 9741, 9742, 9743 }) do
    ledger:AddDimension("recipe", recipeId, { name = "Proc recipe " .. recipeId })
    for index = 1, 20 do
      ledger:BeginCraft(recipeId)
      local returns
      if recipeId == 9741 then
        returns = index <= 5 and { { reagent = { itemID = 8 }, quantity = 1 } } or {}
      elseif recipeId == 9742 then returns = {}
      elseif index <= 8 then returns = { { reagent = { itemID = 8 }, quantity = 1 } } end
      assert(ledger:RecordResult({ operationID = recipeId * 100 + index, resourcesReturned = returns,
        multicraft = 0, hasIngenuityProc = false }))
    end
  end
  local ui = loadUI()
  local window = ui.productionWindow
  window:Show()
  for _, destination in ipairs({ "Overview", "Recipes" }) do
    window:Activate(destination)
    local page = window.pages[destination]
    local list = page.topRecipes or page.catalogue
    while list.worker.scripts.OnUpdate do list.worker.scripts.OnUpdate(list.worker) end
    local expected = { [9741] = "25.0%", [9742] = "0.0%", [9743] = "8 procs" }
    for _, row in ipairs(list.rows) do
      if row.item then
        local resource
        for _, cell in ipairs(row.cells) do if cell.column.title == "Resourcefulness" then resource = cell end end
        assert(resource and resource.label.text == expected[row.item.recipe.id])
        for _, cell in ipairs(row.cells) do
          if cell.column.title == "Multicraft" or cell.column.title == "Ingenuity" then assert(cell.label.text == "") end
        end
        if row.item.recipe.id == 9743 then
          row.scripts.OnEnter(row)
          local tooltip = table.concat(environment.GameTooltip.lines, "\n")
          assert(tooltip:find("12 crafts have no return outcome", 1, true))
        end
      end
    end
  end
  window:Hide()
  print("PASS recipe Resourcefulness shows measured mixed rates or known procs without treating missing outcomes as failures")
end

do
  local core = reload(nil)
  local ledger, api = core.ledger, environment.ArtisanLogbookAPI
  local now = environment.GetServerTime()
  ledger:AddDimension("recipe", 9901, { name = "Quality recipe", maxQuality = 3 })
  ledger:AddDimension("recipe", 9902, { name = "Second recipe", maxQuality = 3 })
  for index = 1, 3 do ledger:AddDimension("item", 6000 + index, { name = "Quality " .. index .. " result" }) end
  local function record(recipeId, itemId, quality, quantity, operation)
    ledger:BeginCraft(recipeId)
    return assert(ledger:RecordResult({ operationID = operation, itemID = itemId, craftingQuality = quality,
      quantity = quantity, multicraft = 0, hasIngenuityProc = false, resourcesReturned = {} }))
  end
  ledger.wall = function() return now - 40 * 86400 end
  record(9901, 6001, 1, 7, 1)
  ledger.wall = environment.GetServerTime
  local firstCharacter = api.GetCharacters()[1].key
  for index = 1, 105 do
    record(9901, index <= 50 and 6001 or index <= 100 and 6002 or 6003,
      index <= 50 and 1 or index <= 100 and 2 or nil, 1, index + 1)
  end
  ledger:CreateSession({ characterName = "Other quality crafter", characterGUID = "Player-quality-other" })
  record(9901, 6003, 3, 4, 107)
  record(9902, 6002, 2, 2, 108)
  local ui = loadUI()
  local window = ui.productionWindow
  window:Show(); window:OpenRecipe({ id = 9901, name = "Quality recipe", maxQuality = 3 })
  local pane = window.recipeOutcomes
  local queries, originalCrafts = 0, api.GetCrafts
  api.GetCrafts = function(filter, options)
    if options.limit == 100 then queries = queries + 1 end
    return originalCrafts(filter, options)
  end
  pane.qualityWorker.scripts.OnUpdate(pane.qualityWorker)
  assert(queries == 1 and pane.qualityWorker.scripts.OnUpdate)
  pane.qualityWorker.scripts.OnUpdate(pane.qualityWorker)
  assert(queries == 2 and not pane.qualityWorker.scripts.OnUpdate)
  assert(#pane.qualityRows == 4 and pane.qualityCraftCount == 101)
  assert(pane.qualityRows[1].quality == 1 and pane.qualityRows[1].quantity == 50)
  assert(pane.qualityRows[2].quality == 2 and pane.qualityRows[2].quantity == 50)
  assert(pane.qualityRows[3].quality == 3 and pane.qualityRows[3].quantity == 4)
  assert(pane.qualityRows[4].quality == nil and pane.qualityRows[4].quantity == 5)
  assert(pane.tiles[2].value.text == "109" and pane.qualityStatus.text:find("101 crafts of 106", 1, true))
  pane.qualityList.rows[1].widgets[1].widget.scripts.OnEnter(pane.qualityList.rows[1].widgets[1].widget)
  assert(environment.GameTooltip.itemId == 6001)
  dropdown(pane, "All time"):Choose(false)
  while pane.qualityWorker.scripts.OnUpdate do pane.qualityWorker.scripts.OnUpdate(pane.qualityWorker) end
  assert(pane.qualityRows[1].quantity == 57 and pane.tiles[2].value.text == "116")
  dropdown(pane, "TestCrafter"):Choose(firstCharacter)
  while pane.qualityWorker.scripts.OnUpdate do pane.qualityWorker.scripts.OnUpdate(pane.qualityWorker) end
  assert(#pane.qualityRows == 3 and pane.qualityCraftCount == 101)
  assert(pane.tiles[2].value.text == "112")
  dropdown(pane, "Today"):Choose(1)
  while pane.qualityWorker.scripts.OnUpdate do pane.qualityWorker.scripts.OnUpdate(pane.qualityWorker) end
  assert(pane.qualityRows[1].quantity == 50)
  pane:Refresh()
  pane.qualityWorker.scripts.OnUpdate(pane.qualityWorker)
  window:OpenRecipe({ id = 9902, name = "Second recipe", maxQuality = 3 })
  while pane.qualityWorker.scripts.OnUpdate do pane.qualityWorker.scripts.OnUpdate(pane.qualityWorker) end
  assert(#pane.qualityRows == 1 and pane.qualityRows[1].quantity == 2)
  ledger:Prune(now + 61 * 86400)
  pane:Refresh()
  while pane.qualityWorker.scripts.OnUpdate do pane.qualityWorker.scripts.OnUpdate(pane.qualityWorker) end
  assert(#pane.qualityRows == 0 and pane.tiles[2].value.text == "2")
  assert(pane.qualityStatus.text:find("0 crafts of 1", 1, true))
  api.GetCrafts = originalCrafts
  window:Hide()
  print("PASS recipe quality totals are scoped, paged, cancellable and honest after detail pruning")
end

do
  local core = reload(nil)
  local ledger, api = core.ledger, environment.ArtisanLogbookAPI
  environment.ArtisanLogbookUISettings.trivialReagents = {}
  local ui = loadUI()
  local window, helpers = ui.productionWindow, ui.UI
  local page, list = window.pages.Reagents, window.pages.Reagents.catalogue
  window:Show(); window:Activate("Reagents")
  assert(window.navItems[3].entry.page == "Recipes" and window.navItems[4].entry.page == "Reagents")
  assert(window.navItems[4].selection:IsShown() and not window.navItems[3].selection:IsShown())
  assert(#list.items == 0 and list.empty:IsShown())
  local summaries = api.GetReagentSummaries
  api.GetReagentSummaries = function(options)
    assert(options.limit == 40 and options.trivial == nil)
    return summaries(options)
  end
  assert(ledger:AddDimension("profession", 171, { name = "Alchemy" }))
  assert(ledger:AddDimension("profession", 333, { name = "Enchanting" }))
  assert(ledger:AddDimension("recipe", 9701, { name = "Potion", professionId = 171 }))
  assert(ledger:AddDimension("recipe", 9702, { name = "Enchant", professionId = 333 }))
  local function record(recipeId, itemId, name, quantity, returned, quality)
    assert(ledger:AddDimension("item", itemId, { name = name }))
    assert(ledger:SubmitCraft(recipeId, 1, false, nil, {
      { dataSlotIndex = 1, quantity = quantity, quality = quality, reagent = { itemID = itemId } },
    }))
    return assert(ledger:RecordResult({ resourcesReturned = { { reagent = { itemID = itemId }, quantity = returned } } }))
  end
  local firstCraft = record(9701, 4008, "Bloom", 5, 2, 1)
  assert(#list.items == 1 and list.items[1].item.id == 4008 and list.items[1].quality == 1)
  assert(list.items[1].allocatedQuantity == 5 and list.items[1].returnedQuantity == 2)
  record(9701, 4009, "Bloom", 7, 3, 2)
  record(9702, 4008, "Bloom", 3, 1, 1)
  assert(#list.items == 2 and list.items[2].item.id == 4009 and list.items[2].quality == 2)
  assert(#list.items[1].professions == 2 and list.items[1].recipeCount == 2)
  assert(list.rows[1].widgets[1].widget.label.text == "Bloom" and not list.rows[1].widgets[1].widget.identity)
  list.rows[1].widgets[1].widget.scripts.OnEnter(list.rows[1].widgets[1].widget)
  assert(environment.GameTooltip.itemId == 4008 and environment.GameTooltip.lines[1] == "Item ID: 4008")
  assert(list.rows[2].widgets[1].widget.item.id == 4009)
  local catalogueCheck = list.rows[1].widgets[2].widget
  catalogueCheck:SetChecked(true); catalogueCheck.scripts.OnClick(catalogueCheck)
  assert(helpers.IsTrivial(4008))
  catalogueCheck:SetChecked(false); catalogueCheck.scripts.OnClick(catalogueCheck)
  assert(not helpers.IsTrivial(4008))
  for index = 1, 45 do record(9701, 4100 + index, string.format("Herb %02d", index), index, index, 1) end
  assert(#list.items == 40)
  page.searchInput:SetText("Bloom")
  page.searchInput.scripts.OnTextChanged(page.searchInput)
  list.scroll:SetVerticalScroll(1200); list.scroll.scripts.OnVerticalScroll(list.scroll)
  assert(#list.items == 47)
  page.searchInput.scripts.OnUpdate(page.searchInput, .3)
  assert(#list.items == 2)
  page.searchInput:SetText("")
  page.searchInput.scripts.OnTextChanged(page.searchInput)
  page.searchInput.scripts.OnUpdate(page.searchInput, .3)
  dropdown(page, "Most returned"):Choose("returned")
  assert(#list.items == 40 and list.items[1].item.id == 4145)
  dropdown(page, "Most used"):Choose("allocated")
  assert(list.items[1].item.id == 4145)
  dropdown(page, "Recipe count"):Choose("recipes")
  assert(list.items[1].item.id == 4008)
  dropdown(page, "Name"):Choose("name")
  dropdown(page, "Enchanting"):Choose(333)
  assert(#list.items == 1 and list.items[1].allocatedQuantity == 3 and list.items[1].returnedQuantity == 1)
  dropdown(page, "Alchemy"):Choose(false)
  local function search(text)
    page.searchInput:SetText(text)
    page.searchInput.scripts.OnTextChanged(page.searchInput)
    page.searchInput.scripts.OnUpdate(page.searchInput, .3)
  end
  search("BLOOM")
  assert(#list.items == 2)
  helpers.SetTrivial(4008, true)
  assert(helpers.IsTrivial(4008) and environment.ArtisanLogbookUISettings.trivialReagents[4008])
  dropdown(page, "Ignored"):Choose("trivial")
  assert(#list.items == 1 and list.items[1].item.id == 4008)
  dropdown(page, "Included"):Choose("non-trivial")
  assert(#list.items == 1 and list.items[1].item.id == 4009)
  dropdown(page, "Ignored"):Choose("all")
  assert(#list.items == 2)
  window:OpenRecipe({ id = 9701 })
  local outcomes = window.recipeOutcomes
  local function finish()
    while outcomes.scripts.OnUpdate do outcomes.scripts.OnUpdate() end
  end
  finish()
  assert(helpers.IsTrivial(outcomes.materialList.items[1].item.id))
  local before = outcomes.resourcefulness.nonTrivial.text
  window:Activate("Reagents")
  assert(#list.items == 2 and page.searchInput:GetText() == "BLOOM")
  helpers.SetTrivial(4008, false)
  finish()
  assert(not helpers.IsTrivial(4008) and outcomes.resourcefulness.nonTrivial.text ~= before)
  list.rows[1].scripts.OnClick(list.rows[1])
  assert(window.activeTab == "Reagent" and window.identity.id == 4008)
  local preference = window.pages.Reagent.classification
  assert(preference and preference.itemId == 4008 and not preference:GetChecked())
  preference:SetChecked(true); preference.scripts.OnClick(preference)
  assert(helpers.IsTrivial(4008))
  window:Activate("Reagents")
  assert(helpers.IsTrivial(4008))
  dropdown(page, "Ignored"):Choose("trivial")
  assert(#list.items == 1)
  helpers.SetTrivial(4008, false)
  assert(#list.items == 0 and list.empty:IsShown() and not preference:GetChecked())
  dropdown(page, "Ignored"):Choose("all")
  search("Herb")
  dropdown(page, "Alchemy"):Choose(171)
  dropdown(page, "Most used"):Choose("allocated")
  list.scroll:SetVerticalScroll(1200); list.scroll.scripts.OnVerticalScroll(list.scroll)
  assert(#list.items == 45)
  list.scroll:SetVerticalScroll(150)
  window:Activate("Recipes"); window:Activate("Reagents")
  assert(#list.items == 45 and list.scroll:GetVerticalScroll() == 150 and page.searchInput:GetText() == "Herb")
  assert(dropdown(page, "Alchemy").value == 171 and dropdown(page, "Most used").value == "allocated")
  search("not recorded")
  assert(#list.items == 0 and list.empty:IsShown())
  assert(helpers.ReagentAmount({ allocatedQuantity = 4, allocationComplete = false }, "allocatedQuantity", "allocationComplete") == "4")
  assert(helpers.ReagentAmount({}, "returnedQuantity", "returnComplete") == "-")
  assert(helpers.ReagentAmount({ returnedQuantity = 0, returnComplete = true }, "returnedQuantity", "returnComplete") == "0")
  api.GetReagentSummaries = summaries
  window:Hide()
  print("PASS Reagents navigation, global filters/sorts, quality identities, shared preferences and scroll restoration")
end

do
  local core = reload(nil)
  local ledger, api = core.ledger, environment.ArtisanLogbookAPI
  ledger:AddDimension("recipe", 9751, { name = "Test potion" })
  ledger:AddDimension("item", 4501, { name = "First herb" })
  ledger:AddDimension("item", 4502, { name = "Second herb" })
  for index = 1, 101 do
    ledger:SubmitCraft(9751, 1, false, nil, {
      { dataSlotIndex = 1, quantity = 5, reagent = { itemID = 4501 } },
    })
    assert(ledger:RecordResult({ operationID = index,
      resourcesReturned = { { reagent = { itemID = 4501 }, quantity = 2 } } }))
  end
  ledger:SubmitCraft(9751, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 3, reagent = { itemID = 4502 } },
  })
  assert(ledger:RecordResult({ operationID = 102 }))
  local ui = loadUI()
  local window = ui.productionWindow
  window:Show(); window:Activate("Reagents")
  local page, detail = window.pages.Reagents, window.pages.Reagent
  page.catalogue.rows[1].scripts.OnClick(page.catalogue.rows[1])
  local crafts, calls = api.GetCrafts, 0
  api.GetCrafts = function(filter, options)
    assert(options.limit == 100 or options.limit == 40)
    if options.limit == 100 then calls = calls + 1 end
    return crafts(filter, options)
  end
  assert(window.activeTab == "Reagent" and detail.item.id == 4501 and page.detail == nil)
  assert(page.summary[1].value.text == "2" and page.summary[2].value.text == "508")
  detail.worker.scripts.OnUpdate(detail.worker)
  assert(calls == 1 and detail.worker.scripts.OnUpdate and detail.fields.crafts.text == "-")
  detail.worker.scripts.OnUpdate(detail.worker)
  assert(calls == 2 and not detail.worker.scripts.OnUpdate)
  assert(detail.totals.crafts == 101 and detail.fields.rate.text == "40.0%")
  assert(detail.fields.characters.text == "1" and #detail.recipes.items == 1)
  assert(detail.recipes.items[1].crafts == 101 and detail.recipes.items[1].returnedQuantity == 202)
  assert(#detail.chart.bars <= 60 and detail.chart.bars[1].returned:IsShown())
  assert(detail.chart.bars[1].tooltip:find("Used: 505", 1, true))
  detail:SelectView("Used in Recipes")
  assert(detail.tabs["Used in Recipes"].selected and detail.recipes:IsShown())
  detail.recipes.rows[1].scripts.OnClick(detail.recipes.rows[1])
  assert(window.activeTab == "Recipe" and window.identity.id == 9751)
  window:Activate("Reagents")
  assert(detail.item.id == 4501 and detail.activeView == "Used in Recipes")
  page.catalogue.rows[2].scripts.OnClick(page.catalogue.rows[2])
  detail:SelectView("Overview")
  while detail.worker.scripts.OnUpdate do detail.worker.scripts.OnUpdate(detail.worker) end
  assert(detail.item.id == 4502 and detail.totals.crafts == 1)
  assert(detail.fields.rate.text == "-" and detail.fields.returned.text == "-")
  assert(not detail.chart.bars[1].returned:IsShown())
  assert(detail.chart.bars[1].tooltip:find("Returned: Unknown", 1, true))
  page.catalogue.rows[1].scripts.OnClick(page.catalogue.rows[1])
  detail.worker.scripts.OnUpdate(detail.worker)
  page.catalogue.rows[2].scripts.OnClick(page.catalogue.rows[2])
  while detail.worker.scripts.OnUpdate do detail.worker.scripts.OnUpdate(detail.worker) end
  assert(detail.row.item.id == 4502 and detail.totals.crafts == 1)
  dropdown(detail, "Today"):Choose(1)
  while detail.worker.scripts.OnUpdate do detail.worker.scripts.OnUpdate(detail.worker) end
  assert(detail:Filter().time.to - detail:Filter().time.from == 86400)
  dropdown(detail, "All time"):Choose(false)
  window:Activate("Reagent", page.catalogue.items[1].item)
  ledger:Prune(ledger.wall() + 61 * 86400)
  detail:Refresh(true)
  while detail.worker.scripts.OnUpdate do detail.worker.scripts.OnUpdate(detail.worker) end
  assert(detail.fields.crafts.text == "0" and detail.fields.returned.text:find("202", 1, true))
  assert(detail.fields.allocated.text == "-" and detail.fields.rate.text == "-")
  assert(#detail.recipes.items == 0 and detail.chart.empty:IsShown())
  api.GetCrafts = crafts
  window:Hide()
  print("PASS reagent detail bounded work, selection, native tabs, quantities, partial rates and pruning")
end

do
  local core = reload(nil)
  local ledger, api = core.ledger, environment.ArtisanLogbookAPI
  for itemId = 5101, 5103 do
    assert(ledger:AddDimension("item", itemId, { name = "Cached herb " .. itemId }))
    assert(ledger:SubmitCraft(9801, 1, false))
    assert(ledger:RecordResult({ resourcesReturned = { { reagent = { itemID = itemId }, quantity = itemId - 5100 } } }))
  end
  local ui = loadUI()
  local window = ui.productionWindow
  local page, list = window.pages.Reagents, window.pages.Reagents.catalogue
  local savedIcon, savedQuality = environment.GetItemIcon, environment.C_TradeSkillUI.GetItemReagentQualityInfo
  local iconCalls, qualityCalls, ready = {}, {}, {}
  environment.GetItemIcon = function(itemId)
    iconCalls[itemId] = (iconCalls[itemId] or 0) + 1
    if itemId ~= 5102 or ready.icon then return "Icon-" .. itemId end
  end
  environment.C_TradeSkillUI.GetItemReagentQualityInfo = function(itemId)
    qualityCalls[itemId] = (qualityCalls[itemId] or 0) + 1
    if itemId == 5103 and not ready.profession then error("Quality metadata unavailable") end
    if itemId == 5101 or itemId == 5102 and ready.quality or itemId == 5103 and ready.profession then
      return { icon = "Quality-" .. itemId }
    end
  end
  local savedSummaries, queries = api.GetReagentSummaries, 0
  api.GetReagentSummaries = function(options)
    queries = queries + 1
    return savedSummaries(options)
  end
  local savedSettings = core.Trace.Serialize(environment.ArtisanLogbookUISettings)
  local savedFacts = core.Trace.Serialize(ledger.database)
  window:Show(); window:Activate("Reagents")
  local function cell(itemId)
    for _, row in ipairs(list.rows) do
      if row.item and row.item.item.id == itemId then return row.widgets[1].widget end
    end
    error("Missing reagent cell " .. itemId)
  end
  assert(cell(5101).icon.texture == "Icon-5101" and cell(5101).quality.atlas == "Quality-5101")
  assert(cell(5102).icon.texture == "Interface\\Icons\\INV_Misc_QuestionMark" and not cell(5102).quality:IsShown())
  page:Refresh(true)
  dropdown(page, "Most returned"):Choose("returned")
  window:Activate("Recipes"); window:Activate("Reagents")
  for itemId = 5101, 5103 do
    assert(iconCalls[itemId] == 1 and qualityCalls[itemId] == 1, "Reagent rerenders must reuse metadata, including unresolved entries")
  end
  assert(page:IsEventRegistered("GET_ITEM_INFO_RECEIVED") and page:IsEventRegistered("TRADE_SKILL_LIST_UPDATE"))
  list.scroll:SetVerticalScroll(45)
  local items, queriesBeforeEvent = list.items, queries
  local function event(name, ...)
    page.scripts.OnEvent(page, name, ...)
  end
  event("GET_ITEM_INFO_RECEIVED", 999999, true)
  event("GET_ITEM_INFO_RECEIVED", 5102, false)
  assert(not iconCalls[999999] and iconCalls[5102] == 1)
  ready.icon = true
  event("GET_ITEM_INFO_RECEIVED", 5102, true)
  assert(iconCalls[5102] == 2 and qualityCalls[5102] == 2)
  assert(cell(5102).icon.texture == "Icon-5102" and not cell(5102).quality:IsShown())
  assert(iconCalls[5101] == 1 and qualityCalls[5101] == 1 and qualityCalls[5103] == 1)
  ready.quality = true
  event("GET_ITEM_INFO_RECEIVED", 5102, true)
  assert(iconCalls[5102] == 2 and qualityCalls[5102] == 3, "Resolved icon must survive quality retry")
  assert(cell(5102).quality:IsShown() and cell(5102).quality.atlas == "Quality-5102")
  event("GET_ITEM_INFO_RECEIVED", 5102, true)
  assert(iconCalls[5102] == 2 and qualityCalls[5102] == 3)
  window:Activate("Recipes")
  ready.profession = true
  event("TRADE_SKILL_LIST_UPDATE")
  assert(iconCalls[5103] == 1 and qualityCalls[5103] == 2)
  assert(cell(5103).quality:IsShown() and cell(5103).quality.atlas == "Quality-5103")
  assert(qualityCalls[5101] == 1 and qualityCalls[5102] == 3)
  assert(window.activeTab == "Recipes")
  window:Activate("Reagents")
  assert(queries == queriesBeforeEvent and list.items == items and list.scroll:GetVerticalScroll() == 45)
  assert(window.activeTab == "Reagents" and dropdown(page, "Most returned").value == "returned")
  page.searchInput:SetText("5102")
  page.searchInput.scripts.OnTextChanged(page.searchInput); page.searchInput.scripts.OnUpdate(page.searchInput, .3)
  assert(#list.items == 1 and cell(5102).icon.texture == "Icon-5102")
  assert(iconCalls[5102] == 2 and qualityCalls[5102] == 3)
  local visibleCell = cell(5102)
  event("GET_ITEM_INFO_RECEIVED", 5101, true)
  event("TRADE_SKILL_LIST_UPDATE")
  assert(visibleCell.icon.texture == "Icon-5102" and visibleCell.quality.atlas == "Quality-5102")
  assert(iconCalls[5101] == 1 and qualityCalls[5101] == 1 and qualityCalls[5103] == 2)
  page.searchInput:SetText("")
  page.searchInput.scripts.OnTextChanged(page.searchInput); page.searchInput.scripts.OnUpdate(page.searchInput, .3)
  assert(cell(5103).quality.atlas == "Quality-5103" and qualityCalls[5103] == 2)
  assert(core.Trace.Serialize(environment.ArtisanLogbookUISettings) == savedSettings)
  assert(core.Trace.Serialize(ledger.database) == savedFacts)
  environment.GetItemIcon, environment.C_TradeSkillUI.GetItemReagentQualityInfo = savedIcon, savedQuality
  api.GetReagentSummaries = savedSummaries
  window:Hide()
  print("PASS session reagent metadata reuse, delayed item/quality events, targeted row updates and no persistence")
end

do
  local core = reload(nil)
  local ledger, api = core.ledger, environment.ArtisanLogbookAPI
  ledger:AddDimension("profession", 171, { name = "Alchemy" })
  ledger:AddDimension("recipe", 9850, { name = "Test potion", professionId = 171, maxQuality = 3 })
  ledger:AddDimension("item", 5301, { name = "Bloom" })
  ledger:AddDimension("item", 5302, { name = "Potion" })
  ledger:SubmitCraft(9850, 1, true, nil, { { dataSlotIndex = 1, quantity = 10, reagent = { itemID = 5301 } } })
  local craft = assert(ledger:RecordResult({ operationID = 1, itemID = 5302, quantity = 4, craftingQuality = 2,
    multicraft = 1, concentrationSpent = 100, hasIngenuityProc = true, ingenuityRefund = 20,
    resourcesReturned = { { reagent = { itemID = 5301 }, quantity = 2 } } }))
  local ui = loadUI()
  local window = ui.productionWindow
  window:Show()
  local overview = window.pages.Overview
  while overview.topRecipes.worker.scripts.OnUpdate do overview.topRecipes.worker.scripts.OnUpdate(overview.topRecipes.worker) end
  assert(not overview.scroll and #overview.topRecipes.items == 1)
  local ranked = overview.topRecipes.items[1]
  assert(ranked.result.outputItem.id == 5302 and ranked.totals.outputQuantity == 4)
  assert(ui.UI.Rate(ranked.totals, "multicraftProcCount") == "100.0%")
  overview.summary.tiles[6].scripts.OnEnter(overview.summary.tiles[6])
  assert(environment.GameTooltip.itemId == 5302)
  overview.summary.tiles[6].scripts.OnClick()
  assert(window.activeTab == "Recipe" and window.identity.id == 9850)
  local recipe = window.pages.Recipe
  while recipe.outcomes.returnWorker.scripts.OnUpdate do recipe.outcomes.returnWorker.scripts.OnUpdate(recipe.outcomes.returnWorker) end
  assert(recipe.outcomes.production.averageOutput.text == "4")
  assert(recipe.outcomes.production.averageConcentration.text == "100")
  assert(recipe.outcomes.production.netConcentration.text == "80")
  assert(recipe.outcomes.tiles[6].note.text == "100.0% proc rate")
  assert(recipe.outcomes.tiles[4].note.text == "100.0% procs\n25.0% of output")
  assert(recipe.outcomes.tiles[4].note:GetStringHeight() <= recipe.outcomes.tiles[4].note:GetHeight())
  assert(-recipe.outcomes.tiles[4].note.y + recipe.outcomes.tiles[4].note:GetHeight() <= recipe.outcomes.summary:GetHeight())
  recipe.outcomes.qualityWorker.scripts.OnUpdate(recipe.outcomes.qualityWorker)
  assert(recipe.outcomes.qualityList.items[1].quality == 2 and recipe.outcomes.qualityList.items[1].quantity == 4)
  assert(recipe.outcomes.qualityTitle:IsShown())
  local from, to = ui.UI.Range(environment.GetServerTime(), 30)
  assert(recipe.outcomes.chart.start.text == os.date("!%d %b %Y", from))
  assert(recipe.outcomes.chart.finish.text == os.date("!%d %b %Y", to - 86400))
  recipe:SelectView("Reagents")
  local reagentRow = recipe.outcomes.materialList.rows[1]
  reagentRow.scripts.OnClick(reagentRow)
  assert(window.activeTab == "Reagent" and window.identity.id == 5301)
  local reagent = window.pages.Reagent
  reagent.iconHover.scripts.OnEnter(reagent.iconHover)
  assert(environment.GameTooltip.itemId == 5301)
  while reagent.worker.scripts.OnUpdate do reagent.worker.scripts.OnUpdate(reagent.worker) end
  assert(reagent.fields.rate.text == "20.0%" and #reagent.history.items == 1)
  reagent:SelectView("Craft History")
  reagent.history.rows[1].scripts.OnClick(reagent.history.rows[1])
  assert(window.openCraftId == craft.id and window.craftDetailPage.result.item.id == 5302)
  assert(not window.craftDetailPage.reagentSelector)
  window.craftDetailWindow:Hide()
  assert(window.activeTab == "Reagent" and reagent.activeView == "Craft History")
  reagent:SelectView("Used in Recipes")
  reagent.recipes.rows[1].scripts.OnClick(reagent.recipes.rows[1])
  assert(window.activeTab == "Recipe" and recipe.activeView == "Reagents")
  local character = api.GetCharacters()[1]
  for _, entry in ipairs({ { "Character", character }, { "Profession", { skillLineId = 171, name = "Alchemy" } } }) do
    window:Activate(entry[1], entry[2])
    local page = window.pages[entry[1]]
    assert(not page.scroll and page.tabbed and page.history)
    page.tabbed:Select("Craft History")
    assert(#page.history.items == 1 and page.history.items[1].id == craft.id)
    dropdown(page, "Custom dates"):Choose("custom")
    assert(page:Filter().time and page.filters:GetHeight() == 92)
  end
  local bar = reagent.filters.controls[1]
  local previousTime = environment.time
  environment.time = os.time
  window:Activate("Reagent", { id = 5301, name = "Bloom" })
  bar:Choose("custom")
  local oldFrom = reagent:Filter().time.from
  bar.inputs[1]:SetText("invalid")
  bar.inputs[1].scripts.OnEnterPressed(bar.inputs[1])
  assert(reagent:Filter().time.from == oldFrom)
  bar.inputs[1]:SetText("2024-02-29"); bar.inputs[2]:SetText("2024-02-29")
  bar.inputs[2].scripts.OnEnterPressed(bar.inputs[2])
  assert(reagent:Filter().time.to - reagent:Filter().time.from == 86400)
  environment.time = previousTime
  window:Hide()
  print("PASS shared entity navigation, enriched recipe analytics, inspect-only modal and custom periods")
  local parentWidth, parentHeight = environment.UIParent.width, environment.UIParent.height
  for _, dimensions in ipairs({ { 1000, 680 }, { 2560, 1440 } }) do
    environment.UIParent:SetSize(dimensions[1], dimensions[2])
    local compact = loadUI().productionWindow
    compact:Show()
    local bodyHeight = compact:GetHeight() - 64
    for _, destination in ipairs({ { "Overview" }, { "Logbook" }, { "Recipes" }, { "Reagents" },
        { "Recipe", { id = 9850 } }, { "Character", character },
        { "Profession", { skillLineId = 171, name = "Alchemy" } }, { "Reagent", { id = 5301, name = "Bloom" } } }) do
      compact:Activate(destination[1], destination[2])
      local page = compact.pages[destination[1]]
      assert(not page.scroll)
      local owner = page.outcomes or page
      dropdown(owner, "Custom dates"):Choose("custom")
      local filters = owner.filters
      for _, control in ipairs(filters.controls) do
        assert(control.middleWidth <= 141 and control.x + control:GetWidth() <= filters:GetWidth())
      end
      local summary = owner.summaryRow or owner.summary
      if summary and summary.tiles then
        assert(summary:GetHeight() <= 80)
        local previousRight = -16
        for _, tile in ipairs(summary.tiles) do
          assert(tile.y == 0 and tile.x >= previousRight + 16 - .01)
          assert(tile.x + tile:GetWidth() <= summary:GetWidth() + .01)
          assert(tile.title:GetWidth() > 64 and -tile.value.y + tile.value:GetHeight() <= summary:GetHeight())
          previousRight = tile.x + tile:GetWidth()
        end
      end
      if owner.tabbed then
        local tabbed = owner.tabbed
        local top = -tabbed.y + (page.outcomes and 62 or 0)
        assert(top + tabbed:GetHeight() <= bodyHeight)
        if owner.topRecipes then
          assert(-owner.topRecipes.y + owner.topRecipes:GetHeight() <= tabbed.views.Overview:GetHeight())
        end
        if destination[1] == "Reagent" then
          assert(-owner.status.y + owner.status:GetHeight() <= tabbed.views.Overview:GetHeight())
        end
      end
    end
    compact:Hide()
  end
  environment.UIParent.width, environment.UIParent.height = parentWidth, parentHeight
  print("PASS bounded filters and entity panels at short and tall window sizes")
end

do
  local core = reload(nil)
  local ledger = core.ledger
  local ui = loadUI()
  local window, helpers = ui.productionWindow, ui.UI
  local api = environment.ArtisanLogbookAPI
  environment.ArtisanLogbookUISettings.trivialReagents = {}
  local function record(result, recipeId)
    assert(ledger:SubmitCraft(recipeId or 9001, 1, false))
    return assert(ledger:RecordResult(result))
  end
  local first = record({ quantity = 5, multicraft = 0, concentrationSpent = 0,
    hasIngenuityProc = false, ingenuityRefund = 99, resourcesReturned = {} })
  local second = record({ quantity = 8, multicraft = 3, concentrationSpent = 20,
    hasIngenuityProc = true, ingenuityRefund = 12,
    resourcesReturned = { { reagent = { itemID = 8 }, quantity = 1 } } })
  record({ quantity = 5, multicraft = 0, concentrationSpent = 0, hasIngenuityProc = false,
    resourcesReturned = { { reagent = { itemID = 8 }, quantity = 2 }, { reagent = { itemID = 9 }, quantity = 3 } } })
  record({ quantity = 5, multicraft = 0, concentrationSpent = 0, hasIngenuityProc = false,
    resourcesReturned = { { reagent = { itemID = 9 }, quantity = 2 }, { reagent = { itemID = 10 }, quantity = 3 } } })
  assert(helpers.MeasuredShare(api.GetRecipeOutcomes(9001).totals, "multicraftBonus", "outputQuantity") == "13.0%")
  assert(helpers.MeasuredShare(api.GetRecipeOutcomes(9001).totals, "ingenuityRefund", "concentrationSpent") == "60.0%")
  record({})
  assert(helpers.MeasuredShare(api.GetRecipeOutcomes(9001).totals, "multicraftBonus", "outputQuantity") == "Unknown")
  assert(helpers.ProcRate(nil, 0) == "-")
  assert(helpers.ProcRate(0, 4) == "0.0%\n0 / 4 crafts")
  local screenshotTotals = {
    craftCount = 30, multicraftProcCount = 7, multicraftProcCountObservedCount = 30,
    multicraftBonus = 52, multicraftBonusObservedCount = 30, outputQuantity = 202, outputQuantityObservedCount = 30,
    ingenuityProcCount = 5, ingenuityProcCountObservedCount = 30, ingenuityRefund = 800, ingenuityRefundObservedCount = 30,
    concentrationSpent = 7130, concentrationSpentObservedCount = 30,
    resourcefulnessProcCount = 8, resourcefulnessProcCountObservedCount = 8,
    resourcefulnessCompleteProcCountObservedCount = 0,
  }
  local summary = helpers.ResourcefulnessSummary(screenshotTotals, 0)
  assert(summary.any == "At least 8 crafts returned reagents")
  assert(not summary.any:find("%%") and not summary.nonTrivial:find("%%"))
  assert(summary.nonTrivial == "-" and summary.complete:find("22 crafts have no return outcome", 1, true))
  local multi = helpers.CompactOutcome(screenshotTotals, "multicraftProcCount", "multicraftBonus", "outputQuantity", "Bonus", "of output")
  local ingenuity = helpers.CompactOutcome(screenshotTotals, "ingenuityProcCount", "ingenuityRefund", "concentrationSpent", "Refund", "of spent")
  assert(multi == "23.3% | 7 procs\nBonus: 52 | 25.7% of output")
  assert(ingenuity == "16.7% | 5 procs\nRefund: 800 | 11.2% of spent")
  screenshotTotals.resourcefulnessProcCountObservedCount = 30
  screenshotTotals.resourcefulnessCompleteProcCountObservedCount = 30
  screenshotTotals.resourcefulnessCompleteProcCount = 8
  summary = helpers.ResourcefulnessSummary(screenshotTotals, 4)
  assert(summary.any == "26.7% | 8 crafts" and summary.nonTrivial == "13.3% | 4 crafts")
  assert(summary.complete == "")
  screenshotTotals.resourcefulnessProcCount = 0
  summary = helpers.ResourcefulnessSummary(screenshotTotals, 0)
  assert(summary.any == "0.0% | 0 crafts")
  screenshotTotals.resourcefulnessProcCountObservedCount = 8
  screenshotTotals.resourcefulnessCompleteProcCountObservedCount = 8
  summary = helpers.ResourcefulnessSummary(screenshotTotals, 0)
  assert(summary.any == "-" and summary.nonTrivial == "-")
  assert(helpers.ResourcefulnessSummary({ craftCount = 0 }, 0).any == "No crafts")
  assert(ledger:AddDimension("item", 8, { name = "Tranquility Bloom" }))
  assert(ledger:AddDimension("item", 9, { name = "Tranquility Bloom" }))
  local oldQuality = environment.C_TradeSkillUI.GetItemReagentQualityInfo
  environment.C_TradeSkillUI.GetItemReagentQualityInfo = function(itemId)
    if itemId == 8 or itemId == 9 then return { icon = "ReagentQuality-" .. itemId } end
  end
  window:Show()
  window:Activate("Recipes")
  local oldSeries = api.GetCraftSeries
  api.GetCraftSeries = function() error("recipe UI requested unbounded daily rows") end
  window:OpenRecipe({ id = 9001, name = "Observed recipe" })
  local pane = window.recipeOutcomes
  assert(window.recipeDetailPage == window.pages.Recipe and window.recipeDetailPage:IsShown())
  assert(pane.filters:GetHeight() == 46 and window.pages.Recipe.scroll == nil)
  dropdown(pane, "Custom dates"):Choose("custom")
  assert(pane.filters:GetHeight() == 92 and pane.period.inputs[1].parent:IsShown())
  dropdown(pane, "All time"):Choose(false)
  assert(pane.filters:GetHeight() == 46 and not pane.period.inputs[1].parent:IsShown())
  assert(not window.modalShade:IsShown() and not window.craftDetailWindow:IsShown())
  local escapeJournal = false
  for _, frameName in ipairs(environment.UISpecialFrames) do
    if frameName == "ArtisanLogbookEscapeFrame" then escapeJournal = true end
  end
  assert(escapeJournal)
  local function finishCalculation()
    while pane.scripts.OnUpdate do pane.scripts.OnUpdate() end
    while pane.returnWorker.scripts.OnUpdate do pane.returnWorker.scripts.OnUpdate(pane.returnWorker) end
  end
  finishCalculation()
  assert(pane.tiles[5].value.text == "11" and pane.tiles[5].note.text == "")
  assert(pane.returnQuantity.text:find("11 reagents returned", 1, true))
  assert(pane.stats[2].text:find("At least 1 proc", 1, true) and pane.stats[4].text:find("12", 1, true))
  assert(pane.stats[3].text == "At least 3 crafts returned reagents" and not pane.stats[3].text:find("%%"))
  assert(pane.resourcefulness.nonTrivial.text == "Savings in at least 3 crafts")
  assert(pane.resourcefulness.complete.text:find("1 craft has no return outcome", 1, true))
  assert(pane.stats[2].text:find("craft has no proc result", 1, true))
  for _, labels in ipairs({ pane.stats, pane.resourcefulness }) do
    for _, label in pairs(labels) do
      for _, technical in ipairs({ "confirmed", "unknown", "observed", "coverage", "unclassified", "fully recorded" }) do
        assert(not label.text:lower():find(technical, 1, true))
      end
    end
  end
  local materialRows = pane.materialList.rows
  local material = materialRows[1].widgets[1].widget
  assert(material.label.text == materialRows[2].widgets[1].widget.label.text)
  assert(materialRows[1].item.item.id == 8 and materialRows[2].item.item.id == 9)
  assert(materialRows[1].item.returnedQuantity == 3 and materialRows[2].item.returnedQuantity == 5)
  local reagentCheck = materialRows[1].widgets[2].widget
  reagentCheck:SetChecked(true); reagentCheck.scripts.OnClick(reagentCheck)
  assert(helpers.IsTrivial(8))
  reagentCheck:SetChecked(false); reagentCheck.scripts.OnClick(reagentCheck)
  assert(not helpers.IsTrivial(8))
  assert(material.icon.texture and material.quality.atlas == "ReagentQuality-8")
  assert(materialRows[2].widgets[1].widget.quality.atlas == "ReagentQuality-9")
  assert(not materialRows[3].widgets[1].widget.quality:IsShown())
  assert(not pane.previous and not pane.next)
  environment.C_TradeSkillUI.GetItemReagentQualityInfo = nil
  pane:Refresh()
  assert(material.quality:IsShown() and materialRows[1].item.item.id == 8)
  environment.C_TradeSkillUI.GetItemReagentQualityInfo = oldQuality
  window.pages.Recipe:SelectView("Statistics")
  assert(pane.views.Statistics:IsShown() and not pane.views.Overview:IsShown())
  window.pages.Recipe:SelectView("Reagents")
  assert(pane.views.Reagents:IsShown() and not pane.views.Statistics:IsShown())
  local recipePage = window.visiblePage
  window:OpenCraft(second.id)
  local detail = window.visiblePage
  assert(window.craftDetailWindow.parent == window.modalShade and window.craftDetailWindow:IsShown())
  assert(window.recipeDetailPage:IsShown() and window.modalShade:IsShown())
  local checkbox
  for _, frame in ipairs(frames) do
    if frame.parent == detail and frame.kind == "CheckButton" then checkbox = frame end
  end
  assert(not checkbox and not detail.reagentSelector and not detail.scroll)
  helpers.SetTrivial(8, true)
  assert(helpers.IsTrivial(8))
  assert(detail.fields.Resourcefulness.text == "1 returned")
  assert(#detail.returnedReagents.items == 1 and detail.returnedReagents.items[1].item.id == 8)
  assert(detail.returnedReagents:GetHeight() >= 170 and detail.result)
  local getCraft = api.GetCraft
  api.GetCraft = function()
    local craft = getCraft(second.id)
    craft.reagents = {
      { item = { id = 8, name = "Bloom" }, allocatedQuantity = 8, returnedQuantity = 1 },
      { item = { id = 9, name = "Petal" }, allocatedQuantity = 2, returnedQuantity = 1 },
    }
    return craft
  end
  detail:ShowCraft(second.id)
  assert(#detail.returnedReagents.items == 2)
  assert(detail.fields.Resourcefulness.text == "2 returned (20.0% of used)")
  api.GetCraft = function()
    local craft = getCraft(second.id)
    craft.resourcefulnessComplete = false
    craft.reagents = { { item = { id = 8 }, returnedQuantity = 3 } }
    return craft
  end
  detail:ShowCraft(second.id)
  assert(detail.fields.Resourcefulness.text == ">= 3 returned")
  api.GetCraft = function()
    local craft = getCraft(second.id)
    craft.reagents = {}
    for index = 1, 8 do
      craft.reagents[index] = { item = { id = index }, allocatedQuantity = 2, returnedQuantity = 1 }
    end
    return craft
  end
  detail:ShowCraft(second.id)
  assert(#detail.returnedReagents.items == 8 and detail.returnedReagents:GetHeight() >= 170)
  assert(detail.returnedReagents.child:GetHeight() > detail.returnedReagents.scroll:GetHeight())
  api.GetCraft = function()
    local craft = getCraft(second.id)
    craft.reagents = {}
    craft.outputItem = { id = 4567, name = "Flask" }
    return craft
  end
  detail:ShowCraft(second.id)
  assert(not detail.reagentSelector and not checkbox)
  assert(detail.returnedReagents.child:GetHeight() == detail.returnedReagents.scroll:GetHeight())
  assert(detail.result.item.id == 4567 and detail.result.label.text == "Flask")
  api.GetCraft = getCraft
  button(detail, "Close").scripts.OnClick()
  finishCalculation()
  assert(window.visiblePage == recipePage, "craft close did not restore recipe page")
  assert(window.recipeDetailPage:IsShown() and not window.craftDetailWindow:IsShown() and not window.modalShade:IsShown())
  assert(pane.resourcefulness.nonTrivial.text == "Savings in at least 2 crafts",
    "unexpected non-trivial summary: " .. tostring(pane.resourcefulness.nonTrivial.text))
  helpers.SetTrivial(9, true)
  finishCalculation()
  assert(pane.resourcefulness.nonTrivial.text == "Savings in at least 1 craft")
  helpers.SetTrivial(10, true); pane:Refresh(); finishCalculation()
  assert(pane.resourcefulness.nonTrivial.text == "-")
  helpers.SetTrivial(9, false); pane:Refresh(); finishCalculation()
  assert(pane.resourcefulness.nonTrivial.text == "Savings in at least 2 crafts")
  local settings = environment.ArtisanLogbookUISettings
  local anotherUI = loadUI()
  assert(anotherUI.UI.IsTrivial(8) and anotherUI.UI.IsTrivial(10) and not anotherUI.UI.IsTrivial(9))
  assert(environment.ArtisanLogbookUISettings == settings and ledger.database.trivialReagents == nil)
  assert(api.SetTrivial == nil and environment.ArtisanLogbookManagement.SetTrivial == nil)
  local timeFunction = environment.time
  environment.time = os.time
  assert(helpers.ParseUTCDate("2024-02-29") and not helpers.ParseUTCDate("2025-02-29"))
  assert(not helpers.ParseUTCDate("2026-13-01") and not helpers.ParseUTCDate("invalid"))
  environment.time = timeFunction
  local otherSession = assert(ledger:CreateSession({ characterName = "Second outcome crafter" }))
  record({ resourcesReturned = {} })
  pane:Open(9001)
  finishCalculation()
  local chosen
  for _, entry in ipairs(api.GetCharacters()) do if entry.name == "Second outcome crafter" then chosen = entry.key end end
  dropdown(pane, "Second outcome crafter"):Choose(chosen)
  assert(pane.stats[1].text == "1" and pane.stats[3].text:find("0.0%%"))
  dropdown(pane, "All"):Choose(false)
  assert(pane.stats[1].text == "6")
  ledger.wall = function() return 1800000000 + 61 * 86400 end
  ledger:Prune(ledger.wall())
  assert(#ledger.database.crafts == 0)
  pane:Refresh()
  finishCalculation()
  assert(pane.stats[1].text == "6" and pane.resourcefulness.nonTrivial.text == "Savings in at least 2 crafts")
  for index = 1, 205 do
    record({ resourcesReturned = { { reagent = { itemID = 1000 + index }, quantity = 1 } } }, 9002)
  end
  local oldSets, pages = api.GetRecipeReturnSets, 0
  api.GetRecipeReturnSets = function(...)
    pages = pages + 1
    return oldSets(...)
  end
  window:OpenRecipe({ id = 9002 })
  assert(pane.production.netConcentration.text == "-")
  pages = 0
  dropdown(pane, "All time"):Choose(false)
  assert(pages == 1 and pane.scripts.OnUpdate and pane.resourcefulness.nonTrivial.text:find("Calculating", 1, true))
  pane.scripts.OnUpdate()
  assert(pages == 2 and pane.scripts.OnUpdate)
  pane.scripts.OnUpdate()
  assert(pages == 3 and pane.scripts.OnUpdate)
  finishCalculation()
  assert(pane.scripts.OnUpdate == nil and pane.resourcefulness.nonTrivial.text:find("100.0%%"))
  pane.materialList:LoadNext()
  assert(#pane.materialList.items == 80)
  local secondPageItem = pane.materialList.items[41].item.id
  pane.materialList.scroll:SetVerticalScroll(1200)
  helpers.SetTrivial(secondPageItem, true)
  finishCalculation()
  while pane.materialList.scripts.OnUpdate do pane.materialList.scripts.OnUpdate(pane.materialList) end
  assert(pane.materialList.items[41].item.id == secondPageItem and pane.materialList.scroll:GetVerticalScroll() == 1200)
  assert(pane.materialList.items[1].item.id == 1001)
  assert(#pane.chart.bars <= 60)
  window:OpenRecipe({ id = 9001, name = "Observed recipe" })
  dropdown(pane, "7 days"):Choose(7)
  window.pages.Recipe:SelectView("Craft History")
  window.pages.Recipe.history.scroll:SetVerticalScroll(60)
  assert(window.pages.Recipe.scroll == nil)
  window:OpenRecipe({ id = 9002 })
  assert(dropdown(pane, "All time").value == false)
  assert(window.pages.Recipe.activeView == "Overview")
  window:OpenRecipe({ id = 9001 })
  assert(dropdown(pane, "7 days").value == 7)
  assert(window.pages.Recipe.activeView == "Craft History" and pane.views["Craft History"]:IsShown())
  assert(window.pages.Recipe.history.scroll:GetVerticalScroll() == 60)
  window:OpenCraft(second.id)
  window.craftDetailWindow:Hide()
  assert(window.pages.Recipe.activeView == "Craft History")
  assert(window.pages.Recipe.history.scroll:GetVerticalScroll() == 60)
  print("PASS recipe-local views and filters, per-recipe state, durable returned quantities and guarded allocation ratios")
  assert(environment.ArtisanLogbookManagement.Clear())
  assert(helpers.IsTrivial(8) and helpers.IsTrivial(10))
  api.GetCraftSeries, api.GetRecipeReturnSets = oldSeries, oldSets
  window:Hide()
  window.scripts.OnHide(window)
  assert(not window.craftDetailWindow:IsShown() and not window.modalShade:IsShown())
  print("PASS recipe outcomes, exact denominators, reversible UI preferences, pruning and bounded rendering")
end

do
  local core = reload(nil)
  local ledger = core.ledger
  assert(ledger:SubmitCraft(9001, 1, false, nil, {
    { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 8 } },
    { dataSlotIndex = 2, quantity = 2, reagent = { itemID = 9 } },
  }))
  assert(ledger:RecordResult({ resourcesReturned = {
    { reagent = { itemID = 8 }, quantity = 1 }, { reagent = { itemID = 9 } },
  } }))
  for index = 2, 30 do
    assert(ledger:SubmitCraft(9001, 1, false, nil, {
      { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 8 } },
    }))
    assert(ledger:RecordResult({ resourcesReturned = index <= 8 and
      { { reagent = { itemID = 8 }, quantity = 1 } } or {} }))
  end
  local data = ledger.database
  data.outcomeVersion, data.resourcefulnessSets, data.returnedReagents = nil, nil, nil
  for _, craft in ipairs(data.crafts) do craft.hasResourcefulnessProc, craft.resourcefulnessComplete = nil, nil end
  for _, row in ipairs(data.craftSeries) do
    for _, metric in ipairs({ "multicraftProcCount", "resourcefulnessProcCount", "resourcefulnessCompleteProcCount" }) do
      row[metric], row[metric .. "ObservedCount"] = nil, nil
    end
  end
  core = reload(data)
  local ui = loadUI()
  ui.UI.SetTrivial(8, true)
  ui.productionWindow:Activate("Recipes")
  ui.productionWindow:OpenRecipe({ id = 9001 })
  while ui.productionWindow.recipeOutcomes.scripts.OnUpdate do
    ui.productionWindow.recipeOutcomes.scripts.OnUpdate()
  end
  local text = ui.productionWindow.recipeOutcomes.stats[3].text
  assert(text == "At least 8 crafts returned reagents" and not text:find("%%"))
  assert(ui.productionWindow.recipeOutcomes.resourcefulness.complete.text:find("22 crafts have no return outcome", 1, true))
  assert(ui.productionWindow.recipeOutcomes.resourcefulness.nonTrivial.text == "-")
  ui.UI.SetTrivial(8, false)
  ui.productionWindow.recipeOutcomes:Refresh()
  while ui.productionWindow.recipeOutcomes.scripts.OnUpdate do
    ui.productionWindow.recipeOutcomes.scripts.OnUpdate()
  end
  assert(ui.productionWindow.recipeOutcomes.resourcefulness.nonTrivial.text == "Savings in at least 8 crafts")
  print("PASS legacy incomplete positive sets never become measured non-trivial false")
end

local invalidTrace = { traceSchemaVersion = 999 }
environment.ArtisanLogbookTraceDB = invalidTrace
local noTracer = reload(nil)
assert(noTracer.ledger and noTracer.recorder == nil and not noTracer.productionWindow)
local noTracerUI = loadUI()
environment.SlashCmdList.ARTISANLOGBOOK("")
assert(noTracerUI.productionWindow:IsShown() and environment.ArtisanLogbookTraceDB == invalidTrace)
local restoredLauncher
for _, frame in ipairs(frames) do
  if frame.name == "ArtisanLogbookButton" then restoredLauncher = frame end
end
assert(math.abs(restoredLauncher.x - 72) < .01 and math.abs(restoredLauncher.y) < .01)
print("PASS production UI remains available when diagnostic trace storage is refused")

environment.ArtisanLogbookTraceDB = nil
local enriched = reload(nil)
local enrichedApi = environment.ArtisanLogbookAPI
local enrichedCommits = {}
enrichedApi.RegisterCallback("CRAFT_COMMITTED", function(craft)
  enrichedCommits[#enrichedCommits + 1] = craft
end)
environment.C_TradeSkillUI.GetRecipeInfo = function() error("recipe cache unavailable") end
environment.C_TradeSkillUI.GetProfessionInfoByRecipeID = function() return nil end
enriched.HandleRetailEvent("TRADE_SKILL_CRAFT_BEGIN", 1230869)
enriched.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", {
  operationID = 100, itemID = 212345, quantity = 2,
  resourcesReturned = { { reagent = { itemID = 212346 }, quantity = 1 } },
})
local data = enriched.ledger.database
local characterKey = enrichedApi.GetCharacters()[1].key
assert(rowCount(data.dimensions.recipes) == 1 and rowCount(data.dimensions.items) == 2)
assert(data.dimensions.recipes[1230869].name == nil and rowCount(data.dimensions.professions) == 0)
assert(#enrichedApi.GetCrafts({ professions = { 171 } }).crafts == 0)
environment.C_TradeSkillUI.GetRecipeInfo = function(id)
  assert(id == 1230869)
  return { recipeID = id, name = "Midnight Potion", categoryID = 81,
    supportsQualities = true, maxQuality = 3 }
end
environment.C_TradeSkillUI.GetProfessionInfoByRecipeID = function(id)
  assert(id == 1230869)
  return { professionID = 2871, professionName = "Midnight Alchemy",
    parentProfessionID = 171, parentProfessionName = "Alchemy", expansionName = "Unknown" }
end
environment.C_TradeSkillUI.GetProfessionInfoBySkillLineID = function(id)
  assert(id == 2871)
  return { professionID = id, parentProfessionID = 171, expansionName = "Unknown" }
end
environment.C_TradeSkillUI.GetAllRecipeIDs = function() return { 1230869 } end
local itemCacheReady = false
environment.GetItemInfo = function(id)
  if not itemCacheReady then return nil end
  if id == 212345 then return "Midnight Potion" end
  if id == 212346 then return "Test Reagent" end
end
enriched.adapter.frame.scripts.OnEvent(enriched.adapter.frame, "TRADE_SKILL_SHOW")
assert(data.dimensions.items[212345].name == nil)
itemCacheReady = true
enriched.adapter.frame.scripts.OnEvent(enriched.adapter.frame, "GET_ITEM_INFO_RECEIVED", 999999, true)
enriched.adapter.frame.scripts.OnEvent(enriched.adapter.frame, "GET_ITEM_INFO_RECEIVED", 212345, true)
enriched.adapter.frame.scripts.OnEvent(enriched.adapter.frame, "GET_ITEM_INFO_RECEIVED", 212346, true)
enriched.adapter.frame.scripts.OnEvent(enriched.adapter.frame, "TRADE_SKILL_SHOW")
assert(enriched.adapter.capabilities.events.GET_ITEM_INFO_RECEIVED)
assert(rowCount(data.dimensions.recipes) == 1 and rowCount(data.dimensions.items) == 2)
assert(rowCount(data.dimensions.professions) == 1 and #data.dimensions.expansions == 0)
assert(data.dimensions.recipes[1230869].professionId == 171 and data.dimensions.professions[171].id == 171)
assert(data.dimensions.recipes[1230869].maxQuality == 3)
assert(enrichedApi.GetCharacters()[1].classFile == "MAGE")
assert(enrichedApi.GetCraft(1).recipe.maxQuality == 3)
assert(data.dimensions.items[212345].name == "Midnight Potion")
assert(data.dimensions.items[212346].name == "Test Reagent")
assert(enrichedApi.GetCrafts({ professions = { 171 } }).crafts[1].outputItem.name == "Midnight Potion")
assert(enrichedApi.GetCraftSeries({ professions = { 171 } }).series[1].craftCount == 1)
assert(enrichedApi.GetProfessions(characterKey)[1].name == "Alchemy")
assert(enrichedApi.GetRecipeSummaries().recipes[1].recipe.name == "Midnight Potion")
assert(enrichedApi.GetFacets(nil, { facets = { "professions" } }).professions[1].value == 171)
local historicalCraft, historicalSeries = data.crafts[1], data.craftSeries[1]
environment.C_TradeSkillUI.GetProfessionInfoBySkillLineID = function(id)
  assert(id == 2871)
  return { professionID = id, parentProfessionID = 999, expansionName = "Midnight" }
end
enriched.HandleRetailEvent("TRADE_SKILL_CLOSE")
enriched.adapter.frame.scripts.OnEvent(enriched.adapter.frame, "TRADE_SKILL_SHOW")
assert(#data.dimensions.expansions == 0)
environment.C_TradeSkillUI.GetProfessionInfoBySkillLineID = function(id)
  assert(id == 2871)
  return { professionID = id, expansionName = "Midnight" }
end
enriched.HandleRetailEvent("TRADE_SKILL_CLOSE")
enriched.adapter.frame.scripts.OnEvent(enriched.adapter.frame, "TRADE_SKILL_SHOW")
assert(data.crafts[1] == historicalCraft and data.craftSeries[1] == historicalSeries)
assert(data.dimensions.expansions[1].key == "skillLine:2871" and
  data.dimensions.recipes[1230869].expansionDimensionId == 1)
assert(enrichedApi.GetCraft(1).recipe.expansion.name == "Midnight")
assert(enrichedApi.GetCraftSeries().series[1].recipe.expansion.name == "Midnight")
assert(#enrichedApi.GetCrafts({ expansions = { "skillLine:2871" } }).crafts == 1)
enriched.HandleRetailEvent("TRADE_SKILL_CRAFT_BEGIN", 1230869)
enriched.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 102, itemID = 212345 })
assert(enrichedCommits[#enrichedCommits].outputItem.name == "Midnight Potion")
assert(rowCount(data.dimensions.recipes) == 1 and rowCount(data.dimensions.items) == 2 and
  rowCount(data.dimensions.professions) == 1)
local restored = reload(data)
assert(restored.ledger and #environment.ArtisanLogbookAPI.GetCraftSeries({ professions = { 171 } }).series == 1)
assert(rowCount(restored.ledger.database.dimensions.recipes) == 1)
assert(environment.ArtisanLogbookAPI.GetCraft(1).recipe.expansion.name == "Midnight")
assert(restored.ledger:SubmitCraft(1230869, 1, false, nil,
  { { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 212346 } } }))
assert(restored.ledger:RecordResult({ operationID = 103, itemID = 212345, resourcesReturned = {} }))
assert(#restored.ledger.database.requests == 1 and #restored.ledger.database.reagents == 2)
print("PASS delayed Retail metadata enriches historical facts, indexes, series and reload")

local oldRecipeInfo = environment.C_TradeSkillUI.GetRecipeInfo
local oldProfessionInfo = environment.C_TradeSkillUI.GetProfessionInfoByRecipeID
local oldRecipeIds = environment.C_TradeSkillUI.GetAllRecipeIDs
local oldSchematic = environment.C_TradeSkillUI.GetRecipeSchematic
local oldChanging = environment.C_TradeSkillUI.IsDataSourceChanging
local outputsCore = reload(nil)
for recipeId = 7001, 7005 do outputsCore.ledger:AddDimension("recipe", recipeId) end
assert(outputsCore.adapter.frame:IsEventRegistered("TRADE_SKILL_LIST_UPDATE"))
for index, outputItemId in ipairs({ 8101, 8102, 8104, 8105 }) do
  outputsCore.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", {
    operationID = 400 + index, itemID = outputItemId,
  })
end
environment.C_TradeSkillUI.GetAllRecipeIDs = function() return { 7001, 7002, 7003, 7004, 7005 } end
environment.C_TradeSkillUI.GetRecipeInfo = function(id) return { recipeID = id } end
environment.C_TradeSkillUI.GetProfessionInfoByRecipeID = function() return nil end
local retryOutputReady = false
environment.C_TradeSkillUI.GetRecipeSchematic = function(id, isRecraft)
  assert(isRecraft == false)
  if id == 7001 then return { recipeID = id, outputItemID = 8101 } end
  if id == 7002 then return { recipeID = id, outputItemID = 8102 } end
  if id == 7003 then return { recipeID = id, outputItemID = 8101 } end
  if id == 7004 and retryOutputReady then return { recipeID = id, outputItemID = 8104 } end
  if id == 7005 then return { recipeID = 7999, outputItemID = 8105 } end
  return { recipeID = id }
end
environment.C_TradeSkillUI.IsDataSourceChanging = function() return false end
local knowledgeChangesByOutput, targetedRepairsByOutput = {}, {}
local onKnowledgeChanged = outputsCore.OnRecipeOutputKnowledgeChanged
outputsCore.OnRecipeOutputKnowledgeChanged = function(ledger, outputItemId, source, deferRepair)
  local candidates = 0
  for _ in pairs(ledger.recipeIdsByOutputItemId[outputItemId] or {}) do
    candidates = candidates + 1
  end
  knowledgeChangesByOutput[outputItemId] =
    (knowledgeChangesByOutput[outputItemId] or 0) + 1
  assert(outputItemId ~= 8101 or candidates == 2)
  return onKnowledgeChanged(ledger, outputItemId, source, deferRepair)
end
local repairUnknownRecipes = outputsCore.ledger.RepairUnknownRecipes
outputsCore.ledger.RepairUnknownRecipes = function(ledger, outputFilter)
  for outputItemId in pairs(outputFilter or {}) do targetedRepairsByOutput[outputItemId] = true end
  return repairUnknownRecipes(ledger, outputFilter)
end
outputsCore.HandleRetailEvent("TRADE_SKILL_SHOW")
assert(outputsCore.ledger.database.recipeOutputs[7001][8101] == true and
  outputsCore.ledger.database.recipeOutputs[7003][8101] == true)
assert(outputsCore.ledger.recipeOutputCount == 3)
assert(outputsCore.ledger.unknownRecipeCount == 3)
assert(outputsCore.ledger.craftById[2].recipeId == 7002)
assert(outputsCore.ledger.craftById[1].recipeId == nil and
  outputsCore.ledger.craftById[3].recipeId == nil and
  outputsCore.ledger.craftById[4].recipeId == nil)
assert(outputsCore.ledger.database.recipeOutputs[7005] == nil)
assert(knowledgeChangesByOutput[8101] == 1)
assert(targetedRepairsByOutput[8101] == nil and targetedRepairsByOutput[8102] == true)

retryOutputReady = true
environment.C_TradeSkillUI.IsDataSourceChanging = function() return true end
outputsCore.HandleRetailEvent("TRADE_SKILL_LIST_UPDATE")
assert(outputsCore.ledger.unknownRecipeCount == 3)
environment.C_TradeSkillUI.IsDataSourceChanging = function() return false end
outputsCore.HandleRetailEvent("TRADE_SKILL_LIST_UPDATE")
assert(outputsCore.ledger.database.recipeOutputs[7004][8104] == true)
assert(outputsCore.ledger.craftById[3].recipeId == 7004)
assert(outputsCore.ledger.craftById[1].recipeId == nil and
  outputsCore.ledger.craftById[4].recipeId == nil and
  outputsCore.ledger.unknownRecipeCount == 2)
assert(outputsCore.ledger.recipeIdsByOutputItemId[8101][7001] == true and
  outputsCore.ledger.recipeIdsByOutputItemId[8101][7003] == true)
environment.C_TradeSkillUI.GetRecipeInfo = oldRecipeInfo
environment.C_TradeSkillUI.GetProfessionInfoByRecipeID = oldProfessionInfo
environment.C_TradeSkillUI.GetAllRecipeIDs = oldRecipeIds
environment.C_TradeSkillUI.GetRecipeSchematic = oldSchematic
environment.C_TradeSkillUI.IsDataSourceChanging = oldChanging
print("PASS Retail output batch exposes shared ambiguity before targeted repair")
restored = reload(restored.ledger.database)

local traceDatabase = restored.recorder.database
restored.recorder:Start({})
restored.recorder:Capture("TRACE_MARK", "keep")
restored.recorder:Stop()
local traceCount = #traceDatabase.records
local function traceButton(text)
  for _, frame in ipairs(frames) do
    if frame.parent == restored.window and frame.kind == "Button" and frame.text == text then
      return frame
    end
  end
  error("Missing trace button: " .. text)
end
traceButton("Purge Logbook DB").scripts.OnClick()
assert(environment.popup == "ARTISANLOGBOOK_PURGE_LOGBOOK_DB")
assert(#restored.ledger.database.crafts == 3)
local popup = environment.StaticPopupDialogs.ARTISANLOGBOOK_PURGE_LOGBOOK_DB
assert(popup.button2 == "Cancel" and popup.text:find("cannot be undone", 1, true))
assert(#restored.ledger.database.crafts == 3)
popup.OnAccept()
local clean = restored.ledger.database
assert(environment.ArtisanLogbookDB == clean)
for _, collection in ipairs({ "crafts", "requests", "reagents", "craftSeries" }) do
  assert(#clean[collection] == 0)
end
for _, collection in ipairs({ "recipes", "items", "professions", "expansions" }) do
  assert(rowCount(clean.dimensions[collection]) == 0)
end
assert(#clean.dimensions.sessions == 1 and #clean.dimensions.characters == 1 and
  #clean.dimensions.realms == 1)
assert(clean.nextCraftId == 1 and clean.nextRequestId == 1 and clean.nextDimensionId.recipe == nil)
assert(#traceDatabase.records == traceCount and environment.ArtisanLogbookTraceDB == traceDatabase)
assert(#environment.ArtisanLogbookAPI.GetCrafts().crafts == 0)
assert(#environment.ArtisanLogbookAPI.GetCraftSeries().series == 0)
assert(#environment.ArtisanLogbookAPI.GetRecipeSummaries().recipes == 0)
assert(#environment.ArtisanLogbookAPI.GetCharacters() == 0 and
  #environment.ArtisanLogbookAPI.GetProfessions() == 0)
restored.HandleRetailEvent("TRADE_SKILL_CRAFT_BEGIN", 1230869)
restored.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 101, itemID = 212345 })
assert(#clean.crafts == 1 and clean.crafts[1].id == 1)
assert(clean.crafts[1].sessionId == clean.dimensions.sessions[1].id)
assert(#environment.ArtisanLogbookAPI.GetCrafts({ professions = { 171 } }).crafts == 1)
print("PASS confirmed full ledger purge preserves trace and supports immediate recapture")

local reagentRuntime = reload(data)
local reagentApi = environment.ArtisanLogbookAPI
local itemLookups = {}
local cacheReady = false
environment.GetItemInfo = function(id)
  itemLookups[id] = (itemLookups[id] or 0) + 1
  if id == 240991 then return "Cached Herb" end
  if id == 240992 then return cacheReady and "Delayed Herb" or nil end
  if id == 236761 then
    if not cacheReady then error("item cache unavailable") end
    return "Returned Herb"
  end
end
reagentRuntime.SubmitCraft(1230869, 1, false, nil, {
  { dataSlotIndex = 1, quantity = 2, reagent = { itemID = 240991 } },
  { dataSlotIndex = 2, quantity = 1, reagent = { itemID = 240992 } },
})
assert(reagentRuntime.ledger.database.dimensions.items[240991].name == "Cached Herb")
assert(reagentRuntime.ledger.database.dimensions.items[240992].name == nil)
reagentRuntime.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", {
  operationID = 203, itemID = 212345, resourcesReturned = {
    { reagent = { itemID = 236761 }, quantity = 1 },
  },
})
local reagentData = reagentRuntime.ledger.database
local reagentCraft = reagentData.crafts[#reagentData.crafts]
local reagentSeries = reagentData.craftSeries[1]
local detail = reagentApi.GetCraft(reagentCraft.id)
assert(detail.reagents[1].item.name == "Cached Herb")
assert(detail.reagents[2].item.id == 240992 and detail.reagents[2].item.name == nil)
assert(detail.reagents[3].item.id == 236761 and detail.reagents[3].item.name == nil)
assert(#reagentData.crafts == 3 and #reagentData.reagents == 4)
local lookupCount = itemLookups[240992]
reagentRuntime.HandleRetailEvent("GET_ITEM_INFO_RECEIVED", 999999, true)
reagentRuntime.HandleRetailEvent("GET_ITEM_INFO_RECEIVED", 240992, false)
assert(itemLookups[240992] == lookupCount and itemLookups[999999] == nil)
cacheReady = true
reagentRuntime.HandleRetailEvent("GET_ITEM_INFO_RECEIVED", 240992, true)
reagentRuntime.HandleRetailEvent("GET_ITEM_INFO_RECEIVED", 236761, true)
reagentRuntime.HandleRetailEvent("GET_ITEM_INFO_RECEIVED", 240991, true)
assert(itemLookups[240991] == 2)
detail = reagentApi.GetCraft(reagentCraft.id)
assert(detail.reagents[2].item.name == "Delayed Herb" and
  detail.reagents[3].item.name == "Returned Herb")
assert(reagentData.crafts[#reagentData.crafts] == reagentCraft and reagentData.craftSeries[1] == reagentSeries)
local reagentReload = reload(reagentData)
assert(reagentReload.ledger and environment.ArtisanLogbookAPI.GetCraft(reagentCraft.id).reagents[3].item.name ==
  "Returned Herb")
print("PASS selected and returned reagent names enrich without altering captured facts")

local refusedData = { schemaVersion = 1, schemaIdentity = "ArtisanLogbookLedger",
  dimensions = { recipes = { { id = 1230869, key = "old-layout" } } } }
local refusedRuntime = reload(refusedData)
local preservedTrace = environment.ArtisanLogbookTraceDB
assert(not refusedRuntime.ledger and refusedRuntime.ledgerError)
assert(environment.ArtisanLogbookDB == refusedData and refusedRuntime.recorder.database == preservedTrace)
local refusedApi = environment.ArtisanLogbookAPI
assert(refusedApi.GetCrafts() == nil and environment.ArtisanLogbookManagement.Status() == nil)
local savedBuildInfo = environment.GetBuildInfo
environment.GetBuildInfo = function() error("runtime build unavailable") end
local purgeDialog = environment.StaticPopupDialogs.ARTISANLOGBOOK_PURGE_LOGBOOK_DB
assert(purgeDialog.button2 == "Cancel")
purgeDialog.OnAccept()
assert(not refusedRuntime.ledger and refusedRuntime.ledgerError:find("runtime build unavailable", 1, true))
assert(environment.ArtisanLogbookDB == refusedData and environment.ArtisanLogbookTraceDB == preservedTrace)
assert(notices[#notices]:find("Logbook DB purge failed:", 1, true))
environment.GetBuildInfo = savedBuildInfo
local savedWall = environment.GetServerTime
environment.GetServerTime = function() return 1800000123 end
purgeDialog.OnAccept()
environment.GetServerTime = savedWall
assert(refusedRuntime.ledger and not refusedRuntime.ledgerError and not refusedRuntime.ledgerCaptureError)
assert(environment.ArtisanLogbookDB == refusedRuntime.ledger.database and
  environment.ArtisanLogbookTraceDB == preservedTrace)
assert(#refusedRuntime.ledger.database.dimensions.sessions == 1 and
  #refusedRuntime.ledger.database.dimensions.characters == 1 and
  #refusedRuntime.ledger.database.dimensions.realms == 1)
assert(refusedRuntime.ledger.database.dimensions.sessions[1].startedAt == 1800000123)
assert(refusedRuntime.ledger.database.schemaVersion == 1 and refusedData.dimensions.recipes[1].key ==
  "old-layout")
assert(#refusedApi.GetCrafts().crafts == 0 and environment.ArtisanLogbookManagement.Status().retainedCrafts == 0)
refusedRuntime.HandleRetailEvent("TRADE_SKILL_CRAFT_BEGIN", 1230869)
refusedRuntime.HandleRetailEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", { operationID = 302, itemID = 212345 })
assert(#refusedApi.GetCrafts().crafts == 1 and not refusedRuntime.ledgerCaptureError)
assert(environment.ArtisanLogbookTraceDB == preservedTrace)
print("PASS confirmed debug purge recovers refused schema without touching trace")

local oldData = data
oldData.dimensions.characters[1].classFile = nil
oldData.dimensions.recipes[1230869].maxQuality = nil
environment.UnitClass = function() return nil, nil end
environment.C_TradeSkillUI.GetRecipeInfo = function() return nil end
local oldCore = reload(oldData)
assert(oldCore.ledger and oldCore.ledger.database.schemaVersion == 1)
assert(oldCore.ledger.database.dimensions.characters[1].classFile == nil)
assert(oldCore.ledger.database.dimensions.recipes[1230869].maxQuality == nil)
environment.UnitClass = function() return "Mage", "MAGE", 8 end
environment.C_TradeSkillUI.GetRecipeInfo = function(id)
  return { recipeID = id, name = "Midnight Potion", supportsQualities = true, maxQuality = 3 }
end
local upgraded = reload(oldCore.ledger.database)
local savedRecipeRow = upgraded.ledger.database.dimensions.recipes[1230869]
assert(upgraded.ledger.database.dimensions.characters[1].classFile == "MAGE")
upgraded.HandleRetailEvent("TRADE_SKILL_SHOW")
assert(upgraded.ledger.database.dimensions.recipes[1230869] == savedRecipeRow)
assert(savedRecipeRow.maxQuality == 3 and upgraded.ledger.database.schemaVersion == 1)
local reloaded = reload(upgraded.ledger.database)
assert(reloaded.ledger.database.dimensions.characters[1].classFile == "MAGE")
assert(reloaded.ledger.database.dimensions.recipes[1230869].maxQuality == 3)
assert(environment.ArtisanLogbookAPI.GetCrafts().crafts[1].recipe.maxQuality == 3)
print("PASS optional schema-v1 class and quality enrichment reuses historical dimensions across reload")
