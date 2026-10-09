local _, addon = ...
local UI = addon.UI

function UI.RecipePage(page, width, height, openCraft, pinsChanged, openReagent)
  local content = page
  page.content, page.states = content, {}
  local heading = UI.Text(content, 42, -4, width - 352, 26, "GameFontNormalLarge")
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
  page.hiddenCheck = UI.HiddenRecipeCheckbox(content, width - 296, -4)
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
  end, UI.VisibleRecipe)
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
    self.hiddenCheck:SetRecipe(recipe.id)
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
  UI.Section(content, "Reagents returned", 0, -270, width - 36)
  local reagents = UI.ScrollList(content, 0, -306, width - 36, height - 378, {
    { title = "Reagent", width = (width - 60) * .78, value = function(row) return UI.Name(row.item) end,
      create = function(owner, left) return UI.ItemCell(owner, left, (width - 60) * .78) end,
      update = function(cell, row) UI.ReagentCell(cell, row.item) end },
    { title = "Returned", width = (width - 60) * .22, value = function(row) return UI.Number(row.returnedQuantity) end,
      exact = function(row) return tostring(row.returnedQuantity) end },
  }, function(row) if openReagent then goBack(); openReagent(row.item) end end, "No reagents returned")
  detail.returnedReagents = reagents

  function detail:ShowCraft(id)
    local craft, reason = ArtisanLogbookAPI.GetCraft(id)
    if not craft then
      heading:SetText("Craft unavailable")
      subtitle:SetText(reason or "Unknown craft")
      for _, field in pairs(fields) do field:SetText("-") end
      reagents:Reset(); resultRow:Update(nil); resultRow.quantity:SetText("-"); resultRow.bonus:SetText("")
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
    local returned, total, allocated, complete = {}, 0, 0, craft.resourcefulnessComplete == true
    for _, reagent in ipairs(craft.reagents or {}) do
      if reagent.allocatedQuantity == nil or reagent.returnedQuantity == nil then complete = false end
      allocated = allocated + (reagent.allocatedQuantity or 0)
      if reagent.returnedQuantity and reagent.returnedQuantity > 0 then
        returned[#returned + 1] = reagent; total = total + reagent.returnedQuantity
        if reagent.allocatedQuantity and reagent.returnedQuantity > reagent.allocatedQuantity then complete = false end
      end
    end
    local returnText = craft.hasResourcefulnessProc == nil and total == 0 and "-" or UI.Number(total) .. " returned"
    if complete and allocated > 0 then
      returnText = returnText .. " (" .. UI.Percent(total, allocated) .. " of used)"
    elseif craft.resourcefulnessComplete ~= true and total > 0 then
      returnText = ">= " .. returnText
    end
    fields.Resourcefulness:SetText(returnText)
    reagents:Reset(); reagents:Append(returned)
  end
  detail:Hide()
  return detail
end