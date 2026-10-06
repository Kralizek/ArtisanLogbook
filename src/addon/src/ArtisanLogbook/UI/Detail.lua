local _, addon = ...
local UI = addon.UI

function UI.RecipePage(page, width, height, openCraft, pinsChanged)
  local content, scroll = UI.PageScroll(page, width, height, 1020)
  width = width - 28
  page.content, page.scroll = content, scroll
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
  UI.Section(content, "Craft history", 0, -732, width)
  history = UI.ScrollList(content, 0, -766, width, 238, UI.HistoryColumns(width),
    function(craft) openCraft(craft.id) end, "No retained crafts in this period")
  page.history = history
  UI.LazyList(history, function(cursor)
    local filter = outcomes:Filter()
    filter.recipes = { page.recipe.id }
    local result, reason = ArtisanLogbookAPI.GetCrafts(filter, { limit = 40, cursor = cursor })
    return result and result.crafts, result and result.nextCursor or reason
  end)
  function page:Open(recipe)
    local changed = not self.recipe or self.recipe.id ~= recipe.id
    self.recipe = recipe
    heading:SetText(UI.Name(recipe))
    local details = { "Recipe #" .. recipe.id }
    if recipe.profession then details[#details + 1] = UI.Name(recipe.profession) end
    if recipe.expansion then details[#details + 1] = UI.Name(recipe.expansion) end
    metadata:SetText(table.concat(details, "  -  "))
    icon:SetTexture(UI.RecipeIcon(recipe))
    pin:SetText(UI.IsPinned(recipe.id) and "Unpin recipe" or "Pin recipe")
    if changed then scroll:SetVerticalScroll(0) end
    if changed or self.dirty then
      outcomes:Open(recipe.id)
      history:Reload(not changed)
      self.dirty = false
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
  local heading = UI.Text(detail, 16, -8, width - 120, 28, "GameFontNormalLarge")
  UI.Button(detail, "Back", width - 92, -8, 76, goBack)
  local preference
  local reagentSelector = UI.Selector(detail, 18, -43, width - 200, {}, function(value)
    preference:SetItem(value)
  end, "Reagent")
  preference = UI.TrivialCheckbox(detail, width - 145, -58, function() end)
  local scroll = CreateFrame("ScrollFrame", nil, detail, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 18, -100)
  scroll:SetPoint("BOTTOMRIGHT", -36, 16)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetWidth(width - 75)
  local text = UI.Text(content, 0, 0, width - 75, height, "GameFontHighlight")
  scroll:SetScrollChild(content)

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
      text:SetText(reason or "Unknown craft")
      content:SetHeight(40)
      return
    end
    heading:SetText(UI.Name(craft.recipe, "Unattributed craft") .. "  #" .. craft.id)
    local lines = {}
    local function section(title)
      lines[#lines + 1] = ""
      lines[#lines + 1] = title
    end
    local function field(title, value)
      lines[#lines + 1] = title .. ": " .. UI.Value(value)
    end
    section("Craft")
    field("Time", date("%Y-%m-%d %H:%M:%S", craft.timestamp))
    field("Character", UI.CharacterName(craft.character))
    field("Realm", UI.Name(craft.realm))
    field("Profession", UI.Name(craft.profession))
    field("Recipe", UI.Name(craft.recipe))
    field("Expansion", UI.Name(craft.expansion))
    field("Output", UI.Name(craft.outputItem))
    field("Quantity", craft.outputQuantity)
    field("Quality", craft.outputQuality)
    field("Item level", craft.outputItemLevel)
    local highlights = UI.CraftHighlights(craft)
    if #highlights > 0 then
      section("Craft activity")
      for _, highlight in ipairs(highlights) do lines[#lines + 1] = highlight end
    end
    if craft.request then
      section("Personal craft request")
      field("Request ID", craft.request.id)
      field("Submitted", date("%Y-%m-%d %H:%M:%S", craft.request.timestamp))
      field("Requested recipe", UI.Name(craft.request.recipe))
      field("Requested count", craft.request.requestedCount)
      field("Use concentration", craft.request.useConcentration)
      field("Quoted concentration", craft.request.concentrationCost)
      field("Base skill", craft.request.baseSkill)
      field("Base difficulty", craft.request.baseDifficulty)
      field("Expected quality", craft.request.craftingQuality)
    end
    if #craft.reagents > 0 then
      section("Reagents and returns")
      for _, reagent in ipairs(craft.reagents) do
        lines[#lines + 1] = UI.ReagentDescription(reagent)
      end
    end
    section("Identity")
    field("Game operation ID", craft.gameOperationId)
    text:SetText(table.concat(lines, "\n"))
    local contentHeight = math.max(scroll:GetHeight(), text:GetStringHeight() + 24)
    content:SetHeight(contentHeight)
    text:SetHeight(contentHeight)
    scroll:UpdateScrollChildRect()
    scroll:SetVerticalScroll(0)
  end
  detail:Hide()
  return detail
end