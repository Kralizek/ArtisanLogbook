local addonName, addon = ...
local UI = addon.UI
local API = ArtisanLogbookAPI
local management = ArtisanLogbookManagement
local tabs = { "Logbook", "Recipes", "Settings" }

local function population(character, profession, recipe)
  local filter = {}
  if character then filter.characters = { character } end
  if profession then filter.professions = { profession } end
  if recipe then filter.recipes = { recipe } end
  return filter
end

local function choices(facet, character)
  local result = { { label = "All", value = false } }
  local filter = character and population(character) or nil
  local facets = API.GetFacets(filter, { facets = { facet } })
  for _, entry in ipairs(facets and facets[facet] or {}) do
    result[#result + 1] = { label = UI.Name(entry.details), value = entry.value,
      classFile = entry.details and entry.details.classFile }
  end
  table.sort(result, function(left, right)
    if left.value == false then return true end
    if right.value == false then return false end
    return left.label < right.label
  end)
  return result
end

local function historyColumns(width)
  local available = width - 24
  return {
    { title = "Recipe", width = available * .30, value = function(row) return UI.Name(row.recipe) end },
    { title = "Character", width = available * .18, value = function(row) return UI.Name(row.character) end,
      color = function(row) return UI.ClassColor(row.character and row.character.classFile) end },
    { title = "Profession", width = available * .18, value = function(row) return UI.Name(row.profession) end },
    { title = "Quantity", width = available * .09, value = function(row) return UI.Value(row.outputQuantity) end },
    { title = "Activity", width = available * .25, activity = true },
  }
end

local function lazyList(list, fetch)
  local cursor, loading, finished
  local function load()
    if loading or finished then return end
    loading = true
    local page, reason = fetch(cursor)
    if page then
      list:Append(page)
      cursor = reason
      finished = cursor == nil
      if finished then list:SetFinished() end
      if #list.items == 0 then list.empty:Show() end
    else
      finished = true
      list.empty:SetText(reason or "Unavailable")
      if #list.items == 0 then list.empty:Show() end
    end
    loading = false
  end
  list.onNearEnd = load
  return function(message)
    cursor, finished = nil, false
    list:Reset(message)
    load()
  end
end

function addon.CreateProductionWindow()
  local width = math.min(940, UIParent:GetWidth() - 40)
  local height = math.min(670, UIParent:GetHeight() - 40)
  local inner = width - 48
  local bodyHeight = height - 112
  local window = CreateFrame("Frame", "ArtisanLogbookWindow", UIParent, "BasicFrameTemplateWithInset")
  addon.productionWindow = window
  window:SetSize(width, height)
  window:SetPoint("CENTER")
  window:SetClampedToScreen(true)
  window:SetMovable(true)
  window:EnableMouse(true)
  window:SetFrameStrata("DIALOG")
  window:SetToplevel(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  window:SetScript("OnMouseDown", function(self) self:Raise() end)
  window.TitleText:SetText("Artisan Logbook")
  tinsert(UISpecialFrames, "ArtisanLogbookWindow")
  local body = CreateFrame("Frame", nil, window)
  body:SetPoint("TOPLEFT", 24, -90)
  body:SetSize(inner, bodyHeight)
  local pages = {}
  for _, name in ipairs(tabs) do
    pages[name] = CreateFrame("Frame", nil, body)
    pages[name]:SetAllPoints(body)
    pages[name]:Hide()
  end
  window.pages = pages
  local detail
  detail = UI.CraftDetail(body, inner, bodyHeight, function()
    detail:Hide()
    window.visiblePage = window.returnPage
    if window.returnPage then window.returnPage:Show() end
    window:Refresh(true)
  end)
  local recipeDetail = CreateFrame("Frame", nil, body)
  recipeDetail:SetAllPoints(body)
  recipeDetail:Hide()
  window.activeTab = "Logbook"
  local buttons = {}
  for index, name in ipairs(tabs) do
    buttons[name] = UI.Button(window, name, 22 + (index - 1) * 112, -52, 108,
      function() window:Activate(name) end)
  end

  local logbook = pages.Logbook
  UI.Text(logbook, 0, -4, inner, 25, "GameFontNormalLarge"):SetText("Logbook")
  local days, character, profession = 30, false, false
  local periodSelect = UI.Selector(logbook, 0, -35, 112, UI.ranges, function(value)
    days = value; window:Refresh(true)
  end, "Period")
  local characterSelect = UI.Selector(logbook, 154, -35, 170, {}, function(value)
    character, profession = value, false; window:Refresh(true)
  end, "Character")
  local professionSelect = UI.Selector(logbook, 363, -35, 155, {}, function(value)
    profession = value; window:Refresh(true)
  end, "Profession")
  local noProfessions = UI.Text(logbook, 530, -52, inner - 530, 22)
  local graph = UI.Chart(logbook, 0, -74, inner)
  local summary = UI.CreateLogbookSummary(logbook, inner)
  UI.Text(logbook, 0, -336, inner, 22, "GameFontNormal"):SetText("Craft history")
  local history = UI.ScrollList(logbook, 0, -362, inner, bodyHeight - 365,
    historyColumns(inner), function(craft) window:OpenCraft(craft.id) end, "No crafts in this period")
  local function logbookFilter()
    local selected = population(character, profession)
    local from, to = UI.Range(GetServerTime(), days)
    selected.time = { from = from, to = to }
    return selected, from, to
  end
  local resetHistory = lazyList(history, function(cursor)
    local page, reason = API.GetCrafts(logbookFilter(), { limit = 40, cursor = cursor })
    return page and page.crafts, page and page.nextCursor or reason
  end)

  local recipes = pages.Recipes
  UI.Text(recipes, 0, -4, inner, 25, "GameFontNormalLarge"):SetText("Recipes")
  local recipeCharacter, recipeProfession, recipeSort = false, false, "name"
  local recipeCharacters = UI.Selector(recipes, 0, -35, 170, {}, function(value)
    recipeCharacter, recipeProfession = value, false; window:Refresh(true)
  end, "Character")
  local recipeProfessions = UI.Selector(recipes, 209, -35, 155, {}, function(value)
    recipeProfession = value; window:Refresh(true)
  end, "Profession")
  local sortSelect = UI.Selector(recipes, 403, -35, 152, {
    { label = "Recipe name", value = "name" }, { label = "Most crafted", value = "count" },
  }, function(value) recipeSort = value; window:Refresh(true) end, "Sort")
  local recipeNoProfessions = UI.Text(recipes, 565, -52, inner - 565, 22)
  local recipeWidth = inner - 24
  local catalogue = UI.ScrollList(recipes, 0, -86, inner, bodyHeight - 90, {
    { title = "Recipe", width = recipeWidth * .52, value = function(row) return UI.Name(row.recipe) end,
      icon = function(row)
        local id = row.recipe and row.recipe.id
        if not id then return nil end
        if C_TradeSkillUI and type(C_TradeSkillUI.GetRecipeInfo) == "function" then
          local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, id)
          if ok and info and info.icon then return info.icon end
        end
        return type(GetSpellTexture) == "function" and GetSpellTexture(id) or nil
      end },
    { title = "Profession", width = recipeWidth * .30, value = function(row) return UI.Name(row.profession) end },
    { title = "Crafts", width = recipeWidth * .18, value = function(row) return tostring(row.craftCount) end },
  }, function(row) window:OpenRecipe(row.recipe) end, "No recipes in this selection")
  local resetRecipes = lazyList(catalogue, function(cursor)
    local page, reason = API.GetRecipeSummaries({ limit = 40, cursor = cursor,
      character = recipeCharacter or nil, profession = recipeProfession or nil, sort = recipeSort })
    return page and page.recipes, page and page.nextCursor or reason
  end)

  local recipeScroll = CreateFrame("ScrollFrame", nil, recipeDetail, "UIPanelScrollFrameTemplate")
  recipeScroll:SetPoint("TOPLEFT", 0, 0)
  recipeScroll:SetSize(inner - 24, bodyHeight)
  local recipeContent = CreateFrame("Frame", nil, recipeScroll)
  local recipeInner = inner - 28
  recipeContent:SetSize(recipeInner, 920)
  recipeScroll:SetScrollChild(recipeContent)
  local recipeHeading = UI.Text(recipeContent, 0, -4, recipeInner - 100, 27, "GameFontNormalLarge")
  local recipeMetadata = UI.Text(recipeContent, 0, -34, recipeInner - 100, 20)
  UI.Button(recipeContent, "Back", recipeInner - 92, -4, 76, function()
    recipeDetail:Hide(); recipes:Show(); window.visiblePage = recipes
  end)
  local resetRecipeHistory
  local outcomes = UI.RecipeOutcomes(recipeContent, recipeInner, function()
    if resetRecipeHistory then resetRecipeHistory() end
  end)
  window.recipeOutcomes = outcomes
  UI.Text(recipeContent, 0, -644, recipeInner, 22, "GameFontNormal"):SetText("Craft history")
  local recipeHistory = UI.ScrollList(recipeContent, 0, -674, recipeInner, 230,
    historyColumns(recipeInner), function(craft) window:OpenCraft(craft.id) end, "No retained crafts in this period")
  local selectedRecipe
  resetRecipeHistory = lazyList(recipeHistory, function(cursor)
    local selected = outcomes:Filter()
    selected.recipes = { selectedRecipe.id }
    local page, reason = API.GetCrafts(selected, { limit = 40, cursor = cursor })
    return page and page.crafts, page and page.nextCursor or reason
  end)

  function window:OpenRecipe(recipe)
    if not selectedRecipe or selectedRecipe.id ~= recipe.id then recipeScroll:SetVerticalScroll(0) end
    selectedRecipe = recipe
    recipeHeading:SetText(UI.Name(recipe, "Unattributed recipe"))
    local metadata = {}
    if recipe.profession then metadata[#metadata + 1] = UI.Name(recipe.profession) end
    if recipe.expansion then metadata[#metadata + 1] = UI.Name(recipe.expansion) end
    recipeMetadata:SetText(table.concat(metadata, "  -  "))
    outcomes:Open(recipe.id)
    resetRecipeHistory()
    recipes:Hide(); recipeDetail:Show(); self.visiblePage = recipeDetail
  end

  local settings = pages.Settings
  UI.Text(settings, 0, -4, inner, 25, "GameFontNormalLarge"):SetText("History settings")
  local settingsStatus = UI.Text(settings, 0, -42, inner, 70)
  UI.Text(settings, 0, -128, 160, 24):SetText("Retention (days)")
  local retention = CreateFrame("EditBox", nil, settings, "InputBoxTemplate")
  retention:SetSize(78, 24)
  retention:SetPoint("TOPLEFT", 175, -123)
  retention:SetAutoFocus(false)
  retention:SetNumeric(true)
  retention:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  UI.Button(settings, "Save", 275, -123, 76, function()
    local ok, reason = management.SetRetentionDays(tonumber(retention:GetText()))
    addon.Notify(ok and "Retention updated." or reason)
    window:Refresh(true)
  end)

  function window:OpenCraft(id)
    self.openCraftId = id
    if self.visiblePage ~= detail then self.returnPage = self.visiblePage end
    if self.returnPage then self.returnPage:Hide() end
    detail:ShowCraft(id); detail:Show(); self.visiblePage = detail
  end

  function window:Refresh(reset)
    if self.activeTab == "Logbook" then
      characterSelect:Update(choices("characters"), character)
      local available = choices("professions", character)
      if not UI.HasChoice(available, profession) then profession = false end
      professionSelect:Update(available, profession)
      noProfessions:SetText(character and #available == 1 and "No professions recorded" or "")
      periodSelect:Update(UI.ranges, days)
      local selected, from, to = logbookFilter()
      local series = API.GetCraftSeries(selected)
      graph:Render(series and series.series or {}, from, to)
      summary(series and series.series or {})
      if reset or #history.items == 0 then resetHistory() end
    elseif self.activeTab == "Recipes" then
      recipeCharacters:Update(choices("characters"), recipeCharacter)
      local available = choices("professions", recipeCharacter)
      if not UI.HasChoice(available, recipeProfession) then recipeProfession = false end
      recipeProfessions:Update(available, recipeProfession)
      recipeNoProfessions:SetText(recipeCharacter and #available == 1 and "No professions recorded" or "")
      sortSelect:Update(sortSelect.choices, recipeSort)
      if reset or #catalogue.items == 0 then resetRecipes() end
    else
      local status, reason = management.Status()
      if not status then settingsStatus:SetText(reason or "Unavailable")
      else
        retention:SetText(tostring(status.retentionDays))
        settingsStatus:SetText(string.format("Retained crafts: %d\nDaily totals: %d\nAddon version: %s",
          status.retainedCrafts, status.dailyRows, UI.Value(status.addonVersion)))
      end
    end
    if self.visiblePage == recipeDetail and selectedRecipe then self:OpenRecipe(selectedRecipe) end
    if self.visiblePage == detail then detail:ShowCraft(self.openCraftId) end
  end

  function window:Activate(name)
    self.activeTab = name
    for title, button in pairs(buttons) do
      if title == name then button:LockHighlight() else button:UnlockHighlight() end
    end
    for _, page in pairs(pages) do page:Hide() end
    detail:Hide(); recipeDetail:Hide()
    pages[name]:Show(); self.visiblePage = pages[name]
    self:Raise(); self:Refresh(true)
  end
  window:SetScript("OnShow", function(self) self:Raise(); self:Activate(self.activeTab) end)
  window:Hide()
  API.RegisterCallback("CRAFT_COMMITTED", function()
    if window:IsShown() then window:Refresh(true) end
  end)

  if type(ArtisanLogbookUISettings) ~= "table" then ArtisanLogbookUISettings = {} end
  local launcher = CreateFrame("Button", "ArtisanLogbookButton", UIParent)
  launcher:SetSize(32, 32)
  launcher:SetFrameStrata("MEDIUM")
  launcher:RegisterForClicks("LeftButtonUp")
  launcher:RegisterForDrag("LeftButton")
  launcher:SetNormalTexture("Interface\\Icons\\INV_Misc_Book_09")
  local icon = launcher:GetNormalTexture()
  icon:ClearAllPoints()
  icon:SetPoint("CENTER")
  icon:SetSize(22, 22)
  icon:SetTexCoord(.08, .92, .08, .92)
  local mask = launcher:CreateMaskTexture()
  mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
  mask:SetAllPoints(icon)
  icon:AddMaskTexture(mask)
  local border = launcher:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(52, 52)
  border:SetPoint("TOPLEFT", launcher, "TOPLEFT", 0, 0)
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