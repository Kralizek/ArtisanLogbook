local addonName, addon = ...
local UI = addon.UI
local API = ArtisanLogbookAPI
local tabs = { "Overview", "Recent", "Character", "Profession", "Recipes" }
local historicalChoices

local function population(character, profession, recipe)
  local filter = {}
  if character then filter.characters = { character } end
  if profession then filter.professions = { profession } end
  if recipe then filter.recipes = { recipe } end
  return filter
end

local function choices(facet, filter, includeAll)
  local result = {}
  local seen = {}
  if includeAll then result[1] = { label = "All", value = false } end
  local facets = API.GetFacets(filter, { facets = { facet } })
  for _, entry in ipairs(facets and facets[facet] or {}) do
    result[#result + 1] = { label = UI.Name(entry.details), value = entry.value }
    seen[entry.value] = true
  end
  if not historicalChoices then
    local response = API.GetCraftSeries()
    historicalChoices = response and response.series or {}
  end
  for _, row in ipairs(historicalChoices) do
    local detail = facet == "characters" and row.character or row.profession
    local value = detail and (facet == "characters" and detail.key or detail.skillLineId)
    local selected = not filter or not filter.characters or
      (row.character and row.character.key == filter.characters[1])
    if selected and value ~= nil and not seen[value] then
      result[#result + 1] = { label = UI.Name(detail), value = value }
      seen[value] = true
    end
  end
  table.sort(result, function(left, right)
    if left.value == false then return true end
    if right.value == false then return false end
    if left.label == right.label then return tostring(left.value) < tostring(right.value) end
    return left.label < right.label
  end)
  return result
end

local function firstProfession(available)
  if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
    local ok, primary, secondary = pcall(GetProfessions)
    if ok then
      for _, index in ipairs({ primary, secondary }) do
        local found, _, _, _, _, _, _, skillLine = pcall(GetProfessionInfo, index)
        if found then
          for _, choice in ipairs(available) do
            if choice.value == skillLine then return skillLine end
          end
        end
      end
    end
  end
  return available[1] and available[1].value or nil
end

local function withCurrent(available, current)
  if current then
    for _, choice in ipairs(available) do
      if choice.value == current.key then return available end
    end
    table.insert(available, 1, { label = current.name or "Current character", value = current.key })
  end
  return available
end

local function includeGameProfessions(available)
  if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then return end
  local ok, primary, secondary = pcall(GetProfessions)
  if not ok then return end
  for _, index in ipairs({ primary, secondary }) do
    local found, name, _, _, _, _, _, skillLine = pcall(GetProfessionInfo, index)
    if found and type(skillLine) == "number" then
      local exists = false
      for _, choice in ipairs(available) do
        if choice.value == skillLine then exists = true; break end
      end
      if not exists then available[#available + 1] = { label = name or "Profession #" .. skillLine,
        value = skillLine } end
    end
  end
end

function addon.CreateProductionWindow()
  local width = math.min(940, UIParent:GetWidth() - 40)
  local height = math.min(670, UIParent:GetHeight() - 40)
  local inner = width - 48
  local window = CreateFrame("Frame", "ArtisanLogbookWindow", UIParent, "BasicFrameTemplateWithInset")
  addon.productionWindow = window
  window:SetSize(width, height)
  window:SetPoint("CENTER")
  window:SetClampedToScreen(true)
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  window.TitleText:SetText("Artisan Logbook")
  tinsert(UISpecialFrames, "ArtisanLogbookWindow")
  local body = CreateFrame("Frame", nil, window)
  body:SetPoint("TOPLEFT", 24, -90)
  body:SetSize(inner, height - 112)
  local pages = {}
  for _, name in ipairs(tabs) do
    pages[name] = CreateFrame("Frame", nil, body)
    pages[name]:SetAllPoints(body)
    pages[name]:Hide()
  end
  window.pages = pages
  pages.Settings = CreateFrame("Frame", nil, body)
  pages.Settings:SetAllPoints(body)
  pages.Settings:Hide()
  local detail = UI.CraftDetail(body, inner, height - 112, function()
    detail:Hide()
    if window.returnPage then window.returnPage:Show() end
  end)
  local recipeDetail = CreateFrame("Frame", nil, body)
  recipeDetail:SetAllPoints(body)
  recipeDetail:Hide()
  window.activeTab = "Overview"

  local function show(page)
    for _, frame in pairs(pages) do frame:Hide() end
    detail:Hide()
    recipeDetail:Hide()
    page:Show()
    window.visiblePage = page
  end

  function window:OpenCraft(id)
    self.openCraftId = id
    self.returnPage = self.visiblePage
    if self.returnPage then self.returnPage:Hide() end
    detail:ShowCraft(id)
    detail:Show()
    self.visiblePage = detail
  end

  for index, name in ipairs(tabs) do
    UI.Button(window, name, 22 + (index - 1) * 112, -52, 108, function() window:Activate(name) end)
  end
  UI.Button(window, "Settings", width - 111, -52, 88, function() window:Activate("Settings") end)

  local refreshOverview, invalidateOverview = UI.CreateOverview(pages.Overview, inner, choices,
    function() window:Refresh() end)

  local recent = pages.Recent
  UI.Text(recent, 0, -4, inner, 25, "GameFontNormalLarge"):SetText("Recent crafts")
  local recentCharacter, recentProfession = false, false
  local recentCharacters = UI.Selector(recent, 154, -38, 168, {}, function(key)
    recentCharacter = key; window:Refresh(true)
  end)
  local recentProfessions = UI.Selector(recent, 360, -38, 168, {}, function(id)
    recentProfession = id; window:Refresh(true)
  end)
  local recentArea = CreateFrame("Frame", nil, recent)
  recentArea:SetPoint("TOPLEFT", 0, -72)
  recentArea:SetSize(inner, height - 185)
  local recentHistory = UI.History(recentArea, inner, false,
    function() return population(recentCharacter, recentProfession) end,
    function(id) window:OpenCraft(id) end)

  local current = addon.Management.CurrentCharacter()
  local characterKey = current and current.key
  local character = pages.Character
  UI.Text(character, 0, -4, inner, 25, "GameFontNormalLarge"):SetText("Character")
  local characterSelect = UI.Selector(character, 0, -34, 220, {}, function(key)
    characterKey = key; window:Refresh(true)
  end)
  local characterArea = CreateFrame("Frame", nil, character)
  characterArea:SetPoint("TOPLEFT", 0, -72)
  characterArea:SetSize(inner, height - 185)
  local characterHistory = UI.History(characterArea, inner, true,
    function() return population(characterKey) end, function(id) window:OpenCraft(id) end)

  local profession = pages.Profession
  UI.Text(profession, 0, -4, inner, 25, "GameFontNormalLarge"):SetText("Profession")
  local professionCharacter = characterKey
  local professionId
  local professionCharacterSelect = UI.Selector(profession, 0, -34, 220, {}, function(key)
    professionCharacter = key; professionId = nil; window:Refresh(true)
  end)
  local professionSelect = UI.Selector(profession, 270, -34, 220, {}, function(id)
    professionId = id; window:Refresh(true)
  end)
  local professionArea = CreateFrame("Frame", nil, profession)
  professionArea:SetPoint("TOPLEFT", 0, -72)
  professionArea:SetSize(inner, height - 185)
  local professionHistory = UI.History(professionArea, inner, true,
    function()
      local filter = population(professionCharacter, professionId)
      if not professionId then filter.professions = {} end
      return filter
    end,
    function(id) window:OpenCraft(id) end)

  local recipes = pages.Recipes
  UI.Text(recipes, 0, -4, inner, 25, "GameFontNormalLarge"):SetText("Tracked recipes")
  local recipePage, recipeCursors, recipeNext = 1, { false }
  local recipeTable = UI.Table(recipes, 0, -42, inner, {
    { title = "Recipe", width = inner * .48, value = function(row) return UI.Name(row.recipe) end },
    { title = "Profession", width = inner * .32, value = function(row) return UI.Name(row.profession) end },
    { title = "Craft count", width = inner * .2, value = function(row) return row.craftCount end },
  }, 10, function(row) window:OpenRecipe(row.recipe) end)
  local recipePageText = UI.Text(recipes, 90, -354, 125, 24)
  local recipePrevious = UI.Button(recipes, "<", 0, -350, 36, function()
    if recipePage > 1 then recipePage = recipePage - 1; window:Refresh() end
  end)
  local recipeForward = UI.Button(recipes, ">", 230, -350, 36, function()
    if recipeNext then
      recipePage = recipePage + 1
      recipeCursors[recipePage] = recipeNext
      window:Refresh()
    end
  end)
  local recipeHeading = UI.Text(recipeDetail, 0, -4, inner - 100, 27, "GameFontNormalLarge")
  UI.Button(recipeDetail, "Back", inner - 92, -4, 76, function()
    recipeDetail:Hide(); recipes:Show(); window.visiblePage = recipes
  end)
  local recipeArea = CreateFrame("Frame", nil, recipeDetail)
  recipeArea:SetPoint("TOPLEFT", 0, -60)
  recipeArea:SetSize(inner, height - 174)
  local selectedRecipe
  local recipeHistory = UI.History(recipeArea, inner, true,
    function() return population(nil, nil, selectedRecipe and selectedRecipe.id) end,
    function(id) window:OpenCraft(id) end)

  function window:OpenRecipe(recipe)
    selectedRecipe = recipe
    recipeHeading:SetText(UI.Name(recipe) .. "  |  " .. UI.Name(recipe.profession) ..
      "  |  " .. UI.Name(recipe.expansion))
    recipes:Hide()
    recipeHistory:Refresh(true)
    recipeDetail:Show()
    self.visiblePage = recipeDetail
  end

  local settings = pages.Settings
  UI.Text(settings, 0, -4, inner, 25, "GameFontNormalLarge"):SetText("Data and settings")
  local settingsStatus = UI.Text(settings, 0, -42, inner, 160)
  UI.Text(settings, 0, -213, 160, 24):SetText("Retention (days)")
  local retention = CreateFrame("EditBox", nil, settings, "InputBoxTemplate")
  retention:SetSize(78, 24)
  retention:SetPoint("TOPLEFT", 175, -208)
  retention:SetAutoFocus(false)
  retention:SetNumeric(true)
  retention:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  UI.Button(settings, "Save", 275, -208, 76, function()
    local ok, reason = addon.Management.SetRetentionDays(tonumber(retention:GetText()))
    addon.Notify(ok and "Retention updated. Use Prune to apply now." or reason)
    window:Refresh(true)
  end)
  UI.Button(settings, "Prune now", 0, -260, 105, function()
    local removed, reason = addon.Management.Prune()
    addon.Notify(removed and (removed .. " detailed crafts pruned.") or reason)
    invalidateOverview()
    window:Refresh(true)
  end)
  UI.Button(settings, "Clear history", 120, -260, 122, function()
    StaticPopup_Show("ARTISANLOGBOOK_CLEAR_HISTORY")
  end)
  StaticPopupDialogs.ARTISANLOGBOOK_CLEAR_HISTORY = {
    text = "Delete all recorded craft history, including daily totals? This cannot be undone.",
    button1 = "Delete", button2 = "Cancel", timeout = 0, whileDead = true,
    hideOnEscape = true, preferredIndex = 3,
    OnAccept = function()
      addon.Management.Clear()
      invalidateOverview()
      historicalChoices = nil
      window:Refresh(true)
    end,
  }
  local function refreshSettings()
    local status, reason = addon.Management.Status()
    local capabilities = API.GetCapabilities()
    if not status then settingsStatus:SetText(reason or "Unavailable"); return end
    retention:SetText(tostring(status.retentionDays))
    settingsStatus:SetText(string.format("Retained crafts: %d  |  Daily rows: %d\nSchema: %s  |  Addon: %s  |  WoW build: %s\nFlavor: %s  |  Results: %s  |  Personal requests: %s  |  Allocations: %s\nCapture error: %s  |  Optional integrations: none\nPortable export is not yet defined; debug trace export is not a production export.",
      status.retainedCrafts, status.dailyRows, UI.Value(status.schemaVersion),
      UI.Value(status.addonVersion), UI.Value(status.wowBuild),
      capabilities and capabilities.flavor or "Unknown",
      capabilities and UI.Value(capabilities.craftResults) or "Unknown",
      capabilities and UI.Value(capabilities.personalRequests) or "Unknown",
      capabilities and UI.Value(capabilities.reagentAllocations) or "Unknown",
      UI.Value(status.captureError)))
  end

  function window:Refresh(reset)
    if self.activeTab == "Overview" then refreshOverview()
    elseif self.activeTab == "Recent" then
      recentCharacters:Update(choices("characters", nil, true), recentCharacter)
      recentProfessions:Update(choices("professions", population(recentCharacter), true), recentProfession)
      recentHistory:Refresh(reset)
    elseif self.activeTab == "Character" then
      local available = withCurrent(choices("characters", nil), current)
      characterSelect:Update(available, characterKey)
      characterHistory:Refresh(reset)
    elseif self.activeTab == "Profession" then
      local available = withCurrent(choices("characters", nil), current)
      professionCharacterSelect:Update(available, professionCharacter)
      local professions = choices("professions", population(professionCharacter))
      if current and professionCharacter == current.key then includeGameProfessions(professions) end
      if not professionId then professionId = firstProfession(professions) end
      professionSelect:Update(professions, professionId)
      professionHistory:Refresh(reset)
    elseif self.activeTab == "Recipes" then
      local page = API.GetRecipeSummaries({ limit = 10, cursor = recipeCursors[recipePage] or nil })
      recipeNext = page and page.nextCursor
      recipeTable:Render(page and page.recipes or {})
      recipePageText:SetText("Page " .. recipePage)
      recipePrevious:SetEnabled(recipePage > 1)
      recipeForward:SetEnabled(recipeNext ~= nil)
    else refreshSettings() end
    if self.visiblePage == recipeDetail then recipeHistory:Refresh(reset) end
    if self.visiblePage == detail then detail:ShowCraft(self.openCraftId) end
  end

  function window:Activate(name)
    self.activeTab = name
    show(pages[name])
    self:Refresh()
  end

  window:SetScript("OnShow", function() window:Activate(window.activeTab) end)
  window:Hide()
  API.RegisterCallback("CRAFT_COMMITTED", function()
    invalidateOverview()
    historicalChoices = nil
    if window:IsShown() then window:Refresh(true) end
  end)

  local launcher = CreateFrame("Button", "ArtisanLogbookButton", UIParent)
  launcher:SetSize(28, 28)
  launcher:SetPoint("TOPRIGHT", Minimap, "BOTTOMRIGHT", 0, -6)
  launcher:SetNormalTexture("Interface\\Icons\\INV_Misc_Book_09")
  launcher:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  launcher:SetScript("OnClick", function()
    if window:IsShown() then window:Hide() else window:Show() end
  end)
  launcher:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Artisan Logbook")
    GameTooltip:Show()
  end)
  launcher:SetScript("OnLeave", function() GameTooltip:Hide() end)
end