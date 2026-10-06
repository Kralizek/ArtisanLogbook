local _, addon = ...
local UI = addon.UI
local reagentMetadata = {}

local function resolveReagentMetadata(itemId, entry, qualityOnly)
  if not qualityOnly and entry.icon == nil and type(GetItemIcon) == "function" then
    local ok, icon = pcall(GetItemIcon, itemId)
    if ok and (type(icon) == "number" or type(icon) == "string") then entry.icon = icon end
  end
  if entry.qualityAtlas == nil and C_TradeSkillUI and type(C_TradeSkillUI.GetItemReagentQualityInfo) == "function" then
    local ok, info = pcall(C_TradeSkillUI.GetItemReagentQualityInfo, itemId)
    if ok and type(info) == "table" and type(info.icon) == "string" then entry.qualityAtlas = info.icon end
  end
end

local function reagentDisplay(itemId)
  local entry = reagentMetadata[itemId]
  if not entry then
    entry = {}
    reagentMetadata[itemId] = entry
    resolveReagentMetadata(itemId, entry)
  end
  return entry
end

local function updateReagentVisuals(cell, metadata)
  cell.icon:SetTexture(metadata.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
  cell.quality:SetShown(metadata.qualityAtlas ~= nil)
  if metadata.qualityAtlas then cell.quality:SetAtlas(metadata.qualityAtlas) end
end

function UI.CataloguePage(page, width, height, openRecipe)
  UI.Section(page, "Recipes", 0, -2, width)
  local character, profession, sort, search = false, false, "name", ""
  local filterWidth = (width - 96) / 4
  local characters = UI.Selector(page, 0, -42, filterWidth, {}, function(value)
    character, profession = value, false; page:Refresh(true)
  end, "Character")
  local professions = UI.Selector(page, filterWidth + 32, -42, filterWidth, {}, function(value)
    profession = value; page:Refresh(true)
  end, "Profession")
  local sorts = UI.Selector(page, 2 * (filterWidth + 32), -42, filterWidth, {
    { label = "Recipe name", value = "name" }, { label = "Profession", value = "profession" },
    { label = "Most crafted", value = "count" },
  }, function(value) sort = value; page:Refresh(true) end, "Sort")
  UI.Text(page, 3 * (filterWidth + 32), -42, filterWidth, 16, "GameFontNormalSmall"):SetText("Search")
  local searchInput = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
  searchInput:SetPoint("TOPLEFT", 3 * (filterWidth + 32) + 4, -60)
  searchInput:SetSize(filterWidth - 8, 24)
  searchInput:SetAutoFocus(false); searchInput:SetMaxLetters(120)
  searchInput:SetScript("OnEnterPressed", function(self) self:ClearFocus(); page:Refresh(true) end)
  searchInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  searchInput:SetScript("OnTextChanged", function(self)
    page.pendingSearch, page.searchDelay = self:GetText(), .2
    page:SetScript("OnUpdate", function(self, elapsed)
      self.searchDelay = self.searchDelay - elapsed
      if self.searchDelay <= 0 then self:Refresh(true) end
    end)
  end)
  page.searchInput = searchInput
  local availableWidth = width - 24
  local list = UI.ScrollList(page, 0, -110, width, height - 110, {
    { title = "Recipe", width = availableWidth * .53, value = function(row) return UI.Name(row.recipe) end,
      icon = function(row) return UI.RecipeIcon(row.recipe) end },
    { title = "Profession", width = availableWidth * .32, value = function(row) return UI.Name(row.profession) end },
    { title = "Crafts", width = availableWidth * .15, value = function(row) return tostring(row.craftCount) end },
  }, function(row) openRecipe(row.recipe) end, "No recipes in this selection")
  page.catalogue = list
  UI.LazyList(list, function(cursor)
    local result, reason = ArtisanLogbookAPI.GetRecipeSummaries({ character = character or nil,
      profession = profession or nil, sort = sort, search = search, limit = 40, cursor = cursor })
    return result and result.recipes, result and result.nextCursor or reason
  end)
  function page:Refresh(reset, preserve)
    self:SetScript("OnUpdate", nil)
    if self.pendingSearch ~= nil then search = self.pendingSearch; self.pendingSearch = nil end
    characters:Update(UI.Choices("characters"), character)
    local available = UI.Choices("professions", character)
    if not UI.HasChoice(available, profession) then profession = false end
    professions:Update(available, profession)
    sorts:Update(sorts.choices, sort)
    if reset or not self.loaded then list:Reload(preserve) end
    self.loaded = true
  end
  function page:Open()
    if self.pendingSearch ~= nil then self:Refresh(true)
    elseif not self.loaded or self.dirty then self:Refresh(self.dirty, true); self.dirty = false end
  end
end

function UI.ReagentAmount(row, amount, complete)
  if row[amount] == nil then return "Unknown" end
  return tostring(row[amount]) .. (row[complete] and "" or " (partial)")
end

function UI.ReagentDetail(parent, width, height, openRecipe)
  local detail = CreateFrame("Frame", nil, parent)
  detail:SetSize(width, height)
  local content, scroll = UI.PageScroll(detail, width, height, 510)
  detail.scroll = scroll
  local inner = width - 28
  detail.icon = content:CreateTexture(nil, "ARTWORK")
  detail.icon:SetSize(32, 32); detail.icon:SetPoint("TOPLEFT", 0, 0)
  detail.quality = content:CreateTexture(nil, "OVERLAY")
  detail.quality:SetSize(16, 16); detail.quality:SetPoint("TOPLEFT", 18, -18)
  local heading = UI.Text(content, 40, 0, inner - 40, 36, "GameFontNormal")
  local identity = UI.Text(content, 0, -40, inner, 18)
  local overview = CreateFrame("Frame", nil, content)
  overview:SetPoint("TOPLEFT", 0, -104); overview:SetSize(inner, 400)
  local recipes = UI.ScrollList(content, 0, -104, inner, 380, {
    { title = "Recipe", width = (inner - 24) * .50, value = function(row) return UI.Name(row.recipe) end,
      icon = function(row) return UI.RecipeIcon(row.recipe) end },
    { title = "Crafts", width = (inner - 24) * .18, value = function(row) return tostring(row.crafts) end },
    { title = "Returned", width = (inner - 24) * .32, value = function(row)
      return UI.ReagentAmount(row, "returnedQuantity", "returnComplete")
    end },
  }, function(row) if row.recipe then openRecipe(row.recipe) end end, "No retained recipe uses")
  detail.recipes, detail.tabs = recipes, {}
  function detail:SelectView(name)
    self.activeView = name
    overview:SetShown(name == "Overview"); recipes:SetShown(name == "Used in Recipes")
    for title, tab in pairs(self.tabs) do tab:Select(title == name) end
  end
  for index, title in ipairs({ "Overview", "Used in Recipes" }) do
    detail.tabs[title] = UI.Tab(content, title, (index - 1) * inner / 2, -66, inner / 2 - 2,
      function() detail:SelectView(title) end)
  end
  detail:SelectView("Overview")
  detail.fields = {}
  for index, entry in ipairs({ { "Allocated (retained)", "allocated" }, { "Returned (recorded)", "returned" },
      { "Uses (retained)", "crafts" }, { "Characters (retained)", "characters" },
      { "Return / allocation (retained)", "rate" } }) do
    UI.Text(overview, 0, -(index - 1) * 26, inner * .67, 24):SetText(entry[1])
    local value = UI.Text(overview, inner * .67, -(index - 1) * 26, inner * .33, 24)
    value:SetJustifyH("RIGHT")
    detail.fields[entry[2]] = value
  end
  detail.chart = UI.Chart(overview, 0, -142, inner, true)
  UI.Text(overview, 0, -308, inner, 18):SetText("|cff2787c2Allocated|r   |cff287040Returned|r")
  detail.status = UI.Text(overview, 0, -336, inner, 54)
  detail.worker = CreateFrame("Frame", nil, detail)
  local function accumulate(target, allocated, returned, complete)
    target.crafts = (target.crafts or 0) + 1
    if allocated ~= nil then target.allocatedQuantity = (target.allocatedQuantity or 0) + allocated end
    if returned ~= nil then target.returnedQuantity = (target.returnedQuantity or 0) + returned end
    target.returnComplete = target.returnComplete ~= false and complete
  end
  function detail:Open(row, filter)
    self.worker:SetScript("OnUpdate", nil)
    local changed = not self.row or not row or self.row.item.id ~= row.item.id
    self.row = row
    if changed then scroll:SetVerticalScroll(0) end
    heading:SetText(row and UI.Elide(UI.Name(row.item), math.floor((inner - 40) / 7) * 2) or "Select a reagent")
    local professions = {}
    for _, entry in ipairs(row and row.professions or {}) do professions[#professions + 1] = UI.Name(entry) end
    identity:SetText(row and UI.Elide("#" .. row.item.id .. "  " .. table.concat(professions, ", "), math.floor(inner / 6)) or "")
    if row then updateReagentVisuals(self, reagentDisplay(row.item.id))
    else self.icon:SetTexture(nil); self.quality:Hide() end
    for _, field in pairs(self.fields) do field:SetText("-") end
    recipes:Reset(); self.chart:Hide(); self.status:SetText("")
    if not row then return end
    self.fields.allocated:SetText(UI.ReagentAmount(row, "allocatedQuantity", "allocationComplete"))
    self.fields.returned:SetText(UI.ReagentAmount(row, "returnedQuantity", "returnComplete"))
    self.status:SetText("Loading retained craft details...")
    local cursor, totals, characters, byRecipe, days = nil, { crafts = 0, returnComplete = true }, {}, {}, {}
    self.worker:SetScript("OnUpdate", function(worker)
      local result, reason = ArtisanLogbookAPI.GetCrafts(filter, { limit = 100, cursor = cursor })
      if not result then
        worker:SetScript("OnUpdate", nil); detail.status:SetText(reason or "Unavailable"); return
      end
      for _, craft in ipairs(result.crafts) do
        local matched, allocated, returned, complete = false, nil, nil, craft.resourcefulnessComplete == true
        for _, reagent in ipairs(craft.reagents or {}) do
          if reagent.item and reagent.item.id == row.item.id then
            matched = true
            if reagent.allocatedQuantity ~= nil then allocated = (allocated or 0) + reagent.allocatedQuantity
            else complete = false end
            if reagent.returnedQuantity ~= nil then returned = (returned or 0) + reagent.returnedQuantity
            else complete = false end
          end
        end
        if matched then
          if allocated and returned and returned > allocated then complete = false end
          accumulate(totals, allocated, returned, complete)
          if craft.character then characters[craft.character.key] = true end
          local recipeId = craft.recipe and craft.recipe.id or 0
          local use = byRecipe[recipeId] or { recipe = craft.recipe, id = recipeId }
          byRecipe[recipeId] = use; accumulate(use, allocated, returned, complete)
          local day = math.floor(craft.timestamp / 86400) * 86400
          days[day] = days[day] or { bucketStart = day }
          accumulate(days[day], allocated, returned, complete)
        end
      end
      cursor = result.nextCursor
      if cursor then return end
      worker:SetScript("OnUpdate", nil)
      local characterCount, ranked, series = 0, {}, {}
      for _ in pairs(characters) do characterCount = characterCount + 1 end
      for _, use in pairs(byRecipe) do ranked[#ranked + 1] = use end
      table.sort(ranked, function(left, right)
        if left.crafts ~= right.crafts then return left.crafts > right.crafts end
        return left.id < right.id
      end)
      for _, day in pairs(days) do series[#series + 1] = day end
      table.sort(series, function(left, right) return left.bucketStart < right.bucketStart end)
      detail.totals, detail.series = totals, series
      detail.fields.crafts:SetText(tostring(totals.crafts))
      detail.fields.characters:SetText(tostring(characterCount))
      if totals.returnComplete and totals.allocatedQuantity and totals.allocatedQuantity > 0 and
          totals.allocatedQuantity < math.huge and totals.returnedQuantity and totals.returnedQuantity < math.huge then
        detail.fields.rate:SetText(string.format("%.1f%%", 100 * totals.returnedQuantity / totals.allocatedQuantity))
      end
      recipes:Append(ranked)
      local from, to = UI.Range(GetServerTime(), 30)
      from = filter.time and filter.time.from or (series[1] and series[1].bucketStart) or from
      to = filter.time and filter.time.to or (series[#series] and series[#series].bucketStart + 86400) or to
      detail.chart:Render(series, from, to); detail.chart:Show()
      detail.status:SetText(totals.crafts == 0 and "No retained uses. Recorded returns may outlive craft details." or
        (totals.returnComplete and "Chart and recipe uses: retained craft details." or "Chart and recipe uses: partial retained details."))
    end)
  end
  return detail
end

function UI.ReagentsPage(page, width, height, openRecipe)
  UI.Section(page, "Reagents", 0, -2, width)
  local profession, trivial, sort, search, character, days = false, "all", "name", "", false, false
  local filterWidth = (width - 64) / 3
  local periods = { { label = "All time", value = false } }
  for _, entry in ipairs(UI.ranges) do periods[#periods + 1] = entry end
  local period = UI.Selector(page, 0, -42, filterWidth, periods, function(value)
    days = value; page:Refresh(true)
  end, "Period")
  local characters = UI.Selector(page, filterWidth + 32, -42, filterWidth, {}, function(value)
    character, profession = value, false; page:Refresh(true)
  end, "Character")
  local professions = UI.Selector(page, 2 * (filterWidth + 32), -42, filterWidth, {}, function(value)
    profession = value; page:Refresh(true)
  end, "Profession")
  local trivialChoices = {
    { label = "All", value = "all" }, { label = "Trivial", value = "trivial" },
    { label = "Non-trivial", value = "non-trivial" },
  }
  local trivialFilter = UI.Selector(page, 0, -88, filterWidth, trivialChoices, function(value)
    trivial = value; page:Refresh(true)
  end, "Trivial state")
  UI.Text(page, 2 * (filterWidth + 32), -88, filterWidth, 16, "GameFontNormalSmall"):SetText("Search")
  local searchInput = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
  searchInput:SetPoint("TOPLEFT", 2 * (filterWidth + 32) + 4, -106)
  searchInput:SetSize(filterWidth - 4, 24)
  searchInput:SetAutoFocus(false)
  searchInput:SetMaxLetters(120)
  searchInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  searchInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  searchInput:SetScript("OnTextChanged", function(self)
    page.pendingSearch = self:GetText()
    page.searchDelay = .2
    page:SetScript("OnUpdate", function(self, elapsed)
      self.searchDelay = self.searchDelay - elapsed
      if self.searchDelay <= 0 then self:SetScript("OnUpdate", nil); self:Refresh(true) end
    end)
  end)
  page.searchInput = searchInput
  local sorts = UI.Selector(page, filterWidth + 32, -88, filterWidth, {
    { label = "Name", value = "name" }, { label = "Most allocated", value = "allocated" },
    { label = "Most returned", value = "returned" }, { label = "Recipe count", value = "recipes" },
  }, function(value) sort = value; page:Refresh(true) end, "Sort")
  page.summary = {}
  for index, entry in ipairs({ { "Reagents", "INV_Misc_Herb_19" },
      { "Allocated (retained)", "INV_Misc_Bag_10" }, { "Returned (recorded)", "Trade_Alchemy" } }) do
    page.summary[index] = UI.Stat(page, entry[1], "Interface\\Icons\\" .. entry[2],
      (index - 1) * width / 3, -142, width / 3 - 12)
  end
  local listWidth = math.floor(width * .55)
  local available = listWidth - 24
  local nameWidth = available * .40
  local list = UI.ScrollList(page, 0, -224, listWidth, height - 258, {
    { title = "Reagent", width = nameWidth, value = function(row)
        return UI.Name(row.item) .. " (#" .. row.item.id .. ")"
      end,
      create = function(parent, left)
        local cell = CreateFrame("Frame", nil, parent)
        cell:SetPoint("TOPLEFT", left, 0); cell:SetSize(nameWidth, 28)
        cell.icon = cell:CreateTexture(nil, "ARTWORK")
        cell.icon:SetSize(22, 22); cell.icon:SetPoint("TOPLEFT", 2, -3)
        cell.quality = cell:CreateTexture(nil, "OVERLAY")
        cell.quality:SetSize(14, 14); cell.quality:SetPoint("TOPLEFT", 12, -14)
        cell.name = UI.Text(cell, 30, -1, nameWidth - 34, 14)
        cell.name:SetWordWrap(false)
        cell.identity = UI.Text(cell, 30, -15, nameWidth - 34, 13)
        return cell
      end,
      update = function(cell, row)
        updateReagentVisuals(cell, reagentDisplay(row.item.id))
        cell.name:SetText(UI.Elide(UI.Name(row.item), math.max(3, math.floor((nameWidth - 34) / 7))))
        cell.identity:SetText("#" .. row.item.id .. (row.quality ~= nil and " | Quality " .. row.quality or ""))
      end },
    { title = "Allocated", width = available * .23, value = function(row)
      return UI.ReagentAmount(row, "allocatedQuantity", "allocationComplete")
    end },
    { title = "Returned", width = available * .23, value = function(row)
      return UI.ReagentAmount(row, "returnedQuantity", "returnComplete")
    end },
    { title = "Trivial", width = available * .14, value = function(row) return UI.IsTrivial(row.item.id) and "Yes" or "No" end,
      create = function(parent, left)
        local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        check:SetPoint("TOPLEFT", left + 8, -2); check:SetSize(24, 24)
        check:SetScript("OnClick", function(self) UI.SetTrivial(self.itemId, self:GetChecked() == true) end)
        check:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:SetText("Trivial reagent #" .. self.itemId)
          GameTooltip:AddLine("Excluded from non-trivial return statistics", 1, 1, 1)
          GameTooltip:Show()
        end)
        check:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return check
      end,
      update = function(check, row) check.itemId = row.item.id; check:SetChecked(UI.IsTrivial(row.item.id)) end },
  }, function(row) page:SelectReagent(row) end, "No recorded reagents in this selection", true)
  page.catalogue = list
  local detail = UI.ReagentDetail(page, width - listWidth - 16, height - 258, openRecipe)
  detail:SetPoint("TOPLEFT", listWidth + 16, -224)
  page.detail = detail
  function page:Filter()
    local filter = UI.Population(character, profession)
    if days then
      local from, to = UI.Range(GetServerTime(), days)
      filter.time = { from = from, to = to }
    end
    return filter
  end
  function page:SelectReagent(row)
    self.selectedItemId = row and row.item.id
    list:SetSelection(self.selectedItemId)
    detail:Open(row, self:Filter())
  end
  local function refreshMetadata(itemId, qualityOnly)
    local entry = reagentMetadata[itemId]
    if not entry then return end
    local icon, atlas = entry.icon, entry.qualityAtlas
    resolveReagentMetadata(itemId, entry, qualityOnly)
    if icon == entry.icon and atlas == entry.qualityAtlas then return end
    for _, row in ipairs(list.rows) do
      if row.item and row.item.item.id == itemId then updateReagentVisuals(row.widgets[1].widget, entry) end
    end
    if detail.row and detail.row.item.id == itemId then updateReagentVisuals(detail, entry) end
  end
  page:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  page:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
  page:SetScript("OnEvent", function(_, event, itemId, success)
    if event == "GET_ITEM_INFO_RECEIVED" then
      if success then refreshMetadata(itemId) end
    elseif event == "TRADE_SKILL_LIST_UPDATE" then
      for id, entry in pairs(reagentMetadata) do
        if entry.qualityAtlas == nil then refreshMetadata(id, true) end
      end
    end
  end)
  UI.Text(page, 0, -height + 26, width, 22):SetText("Allocated: retained craft facts. Returned: recorded totals.")
  local selectedItems, excludedItems
  UI.LazyList(list, function(cursor)
    local result, reason = ArtisanLogbookAPI.GetReagentSummaries({ profession = profession or nil,
      character = character or nil, time = page:Filter().time,
      search = search, sort = sort, items = selectedItems, excludeItems = excludedItems, limit = 40, cursor = cursor })
    page.summary[1].value:SetText(result and tostring(result.totalCount) or "-")
    for index, metric in ipairs({ "allocatedQuantity", "returnedQuantity" }) do
      local totals = result and result.totals or {}
      page.summary[index + 1].value:SetText(UI.Value(totals[metric]))
      local complete = index == 1 and totals.allocationComplete or index == 2 and totals.returnComplete
      page.summary[index + 1].note:SetText(totals[metric] and not complete and "Partial details" or "")
    end
    return result and result.reagents, result and result.nextCursor or reason
  end)
  function page:Refresh(reset, preserve)
    self:SetScript("OnUpdate", nil)
    if self.pendingSearch ~= nil then search = self.pendingSearch; self.pendingSearch = nil end
    period:Update(periods, days)
    characters:Update(UI.Choices("characters"), character)
    local availableProfessions = UI.Choices("professions", character)
    if not UI.HasChoice(availableProfessions, profession) then profession = false end
    professions:Update(availableProfessions, profession)
    trivialFilter:Update(trivialChoices, trivial)
    sorts:Update(sorts.choices, sort)
    selectedItems = trivial == "trivial" and UI.TrivialItemIds() or nil
    excludedItems = trivial == "non-trivial" and UI.TrivialItemIds() or nil
    if reset or not self.loaded then list:Reload(preserve) end
    local selected
    for _, row in ipairs(list.items) do if row.item.id == self.selectedItemId then selected = row; break end end
    if not selected and self.selectedItemId and
        (trivial == "all" or (trivial == "trivial") == UI.IsTrivial(self.selectedItemId)) then
      local result = ArtisanLogbookAPI.GetReagentSummaries({ profession = profession or nil,
        character = character or nil, time = self:Filter().time, search = search,
        items = { self.selectedItemId }, limit = 40 })
      selected = result and result.reagents[1]
    end
    self:SelectReagent(selected or list.items[1])
    self.loaded, self.dirty = true, false
  end
  function page:Open()
    if self.pendingSearch ~= nil then self:Refresh(true)
    elseif not self.loaded or self.dirty then self:Refresh(true, true) end
  end
  UI.RegisterTrivialCallback(function()
    page.dirty = true
    if page:IsShown() then page:Refresh(true, true) end
  end)
end