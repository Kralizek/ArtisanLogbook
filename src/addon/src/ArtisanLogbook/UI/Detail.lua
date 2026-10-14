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
  local titleHover = CreateFrame("Frame", nil, content)
  titleHover:SetPoint("TOPLEFT", 0, -4); titleHover:SetSize(width - 244, 52)
  titleHover:EnableMouse(true)
  UI.Tooltip.Bind(titleHover, function(self) UI.RecipeTooltip(self, page.recipe, outcomes:Filter()) end)
  page.titleHover = titleHover
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
    UI.Tooltip.ReleaseTree(titleHover)
    outcomes.recipe = recipe
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

function UI.ConfigurationRows(craft)
  craft = craft or {}
  local configuration = craft.configuration or {}
  local evidence = craft.configurationObservation or {}
  local stats = configuration.stats or {}
  local rows = { stats = {}, equipment = {}, buffs = {}, finishingReagents = {}, scope = evidence.scope,
    equipmentCoverage = evidence.equipmentCoverage, buffsCoverage = evidence.buffsCoverage,
    finishingCoverage = evidence.finishingCoverage }
  local function totalStat(label, base, bonus)
    if type(base) == "number" and type(bonus) == "number" then
      return { label = label, value = UI.Number(base + bonus), detail =
        "Base " .. UI.Number(base) .. " + bonus " .. UI.Number(bonus), available = true }
    elseif type(base) == "number" or type(bonus) == "number" then
      return { label = label, value = (base ~= nil and "Base " .. UI.Number(base) or "Bonus " .. UI.Number(bonus)),
        detail = "Total unavailable because one value wasn't recorded.", available = true }
    end
    return { label = label, value = "Not recorded", detail = "This value wasn't available in the crafting quote.", available = false }
  end
  rows.stats[1] = totalStat("Effective skill", stats.baseSkill, stats.bonusSkill)
  rows.stats[2] = totalStat("Difficulty", stats.baseDifficulty, stats.bonusDifficulty)
  for index, spec in ipairs({ { "multicraft", "Multicraft" }, { "resourcefulness", "Resourcefulness" },
      { "ingenuity", "Ingenuity" }, { "craftingSpeed", "Crafting speed" } }) do
    local stat = stats[spec[1]]
    local value = stat and stat.ratingPct ~= nil and (UI.Number(stat.ratingPct) .. "%") or "Not recorded"
    local detail = stat and stat.rating ~= nil and (UI.Number(stat.rating) .. " rating") or
      (stat and "Rating wasn't recorded." or "This stat wasn't identified in the crafting quote.")
    rows.stats[index + 2] = { label = spec[2], value = value, detail = detail,
      available = stat ~= nil and stat.ratingPct ~= nil,
      explanation = stat and ("Reported rating: " .. UI.Value(stat.rating) .. ". Reported percentage: " ..
        UI.Value(stat.ratingPct) .. "%. Additional percentage: " .. UI.Value(stat.bonusRatingPct) .. "%.") or nil }
  end
  rows.concentration = configuration.useConcentration == nil and "Not recorded" or
    (configuration.useConcentration and "Used" or "Not used")
  for index, equipment in ipairs(configuration.equipment or {}) do
    rows.equipment[#rows.equipment + 1] = { role = index == 1 and "Profession tool" or "Accessory " .. (index - 1),
      itemID = equipment.itemID, empty = equipment.empty == true, slot = equipment.slot }
  end
  for _, buff in ipairs(configuration.buffs or {}) do
    local name, icon
    if C_Spell and type(C_Spell.GetSpellName) == "function" then
      local ok, value = pcall(C_Spell.GetSpellName, buff.spellID)
      if ok and type(value) == "string" then name = value end
    end
    if C_Spell and type(C_Spell.GetSpellTexture) == "function" then
      local ok, value = pcall(C_Spell.GetSpellTexture, buff.spellID)
      if ok then icon = value end
    end
    rows.buffs[#rows.buffs + 1] = { spellID = buff.spellID, name = name or "Crafting phial",
      icon = icon, applications = buff.applications }
  end
  for _, reagent in ipairs(configuration.finishingReagents or {}) do
    rows.finishingReagents[#rows.finishingReagents + 1] = {
      itemID = reagent.itemID, name = UI.ItemName(reagent.itemID), quantity = reagent.quantity,
    }
  end
  if evidence.equipmentCoverage == "observed" then
    local equipped = false
    for _, equipment in ipairs(rows.equipment) do if not equipment.empty then equipped = true end end
    if #rows.equipment == 0 then rows.equipmentStatus = "Equipment slots weren't reported."
    elseif not equipped then rows.equipmentStatus = "No profession equipment equipped" end
  elseif evidence.equipmentCoverage == "partial" then
    rows.equipmentStatus = "Some equipment details weren't recorded."
  else
    rows.equipmentStatus = "Equipment wasn't recorded."
  end
  if evidence.buffsCoverage == "supported-list" then
    rows.buffsStatus = #rows.buffs == 0 and "No supported profession phial detected; other buffs aren't checked." or
      "Only supported profession phials are checked."
  elseif evidence.buffsCoverage == "partial" then
    rows.buffsStatus = "Some phials couldn't be checked; other crafting buffs aren't included."
  else
    rows.buffsStatus = "Buff information wasn't recorded."
  end
  if evidence.finishingCoverage == "submitted" then
    rows.finishingStatus = #rows.finishingReagents == 0 and "None selected" or nil
  elseif evidence.finishingCoverage == "partial" then
    rows.finishingStatus = "Some finishing reagents weren't identified."
  else
    rows.finishingStatus = "Finishing reagents weren't recorded."
  end
  rows.provenance = evidence.scope == "attempt-start" and "Observed at craft start" or
    evidence.scope == "request" and "Observed at submission" or "Observation time unavailable"
  rows.provenance = rows.provenance .. " - Not verified at completion"
  if not craft.configuration then
    rows.provenance = (craft.configurationCoverage == "changed" and "Configuration changed during the attempt" or
      "Configuration wasn't recorded") .. " - Not verified at completion"
  end
  return rows
end

function UI.ConfigurationPanel(parent, x, y, width, height)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetPoint("TOPLEFT", x, y); frame:SetSize(width, height)
  local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, 0); scroll:SetSize(width - 24, height)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(width - 24, height)
  scroll:SetScrollChild(child)
  scroll:HookScript("OnScrollRangeChanged", function(self, _, range)
    if self.ScrollBar then self.ScrollBar:SetShown((range or 0) > 0) end
  end)
  frame.scroll, frame.child, frame.itemCells = scroll, child, {}

  local function sectionHeader(title)
    local header = UI.Text(child, 0, 0, width - 34, 22, "QuestTitleFont")
    header:SetTextColor(.94, .82, .55); header:SetShadowOffset(0, 0)
    local rule = child:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(.35, .27, .14, .3); rule:SetHeight(1)
    header.rule = rule
    return header
  end
  frame.headers = { sectionHeader("Crafting stats"), sectionHeader("Profession equipment"),
    sectionHeader("Buffs and finishing reagents") }

  local bodyWidth = width - 34
  local columns = bodyWidth < 540 and 2 or 3
  frame.statColumns = columns
  local cardGap, cardHeight = 7, 60
  local cardWidth = (bodyWidth - cardGap * (columns - 1)) / columns
  frame.statCards = {}
  for index = 1, 6 do
    local card = CreateFrame("Frame", nil, child)
    card:SetSize(cardWidth, cardHeight)
    card.background = card:CreateTexture(nil, "BACKGROUND")
    card.background:SetAllPoints(card); card.background:SetColorTexture(.12, .115, .105, 1)
    card.label = UI.Text(card, 7, -4, cardWidth - 14, 15, "GameFontNormalSmall")
    card.value = UI.Text(card, 7, -21, cardWidth - 14, 21, "GameFontNormal")
    card.detail = UI.Text(card, 7, -42, cardWidth - 14, 15, "GameFontNormalSmall")
    card.detail:SetTextColor(.67, .64, .58)
    card:EnableMouse(true)
    card:SetScript("OnEnter", function(self)
      if not self.explanation then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(self.label:GetText())
      GameTooltip:AddLine(self.explanation, 1, 1, 1, true); GameTooltip:Show()
    end)
    card:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.statCards[index] = card
  end

  local dynamicText = {}
  local textIndex = 0
  local function addText(top, text, widthValue, heightValue, muted)
    textIndex = textIndex + 1
    local label = dynamicText[textIndex]
    if not label then
      label = UI.Text(child, 0, 0, widthValue, heightValue, "GameFontNormalSmall")
      dynamicText[textIndex] = label
    end
    label:ClearAllPoints(); label:SetPoint("TOPLEFT", 0, -top)
    label:SetSize(widthValue or bodyWidth, heightValue or 18)
    label:SetText(text or "")
    label:SetTextColor(muted and .68 or .88, muted and .65 or .86, muted and .59 or .78)
    label:Show()
    return label
  end
  local equipmentCells, reagentCells, buffRows = {}, {}, {}
  frame.equipmentCells, frame.reagentCells, frame.buffRows = equipmentCells, reagentCells, buffRows

  function frame:ShowCraft(craft)
    local rows = UI.ConfigurationRows(craft)
    self.rows = rows
    self.itemCells = {}
    textIndex = 0
    for _, label in ipairs(dynamicText) do label:Hide() end
    for _, cell in ipairs(equipmentCells) do cell:Hide() end
    for _, cell in ipairs(reagentCells) do cell:Hide() end
    for _, row in ipairs(buffRows) do row:Hide() end
    local top = 0
    local function placeHeader(index, title)
      local header = self.headers[index]
      header:ClearAllPoints(); header:SetPoint("TOPLEFT", 0, -top); header:SetText(title); header:Show()
      header.rule:ClearAllPoints(); header.rule:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -1)
      header.rule:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -1); header.rule:Show()
      top = top + 26
    end
    placeHeader(1, "Crafting stats")
    for index, stat in ipairs(rows.stats) do
      local card = self.statCards[index]
      local column = (index - 1) % columns
      local row = math.floor((index - 1) / columns)
      card:ClearAllPoints(); card:SetPoint("TOPLEFT", column * (cardWidth + cardGap), -(top + row * (cardHeight + 6)))
      card.label:SetText(stat.label); card.value:SetText(stat.value); card.detail:SetText(stat.detail or "")
      card.value:SetTextColor(stat.available == false and .65 or .92, stat.available == false and .62 or .87,
        stat.available == false and .56 or .75)
      card.explanation = stat.explanation or stat.detail
      card:Show()
    end
    local statRows = math.ceil(#rows.stats / columns)
    top = top + statRows * (cardHeight + 6)
    addText(top, "Concentration " .. rows.concentration, bodyWidth, 18, true)
    top = top + 23

    placeHeader(2, "Profession equipment")
    if #rows.equipment == 0 then
      addText(top, rows.equipmentStatus, bodyWidth, 18, true); top = top + 22
    else
      local roleWidth = 112
      for index, equipment in ipairs(rows.equipment) do
        addText(top + 6, equipment.role, roleWidth, 18, true)
        if equipment.empty then
          addText(top + 6, "Not equipped", bodyWidth - roleWidth, 18, true)
        elseif equipment.itemID then
          local cell = equipmentCells[index]
          if not cell then
            cell = UI.ItemCell(child, roleWidth, bodyWidth - roleWidth)
            equipmentCells[index] = cell
          end
          local item = { id = equipment.itemID, name = UI.ItemName(equipment.itemID), note = equipment.role }
          cell:ClearAllPoints(); cell:SetPoint("TOPLEFT", roleWidth, -top); cell:SetWidth(bodyWidth - roleWidth)
          cell:Update(item); cell:Show()
          self.itemCells[#self.itemCells + 1] = { itemID = equipment.itemID, cell = cell, note = equipment.role }
        else
          addText(top + 6, "Item details unavailable", bodyWidth - roleWidth, 18, true)
        end
        top = top + 30
      end
      if rows.equipmentStatus then addText(top, rows.equipmentStatus, bodyWidth, 16, true); top = top + 19 end
    end

    placeHeader(3, "Buffs and finishing reagents")
    addText(top, "Crafting buffs", bodyWidth, 18, false); top = top + 20
    for index, buff in ipairs(rows.buffs) do
      local row = buffRows[index]
      if not row then
        row = CreateFrame("Frame", nil, child); row:SetSize(bodyWidth, 28); row:EnableMouse(true)
        row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(20, 20); row.icon:SetPoint("TOPLEFT", 0, -3)
        row.label = UI.Text(row, 27, -3, bodyWidth - 115, 20, "GameFontNormalSmall")
        row.stacks = UI.Text(row, bodyWidth - 82, -3, 78, 20, "GameFontNormalSmall")
        row.stacks:SetJustifyH("RIGHT")
        row:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(self.buffName)
          if self.applications ~= nil then GameTooltip:AddLine("Stacks: " .. UI.Number(self.applications), 1, 1, 1) end
          GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        buffRows[index] = row
      end
      row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -top)
      row.icon:SetTexture(buff.icon or "Interface\\Icons\\INV_Potion_01")
      row.label:SetText(buff.name); row.stacks:SetText(buff.applications ~= nil and ("x" .. UI.Number(buff.applications)) or "")
      row.buffName, row.applications, row.spellID = buff.name, buff.applications, buff.spellID
      row:Show(); top = top + 28
    end
    if rows.buffsStatus then addText(top, rows.buffsStatus, bodyWidth, 16, true); top = top + 19 end
    addText(top, "Finishing reagents", bodyWidth, 18, false); top = top + 20
    if #rows.finishingReagents == 0 then
      addText(top, rows.finishingStatus, bodyWidth, 18, true); top = top + 20
    else
      for index, reagent in ipairs(rows.finishingReagents) do
        local cell = reagentCells[index]
        if not cell then
          cell = UI.ItemCell(child, 0, bodyWidth - 84)
          reagentCells[index] = cell
        end
        cell:ClearAllPoints(); cell:SetPoint("TOPLEFT", 0, -top); cell:SetWidth(bodyWidth - 84)
        cell:Update({ id = reagent.itemID, name = reagent.name, note = "Finishing reagent" }); cell:Show()
        self.itemCells[#self.itemCells + 1] = { itemID = reagent.itemID, cell = cell, note = "Finishing reagent" }
        local amount = addText(top + 6, "x" .. UI.Number(reagent.quantity), 72, 18, true)
        amount:ClearAllPoints(); amount:SetPoint("TOPRIGHT", child, "TOPRIGHT", -4, -(top + 6)); amount:SetJustifyH("RIGHT")
        top = top + 30
      end
    end
    addText(top + 2, rows.provenance, bodyWidth, 18, true)
    top = top + 24
    self.child:SetHeight(math.max(self.scroll:GetHeight(), top))
    self.scroll:SetVerticalScroll(0)
  end

  function frame:RefreshItem(itemID)
    for _, entry in ipairs(self.itemCells) do
      if entry.itemID == itemID then
        entry.cell:Update({ id = itemID, name = UI.ItemName(itemID), note = entry.note })
      end
    end
  end

  frame:Hide()
  return frame
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
  local titleHover = CreateFrame("Frame", nil, detail)
  titleHover:SetPoint("TOPLEFT", 16, -8); titleHover:SetSize(width - 120, 52)
  titleHover:EnableMouse(true)
  UI.Tooltip.Bind(titleHover, function(self) if detail.craft then UI.CraftTooltip(self, detail.craft) end end)
  detail.titleHover = titleHover
  local iconHover = CreateFrame("Frame", nil, titleHover)
  iconHover:SetAllPoints(identity); iconHover:EnableMouse(true)
  UI.Tooltip.Bind(iconHover, function(self)
    if detail.craft and detail.craft.outputItem then UI.ItemTooltip(self, detail.craft.outputItem)
    elseif detail.craft then UI.CraftTooltip(self, detail.craft) end
  end)
  detail.iconHover = iconHover
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
  local ingredientsTab, configurationTab
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
  local configurationPanel = UI.ConfigurationPanel(content, 0, -280, width - 36, height - 352)
  local function selectInspection(configuration)
    reagents:SetShown(not configuration); configurationPanel:SetShown(configuration)
    ingredientsTab:Select(not configuration); configurationTab:Select(configuration)
  end
  ingredientsTab = UI.Tab(content, "Ingredients", 0, -244, 124, function() selectInspection(false) end)
  configurationTab = UI.Tab(content, "Configuration", 128, -244, 140, function() selectInspection(true) end)
  detail.configurationList, detail.configurationPanel, detail.configurationTab = configurationPanel, configurationPanel, configurationTab
  detail:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  detail:SetScript("OnEvent", function(_, event, itemID, success)
    if event == "GET_ITEM_INFO_RECEIVED" and success and detail.craft then
      configurationPanel:RefreshItem(itemID)
    end
  end)
  selectInspection(false)

  function detail:ShowCraft(id)
    UI.Tooltip.ReleaseTree(self)
    local craft, reason = ArtisanLogbookAPI.GetCraft(id)
    self.craft = craft
    if not craft then
      heading:SetText("Craft unavailable")
      subtitle:SetText(reason or "Unknown craft")
      for _, field in pairs(fields) do field:SetText("-") end
      reagents:Reset(); resultRow:Update(nil); resultRow.quantity:SetText("-"); resultRow.bonus:SetText("")
      detail.inputEvidence:SetText("")
      configurationPanel:ShowCraft(nil)
      identity:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
      return
    end
    heading:SetText(UI.Elide(UI.Name(craft.recipe, "Unattributed craft"), math.floor((width - 166) / 10)))
    subtitle:SetText(UI.Name(craft.profession) .. " - " .. UI.ContextText(craft))
    identity:SetTexture(craft.outputItem and UI.ItemIcon(craft.outputItem.id) or UI.RecipeIcon(craft.recipe))
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
    configurationPanel:ShowCraft(craft)
  end
  detail:Hide()
  return detail
end