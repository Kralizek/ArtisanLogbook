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
  local fieldNames = { "Character", "Timestamp", "Quality", "Concentration", "Multicraft", "Ingenuity", "Resourcefulness" }
  for index, title in ipairs(fieldNames) do
    local offset = -100 - math.floor((index - 1) / 2) * 30
    local left = ((index - 1) % 2) * (width - 36) / 2
    UI.Text(content, left, offset, 110, 22, "GameFontNormalSmall"):SetText(title .. ":")
    fields[title] = UI.Text(content, left + 112, offset, (width - 36) / 2 - 126, 24)
  end
  detail.fields = fields
  detail.inputEvidence = UI.Text(content, 0, -218, width - 36, 18, "GameFontNormalSmall")
  UI.Section(content, "Ingredients", 0, -244, width - 36)
  local nameWidth, amountWidth = (width - 60) * .6, (width - 60) * .2
  local returnColor = { r = .45, g = .85, b = .45 }
  local shownCraft
  local reagents = UI.ScrollList(content, 0, -280, width - 36, height - 352, {
    { title = "Reagent", width = nameWidth, value = function(row) return row.name end,
      create = function(owner, left) return UI.ItemCell(owner, left, nameWidth) end,
      update = function(cell, row)
        if row.qualityUnknown then UI.ReagentFamilyCell(cell, row.item, row.name) else UI.ReagentCell(cell, row.item) end
      end },
    { title = "Required", width = amountWidth, sentence = true, value = function(row)
      return row.required ~= nil and UI.Number(row.required) or "-"
    end, exact = UI.IngredientRequiredText },
    { title = "Returned", width = amountWidth, sentence = true, value = function(row)
      return row.returned ~= nil and UI.Number(row.returned) or "-"
    end, exact = function(row) return UI.IngredientReturnedText(row, shownCraft) end,
      color = function(row) return row.returned and row.returned > 0 and returnColor or nil end },
  }, function(row) if openReagent and not row.qualityUnknown then goBack(); openReagent(row.item) end end,
    "Ingredients weren't recorded for this craft.")
  detail.returnedReagents = reagents

  function detail:ShowCraft(id)
    local craft, reason = ArtisanLogbookAPI.GetCraft(id)
    if not craft then
      heading:SetText("Craft unavailable")
      subtitle:SetText(reason or "Unknown craft")
      for _, field in pairs(fields) do field:SetText("-") end
      reagents:Reset(); resultRow:Update(nil); resultRow.quantity:SetText("-"); resultRow.bonus:SetText("")
      detail.inputEvidence:SetText("")
      identity:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
      return
    end
    heading:SetText(UI.Elide(UI.Name(craft.recipe, "Unattributed craft"), math.floor((width - 166) / 10)))
    subtitle:SetText(UI.Name(craft.profession))
    identity:SetTexture(craft.outputItem and type(GetItemIcon) == "function" and GetItemIcon(craft.outputItem.id) or UI.RecipeIcon(craft.recipe))
    resultRow:Update(craft.outputItem)
    resultRow.quantity:SetText(UI.Number(craft.outputQuantity) .. " items")
    resultRow.bonus:SetText(craft.multicraftBonus and craft.multicraftBonus > 0 and "+" .. UI.Number(craft.multicraftBonus) .. " Multicraft" or "")
    fields.Character:SetText(UI.CharacterName(craft.character))
    fields.Timestamp:SetText(UI.DateTime(craft.timestamp))
    fields.Quality:SetText(UI.Value(craft.outputQuality))
    fields.Concentration:SetText(UI.Number(craft.concentrationSpent))
    fields.Multicraft:SetText(craft.multicraftBonus and (UI.Number(craft.multicraftBonus) .. " additional") or "-")
    fields.Ingenuity:SetText(craft.hasIngenuityProc == true and
      (craft.ingenuityRefund and UI.Number(craft.ingenuityRefund) .. " refunded" or "Proc") or
      (craft.hasIngenuityProc == false and "No proc" or "-"))
    local rows = UI.CraftIngredients(craft)
    shownCraft = craft
    local returnVerified = craft.outcomeSource == "native" and craft.resourcefulnessComplete == true
    local total, unknownRequired = 0, false
    for _, row in ipairs(rows) do
      if row.returned and row.returned > 0 then total = total + row.returned end
      if row.required == nil then unknownRequired = true end
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
    local allListed = craft.inputComplete == true or craft.grossRequirementsComplete == true
    detail.inputEvidence:SetText(#rows > 0 and (unknownRequired or not allListed) and
      "Some ingredient details weren't recorded for this craft." or "")
    reagents:Reset(); reagents:Append(rows)
  end
  detail:Hide()
  return detail
end