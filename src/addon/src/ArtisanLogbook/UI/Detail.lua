local _, addon = ...
local UI = addon.UI

function UI.RecipePage(page, width, height, openCraft, pinsChanged)
  local content, scroll = UI.PageScroll(page, width, height, 626)
  width = width - 28
  page.content, page.scroll, page.states = content, scroll, {}
  local heading = UI.Text(content, 42, -4, width - 174, 26, "GameFontNormalLarge")
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
  local history
  local outcomes = UI.RecipeOutcomes(content, width, function() history:Reload() end)
  page.outcomes = outcomes
  history = UI.ScrollList(outcomes, 0, -88, width, math.max(280, height - 210), UI.RecipeHistoryColumns(width),
    function(craft) openCraft(craft.id) end, "No retained crafts in this period")
  outcomes.views["Craft History"] = history
  page.history = history
  local buttons, offsets = {}, {}
  function page:SelectView(name)
    if self.activeView then offsets[self.activeView] = scroll:GetVerticalScroll() end
    self.activeView = name
    outcomes:SelectView(name)
    for title, button in pairs(buttons) do
      button:Select(title == name)
    end
    scroll:SetVerticalScroll(offsets[name] or 0)
  end
  for index, name in ipairs({ "Overview", "Craft History", "Statistics", "Reagents" }) do
    buttons[name] = UI.Tab(content, name, (index - 1) * 124, -62, 120, function() page:SelectView(name) end)
  end
  page.tabs = buttons
  UI.LazyList(history, function(cursor)
    local filter = outcomes:Filter()
    filter.recipes = { page.recipe.id }
    local result, reason = ArtisanLogbookAPI.GetCrafts(filter, { limit = 40, cursor = cursor })
    return result and result.crafts, result and result.nextCursor or reason
  end)
  function page:Open(recipe)
    local changed = not self.recipe or self.recipe.id ~= recipe.id
    if changed and self.recipe then
      self.states[self.recipe.id] = { filters = outcomes:State(), history = history:Save(),
        view = self.activeView, offsets = offsets, offset = scroll:GetVerticalScroll(), recipe = self.recipe,
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
    if changed then offsets = saved and saved.offsets or {} end
    if changed or self.dirty then
      outcomes:Open(recipe.id, saved and saved.filters)
      if changed and saved then history:Restore(saved.history) end
      if not saved or self.dirty or saved.revision ~= (self.revision or 0) then history:Reload(not changed or saved ~= nil) end
      self.dirty = false
      self.loadedRevision = self.revision or 0
    end
    if changed then
      self.activeView = nil
      self:SelectView(saved and saved.view or "Overview")
      scroll:SetVerticalScroll(saved and saved.offset or 0)
    end
  end
  function page:Refresh()
    self.dirty = true
    if self.recipe then self:Open(self.recipe) end
  end
end

function UI.CraftDetail(parent, width, height, goBack)
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
  local preference
  local reagentSelector = UI.Selector(detail, 18, -64, width - 200, {}, function(value)
    preference:SetItem(value)
  end, "Reagent")
  preference = UI.TrivialCheckbox(detail, width - 145, -79, function() end)
  UI.RegisterTrivialCallback(function()
    preference:SetItem(reagentSelector.value)
  end)
  local scroll = CreateFrame("ScrollFrame", nil, detail, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 18, -126)
  scroll:SetPoint("BOTTOMRIGHT", -36, 16)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetWidth(width - 75)
  scroll:SetScrollChild(content)
  local fields = {}
  local fieldNames = { "Character", "Timestamp", "Quantity", "Quality", "Concentration", "Multicraft", "Ingenuity", "Resourcefulness" }
  for index, title in ipairs(fieldNames) do
    local offset = -(index - 1) * 26
    UI.Text(content, 0, offset, 146, 22, "GameFontNormalSmall"):SetText(title .. ":")
    fields[title] = UI.Text(content, 154, offset, width - 229, 24)
  end
  detail.fields = fields
  UI.Section(content, "Reagents returned", 0, -224, width - 75)
  local reagents = UI.ScrollList(content, 0, -258, width - 75, 172, {
    { title = "Reagent", width = (width - 99) * .60, value = function(row) return UI.Name(row.item) end,
      icon = function(row) return row.item and type(GetItemIcon) == "function" and GetItemIcon(row.item.id) end },
    { title = "Quality", width = (width - 99) * .18, value = function(row) return UI.Value(row.quality) end },
    { title = "Returned", width = (width - 99) * .22, value = function(row) return tostring(row.returnedQuantity) end },
  }, function() end, "No returned reagents recorded")
  detail.returnedReagents = reagents
  UI.Section(content, "Resulting items", 0, -448, width - 75)
  local output = UI.ScrollList(content, 0, -482, width - 75, 84, {
    { title = "Item", width = (width - 99) * .78, value = function(row) return UI.Name(row.item) end,
      icon = function(row) return row.item and type(GetItemIcon) == "function" and GetItemIcon(row.item.id) end },
    { title = "Quantity", width = (width - 99) * .22, value = function(row) return UI.Value(row.quantity) end },
  }, function() end, "Output identity unavailable")
  detail.output = output
  local metadata = UI.Text(content, 0, -592, width - 75, 140)
  content:SetHeight(746)

  function detail:ShowCraft(id)
    local craft, reason = ArtisanLogbookAPI.GetCraft(id)
    local choices, seen = {}, {}
    for _, reagent in ipairs(craft and craft.reagents or {}) do
      local item = reagent.item
      if item and item.id and not seen[item.id] then
        seen[item.id] = true
        choices[#choices + 1] = { label = UI.Name(item), value = item.id }
      end
    end
    local selected = seen[reagentSelector.value] and reagentSelector.value or (choices[1] and choices[1].value)
    reagentSelector:Update(choices, selected)
    preference:SetItem(selected)
    reagentSelector:SetShown(#choices > 0)
    if not craft then
      heading:SetText("Craft unavailable")
      subtitle:SetText(reason or "Unknown craft")
      for _, field in pairs(fields) do field:SetText("-") end
      reagents:Reset(); output:Reset(); metadata:SetText("")
      identity:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); quality:Hide()
      return
    end
    heading:SetText(UI.Elide(UI.Name(craft.recipe, "Unattributed craft"), math.floor((width - 166) / 10)))
    subtitle:SetText(UI.Name(craft.profession))
    identity:SetTexture(craft.outputItem and type(GetItemIcon) == "function" and GetItemIcon(craft.outputItem.id) or UI.RecipeIcon(craft.recipe))
    local atlas = UI.QualityAtlas(craft.recipe and craft.recipe.id, craft.outputQuality, craft.recipe and craft.recipe.maxQuality)
    quality:SetShown(atlas ~= nil)
    if atlas then quality:SetAtlas(atlas) end
    fields.Character:SetText(UI.CharacterName(craft.character))
    fields.Timestamp:SetText(date("%Y-%m-%d %H:%M:%S", craft.timestamp))
    fields.Quantity:SetText(UI.Value(craft.outputQuantity))
    fields.Quality:SetText(UI.Value(craft.outputQuality))
    fields.Concentration:SetText(UI.Value(craft.concentrationSpent))
    fields.Multicraft:SetText(craft.multicraftBonus and (craft.multicraftBonus .. " additional") or "Unknown")
    fields.Ingenuity:SetText(craft.hasIngenuityProc == true and
      (craft.ingenuityRefund and craft.ingenuityRefund .. " concentration refunded" or "Proc recorded") or
      (craft.hasIngenuityProc == false and "No proc" or "Unknown"))
    local returned, total, allocated, complete = {}, 0, 0, craft.resourcefulnessComplete == true
    for _, reagent in ipairs(craft.reagents or {}) do
      if reagent.allocatedQuantity == nil or reagent.returnedQuantity == nil then complete = false end
      allocated = allocated + (reagent.allocatedQuantity or 0)
      if reagent.returnedQuantity and reagent.returnedQuantity > 0 then
        returned[#returned + 1] = reagent; total = total + reagent.returnedQuantity
        if reagent.allocatedQuantity and reagent.returnedQuantity > reagent.allocatedQuantity then complete = false end
      end
    end
    local returnText = craft.hasResourcefulnessProc == nil and total == 0 and "Unknown" or total .. " returned"
    if complete and allocated > 0 then
      returnText = returnText .. string.format(" (%.1f%% of allocated reagents)", 100 * total / allocated)
    elseif craft.resourcefulnessComplete ~= true and total > 0 then
      returnText = returnText .. " (partial details)"
    end
    fields.Resourcefulness:SetText(returnText)
    reagents:Reset(); reagents:Append(returned)
    output:Reset()
    if craft.outputItem then output:Append({ { item = craft.outputItem, quantity = craft.outputQuantity } }) end
    local lines = { "Recipe: " .. UI.Name(craft.recipe), "Realm: " .. UI.Name(craft.realm),
      "Expansion: " .. UI.Name(craft.expansion), "Craft #" .. craft.id }
    if craft.request then
      lines[#lines + 1] = "Requested crafts: " .. UI.Value(craft.request.requestedCount)
      lines[#lines + 1] = "Quoted concentration: " .. UI.Value(craft.request.concentrationCost)
    end
    metadata:SetText(table.concat(lines, "\n"))
    scroll:UpdateScrollChildRect()
    scroll:SetVerticalScroll(0)
  end
  detail:Hide()
  return detail
end