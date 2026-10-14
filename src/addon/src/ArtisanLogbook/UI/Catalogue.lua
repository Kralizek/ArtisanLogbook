local _, addon = ...
local UI = addon.UI
local reagentMetadata = {}
local reagentCells = setmetatable({}, { __mode = "k" })

local function resolveReagentMetadata(itemId, entry, qualityOnly)
  if not qualityOnly and entry.icon == nil then
    entry.icon = UI.ItemIcon(itemId)
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

function UI.ReagentCell(cell, item)
  local metadata = reagentDisplay(item.id)
  cell:Update(item, nil, metadata.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
  UI.ReagentVisual(cell, item.id)
end

-- No quality badge: the recipe's total is known, but not which quality was used.
function UI.ReagentFamilyCell(cell, item, label)
  reagentCells[cell] = nil
  cell:Update({ name = label, note = "The quality used wasn't recorded." }, nil,
    reagentDisplay(item.id).icon or "Interface\\Icons\\INV_Misc_QuestionMark")
end

function UI.ReagentSummaryTooltip(owner, row)
  if not row or not row.item then return end
  UI.Tooltip.Begin(owner, UI.Elide(UI.Name(row.item), 44))

  local input = row.allocatedQuantity ~= nil and UI.Number(row.allocatedQuantity) or "-"
  if row.allocatedQuantity ~= nil and not row.allocationComplete then input = input .. " recorded" end
  UI.Tooltip.Row("Input", input)

  local returned
  if row.returnComplete then
    if row.returnedQuantity == nil or row.returnedQuantity == 0 then returned = "None"
    else returned = UI.Number(row.returnedQuantity) end
  elseif row.returnedQuantity ~= nil then
    returned = UI.Number(row.returnedQuantity) .. " recorded"
  else
    returned = "-"
  end
  UI.Tooltip.Row("Returned", returned)

  local saved = UI.MatchedSavings(row)
  local savingsAvailable = saved ~= "Unavailable" and not UI.IsTrivial(row.item.id)
  UI.Tooltip.Row("Saved share", UI.IsTrivial(row.item.id) and "Excluded" or (savingsAvailable and saved or "-"))

  local notes = {}
  if not row.allocationComplete then
    local missing = row.allocationUnknownCount or 0
    notes[#notes + 1] = missing > 0 and
      ("Input missing for " .. UI.Count(missing, "craft") .. "; total may be higher.") or
      "Some input details are missing; total may be higher."
  end
  if not row.returnComplete then
    local missing = row.returnUnknownCount or 0
    notes[#notes + 1] = row.returnedQuantity ~= nil and "Some return results are missing." or
      (missing > 0 and ("Returns unavailable for " .. UI.Count(missing, "craft") .. ".") or
        "Return results are incomplete.")
  end
  if UI.IsTrivial(row.item.id) then
    notes[#notes + 1] = "Excluded from savings by preference."
  elseif not savingsAvailable then
    notes[#notes + 1] = "Not enough comparable data to calculate savings."
  elseif row.matchedCraftCount and row.matchedCraftCount > 0 then
    notes[#notes + 1] = "Based on " .. UI.Count(row.matchedCraftCount, "comparable craft") .. "."
  end
  if #notes > 0 then
    UI.Tooltip.Section("About these amounts")
    for _, note in ipairs(notes) do UI.Tooltip.Subtitle(UI.Elide(note, 56), "partial") end
  end
  UI.Tooltip.Show()
end

function UI.CataloguePage(page, width, height, openRecipe)
  UI.Section(page, "Recipes", 0, -2, width)
  local character, profession, sort, search = false, false, "count", ""
  local state = { craftType = UI.DefaultCraftType() }
  local filters = UI.FilterBar(page, width, -42)
  page.filters = filters
  local controlWidth = math.min(156, (width - 246) / 4)
  local period = filters:Period({ days = false }, function() page:Refresh(true) end, true, controlWidth)
  filters:CraftType(state, function() page:Refresh(true) end, controlWidth)
  local characters = filters:Select("Character", {}, function(value)
    character, profession = value, false; page:Refresh(true)
  end, controlWidth)
  local professions = filters:Select("Profession", {}, function(value)
    profession = value; page:Refresh(true)
  end, controlWidth)
  local sorts = filters:Select("Sort", {
    { label = "Recipe name", value = "name" }, { label = "Profession", value = "profession" },
    { label = "Most crafted", value = "count" },
  }, function(value) sort = value; page:Refresh(true) end, controlWidth)
  page.searchInput = filters:Search(function(value) search = value; page:Refresh(true) end)
  local list = UI.RecipeTable(page, 0, -144, width, height - 144, openRecipe, true)
  page.catalogue = list
  function filters.onLayout(filterHeight)
    list:ClearAllPoints(); list:SetPoint("TOPLEFT", 0, -48 - filterHeight)
    list:SetViewportHeight(height - 48 - filterHeight)
  end
  UI.LazyList(list, function(cursor)
    local result, reason = ArtisanLogbookAPI.GetRecipeSummaries({ character = character or nil,
      profession = profession or nil, time = period:Time(), craftType = UI.CraftTypeFilter(state), sort = sort, search = search, limit = 40, cursor = cursor })
    list:Enrich({ time = period:Time(), characters = character and { character } or nil,
      professions = profession and { profession } or nil, craftType = UI.CraftTypeFilter(state) })
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
  local state = { days = false, character = false, profession = false, craftType = UI.DefaultCraftType() }
  detail.states = {}
  detail.icon = content:CreateTexture(nil, "ARTWORK")
  detail.icon:SetSize(32, 32); detail.icon:SetPoint("TOPLEFT", 0, 0)
  detail.quality = content:CreateTexture(nil, "OVERLAY")
  detail.quality:SetSize(16, 16); detail.quality:SetPoint("TOPLEFT", 18, -18)
  local iconHover = CreateFrame("Frame", nil, content)
  iconHover:SetAllPoints(detail.icon); iconHover:EnableMouse(true)
  UI.Tooltip.Bind(iconHover, function(self) UI.ItemTooltip(self, detail.item) end)
  detail.iconHover = iconHover
  local heading = UI.Text(content, 40, 0, width - 320, 28, "GameFontNormalLarge")
  local identity = UI.Text(content, 40, -30, width - 40, 18)
  detail.classification = UI.TrivialCheckbox(content, width - 250, 0, function() end)
  local filters = UI.FilterBar(content, width, -58)
  detail.filters = filters
  local period = filters:Period(state, function() detail:Refresh() end, true)
  filters:CraftType(state, function() detail:Refresh() end)
  local characters = filters:Select("Character", {}, function(value) state.character = value; detail:Refresh() end)
  local professions = filters:Select("Profession", {}, function(value) state.profession = value; detail:Refresh() end)
    local entries = { { "Recorded units", "allocated" }, { "Returned units", "returned" }, { "Crafts in recipes", "crafts" },
    { "Recent crafters", "characters" }, { "Saved share", "rate" }, { "Recipes using this", "recipes" } }
  local metrics = {}
  for index, entry in ipairs(entries) do metrics[index] = { entry[1], "INV_Misc_Herb_19" } end
  local summary = UI.SummaryRow(content, width, -110, metrics)
  detail.summary = summary
  detail.fields, detail.tiles = {}, {}
  for index, entry in ipairs(entries) do
    local tile = summary.tiles[index]
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
    { title = "Quantity", width = (inner - 24) * .20,
      value = function(row) return UI.ReagentAmount(row, "allocatedQuantity", "allocationComplete") end,
      exact = function(row)
        return UI.AmountTooltip(row.allocatedQuantity, row.allocationComplete) ..
          " Total quantity recorded for this item across the listed crafts. Returns are shown separately."
      end },
    { title = "Returned", width = (inner - 24) * .20, value = function(row)
      return UI.ReagentAmount(row, "returnedQuantity", "returnComplete")
    end },
  }, function(row) if row.recipe then openRecipe(row.recipe) end end, "No crafts with ingredient details")
  recipes.tooltipKind = "recipe"
  recipes.tooltipFilter = function() return detail:Filter() end
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
  end, UI.VisibleCraft)
  detail.chart = UI.Chart(overview, 0, 0, inner, true)
  local legend = UI.Text(overview, 0, -168, inner, 18)
  legend:SetText("|cff2787c2Required|r   |cff287040Returned|r")
  detail.status = UI.Text(overview, 0, -196, inner, 54)
  detail.worker = CreateFrame("Frame", nil, detail)
  function filters.onLayout(filterHeight)
    local top = 64 + filterHeight
    summary:ClearAllPoints(); summary:SetPoint("TOPLEFT", 0, -top)
    local summaryHeight = summary:GetHeight() + 8
    local viewHeight = height - top - summaryHeight - 51
    tabs:ClearAllPoints(); tabs:SetPoint("TOPLEFT", 0, -top - summaryHeight); tabs:Resize(height - top - summaryHeight)
    recipes:SetViewportHeight(viewHeight); detail.history:SetViewportHeight(viewHeight)
    local chartHeight = math.min(168, viewHeight - 78)
    detail.chart:Layout(chartHeight)
    legend:ClearAllPoints(); legend:SetPoint("TOPLEFT", 0, -chartHeight)
    detail.status:ClearAllPoints(); detail.status:SetPoint("TOPLEFT", 0, -chartHeight - 28)
    detail.status:SetHeight(50)
  end
  function detail:Filter()
    return { time = period:Time(), characters = state.character and { state.character } or nil,
      professions = state.profession and { state.profession } or nil, craftType = UI.CraftTypeFilter(state) }
  end
  local function accumulate(target, allocated, returned, returnKnown)
    target.crafts = (target.crafts or 0) + 1
    if allocated ~= nil then target.allocatedQuantity = (target.allocatedQuantity or 0) + allocated end
    if returned ~= nil then target.returnedQuantity = (target.returnedQuantity or 0) + returned end
    if allocated ~= nil then target.allocationObservedCount = (target.allocationObservedCount or 0) + 1 end
    target.returnObservedCount = (target.returnObservedCount or 0) + (returnKnown and 1 or 0)
    target.returnComplete = target.returnComplete ~= false and returnKnown
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
    self.tiles.allocated:SetScript("OnEnter", function(tile)
      GameTooltip:SetOwner(tile, "ANCHOR_RIGHT")
      GameTooltip:SetText("Required quantity")
      GameTooltip:AddLine(UI.AmountTooltip(row.allocatedQuantity, row.allocationComplete), 1, 1, 1, true)
      GameTooltip:AddLine("Counts crafts where this item was recorded. Returns aren't subtracted.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    self.tiles.allocated:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.fields.crafts:SetText(UI.Number(row.craftCount))
    self.tiles.crafts:SetScript("OnEnter", function(tile)
      GameTooltip:SetOwner(tile, "ANCHOR_RIGHT")
      GameTooltip:SetText("Crafts in selected recipes")
      GameTooltip:AddLine("Counts the recipe population with a saved measure for this item; not every craft necessarily used it.",
        1, 1, 1, true)
      GameTooltip:Show()
    end)
    self.tiles.crafts:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.fields.recipes:SetText(UI.Number(row.recipeCount))
    self.fields.rate:SetText(UI.MatchedSavingsText(row))
    self.tiles.rate.note:SetText(row.matchedCraftCount and row.matchedCraftCount > 0 and
      UI.Count(row.matchedCraftCount, "comparable craft") .. "\nSelected history" or "No comparable sample")
    self.tiles.rate:SetScript("OnEnter", function(tile)
      GameTooltip:SetOwner(tile, "ANCHOR_RIGHT")
      if UI.MatchedSavings(row) == "Unavailable" then
        GameTooltip:SetText("Saved share unavailable")
        GameTooltip:AddLine("No comparable crafts have both required and returned amounts known for this item.", 1, 1, 1, true)
      else
        GameTooltip:SetText("Saved share for this selection: " .. UI.MatchedSavings(row))
        GameTooltip:AddLine(UI.Number(row.matchedReturnedQuantity) .. " saved of " ..
          UI.Number(row.matchedAllocatedQuantity) .. " required across " ..
            UI.Count(row.matchedCraftCount, "comparable craft") ..
          ". The item is compared only when both quantities are known for the same craft.", 1, 1, 1, true)
      end
      GameTooltip:Show()
    end)
    self.tiles.rate:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.status:SetText("Loading craft history...")
    local cursor, totals, characters, byRecipe, days, ids, retainedCraftCount = nil,
      { crafts = 0 }, {}, {}, {}, {}, 0
    self.worker:SetScript("OnUpdate", function(worker)
      local result, reason = ArtisanLogbookAPI.GetCrafts(filter, { limit = 100, cursor = cursor })
      if not result then
        worker:SetScript("OnUpdate", nil); detail.status:SetText(reason or "Unavailable"); return
      end
      for _, craft in ipairs(result.crafts) do
        retainedCraftCount = retainedCraftCount + 1
        local matched, allocated, returned = false, nil, nil
        for _, reagent in ipairs(craft.reagents or {}) do
          if reagent.item and reagent.item.id == row.item.id then
            matched = true
            if reagent.allocatedQuantity ~= nil then allocated = (allocated or 0) + reagent.allocatedQuantity
            end
            if reagent.returnedQuantity ~= nil then returned = (returned or 0) + reagent.returnedQuantity
            end
          end
        end
        if matched then
          ids[#ids + 1] = craft.id
          local returnKnown = craft.outcomeSource == "native" and craft.resourcefulnessComplete == true
          if returnKnown and returned == nil then returned = 0 end
          accumulate(totals, allocated, returned, returnKnown)
          if craft.character then characters[craft.character.key] = true end
          local recipeId = craft.recipe and craft.recipe.id or 0
          local use = byRecipe[recipeId] or { recipe = craft.recipe, id = recipeId }
          byRecipe[recipeId] = use; accumulate(use, allocated, returned, returnKnown)
          local day = math.floor(craft.timestamp / 86400) * 86400
          days[day] = days[day] or { bucketStart = day }
          accumulate(days[day], allocated, returned, returnKnown)
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
      detail.fields.characters:SetText(UI.Number(characterCount))
      UI.LazyList(recipes, function(cursor)
        local offset, rows = cursor or 0, {}
        for index = offset + 1, math.min(offset + 40, #ranked) do rows[#rows + 1] = ranked[index] end
        return rows, offset + 40 < #ranked and offset + 40 or nil
      end, UI.VisibleCraft)
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
      local detailCoverage = "Item details are available for " .. UI.Number(totals.crafts) .. " of " ..
        UI.Number(retainedCraftCount) .. " crafts; input quantities appear in " ..
        UI.Number(totals.allocationObservedCount or 0) .. " item rows and recorded return results for " ..
        UI.Number(totals.returnObservedCount or 0) .. "."
      local savingsCoverage = row.matchedCraftCount and row.matchedCraftCount > 0 and
        UI.Count(row.matchedCraftCount, "comparable craft") .. " in the selected saved history." or
        "No comparable crafts in the selected saved history."
      detail.status:SetText(totals.crafts == 0 and
        "No individual craft details are available in this period. Saved share: " .. savingsCoverage or
        "Recent craft details: " .. UI.Number(retainedCraftCount) .. " crafts, " .. date("!%d %b %Y", series[1].bucketStart) ..
        " to " .. date("!%d %b %Y", series[#series].bucketStart) .. ". " .. detailCoverage ..
        " Saved share compares required amounts with recorded returns for the same item: " .. savingsCoverage)
    end)
  end
  function detail:Refresh(preserve)
    if not self.item then return end
    period:UpdateState(state)
    filters.craftType:UpdateState(state)
    characters:Update(UI.Choices("characters"), state.character)
    professions:Update(UI.Choices("professions", state.character), state.profession)
    local result = ArtisanLogbookAPI.GetReagentSummaries({ items = { self.item.id }, limit = 40,
      time = period:Time(), character = state.character or nil, profession = state.profession or nil,
      craftType = UI.CraftTypeFilter(state) })
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
  local state = { craftType = UI.DefaultCraftType() }
  local filters = UI.FilterBar(page, width, -42)
  page.filters = filters
  local period = filters:Period({ days = false }, function() page:Refresh(true) end, true)
  filters:CraftType(state, function() page:Refresh(true) end)
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
    { label = "Name", value = "name" }, { label = "Most required", value = "allocated" },
    { label = "Most returned", value = "returned" }, { label = "Recipe count", value = "recipes" },
  }, function(value) sort = value; page:Refresh(true) end)
  page.searchInput = filters:Search(function(value) search = value; page:Refresh(true) end)
  local summary = UI.SummaryRow(page, width, -142, { { "Reagents", "INV_Misc_Herb_19" },
    { "Recorded units", "INV_Misc_Bag_10" }, { "Returned units", "Trade_Alchemy" } })
  summary:SetHeight(60)
  for _, tile in ipairs(summary.tiles) do tile:SetHeight(60); tile.note:Hide() end
  page.summary, page.summaryRow = summary.tiles, summary
  local listWidth = width
  local available = listWidth - 24
  local nameWidth = available - 550
  local list = UI.ScrollList(page, 0, -224, listWidth, height - 258, {
    { title = "Reagent", width = nameWidth, value = function(row)
        return UI.Name(row.item) .. " (#" .. row.item.id .. ")"
      end,
      create = function(parent, left)
        return UI.ItemCell(parent, left, nameWidth)
      end,
      update = function(cell, row)
        UI.ReagentCell(cell, row.item)
      end },
    { title = "Profession", width = 180, value = function(row)
      local names = {}
      for _, profession in ipairs(row.professions or {}) do names[#names + 1] = UI.Name(profession) end
      return table.concat(names, ", ")
    end },
    { title = "Recipes", width = 54, value = function(row) return UI.Number(row.recipeCount) end },
    { title = "Input", width = 80, value = function(row)
      return UI.ReagentAmount(row, "allocatedQuantity", "allocationComplete")
    end, exact = function(row)
      return UI.AmountTooltip(row.allocatedQuantity, row.allocationComplete) ..
        " Input quantity recorded for this item across crafts. Returns are shown separately."
    end },
      { title = "Returned", width = 80, value = function(row)
      return UI.ReagentAmount(row, "returnedQuantity", "returnComplete")
    end, exact = function(row) return UI.AmountTooltip(row.returnedQuantity, row.returnComplete) end },
    { title = "Saved share", width = 92, value = function(row)
      return UI.IsTrivial(row.item.id) and "-" or UI.MatchedSavingsText(row)
    end, exact = function(row)
      if UI.IsTrivial(row.item.id) then return "Excluded from savings by your preference. Recorded quantities are unchanged." end
      if UI.MatchedSavings(row) == "Unavailable" then
        return "No comparable crafts have both required and returned quantities known for this item."
      end
      return UI.Number(row.matchedReturnedQuantity) .. " saved of " .. UI.Number(row.matchedAllocatedQuantity) ..
        " required across " .. UI.Count(row.matchedCraftCount, "measured craft")
    end },
    { title = "Ignore", width = 64,
      value = function(row) return UI.IsTrivial(row.item.id) and "Yes" or "No" end,
      create = function(parent, left) return UI.TrivialCheckbox(parent, left + 8, -2, function() end, true) end,
      update = function(check, row) check:SetItem(row.item.id) end },
  }, function(row) openReagent(row.item) end, "No reagents in this selection")
  page.catalogue = list
  list.rowTooltip = UI.ReagentSummaryTooltip
  function filters.onLayout(filterHeight)
    local top = 48 + filterHeight
    summary:ClearAllPoints(); summary:SetPoint("TOPLEFT", 0, -top)
    local listTop = top + summary:GetHeight() + 8
    list:ClearAllPoints(); list:SetPoint("TOPLEFT", 0, -listTop); list:SetViewportHeight(height - listTop)
  end
  function page:Filter()
    local filter = UI.Population(character, profession, state.craftType)
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
      character = character or nil, time = page:Filter().time, craftType = UI.CraftTypeFilter(state),
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