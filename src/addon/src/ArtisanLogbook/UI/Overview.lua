local _, addon = ...
local UI = addon.UI

function UI.Aggregate(series)
  local totals = { craftCount = 0 }
  local recipes = {}
  local metrics = { "outputQuantity", "concentrationSpent", "multicraftBonus", "ingenuityRefund" }
  for _, metric in ipairs(metrics) do totals[metric], totals[metric .. "ObservedCount"] = 0, 0 end
  for _, row in ipairs(series) do
    totals.craftCount = totals.craftCount + row.craftCount
    for _, metric in ipairs(metrics) do
      totals[metric] = totals[metric] + (row[metric] or 0)
      totals[metric .. "ObservedCount"] = totals[metric .. "ObservedCount"] + (row[metric .. "ObservedCount"] or 0)
    end
    local id = row.recipe and row.recipe.id or 0
    local recipe = recipes[id] or { recipe = row.recipe, craftCount = 0, id = id }
    recipe.craftCount = recipe.craftCount + row.craftCount
    recipes[id] = recipe
  end
  local ranked = {}
  for _, recipe in pairs(recipes) do ranked[#ranked + 1] = recipe end
  table.sort(ranked, function(left, right)
    if left.craftCount ~= right.craftCount then return left.craftCount > right.craftCount end
    if UI.Name(left.recipe) == UI.Name(right.recipe) then return left.id < right.id end
    return UI.Name(left.recipe) < UI.Name(right.recipe)
  end)
  return totals, ranked
end

function UI.ReturnTotals(owner, recipes, filter, onResult)
  local index, cursor, phase = 1, nil, "outcomes"
  local total, crafts, complete = 0, 0, 0
  owner:SetScript("OnUpdate", function(self)
    local recipe = recipes[index]
    if not recipe then
      self:SetScript("OnUpdate", nil)
      onResult(total, crafts, complete)
      return
    end
    if phase == "outcomes" then
      local result = ArtisanLogbookAPI.GetRecipeOutcomes(recipe.id, filter, { buckets = 1 })
      if not result then self:SetScript("OnUpdate", nil); onResult(nil); return end
      crafts = crafts + result.totals.craftCount
      complete = complete + result.totals.resourcefulnessCompleteProcCountObservedCount
      phase = "returns"
    else
      local page = ArtisanLogbookAPI.GetRecipeReturnedReagents(recipe.id, filter, { limit = 100, cursor = cursor })
      if not page then self:SetScript("OnUpdate", nil); onResult(nil); return end
      for _, reagent in ipairs(page.returns) do total = total + reagent.returnedQuantity end
      cursor = page.nextCursor
      if not cursor then index, phase = index + 1, "outcomes" end
    end
  end)
end

function UI.ReturnQuantity(total, crafts, complete)
  if total == nil then return "Unavailable" end
  if total == 0 and complete < crafts then return "-" end
  return UI.Number(total)
end

function UI.Stat(parent, title, icon, x, y, width)
  local tile = CreateFrame("Button", nil, parent)
  tile:SetPoint("TOPLEFT", x, y)
  tile:SetSize(width, 80)
  local texture = tile:CreateTexture(nil, "ARTWORK")
  texture:SetSize(18, 18)
  texture:SetPoint("TOPLEFT", 0, -2)
  texture:SetTexture(icon)
  tile.icon = texture
  tile.title = UI.Text(tile, 24, -2, width - 24, 26, "GameFontNormalSmall")
  tile.title:SetText(title)
  tile.value = UI.Text(tile, 0, -30, width, 20, "GameFontNormalLarge")
  tile.note = UI.Text(tile, 0, -52, width, 28)
  function tile:SetNumber(value, complete, note)
    self.value:SetText(UI.Amount(value, complete))
    self.note:SetText(note or "")
    self:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(title .. ": " .. UI.AmountTooltip(value, complete))
      GameTooltip:Show()
    end)
    self:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  return tile
end

function UI.SummaryRow(parent, width, y, entries)
  local summary = CreateFrame("Frame", nil, parent)
  summary:SetSize(width, 80)
  summary:SetPoint("TOPLEFT", 0, y)
  summary.tiles = {}
  local weight = 0
  for _, entry in ipairs(entries) do weight = weight + (entry[3] or 1) end
  local unit = (width - (#entries - 1) * 16) / weight
  if #entries <= 3 then unit = math.min(unit, 192) end
  local left = 0
  for index, entry in ipairs(entries) do
    local tileWidth = unit * (entry[3] or 1)
    summary.tiles[index] = UI.Stat(summary, entry[1], "Interface\\Icons\\" .. entry[2], left, 0, tileWidth)
    if index > 1 then
      local rule = summary:CreateTexture(nil, "ARTWORK")
      rule:SetPoint("TOPLEFT", left - 8, -4); rule:SetSize(1, 64)
      rule:SetColorTexture(.35, .27, .14, .18)
    end
    left = left + tileWidth + 16
  end
  return summary
end

function UI.ProductionSummary(parent, width, y, openRecipe, splitProfessions)
  local entries = {
    { "Crafts", "Trade_BlackSmithing", splitProfessions and 1.35 or 1 },
    { splitProfessions and "Output" or "Total output", "INV_Misc_Bag_10", splitProfessions and 1.35 or 1 },
    { "Concentration spent", "Spell_Arcane_Arcane01" }, { "Multicraft bonus", "Trade_Engineering" },
    { "Reagents returned", "INV_Misc_Herb_19" }, { "Most crafted", "INV_Misc_Book_09", 2 },
  }
  local summary = UI.SummaryRow(parent, width, y, entries)
  function summary:Render(series, filter)
    local totals, recipes = UI.Aggregate(series)
    self.totals, self.recipes = totals, recipes
    local professions, professionRows = {}, {}
    for _, row in ipairs(series) do
      local key = row.profession and row.profession.skillLineId or "unknown"
      local entry = professions[key] or { profession = row.profession, crafts = 0, output = 0, outputObserved = 0 }
      professions[key] = entry
      entry.crafts = entry.crafts + row.craftCount
      entry.output = entry.output + (row.outputQuantity or 0)
      entry.outputObserved = entry.outputObserved + (row.outputQuantityObservedCount or 0)
    end
    for _, row in pairs(professions) do professionRows[#professionRows + 1] = row end
    table.sort(professionRows, function(left, right) return UI.Name(left.profession) < UI.Name(right.profession) end)
    self.professionCounts = professionRows
    self.tiles[1]:SetNumber(totals.craftCount, true)
    self.tiles[1].note:SetText("")
    for index, metric in pairs({ [2] = "outputQuantity", [3] = "concentrationSpent", [4] = "multicraftBonus" }) do
      local known = totals[metric .. "ObservedCount"]
      self.tiles[index]:SetNumber(known > 0 and totals[metric] or nil, known == totals.craftCount)
    end
    local split = splitProfessions and #professionRows > 1
    self:SetHeight(split and math.max(80, 34 + #professionRows * 14) or 80)
    for index = 1, 2 do
      local tile = self.tiles[index]
      tile:SetHeight(self:GetHeight())
      tile.value:SetFontObject(split and "GameFontHighlightSmall" or "GameFontNormalLarge")
      if UI.IsParchment(self) then
        tile.value:SetTextColor(unpack(UI.ink)); tile.value:SetShadowOffset(0, 0)
      end
      tile.value:SetHeight(split and #professionRows * 14 or 20)
      tile.note:SetShown(not split)
      if split then
        local lines = {}
        for _, entry in ipairs(professionRows) do
          local value = index == 1 and UI.Number(entry.crafts) or
            UI.Amount(entry.outputObserved > 0 and entry.output or nil, entry.outputObserved == entry.crafts)
          local nameWidth = math.max(4, math.floor(tile:GetWidth() / 6) - #value - 2)
          lines[#lines + 1] = UI.Elide(UI.Name(entry.profession), nameWidth) .. ": " .. value
        end
        tile.value:SetText(table.concat(lines, "\n"))
        tile:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(index == 1 and "Crafts" or "Output")
          for _, entry in ipairs(professionRows) do
            local value = index == 1 and tostring(entry.crafts) or UI.AmountTooltip(
              entry.outputObserved > 0 and entry.output or nil, entry.outputObserved == entry.crafts)
            GameTooltip:AddLine(UI.Name(entry.profession) .. ": " .. value, 1, 1, 1, true)
          end
          GameTooltip:Show()
        end)
      end
    end
    local share = UI.MeasuredShare(totals, "multicraftBonus", "outputQuantity")
    if share ~= "Unknown" then self.tiles[4].note:SetText(share .. " of total output") end
    local top = recipes[1]
    self.tiles[6].icon:SetTexture(UI.RecipeIcon(top and top.recipe))
    self.tiles[6].value:SetText(top and UI.Elide(UI.Name(top.recipe), math.floor(self.tiles[6]:GetWidth() / 10)) or "-")
    self.tiles[6].note:SetText(top and UI.Count(top.craftCount, "craft") or "No crafts in this period")
    self.tiles[6].value:SetTextColor(.30, .22, .06)
    self.tiles[6]:SetScript("OnClick", function() if top and top.recipe and openRecipe then openRecipe(top.recipe) end end)
    self.tiles[6]:EnableMouse(true)
    self.tiles[6]:SetScript("OnEnter", function(self)
      local result = top and top.recipe and ArtisanLogbookAPI.GetCrafts({ recipes = { top.recipe.id },
        time = filter.time, characters = filter.characters }, { limit = 1 })
      local item = result and result.crafts[1] and result.crafts[1].outputItem
      if item then UI.ItemTooltip(self, item)
      else
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(top and UI.Name(top.recipe) or "No crafts in this period")
        GameTooltip:Show()
      end
    end)
    self.tiles[6]:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.tiles[5].value:SetText("...")
    self.tiles[5].note:SetText("")
    UI.ReturnTotals(self, recipes, { time = filter.time, characters = filter.characters }, function(total, crafts, complete)
      self.tiles[5]:SetNumber(total, total ~= nil and complete == crafts)
    end)
  end
  return summary
end

function UI.PopulationPage(page, kind, width, height, navigate, openCraft)
  local content = page
  page.content, page.states = content, {}
  local entity = kind == "Character" or kind == "Profession"
  local heading = UI.Section(content, kind, 0, -2, width)
  local identityIcon
  if entity then
    identityIcon = content:CreateTexture(nil, "ARTWORK")
    identityIcon:SetPoint("TOPLEFT", 0, -1)
    identityIcon:SetSize(30, 30)
    heading:ClearAllPoints(); heading:SetPoint("TOPLEFT", 40, -5); heading:SetWidth(width - 136)
  end
  local state = { days = 30, character = false, profession = false }
  local filters = UI.FilterBar(content, width, -42)
  page.filters = filters
  local period = filters:Period(state, function() page:Refresh(true) end)
  local characters, professions
  if kind ~= "Character" then
    characters = filters:Select("Character", {}, function(value)
      state.character, state.profession = value, false; page:Refresh(true)
    end)
  end
  if kind ~= "Profession" then
    professions = filters:Select("Profession", {}, function(value) state.profession = value; page:Refresh(true) end)
  end
  local status = UI.Text(content, 520, -58, width - 520, 24)
  function page:Filter()
    local filter = UI.Population(kind == "Character" and self.identity.key or state.character,
      kind == "Profession" and self.identity.skillLineId or state.profession)
    filter.time = period:Time()
    return filter
  end
  local tabs, overview = nil, content
  if kind ~= "Logbook" then
    page.summary = UI.ProductionSummary(content, width, -100, function(recipe) navigate("Recipe", recipe) end, kind == "Character")
  end
  if entity then
    tabs = UI.TabbedContent(content, width, height - 248, -248, { "Overview", "Craft History" },
      function(name) state.view = name end)
    page.tabbed, overview = tabs, tabs.views.Overview
    page.history = UI.ScrollList(tabs.views["Craft History"], 0, 0, width - 24, height - 299,
      UI.HistoryColumns(width - 24, kind), function(craft) openCraft(craft.id) end, "No crafts in this period")
    if kind == "Character" then
      page.professionSlots = {}
      for index = 1, 2 do
        local slot = UI.NavItem(content, 40, function(entry)
          if entry.details then navigate("Profession", entry.details) end
        end)
        slot:SetSize(32, 30)
        slot:SetPoint("TOPLEFT", width - 84 + (index - 1) * 36, -2)
        slot.label:Hide()
        slot.icon:ClearAllPoints(); slot.icon:SetPoint("CENTER"); slot.icon:SetSize(24, 24)
        page.professionSlots[index] = slot
      end
    end
  elseif kind == "Logbook" then
    page.history = UI.ScrollList(content, 0, -110, width, height - 110, UI.HistoryColumns(width, "Logbook"),
      function(craft) openCraft(craft.id) end, "No crafts in this period")
  end
  local recipesHeading
  if kind ~= "Logbook" then
    local inner = entity and width - 24 or width
    page.chart = UI.Chart(overview, 0, entity and 0 or -248, inner)
    recipesHeading = UI.Section(overview, "Most-crafted recipes", 0, entity and -168 or -416, inner)
    page.topRecipes = UI.RecipeTable(overview, 0, entity and -200 or -448, inner,
      math.max(58, height - (entity and 499 or 448)), function(recipe) navigate("Recipe", recipe) end)
  end
  function filters.onLayout(filterHeight)
    local top = 48 + filterHeight
    local summaryHeight = page.summary and page.summary:GetHeight() + 8 or 0
    if page.summary then page.summary:ClearAllPoints(); page.summary:SetPoint("TOPLEFT", 0, -top) end
    if tabs then
      tabs:ClearAllPoints(); tabs:SetPoint("TOPLEFT", 0, -top - summaryHeight)
      tabs:Resize(height - top - summaryHeight)
      local viewHeight = height - top - summaryHeight - 51
      page.history:SetViewportHeight(viewHeight)
      local chartHeight = math.min(168, viewHeight - 90)
      page.chart:Layout(chartHeight)
      recipesHeading:ClearAllPoints(); recipesHeading:SetPoint("TOPLEFT", 0, -chartHeight)
      page.topRecipes:ClearAllPoints(); page.topRecipes:SetPoint("TOPLEFT", 0, -chartHeight - 32)
      page.topRecipes:SetViewportHeight(viewHeight - chartHeight - 32)
    elseif page.chart then
      page.chart:ClearAllPoints(); page.chart:SetPoint("TOPLEFT", 0, -top - summaryHeight)
      recipesHeading:ClearAllPoints(); recipesHeading:SetPoint("TOPLEFT", 0, -top - summaryHeight - 168)
      page.topRecipes:ClearAllPoints(); page.topRecipes:SetPoint("TOPLEFT", 0, -top - summaryHeight - 200)
      page.topRecipes:SetViewportHeight(math.max(58, height - top - summaryHeight - 200))
    else
      page.history:ClearAllPoints(); page.history:SetPoint("TOPLEFT", 0, -top)
      page.history:SetViewportHeight(height - top)
    end
  end
  if page.history then
    UI.LazyList(page.history, function(cursor)
      local result, reason = ArtisanLogbookAPI.GetCrafts(page:Filter(), { limit = 40, cursor = cursor })
      return result and result.crafts, result and result.nextCursor or reason
    end)
  end
  function page:Refresh(reset, preserve)
    local character = kind == "Character" and self.identity.key or state.character
    if characters then characters:Update(UI.Choices("characters"), state.character) end
    if professions then
      local available = UI.Choices("professions", character)
      if not UI.HasChoice(available, state.profession) then state.profession = false end
      professions:Update(available, state.profession)
      status:SetText("")
    end
    period:UpdateState(state)
    local filter = self:Filter()
    if self.chart then
      local result, reason = ArtisanLogbookAPI.GetCraftSeries(filter)
      if not result then status:SetText(reason or "Unavailable") end
      local series = result and result.series or {}
      self.chart:Render(series, filter.time.from, filter.time.to)
      self.summary:Render(series, filter)
      filters.onLayout(filters:GetHeight())
      if self.topRecipes then
        self.topRecipes:Render(self.summary.recipes, filter)
      end
    end
    if self.professionSlots then
      local primary = {}
      for _, profession in ipairs(ArtisanLogbookAPI.GetProfessions(self.identity.key) or {}) do
        if UI.professionIcons[profession.skillLineId] then
          primary[#primary + 1] = profession
          if #primary == 2 then break end
        end
      end
      for index, slot in ipairs(self.professionSlots) do
        local entry = primary[index]
        slot:Update({ label = entry and UI.Name(entry) or "",
          icon = UI.ProfessionIcon(entry and entry.skillLineId), details = entry }, false)
        slot:SetShown(entry ~= nil)
      end
    end
    if self.history and (reset or not self.loaded) then self.history:Reload(preserve) end
    self.loaded = true
  end
  function page:Open(identity)
    local changed = self.identity ~= identity and (not self.identity or not identity or
      (self.identity.key or self.identity.skillLineId) ~= (identity.key or identity.skillLineId))
    if changed then
      if self.identity then
        state.history = self.history and self.history:Save()
        self.states[self.identity.key or self.identity.skillLineId] = state
      end
      self.identity = identity
      state = identity and self.states[identity.key or identity.skillLineId] or nil
      state = state or { days = 30, character = false, profession = false }
      self.loaded = false
      if self.history and state.history then self.history:Restore(state.history); self.loaded = true end
      if tabs then tabs:Select(state.view or "Overview") end
    end
    if identityIcon then
      identityIcon:SetTexture(kind == "Character" and "Interface\\Icons\\INV_Helmet_03" or UI.ProfessionIcon(identity.skillLineId))
      heading:SetText(kind == "Character" and UI.CharacterName(identity, content) or UI.Name(identity))
    end
    local stale = state.revision ~= (self.revision or 0)
    if changed or not self.loaded or self.dirty or stale then
      self:Refresh(self.dirty or stale, true)
      self.dirty, state.revision = false, self.revision or 0
    end
  end
end