local _, addon = ...
local UI = addon.UI
local API = ArtisanLogbookAPI
local management = ArtisanLogbookManagement

local function shell(name, title, parent, width, height)
  local frame = CreateFrame("Frame", name, parent, "BasicFrameTemplateWithInset")
  frame:SetSize(width, height)
  frame:SetPoint("CENTER")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetToplevel(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetScript("OnMouseDown", function(self) self:Raise() end)
  frame.TitleText:SetText(title)
  return frame
end

function addon.CreateProductionWindow()
  local width = math.max(960, math.min(1100, UIParent:GetWidth() - 40))
  local height = math.max(640, math.min(780, UIParent:GetHeight() - 40))
  local scale = math.min(1, (UIParent:GetWidth() - 24) / width, (UIParent:GetHeight() - 24) / height)
  local window = shell("ArtisanLogbookWindow", "Artisan Logbook", UIParent, width, height)
  addon.productionWindow = window
  window:SetScale(scale)
  window:SetFrameStrata("DIALOG")
  local sideWidth, inner, bodyHeight = 180, width - 228, height - 64
  local sidebar = CreateFrame("Frame", nil, window)
  sidebar:SetPoint("TOPLEFT", 8, -30)
  sidebar:SetSize(sideWidth, height - 38)
  UI.Surface(sidebar, false)
  local paper = CreateFrame("Frame", nil, window)
  paper:SetPoint("TOPLEFT", 194, -30)
  paper:SetSize(width - 202, height - 38)
  UI.Surface(paper, true)
  local body = CreateFrame("Frame", nil, paper)
  body:SetPoint("TOPLEFT", 14, -16)
  body:SetSize(inner, bodyHeight)
  local pages = {}
  for _, name in ipairs({ "Overview", "Logbook", "Recipes", "Reagents", "Character", "Profession", "Recipe", "Settings" }) do
    pages[name] = CreateFrame("Frame", nil, body)
    pages[name]:SetAllPoints(body)
    pages[name]:Hide()
  end
  window.pages, window.activeTab = pages, "Overview"
  local navContent, navScroll = UI.PageScroll(sidebar, sideWidth - 4, height - 86, height - 86)
  navScroll:ClearAllPoints(); navScroll:SetPoint("TOPLEFT", 2, -8)
  window.sidebar, window.sidebarScroll, window.navItems = sidebar, navScroll, {}
  local headings = {}
  local settingsNav = UI.NavItem(sidebar, sideWidth - 8, function() window:Activate("Settings") end)
  settingsNav:SetPoint("BOTTOMLEFT", 4, 4)
  window.settingsNav = settingsNav

  function window:RefreshSidebar()
    local entries = {
      { label = "Overview", page = "Overview", icon = "Interface\\Icons\\INV_Misc_Book_09" },
      { label = "Logbook", page = "Logbook", icon = "Interface\\Icons\\INV_Misc_Note_01" },
      { label = "Recipes", page = "Recipes", icon = "Interface\\Icons\\INV_Scroll_03" },
      { label = "Reagents", page = "Reagents", icon = "Interface\\Icons\\INV_Misc_Herb_19" },
      { section = "PINNED RECIPES" },
    }
    local pins = UI.Pins()
    for _, recipe in ipairs(pins) do
      entries[#entries + 1] = { label = UI.Name(recipe), page = "Recipe", identity = recipe, icon = UI.RecipeIcon(recipe) }
    end
    if #pins == 0 then entries[#entries + 1] = { section = "No pinned recipes" } end
    entries[#entries + 1] = { section = "CHARACTERS" }
    local characters = API.GetCharacters() or {}
    table.sort(characters, function(left, right)
      if UI.Name(left) == UI.Name(right) then return left.key < right.key end
      return UI.Name(left) < UI.Name(right)
    end)
    for _, character in ipairs(characters) do
      entries[#entries + 1] = { label = UI.Name(character), page = "Character", identity = character,
        classFile = character.classFile, icon = "Interface\\Icons\\INV_Helmet_03" }
    end
    if #characters == 0 then entries[#entries + 1] = { section = "None recorded" } end
    entries[#entries + 1] = { section = "PROFESSIONS" }
    local professions = API.GetProfessions() or {}
    table.sort(professions, function(left, right) return UI.Name(left) < UI.Name(right) end)
    for _, profession in ipairs(professions) do
      entries[#entries + 1] = { label = UI.Name(profession), page = "Profession", identity = profession,
        icon = UI.ProfessionIcon(profession.skillLineId) }
    end
    if #professions == 0 then entries[#entries + 1] = { section = "None recorded" } end
    for _, item in ipairs(self.navItems) do item:Hide() end
    for _, heading in ipairs(headings) do heading:Hide() end
    local offset, itemCount, headingCount = 0, 0, 0
    for _, entry in ipairs(entries) do
      if entry.section then
        headingCount = headingCount + 1
        local heading = headings[headingCount] or UI.Text(navContent, 4, 0, sideWidth - 36, 20)
        headings[headingCount] = heading
        heading:ClearAllPoints(); heading:SetPoint("TOPLEFT", 4, -offset - 6)
        heading:SetText(entry.section); heading:SetTextColor(.65, .64, .58); heading:Show()
        offset = offset + 24
      else
        itemCount = itemCount + 1
        local item = self.navItems[itemCount] or UI.NavItem(navContent, sideWidth - 30,
          function(selected) self:Activate(selected.page, selected.identity) end)
        self.navItems[itemCount] = item
        item:ClearAllPoints(); item:SetPoint("TOPLEFT", 0, -offset)
        local selected = self.activeTab == entry.page or
          (self.activeTab == "Recipe" and entry.page == "Recipes")
        if selected and entry.identity then
          local current = self.identity
          selected = current and (current.key or current.skillLineId or current.id) ==
            (entry.identity.key or entry.identity.skillLineId or entry.identity.id)
        end
        item:Update(entry, selected); item:Show()
        offset = offset + 24
      end
    end
    navContent:SetHeight(math.max(navScroll:GetHeight(), offset + 8))
    settingsNav:Update({ label = "Settings", icon = "Interface\\Icons\\Trade_Engineering" }, self.activeTab == "Settings")
  end

  local modalShade = CreateFrame("Frame", nil, UIParent)
  modalShade:SetAllPoints(UIParent)
  modalShade:SetFrameStrata("FULLSCREEN_DIALOG")
  modalShade:EnableMouse(true)
  modalShade:SetScript("OnMouseDown", function() end)
  local shade = modalShade:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints(modalShade); shade:SetColorTexture(0, 0, 0, .55)
  modalShade:Hide()
  window.modalShade = modalShade
  local craftModal = shell("ArtisanLogbookCraftDetailWindow", "Craft Detail", modalShade, 700, 620)
  craftModal:SetScale(scale)
  craftModal:SetFrameStrata("FULLSCREEN_DIALOG")
  craftModal:Hide()
  window.craftDetailWindow = craftModal
  local craftBody = CreateFrame("Frame", nil, craftModal)
  craftBody:SetPoint("TOPLEFT", 12, -34); craftBody:SetSize(676, 568)
  local closingMain, closingCraft = false, false
  local detail
  local function closeCraft()
    if closingCraft then return end
    closingCraft = true
    craftModal:Hide(); detail:Hide(); modalShade:Hide()
    window.visiblePage = pages[window.activeTab]
    window.openCraftId = nil
    if not closingMain and window.activeTab == "Recipe" then pages.Recipe.outcomes:Refresh(true) end
    closingCraft = false
  end
  detail = UI.CraftDetail(craftBody, 676, 550, closeCraft)
  window.craftDetailPage = detail
  craftModal:SetScript("OnHide", closeCraft)
  function window:OpenCraft(id)
    self.returnPage = pages[self.activeTab]
    self.openCraftId, self.visiblePage = id, detail
    detail:ShowCraft(id); detail:Show()
    modalShade:Show(); craftModal:Show(); craftModal:Raise()
  end
  local function navigate(name, identity) window:Activate(name, identity) end
  local function openCraft(id) window:OpenCraft(id) end
  for _, name in ipairs({ "Overview", "Logbook", "Character", "Profession" }) do
    UI.PopulationPage(pages[name], name, inner, bodyHeight, navigate, openCraft)
  end
  UI.CataloguePage(pages.Recipes, inner, bodyHeight, function(recipe) window:OpenRecipe(recipe) end)
  UI.ReagentsPage(pages.Reagents, inner, bodyHeight, function(recipe) window:OpenRecipe(recipe) end)
  UI.RecipePage(pages.Recipe, inner, bodyHeight, openCraft, function() window:RefreshSidebar() end)
  window.recipeDetailPage, window.recipeOutcomes = pages.Recipe, pages.Recipe.outcomes
  function window:OpenRecipe(recipe) self:Activate("Recipe", recipe) end

  local settings = pages.Settings
  UI.Section(settings, "History settings", 0, -2, inner)
  local settingsStatus = UI.Text(settings, 0, -46, inner, 70)
  UI.Text(settings, 0, -132, 160, 24):SetText("Retention (days)")
  local retention = CreateFrame("EditBox", nil, settings, "InputBoxTemplate")
  retention:SetSize(78, 24); retention:SetPoint("TOPLEFT", 175, -127)
  retention:SetAutoFocus(false); retention:SetNumeric(true)
  retention:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  UI.Button(settings, "Save", 275, -127, 76, function()
    local ok, reason = management.SetRetentionDays(tonumber(retention:GetText()))
    addon.Notify(ok and "Retention updated." or reason)
    settings:Open()
  end)
  function settings:Open()
    local status, reason = management.Status()
    if not status then settingsStatus:SetText(reason or "Unavailable"); return end
    retention:SetText(tostring(status.retentionDays))
    settingsStatus:SetText(string.format("Retained crafts: %d\nDaily totals: %d\nAddon version: %s",
      status.retainedCrafts, status.dailyRows, UI.Value(status.addonVersion)))
  end
  function window:Activate(name, identity)
    if not pages[name] then return end
    if (name == "Character" or name == "Profession" or name == "Recipe") and not identity then return end
    if self.openCraftId then closeCraft() end
    local status = management.Status()
    local signature = status and (status.retainedCrafts .. ":" .. status.dailyRows)
    if signature ~= self.dataSignature then self:Invalidate(); self.dataSignature = signature end
    for _, page in pairs(pages) do page:Hide() end
    self.activeTab, self.identity = name, identity
    pages[name]:Open(identity)
    pages[name]:Show(); self.visiblePage = pages[name]
    self:RefreshSidebar(); self:Raise()
  end
  function window:Refresh()
    self:RefreshSidebar()
    if not self.openCraftId then pages[self.activeTab]:Open(self.identity) end
  end
  function window:Invalidate()
    for _, page in pairs(pages) do
      page.dirty = true
      page.revision = (page.revision or 0) + 1
    end
  end
  local escape = CreateFrame("Frame", "ArtisanLogbookEscapeFrame", UIParent)
  escape:Hide()
  tinsert(UISpecialFrames, "ArtisanLogbookEscapeFrame")
  escape:SetScript("OnHide", function(self)
    if closingMain then return end
    if window.openCraftId then closeCraft(); self:Show()
    else window:Hide() end
  end)
  window.escapeFrame = escape
  window:SetScript("OnHide", function()
    closingMain = true
    if window.openCraftId then closeCraft() end
    escape:Hide()
    closingMain = false
  end)
  window:SetScript("OnShow", function(self)
    self:Activate(self.activeTab, self.identity); escape:Show()
  end)
  API.RegisterCallback("CRAFT_COMMITTED", function(craft)
    if craft.recipe and UI.IsPinned(craft.recipe.id) then
      ArtisanLogbookUISettings.pinnedRecipes[craft.recipe.id] = UI.CopyRecipe(craft.recipe,
        ArtisanLogbookUISettings.pinnedRecipes[craft.recipe.id])
    end
    window:Invalidate()
    if window:IsShown() then window:Refresh() end
  end)
  window:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
  window:RegisterEvent("PLAYER_ENTERING_WORLD")
  window:SetScript("OnEvent", function(self)
    self:Invalidate()
    self:SetScript("OnUpdate", function(self)
      self:SetScript("OnUpdate", nil)
      if self:IsShown() then self:Refresh() end
    end)
  end)
  window:Hide()

  UI.Pins()
  local launcher = CreateFrame("Button", "ArtisanLogbookButton", UIParent)
  launcher:SetSize(32, 32)
  launcher:SetFrameStrata("MEDIUM")
  launcher:RegisterForClicks("LeftButtonUp")
  launcher:RegisterForDrag("LeftButton")
  launcher:SetNormalTexture("Interface\\Icons\\INV_Misc_Book_09")
  local icon = launcher:GetNormalTexture()
  icon:ClearAllPoints(); icon:SetPoint("CENTER"); icon:SetSize(22, 22)
  icon:SetTexCoord(.08, .92, .08, .92)
  local mask = launcher:CreateMaskTexture()
  mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
  mask:SetAllPoints(icon); icon:AddMaskTexture(mask)
  local border = launcher:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(52, 52); border:SetPoint("TOPLEFT", launcher, "TOPLEFT", 0, 0)
  launcher:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
  local angle = type(ArtisanLogbookUISettings.minimapAngle) == "number" and
    ArtisanLogbookUISettings.minimapAngle or math.pi / 4
  local function place()
    local minimapScale = Minimap:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local radius = math.min(Minimap:GetWidth(), Minimap:GetHeight()) * minimapScale / 2 + 2
    launcher:ClearAllPoints()
    launcher:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
  end
  launcher:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local scale = UIParent:GetEffectiveScale()
      local x, y = GetCursorPosition()
      local centerX, centerY = Minimap:GetCenter()
      if x and y and centerX and centerY then
        angle = math.atan2(y / scale - centerY, x / scale - centerX)
        place()
      end
    end)
  end)
  launcher:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    ArtisanLogbookUISettings.minimapAngle = angle
  end)
  place()
  launcher:SetScript("OnClick", function()
    if window:IsShown() then window:Hide() else window:Show() end
  end)
  launcher:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Artisan Logbook")
    GameTooltip:AddLine("Left-click to open or close", 1, 1, 1)
    GameTooltip:Show()
  end)
  launcher:SetScript("OnLeave", function() GameTooltip:Hide() end)
end