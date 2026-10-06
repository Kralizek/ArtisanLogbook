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
  return tostring(total)
end

function UI.Stat(parent, title, icon, x, y, width)
  local tile = CreateFrame("Frame", nil, parent)
  tile:SetPoint("TOPLEFT", x, y)
  tile:SetSize(width, 88)
  local texture = tile:CreateTexture(nil, "ARTWORK")
  texture:SetSize(24, 24)
  texture:SetPoint("TOPLEFT", 0, -8)
  texture:SetTexture(icon)
  UI.Text(tile, 32, -6, width - 38, 18, "GameFontNormalSmall"):SetText(title)
  tile.value = UI.Text(tile, 32, -28, width - 38, 22, "GameFontNormalLarge")
  tile.note = UI.Text(tile, 32, -52, width - 38, 34)
  return tile
end

function UI.ProductionSummary(parent, width, y)
  local summary = CreateFrame("Frame", nil, parent)
  summary:SetSize(width, 186)
  summary:SetPoint("TOPLEFT", 0, y)
  local entries = {
    { "Crafts", "Trade_BlackSmithing" }, { "Total output", "INV_Misc_Bag_10" },
    { "Concentration spent", "Spell_Arcane_Arcane01" }, { "Multicraft bonus", "Trade_Engineering" },
    { "Reagents returned", "INV_Misc_Herb_19" }, { "Most crafted", "INV_Misc_Book_09" },
  }
  summary.tiles = {}
  local column = width / 3
  for index, entry in ipairs(entries) do
    summary.tiles[index] = UI.Stat(summary, entry[1], "Interface\\Icons\\" .. entry[2],
      ((index - 1) % 3) * column, -math.floor((index - 1) / 3) * 94, column - 10)
  end
  function summary:Render(series, filter)
    local totals, recipes = UI.Aggregate(series)
    self.totals, self.recipes = totals, recipes
    self.tiles[1].value:SetText(tostring(totals.craftCount))
    self.tiles[1].note:SetText("")
    for index, metric in pairs({ [2] = "outputQuantity", [3] = "concentrationSpent", [4] = "multicraftBonus" }) do
      local known = totals[metric .. "ObservedCount"]
      self.tiles[index].value:SetText(known == 0 and "-" or tostring(totals[metric]))
      self.tiles[index].note:SetText(known < totals.craftCount and "Some crafts have no details" or "")
    end
    local share = UI.MeasuredShare(totals, "multicraftBonus", "outputQuantity")
    if share ~= "Unknown" then self.tiles[4].note:SetText(share .. " of total output") end
    local top = recipes[1]
    self.tiles[6].value:SetText(top and UI.Elide(UI.Name(top.recipe), math.floor((column - 38) / 10)) or "-")
    self.tiles[6].note:SetText(top and (top.craftCount .. " crafts") or "No crafts in this period")
    self.tiles[6]:EnableMouse(true)
    self.tiles[6]:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(top and UI.Name(top.recipe) or "No crafts in this period")
      GameTooltip:Show()
    end)
    self.tiles[6]:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.tiles[5].value:SetText("...")
    self.tiles[5].note:SetText("")
    UI.ReturnTotals(self, recipes, { time = filter.time, characters = filter.characters }, function(total, crafts, complete)
      self.tiles[5].value:SetText(UI.ReturnQuantity(total, crafts, complete))
      self.tiles[5].note:SetText(total and (complete < crafts and "Some return details missing" or "Recorded returns") or "")
    end)
  end
  return summary
end

function UI.PopulationPage(page, kind, width, height, navigate, openCraft)
  local content, scroll = page, nil
  if kind ~= "Logbook" then
    content, scroll = UI.PageScroll(page, width, height, kind == "Overview" and 492 or 790)
    width = width - 28
  end
  page.content, page.scroll, page.states = content, scroll, {}
  local heading = UI.Section(content, kind, 0, -2, width)
  local identityIcon
  if kind == "Character" or kind == "Profession" then
    identityIcon = content:CreateTexture(nil, "ARTWORK")
    identityIcon:SetPoint("TOPLEFT", 0, -1)
    identityIcon:SetSize(30, 30)
    heading:ClearAllPoints(); heading:SetPoint("TOPLEFT", 40, -5); heading:SetWidth(width - 40)
  end
  local state = { days = 30, character = false, profession = false }
  local filterWidth = math.min(174, (width - 72) / 3)
  local period = UI.Selector(content, 0, -42, filterWidth, UI.ranges, function(value)
    state.days = value; page:Refresh(true)
  end, "Period")
  local characters, professions
  if kind ~= "Character" then
    characters = UI.Selector(content, filterWidth + 32, -42, filterWidth, {}, function(value)
      state.character, state.profession = value, false; page:Refresh(true)
    end, "Character")
  end
  if kind ~= "Profession" then
    professions = UI.Selector(content, (kind == "Character" and 1 or 2) * (filterWidth + 32), -42,
      filterWidth, {}, function(value) state.profession = value; page:Refresh(true) end, "Profession")
  end
  local status = UI.Text(content, 0, -85, width, 20)
  function page:Filter()
    local filter = UI.Population(kind == "Character" and self.identity.key or state.character,
      kind == "Profession" and self.identity.skillLineId or state.profession)
    local from, to = UI.Range(GetServerTime(), state.days)
    filter.time = { from = from, to = to }
    return filter
  end
  if kind ~= "Logbook" then
    page.chart = UI.Chart(content, 0, -112, width)
    page.summary = UI.ProductionSummary(content, width, -292)
  end
  if kind == "Character" or kind == "Profession" then
    local rankedWidth = kind == "Character" and width * .54 or width
    UI.Section(content, "Most-crafted recipes", kind == "Character" and width * .46 or 0, -490, rankedWidth)
    page.topRecipes = UI.ScrollList(content, kind == "Character" and width * .46 or 0, -523, rankedWidth, 218, {
      { title = "Recipe", width = (rankedWidth - 24) * .78, value = function(row) return UI.Name(row.recipe) end,
        icon = function(row) return UI.RecipeIcon(row.recipe) end },
      { title = "Crafts", width = (rankedWidth - 24) * .22, value = function(row) return tostring(row.craftCount) end },
    }, function(row) if row.recipe then navigate("Recipe", row.recipe) end end, "No recipes in this period")
    if kind == "Character" then
      UI.Section(content, "Recorded primary professions", 0, -490, width * .43)
      page.professionSlots = {}
      for index = 1, 2 do
        local slot = UI.NavItem(content, width * .43, function(entry)
          if entry.details then navigate("Profession", entry.details) end
        end)
        slot:SetPoint("TOPLEFT", 0, -535 - (index - 1) * 76)
        page.professionSlots[index] = slot
      end
    else
      content:SetHeight(math.max(height, 1050))
      UI.Section(content, "Recent crafts", 0, -768, width)
      page.history = UI.ScrollList(content, 0, -804, width, 230, UI.HistoryColumns(width),
        function(craft) openCraft(craft.id) end, "No retained crafts in this period")
    end
  elseif kind == "Logbook" then
    page.history = UI.ScrollList(content, 0, -110, width, height - 110, UI.HistoryColumns(width),
      function(craft) openCraft(craft.id) end, "No retained crafts in this period")
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
      status:SetText(character and #available == 1 and "No professions recorded" or "")
    end
    period:Update(UI.ranges, state.days)
    local filter = self:Filter()
    if self.chart then
      local result, reason = ArtisanLogbookAPI.GetCraftSeries(filter)
      if not result then status:SetText(reason or "Unavailable") end
      local series = result and result.series or {}
      self.chart:Render(series, filter.time.from, filter.time.to)
      self.summary:Render(series, filter)
      if self.topRecipes then
        local top = {}
        for index = 1, math.min(5, #self.summary.recipes) do top[index] = self.summary.recipes[index] end
        self.topRecipes:Reset(); self.topRecipes:Append(top)
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
        slot:Update({ label = entry and UI.Name(entry) or "Not recorded",
          icon = UI.ProfessionIcon(entry and entry.skillLineId), details = entry }, false)
        slot.label:SetTextColor(unpack(UI.ink))
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
        state.offset = scroll and scroll:GetVerticalScroll() or 0
        state.history = self.history and self.history:Save()
        self.states[self.identity.key or self.identity.skillLineId] = state
      end
      self.identity = identity
      state = identity and self.states[identity.key or identity.skillLineId] or nil
      state = state or { days = 30, character = false, profession = false }
      self.loaded = false
      if scroll then scroll:SetVerticalScroll(state.offset or 0) end
      if self.history and state.history then self.history:Restore(state.history); self.loaded = true end
    end
    if identityIcon then
      identityIcon:SetTexture(kind == "Character" and "Interface\\Icons\\INV_Helmet_03" or UI.ProfessionIcon(identity.skillLineId))
      heading:SetText(kind == "Character" and UI.CharacterName(identity) or UI.Name(identity))
    end
    local stale = state.revision ~= (self.revision or 0)
    if changed or not self.loaded or self.dirty or stale then
      self:Refresh(self.dirty or stale, true)
      self.dirty, state.revision = false, self.revision or 0
    end
  end
end