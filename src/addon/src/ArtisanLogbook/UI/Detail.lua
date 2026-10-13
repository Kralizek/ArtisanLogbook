local _, addon = ...
local UI = addon.UI

function UI.RecipePage(page, width, height, openCraft, pinsChanged, openReagent)
  local content = page
  page.content, page.states = content, {}
  local heading = UI.Text(content, 42, -4, width - 292, 26, "GameFontNormalLarge")
  heading:SetWordWrap(false); heading:SetMaxLines(1)
  local metadata = UI.Text(content, 42, -34, width - 48, 20)
  local icon = content:CreateTexture(nil, "ARTWORK")
  icon:SetSize(34, 34); icon:SetPoint("TOPLEFT", 0, -4)
  local pin
  pin = UI.Button(content, "Pin recipe", width - 116, -4, 112, function()
    local ok, reason = UI.TogglePin(page.recipe)
    if not ok then addon.Notify(reason) end
    pin:SetText(UI.IsPinned(page.recipe.id) and "Unpin recipe" or "Pin recipe")
    pinsChanged()
  end)
  local hidden = UI.Button(content, "Hide recipe", width - 236, -4, 112, function()
    if page.recipe then UI.SetRecipeHidden(page.recipe.id, not UI.IsRecipeHidden(page.recipe.id)) end
  end)
  page.hiddenButton = hidden
  local function updateHiddenButton()
    hidden:SetText(page.recipe and UI.IsRecipeHidden(page.recipe.id) and "Show recipe" or "Hide recipe")
  end
  hidden:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(self:GetText())
    GameTooltip:AddLine("Toggle this recipe in most-crafted tables and craft lists. It stays in Recipes; totals and saved history do not change.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  hidden:SetScript("OnLeave", function() GameTooltip:Hide() end)
  UI.RegisterHiddenRecipeCallback(function(recipeId)
    if page.recipe and page.recipe.id == recipeId then updateHiddenButton() end
  end)
  local history
  local outcomes = UI.RecipeOutcomes(content, width, function() history:Reload() end, height - 62, openReagent)
  page.outcomes = outcomes
  history = UI.ScrollList(outcomes.views["Craft History"], 0, 0, width - 24, height - 315, UI.RecipeHistoryColumns(width - 24),
    function(craft) openCraft(craft.id) end, "No crafts in this period")
  page.history = history
  function outcomes:OnLayout(viewHeight) history:SetViewportHeight(viewHeight) end
  function outcomes:OnSelect(name) page.activeView = name end
  function page:SelectView(name)
    self.activeView = name
    outcomes:SelectView(name)
  end
  page.tabs = outcomes.tabbed.buttons
  UI.LazyList(history, function(cursor)
    local filter = outcomes:Filter()
    filter.recipes = { page.recipe.id }
    local result, reason = ArtisanLogbookAPI.GetCrafts(filter, { limit = 40, cursor = cursor })
    return result and result.crafts, result and result.nextCursor or reason
  end, UI.VisibleCraft)
  function page:Open(recipe)
    local changed = not self.recipe or self.recipe.id ~= recipe.id
    if changed and self.recipe then
      self.states[self.recipe.id] = { filters = outcomes:State(), history = history:Save(),
        view = self.activeView, recipe = self.recipe,
        revision = self.loadedRevision }
    end
    local saved = self.states[recipe.id]
    local previous = not changed and self.recipe or saved and saved.recipe
    if changed or self.dirty then
      local facets = ArtisanLogbookAPI.GetFacets({ recipes = { recipe.id } }, { facets = { "recipes" }, mode = "strict" })
      local available = facets and facets.recipes[1]
      if available then recipe = UI.CopyRecipe(available.details, recipe) end
    end
    self.recipe = UI.CopyRecipe(recipe, previous)
    recipe = self.recipe
    heading:SetText(UI.Name(recipe))
    local details = { "Recipe #" .. recipe.id }
    if recipe.profession then details[#details + 1] = UI.Name(recipe.profession) end
    if recipe.expansion then details[#details + 1] = UI.Name(recipe.expansion) end
    metadata:SetText(table.concat(details, "  -  "))
    icon:SetTexture(UI.RecipeIcon(recipe))
    pin:SetText(UI.IsPinned(recipe.id) and "Unpin recipe" or "Pin recipe")
    updateHiddenButton()
    if changed or self.dirty then
      outcomes.maxQuality = recipe.maxQuality
      outcomes:Open(recipe.id, saved and saved.filters)
      if changed and saved then history:Restore(saved.history) end
      if not saved or self.dirty or saved.revision ~= (self.revision or 0) then history:Reload(not changed or saved ~= nil) end
      self.dirty = false
      self.loadedRevision = self.revision or 0
    end
    if changed then
      self.activeView = nil
      self:SelectView(saved and saved.view or "Overview")
    end
  end
  function page:Refresh()
    self.dirty = true
    if self.recipe then self:Open(self.recipe) end
  end
end

function UI.CraftDetail(parent, width, height, goBack, openReagent)
  local detail = CreateFrame("Frame", nil, parent)
  detail:SetAllPoints(parent)
  UI.Surface(detail, false)
  local identity = detail:CreateTexture(nil, "ARTWORK")
  identity:SetSize(36, 36); identity:SetPoint("TOPLEFT", 16, -8)
  local quality = detail:CreateTexture(nil, "OVERLAY")
  quality:SetSize(18, 18); quality:SetPoint("TOPLEFT", 38, -29)
  local heading = UI.Text(detail, 62, -8, width - 166, 26, "GameFontNormalLarge")
  heading:SetWordWrap(false); heading:SetMaxLines(1)
  local subtitle = UI.Text(detail, 62, -35, width - 166, 20)
  UI.Button(detail, "Close", width - 92, -8, 76, goBack)
  local content = CreateFrame("Frame", nil, detail)
  content:SetPoint("TOPLEFT", 18, -72); content:SetSize(width - 36, height - 72)
  detail.content = content
  UI.Section(content, "Result", 0, 0, width - 36)
  local resultRow = UI.ItemCell(content, 0, width - 220)
  resultRow:ClearAllPoints(); resultRow:SetPoint("TOPLEFT", 0, -34)
  resultRow:SetHeight(40)
  resultRow.quantity = UI.Text(content, width - 214, -34, 176, 24, "GameFontNormalLarge")
  resultRow.bonus = UI.Text(content, width - 214, -60, 176, 22)
  detail.result = resultRow
  local fields = {}
  local fieldNames = { "Character", "Timestamp", "Quantity", "Quality", "Concentration", "Multicraft", "Ingenuity", "Resourcefulness" }
  for index, title in ipairs(fieldNames) do
    local offset = -104 - math.floor((index - 1) / 2) * 38
    local left = ((index - 1) % 2) * (width - 36) / 2
    UI.Text(content, left, offset, 110, 22, "GameFontNormalSmall"):SetText(title .. ":")
    fields[title] = UI.Text(content, left + 112, offset, (width - 36) / 2 - 126, 34)
  end
  detail.fields = fields
  detail.inputEvidence = UI.Text(content, 0, -258, width - 36, 18, "GameFontNormalSmall")
  UI.Section(content, "Inputs and returned materials", 0, -286, width - 36)
  local function candidates(requirement)
    local items = {}
    for _, item in ipairs(requirement.candidateItems or {}) do items[#items + 1] = item end
    for _, itemId in ipairs(#items == 0 and requirement.candidateItemIDs or {}) do items[#items + 1] = { id = itemId } end
    return items
  end
  local function familyLabel(items)
    local names, seen = {}, {}
    for _, item in ipairs(items) do
      local name = UI.Name(item)
      if not seen[name] then seen[name] = true; names[#names + 1] = name end
    end
    if #names == 1 then return names[1] .. " (any of " .. UI.Count(#items, "quality", "qualities") .. ")" end
    return table.concat(names, " / ")
  end
  local columnWidth = (width - 60) * .18
  local reagents = UI.ScrollList(content, 0, -322, width - 36, height - 394, {
    { title = "Reagent", width = (width - 60) * .46, value = function(row) return row.label or UI.Name(row.item) end,
      create = function(owner, left) return UI.ItemCell(owner, left, (width - 60) * .46) end,
      update = function(cell, row)
        if row.family then UI.ReagentFamilyCell(cell, row.item, row.label) else UI.ReagentCell(cell, row.item) end
      end },
    { title = "Exact input", width = columnWidth, value = function(row)
      return row.allocatedQuantity ~= nil and UI.Number(row.allocatedQuantity) or "-"
    end, exact = function(row)
      if row.allocatedQuantity == nil then
        return row.family and "Quality choice not captured; see the schematic expectation." or
          "No exact item allocation was captured."
      end
      if row.inputTotalComplete then return UI.Number(row.allocatedQuantity) .. " exact item units reconciled to the recipe." end
      return UI.Number(row.allocatedQuantity) .. " submitted or schematic-fixed units; the exact item total is not reconciled and is not a savings basis."
    end },
    { title = "Expected", width = columnWidth, value = function(row)
      return row.expectedQuantity ~= nil and UI.Number(row.expectedQuantity) or "-"
    end, exact = function(row)
      if row.expectedQuantity == nil then return "No separate schematic expectation." end
      if row.family then
        return "Schematic expects " .. UI.Number(row.expectedQuantity) .. " units across " ..
          UI.Count(#row.candidates, "quality option") .. "; exact quality split is not established and not a savings basis."
      end
      return "Schematic expects " .. UI.Number(row.expectedQuantity) .. " units; submitted allocation not reconciled and not a savings basis."
    end },
    { title = "Returned", width = columnWidth, value = function(row)
      if row.returnedQuantity ~= nil then return UI.Number(row.returnedQuantity) end
      return row.returnComplete and "0" or "-"
    end, exact = function(row)
      if row.returnedQuantity ~= nil then
        local text = UI.Count(row.returnedQuantity, "unit") .. " returned"
        if row.family then
          local parts = {}
          for _, returned in ipairs(row.returnedItems) do
            parts[#parts + 1] = UI.Number(returned.quantity) .. " " .. UI.Name(returned.item) ..
              (returned.item.id and " (#" .. returned.item.id .. ")" or "")
          end
          text = text .. ": " .. table.concat(parts, ", ")
        end
        return text .. "."
      end
      return row.returnComplete and "0" or "Unavailable"
    end },
  }, function(row) if openReagent and not row.family then goBack(); openReagent(row.item) end end, "No input or return details")
  detail.returnedReagents = reagents

  -- Exact allocations, schematic expectations and returns stay in separate columns, so overlap never sums.
  local function ingredientRows(craft)
    local byItem, rows, families = {}, {}, {}
    local exactSlots, expectedSlots, familyCount = {}, 0, 0
    local function itemRow(item, slot)
      local row = byItem[item.id]
      if not row then
        row = { item = item }
        byItem[item.id] = row
        rows[#rows + 1] = row
      end
      if slot and (not row.slot or slot < row.slot) then row.slot = slot end
      return row
    end
    for _, reagent in ipairs(craft.reagents or {}) do
      if reagent.item and reagent.item.id and reagent.allocatedQuantity ~= nil then
        local row = itemRow(reagent.item, reagent.dataSlotIndex)
        row.inputTotalComplete = (row.allocatedQuantity == nil or row.inputTotalComplete) and
          reagent.inputTotalComplete == true
        row.allocatedQuantity = (row.allocatedQuantity or 0) + reagent.allocatedQuantity
        exactSlots[reagent.dataSlotIndex or ("item:" .. reagent.item.id)] = true
      end
    end
    for _, requirement in ipairs(craft.reagentRequirements or {}) do
      local items = candidates(requirement)
      if #items > 0 and requirement.requiredQuantity ~= nil then
        expectedSlots = expectedSlots + 1
        if #items == 1 then
          local row = itemRow(items[1], requirement.dataSlotIndex)
          row.expectedQuantity = (row.expectedQuantity or 0) + requirement.requiredQuantity
        else
          familyCount = familyCount + 1
          local row = { family = true, item = items[1], candidates = items, label = familyLabel(items),
            expectedQuantity = requirement.requiredQuantity, slot = requirement.dataSlotIndex, returnedItems = {} }
          rows[#rows + 1] = row
          families[#families + 1] = row
        end
      end
    end
    for _, reagent in ipairs(craft.reagents or {}) do
      local quantity, item = reagent.returnedQuantity, reagent.item
      if quantity ~= nil and item and item.id then
        local row = byItem[item.id]
        if not row then
          for _, family in ipairs(families) do
            for _, candidate in ipairs(family.candidates) do
              if candidate.id == item.id then row = family; break end
            end
            if row then break end
          end
        end
        row = row or itemRow(item)
        row.returnedQuantity = (row.returnedQuantity or 0) + quantity
        if row.family then row.returnedItems[#row.returnedItems + 1] = { item = item, quantity = quantity } end
      end
    end
    table.sort(rows, function(left, right)
      if (left.slot or math.huge) ~= (right.slot or math.huge) then return (left.slot or math.huge) < (right.slot or math.huge) end
      if (left.family == true) ~= (right.family == true) then return not left.family end
      return (left.item.id or 0) < (right.item.id or 0)
    end)
    local exactCount = 0
    for _ in pairs(exactSlots) do exactCount = exactCount + 1 end
    return rows, exactCount, expectedSlots, familyCount
  end

  local function ingredientSummary(craft, exactCount, expectedCount, familyCount)
    if exactCount + expectedCount == 0 then return "Input requirements are unavailable." end
    local parts = {}
    if exactCount > 0 then parts[#parts + 1] = UI.Count(exactCount, "exact input slot") end
    if expectedCount > 0 then
      parts[#parts + 1] = UI.Count(expectedCount, "schematic slot") ..
        (familyCount > 0 and " (" .. UI.Count(familyCount, "quality family", "quality families") .. ")" or "")
    end
    local prefix = craft.inputComplete == true and "All inputs known: " or
      craft.grossRequirementsComplete == true and "All slots known: " or "Known so far: "
    local suffix = craft.requirementObservation == "result" and "; observed at result, submitted inputs unavailable." or
      familyCount > 0 and "; quality used is not recorded." or "."
    return prefix .. table.concat(parts, " + ") .. suffix
  end

  function detail:ShowCraft(id)
    local craft, reason = ArtisanLogbookAPI.GetCraft(id)
    if not craft then
      heading:SetText("Craft unavailable")
      subtitle:SetText(reason or "Unknown craft")
      for _, field in pairs(fields) do field:SetText("-") end
      reagents:Reset(); resultRow:Update(nil); resultRow.quantity:SetText("-"); resultRow.bonus:SetText("")
      detail.inputEvidence:SetText("")
      identity:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); quality:Hide()
      return
    end
    heading:SetText(UI.Elide(UI.Name(craft.recipe, "Unattributed craft"), math.floor((width - 166) / 10)))
    subtitle:SetText(UI.Name(craft.profession))
    identity:SetTexture(craft.outputItem and type(GetItemIcon) == "function" and GetItemIcon(craft.outputItem.id) or UI.RecipeIcon(craft.recipe))
    local atlas = UI.QualityAtlas(craft.recipe and craft.recipe.id, craft.outputQuality, craft.recipe and craft.recipe.maxQuality)
    quality:SetShown(atlas ~= nil)
    if atlas then quality:SetAtlas(atlas) end
    resultRow:Update(craft.outputItem, atlas)
    resultRow.quantity:SetText(UI.Number(craft.outputQuantity) .. " items")
    resultRow.bonus:SetText(craft.multicraftBonus and craft.multicraftBonus > 0 and "+" .. UI.Number(craft.multicraftBonus) .. " Multicraft" or "")
    fields.Character:SetText(UI.CharacterName(craft.character))
    fields.Timestamp:SetText(UI.DateTime(craft.timestamp))
    fields.Quantity:SetText(UI.Number(craft.outputQuantity))
    fields.Quality:SetText(UI.Value(craft.outputQuality))
    fields.Concentration:SetText(UI.Number(craft.concentrationSpent))
    fields.Multicraft:SetText(craft.multicraftBonus and (UI.Number(craft.multicraftBonus) .. " additional") or "-")
    fields.Ingenuity:SetText(craft.hasIngenuityProc == true and
      (craft.ingenuityRefund and UI.Number(craft.ingenuityRefund) .. " refunded" or "Proc") or
      (craft.hasIngenuityProc == false and "No proc" or "-"))
    local rows, exactCount, expectedCount, familyCount = ingredientRows(craft)
    local returnVerified = craft.outcomeSource == "native" and craft.resourcefulnessComplete == true
    local total = 0
    for _, row in ipairs(rows) do
      row.returnComplete = returnVerified
      if row.returnedQuantity and row.returnedQuantity > 0 then total = total + row.returnedQuantity end
    end
    if returnVerified and craft.hasResourcefulnessProc == true then
      fields.Resourcefulness:SetText("Return recorded")
    elseif returnVerified and craft.hasResourcefulnessProc == false then
      fields.Resourcefulness:SetText("No return recorded")
    elseif total > 0 then
      fields.Resourcefulness:SetText("Known returns; other results may be unavailable")
    else
      fields.Resourcefulness:SetText("Outcome unavailable")
    end
    detail.inputEvidence:SetText(ingredientSummary(craft, exactCount, expectedCount, familyCount))
    reagents:Reset(); reagents:Append(rows)
  end
  detail:Hide()
  return detail
end