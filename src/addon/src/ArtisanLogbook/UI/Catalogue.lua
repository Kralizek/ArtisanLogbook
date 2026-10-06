local _, addon = ...
local UI = addon.UI
local reagentMetadata = {}
local reagentCells = setmetatable({}, { __mode = "k" })

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

function UI.ReagentVisual(cell, itemId)
  reagentCells[cell] = itemId
  updateReagentVisuals(cell, reagentDisplay(itemId))
end

function UI.CataloguePage(page, width, height, openRecipe)
  UI.Section(page, "Recipes", 0, -2, width)
  local character, profession, sort, search = false, false, "count", ""
  local filters = UI.FilterBar(page, width, -42)
  page.filters = filters
  local period = filters:Period({ days = false }, function() page:Refresh(true) end, true)
  local characters = filters:Select("Character", {}, function(value)
    character, profession = value, false; page:Refresh(true)
  end)
  local professions = filters:Select("Profession", {}, function(value)
    profession = value; page:Refresh(true)
  end)
  local sorts = filters:Select("Sort", {
    { label = "Recipe name", value = "name" }, { label = "Profession", value = "profession" },
    { label = "Most crafted", value = "count" },
  }, function(value) sort = value; page:Refresh(true) end)
  page.searchInput = filters:Search(function(value) search = value; page:Refresh(true) end)
  local list = UI.RecipeTable(page, 0, -144, width, height - 144, openRecipe)
  page.catalogue = list
  function filters.onLayout(filterHeight)
    list:ClearAllPoints(); list:SetPoint("TOPLEFT", 0, -48 - filterHeight)
    list:SetViewportHeight(height - 48 - filterHeight)
  end
  UI.LazyList(list, function(cursor)
    local result, reason = ArtisanLogbookAPI.GetRecipeSummaries({ character = character or nil,
      profession = profession or nil, time = period:Time(), sort = sort, search = search, limit = 40, cursor = cursor })
    list:Enrich({ time = period:Time(), characters = character and { character } or nil })
    return result and result.recipes, result and result.nextCursor or reason
  end)
  function page:Refresh(reset, preserve)
    period:UpdateState()
    characters:Update(UI.Choices("characters"), character)
    local available = UI.Choices("professions", character)
    if not UI.HasChoice(available, profession) then profession = false end
    professions:Update(available, profession)
    sorts:Update(sorts.choices, sort)
    if reset or not self.loaded then list:Reload(preserve) end
    self.loaded = true
  end
  function page:Open()
    if self.searchInput:GetScript("OnUpdate") then self.searchInput:GetScript("OnEnterPressed")(self.searchInput)
    elseif not self.loaded or self.dirty then self:Refresh(self.dirty, true); self.dirty = false end
  end
end

function UI.ReagentAmount(row, amount, complete)
  return UI.Amount(row[amount], row[complete])
end

function UI.ReagentPage(detail, width, height, openRecipe, openCraft)
  local content, inner = detail, width - 24
  local state = { days = false, character = false, profession = false }
  detail.states = {}
  detail.icon = content:CreateTexture(nil, "ARTWORK")
  detail.icon:SetSize(32, 32); detail.icon:SetPoint("TOPLEFT", 0, 0)
  detail.quality = content:CreateTexture(nil, "OVERLAY")
  detail.quality:SetSize(16, 16); detail.quality:SetPoint("TOPLEFT", 18, -18)
  local heading = UI.Text(content, 40, 0, width - 320, 28, "GameFontNormalLarge")
  local identity = UI.Text(content, 40, -30, width - 40, 18)
  detail.classification = UI.TrivialCheckbox(content, width - 250, 0, function() end)
  local filters = UI.FilterBar(content, width, -58)
  detail.filters = filters
  local period = filters:Period(state, function() detail:Refresh() end, true)
  local characters = filters:Select("Character", {}, function(value) state.character = value; detail:Refresh() end)
  local professions = filters:Select("Profession", {}, function(value) state.profession = value; detail:Refresh() end)
  local summary = CreateFrame("Frame", nil, content)
  summary:SetPoint("TOPLEFT", 0, -110); summary:SetSize(width, 142)
  detail.fields, detail.tiles = {}, {}
  for index, entry in ipairs({ { "Used", "allocated" }, { "Returned", "returned" }, { "Crafts using this", "crafts" },
      { "Crafters", "characters" }, { "Returned / used", "rate" }, { "Recipes using this", "recipes" } }) do
    local tile = UI.Stat(summary, entry[1], "Interface\\Icons\\INV_Misc_Herb_19",
      ((index - 1) % 3) * width / 3, -math.floor((index - 1) / 3) * 70, width / 3 - 12)
    detail.fields[entry[2]], detail.tiles[entry[2]] = tile.value, tile
  end
  local tabs = UI.TabbedContent(content, width, height - 260, -260, { "Overview", "Used in Recipes", "Craft History" },
    function(name) detail.activeView = name; state.view = name end)
  detail.tabbed, detail.tabs = tabs, tabs.buttons
  local overview = tabs.views.Overview
  local recipes = UI.ScrollList(tabs.views["Used in Recipes"], 0, 0, inner, height - 311, {
    { title = "Recipe", width = (inner - 24) * .46, value = function(row) return UI.Name(row.recipe) end,
      icon = function(row) return UI.RecipeIcon(row.recipe) end },
    { title = "Crafts", width = (inner - 24) * .14, value = function(row) return UI.Number(row.crafts) end },
    { title = "Used", width = (inner - 24) * .20, value = function(row) return UI.ReagentAmount(row, "allocatedQuantity", "returnComplete") end },
    { title = "Returned", width = (inner - 24) * .20, value = function(row)
      return UI.ReagentAmount(row, "returnedQuantity", "returnComplete")
    end },
  }, function(row) if row.recipe then openRecipe(row.recipe) end end, "No crafts with ingredient details")
  detail.recipes = recipes
  function detail:SelectView(name) tabs:Select(name) end
  detail.history = UI.ScrollList(tabs.views["Craft History"], 0, 0, inner, height - 311, UI.HistoryColumns(inner),
    function(craft) openCraft(craft.id) end, "No crafts with ingredient details")
  UI.LazyList(detail.history, function(cursor)
    local rows, offset = {}, cursor or 0
    local ids = detail.historyIds or {}
    for index = offset + 1, math.min(offset + 40, #ids) do
      local craft = ArtisanLogbookAPI.GetCraft(ids[index])
      if craft then rows[#rows + 1] = craft end
    end
    return rows, offset + 40 < #ids and offset + 40 or nil
  end)
  detail.chart = UI.Chart(overview, 0, 0, inner, true)
  local legend = UI.Text(overview, 0, -168, inner, 18)
  legend:SetText("|cff2787c2Used|r   |cff287040Returned|r")
  detail.status = UI.Text(overview, 0, -196, inner, 54)
  detail.worker = CreateFrame("Frame", nil, detail)
  function filters.onLayout(filterHeight)
    local top = 64 + filterHeight
    summary:ClearAllPoints(); summary:SetPoint("TOPLEFT", 0, -top)
    tabs:ClearAllPoints(); tabs:SetPoint("TOPLEFT", 0, -top - 150); tabs:Resize(height - top - 150)
    recipes:SetViewportHeight(height - top - 201); detail.history:SetViewportHeight(height - top - 201)
    local chartHeight = math.min(168, height - top - 279)
    detail.chart:Layout(chartHeight)
    legend:ClearAllPoints(); legend:SetPoint("TOPLEFT", 0, -chartHeight)
    detail.status:ClearAllPoints(); detail.status:SetPoint("TOPLEFT", 0, -chartHeight - 28)
    detail.status:SetHeight(50)
  end
  function detail:Filter()
    return { time = period:Time(), characters = state.character and { state.character } or nil,
      professions = state.profession and { state.profession } or nil }
  end
  local function accumulate(target, allocated, returned, complete)
    target.crafts = (target.crafts or 0) + 1
    if allocated ~= nil then target.allocatedQuantity = (target.allocatedQuantity or 0) + allocated end
    if returned ~= nil then target.returnedQuantity = (target.returnedQuantity or 0) + returned end
    target.returnComplete = target.returnComplete ~= false and complete
  end
  function detail:Render(row, filter, preserve)
    self.worker:SetScript("OnUpdate", nil)
    self.row = row
    heading:SetText(row and UI.Elide(UI.Name(row.item), math.floor((inner - 40) / 7) * 2) or "Select a reagent")
    local professions = {}
    for _, entry in ipairs(row and row.professions or {}) do professions[#professions + 1] = UI.Name(entry) end
    identity:SetText(row and UI.Elide("#" .. row.item.id .. "  " .. table.concat(professions, ", "), math.floor(inner / 6)) or "")
    if row then UI.ReagentVisual(self, row.item.id)
    else self.icon:SetTexture(nil); self.quality:Hide() end
    for _, field in pairs(self.fields) do field:SetText("-") end
    local recipeCount, recipeOffset = #recipes.items, recipes.scroll:GetVerticalScroll()
    recipes:Reset(); self.chart:Hide(); self.status:SetText("")
    self.historyState = preserve and self.history:Save() or nil
    self.history:Reset("Loading crafts...")
    if not row then return end
    self.tiles.allocated:SetNumber(row.allocatedQuantity, row.allocationComplete)
    self.tiles.returned:SetNumber(row.returnedQuantity, row.returnComplete)
    self.status:SetText("Loading craft history...")
    local cursor, totals, characters, byRecipe, days, ids = nil, { crafts = 0, returnComplete = true }, {}, {}, {}, {}
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
          ids[#ids + 1] = craft.id
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
      detail.fields.crafts:SetText(UI.Number(totals.crafts))
      detail.fields.characters:SetText(UI.Number(characterCount))
      detail.fields.recipes:SetText(UI.Number(#ranked))
      if totals.returnComplete and totals.allocatedQuantity and totals.allocatedQuantity > 0 and
          totals.allocatedQuantity < math.huge and totals.returnedQuantity and totals.returnedQuantity < math.huge then
        detail.fields.rate:SetText(UI.Percent(totals.returnedQuantity, totals.allocatedQuantity))
      end
      UI.LazyList(recipes, function(cursor)
        local offset, rows = cursor or 0, {}
        for index = offset + 1, math.min(offset + 40, #ranked) do rows[#rows + 1] = ranked[index] end
        return rows, offset + 40 < #ranked and offset + 40 or nil
      end)
      recipes:Reload()
      if preserve then
        recipes.restoreCount, recipes.restoreOffset = recipeCount, recipeOffset
        recipes:SetScript("OnUpdate", function(self)
          if #self.items < math.min(recipeCount, #ranked) then self:LoadNext()
          else self.scroll:SetVerticalScroll(recipeOffset); self:SetScript("OnUpdate", nil) end
        end)
      end
      detail.historyIds = ids
      if detail.historyState then detail.history:Restore(detail.historyState) end
      detail.history:Reload(detail.historyState ~= nil)
      local from, to = UI.Range(GetServerTime(), 30)
      from = filter.time and filter.time.from or (series[1] and series[1].bucketStart) or from
      to = filter.time and filter.time.to or (series[#series] and series[#series].bucketStart + 86400) or to
      detail.chart:Render(series, from, to); detail.chart:Show()
      detail.status:SetText(totals.crafts == 0 and "No crafts with ingredient quantities in this period." or
        "Ingredient use from " .. UI.Number(totals.crafts) .. " crafts, " .. date("!%d %b %Y", series[1].bucketStart) ..
        " to " .. date("!%d %b %Y", series[#series].bucketStart) .. "." ..
        (row.hasPrunedReturns and " Older ingredient-use quantities are unavailable." or ""))
    end)
  end
  function detail:Refresh(preserve)
    if not self.item then return end
    period:UpdateState(state)
    characters:Update(UI.Choices("characters"), state.character)
    professions:Update(UI.Choices("professions", state.character), state.profession)
    local result = ArtisanLogbookAPI.GetReagentSummaries({ items = { self.item.id }, limit = 40,
      time = period:Time(), character = state.character or nil, profession = state.profession or nil })
    self:Render(result and result.reagents[1] or { item = self.item, professions = {} }, self:Filter(), preserve)
    self.classification:SetItem(self.item.id)
    self.loaded, self.dirty = true, false
  end
  function detail:Open(item)
    if not self.item or self.item.id ~= item.id then
      if self.item then
        state.history = self.history:Save(); state.recipeOffset = recipes.scroll:GetVerticalScroll()
        self.states[self.item.id] = state
      end
      self.item = item
      state = self.states[item.id] or { days = false, character = false, profession = false }
      tabs:Select(state.view or "Overview")
      if state.history then self.history:Restore(state.history) end
      self:Refresh(state.history ~= nil)
      recipes.scroll:SetVerticalScroll(state.recipeOffset or 0)
    elseif self.dirty or not self.loaded then self:Refresh(true) end
  end
  UI.RegisterTrivialCallback(function() if detail.item then detail.classification:SetItem(detail.item.id) end end)
  return detail
end

function UI.ReagentsPage(page, width, height, openReagent)
  UI.Section(page, "Reagents", 0, -2, width)
  local profession, trivial, sort, search, character = false, "all", "name", "", false
  local filters = UI.FilterBar(page, width, -42)
  page.filters = filters
  local period = filters:Period({ days = false }, function() page:Refresh(true) end, true)
  local characters = filters:Select("Character", {}, function(value)
    character, profession = value, false; page:Refresh(true)
  end)
  local professions = filters:Select("Profession", {}, function(value)
    profession = value; page:Refresh(true)
  end)
  local trivialChoices = {
    { label = "All", value = "all" }, { label = "Ignored", value = "trivial" },
    { label = "Included", value = "non-trivial" },
  }
  local trivialFilter = filters:Select("Savings statistics", trivialChoices, function(value)
    trivial = value; page:Refresh(true)
  end)
  local sorts = filters:Select("Sort", {
    { label = "Name", value = "name" }, { label = "Most used", value = "allocated" },
    { label = "Most returned", value = "returned" }, { label = "Recipe count", value = "recipes" },
  }, function(value) sort = value; page:Refresh(true) end)
  page.searchInput = filters:Search(function(value) search = value; page:Refresh(true) end)
  page.summary = {}
  for index, entry in ipairs({ { "Reagents", "INV_Misc_Herb_19" },
      { "Used", "INV_Misc_Bag_10" }, { "Returned", "Trade_Alchemy" } }) do
    page.summary[index] = UI.Stat(page, entry[1], "Interface\\Icons\\" .. entry[2],
      (index - 1) * width / 3, -142, width / 3 - 12)
  end
  local listWidth = width
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
        UI.ReagentVisual(cell, row.item.id)
        cell.name:SetText(UI.Elide(UI.Name(row.item), math.max(3, math.floor((nameWidth - 34) / 7))))
        cell.identity:SetText("#" .. row.item.id .. (row.quality ~= nil and " | Quality " .. row.quality or ""))
      end },
    { title = "Used", width = available * .23, value = function(row)
      return UI.ReagentAmount(row, "allocatedQuantity", "allocationComplete")
    end },
    { title = "Returned", width = available * .23, value = function(row)
      return UI.ReagentAmount(row, "returnedQuantity", "returnComplete")
    end },
    { title = "Savings stats", width = available * .14,
      value = function(row) return UI.IsTrivial(row.item.id) and "Ignored" or "Included" end },
  }, function(row) openReagent(row.item) end, "No reagents in this selection")
  page.catalogue = list
  function filters.onLayout(filterHeight)
    local top = 48 + filterHeight
    for index, tile in ipairs(page.summary) do tile:ClearAllPoints(); tile:SetPoint("TOPLEFT", (index - 1) * width / 3, -top) end
    list:ClearAllPoints(); list:SetPoint("TOPLEFT", 0, -top - 82); list:SetViewportHeight(height - top - 82)
  end
  function page:Filter()
    local filter = UI.Population(character, profession)
    filter.time = period:Time()
    return filter
  end
  local function refreshMetadata(itemId, qualityOnly)
    local entry = reagentMetadata[itemId]
    if not entry then return end
    local icon, atlas = entry.icon, entry.qualityAtlas
    resolveReagentMetadata(itemId, entry, qualityOnly)
    if icon == entry.icon and atlas == entry.qualityAtlas then return end
    for cell, id in pairs(reagentCells) do
      if id == itemId then updateReagentVisuals(cell, entry) end
    end
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
  local selectedItems, excludedItems
  UI.LazyList(list, function(cursor)
    local result, reason = ArtisanLogbookAPI.GetReagentSummaries({ profession = profession or nil,
      character = character or nil, time = page:Filter().time,
      search = search, sort = sort, items = selectedItems, excludeItems = excludedItems, limit = 40, cursor = cursor })
    page.summary[1]:SetNumber(result and result.totalCount, true)
    for index, metric in ipairs({ "allocatedQuantity", "returnedQuantity" }) do
      local totals = result and result.totals or {}
      local complete = index == 1 and totals.allocationComplete or index == 2 and totals.returnComplete
      page.summary[index + 1]:SetNumber(totals[metric], complete)
    end
    return result and result.reagents, result and result.nextCursor or reason
  end)
  function page:Refresh(reset, preserve)
    period:UpdateState()
    characters:Update(UI.Choices("characters"), character)
    local availableProfessions = UI.Choices("professions", character)
    if not UI.HasChoice(availableProfessions, profession) then profession = false end
    professions:Update(availableProfessions, profession)
    trivialFilter:Update(trivialChoices, trivial)
    sorts:Update(sorts.choices, sort)
    selectedItems = trivial == "trivial" and UI.TrivialItemIds() or nil
    excludedItems = trivial == "non-trivial" and UI.TrivialItemIds() or nil
    if reset or not self.loaded then list:Reload(preserve) end
    self.loaded, self.dirty = true, false
  end
  function page:Open()
    if self.searchInput:GetScript("OnUpdate") then self.searchInput:GetScript("OnEnterPressed")(self.searchInput)
    elseif not self.loaded or self.dirty then self:Refresh(true, true) end
  end
  UI.RegisterTrivialCallback(function()
    page.dirty = true
    if page:IsShown() then page:Refresh(true, true) end
  end)
end