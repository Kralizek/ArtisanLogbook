local _, addon = ...
local UI = {}
addon.UI = UI

UI.ink = { .20, .16, .10 }

function UI.Surface(parent, parchment)
  parent.parchment, parent.dark = parchment, not parchment
  local texture = parent:CreateTexture(nil, "BACKGROUND")
  texture:SetAllPoints(parent)
  if parchment then
    texture:SetTexture("Interface\\QuestFrame\\QuestBG")
    texture:SetTexCoord(0, .585, 0, .9)
  else
    texture:SetColorTexture(.075, .075, .07, 1)
  end
  return texture
end

function UI.Section(parent, title, x, y, width)
  local label = UI.Text(parent, x, y, width, 24, "GameFontNormal")
  label:SetText(title)
  local rule = parent:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(.35, .27, .14, .3)
  rule:SetPoint("TOPLEFT", x, y - 25)
  rule:SetSize(width, 1)
  return label
end

function UI.NavItem(parent, width, action)
  local button = CreateFrame("Button", nil, parent)
  button:SetSize(width, 30)
  button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  button.selection = button:CreateTexture(nil, "BACKGROUND")
  button.selection:SetAllPoints(button)
  button.selection:SetColorTexture(.55, .38, .08, .45)
  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetSize(18, 18)
  button.icon:SetPoint("TOPLEFT", 6, -6)
  button.label = UI.Text(button, 30, -7, width - 36, 20)
  button.label:SetWordWrap(false)
  button:SetScript("OnClick", function(self) action(self.entry) end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.entry.label)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  function button:Update(entry, selected)
    self.entry = entry
    self.icon:SetTexture(entry.icon or "Interface\\Icons\\INV_Misc_Book_09")
    self.label:SetText(UI.Elide(entry.label, math.floor((width - 36) / 7)))
    local color = UI.ClassColor(entry.classFile)
    if color then self.label:SetTextColor(color.r, color.g, color.b)
    else self.label:SetTextColor(.92, .87, .72) end
    self.selection:SetShown(selected)
  end
  return button
end

function UI.CopyRecipe(recipe, fallback)
  local result = { id = recipe.id }
  for _, key in ipairs({ "name", "maxQuality" }) do
    result[key] = recipe[key] or (fallback and fallback[key])
  end
  for _, key in ipairs({ "profession", "expansion" }) do
    local value = recipe[key] or (fallback and fallback[key])
    if type(value) == "table" then
      result[key] = { name = value.name, key = value.key, skillLineId = value.skillLineId }
    end
  end
  return result
end

function UI.Pins()
  if type(ArtisanLogbookUISettings) ~= "table" then ArtisanLogbookUISettings = {} end
  local stored = ArtisanLogbookUISettings.pinnedRecipes
  local pins = {}
  if type(stored) == "table" then
    for id, recipe in pairs(stored) do
      if type(id) == "number" and id > 0 and id < math.huge and id % 1 == 0 and
          type(recipe) == "table" then
        pins[#pins + 1] = UI.CopyRecipe({ id = id, name = type(recipe.name) == "string" and recipe.name or nil,
          profession = recipe.profession, expansion = recipe.expansion, maxQuality = recipe.maxQuality })
      end
    end
  end
  table.sort(pins, function(left, right)
    local leftName, rightName = UI.Name(left):lower(), UI.Name(right):lower()
    if leftName == rightName then return left.id < right.id end
    return leftName < rightName
  end)
  ArtisanLogbookUISettings.pinnedRecipes = {}
  for index = #pins, 6, -1 do table.remove(pins, index) end
  for _, recipe in ipairs(pins) do ArtisanLogbookUISettings.pinnedRecipes[recipe.id] = recipe end
  return pins
end

function UI.IsPinned(id)
  UI.Pins()
  return ArtisanLogbookUISettings.pinnedRecipes[id] ~= nil
end

function UI.TogglePin(recipe)
  if type(recipe) ~= "table" or type(recipe.id) ~= "number" or recipe.id <= 0 or
      recipe.id >= math.huge or recipe.id % 1 ~= 0 then return nil, "Unavailable recipe" end
  local pins = UI.Pins()
  local stored = ArtisanLogbookUISettings.pinnedRecipes
  if stored[recipe.id] then stored[recipe.id] = nil; return true end
  if #pins >= 5 then return nil, "Five recipes are already pinned" end
  stored[recipe.id] = UI.CopyRecipe(recipe)
  return true
end

function UI.Text(parent, x, y, width, height, font)
  local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", x, y)
  label:SetSize(width, height)
  label:SetJustifyH("LEFT")
  label:SetJustifyV("TOP")
  if UI.IsParchment(parent) then label:SetTextColor(unpack(UI.ink)) end
  return label
end

function UI.IsParchment(parent)
  while parent do
    if parent.parchment then return true end
    if parent.dark then return false end
    parent = parent:GetParent()
  end
  return false
end

function UI.RecipeIcon(recipe)
  local id = recipe and recipe.id
  if id and C_TradeSkillUI and type(C_TradeSkillUI.GetRecipeInfo) == "function" then
    local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, id)
    if ok and info and info.icon then return info.icon end
  end
  return id and type(GetSpellTexture) == "function" and GetSpellTexture(id) or
    "Interface\\Icons\\INV_Misc_Book_09"
end

UI.professionIcons = {
  [171] = "Trade_Alchemy", [164] = "Trade_BlackSmithing", [333] = "Trade_Engraving",
  [202] = "Trade_Engineering", [182] = "Trade_Herbalism", [773] = "INV_Inscription_Tradeskill01",
  [755] = "INV_Misc_Gem_01", [165] = "Trade_LeatherWorking", [186] = "Trade_Mining",
  [393] = "INV_Misc_Pelt_Wolf_01", [197] = "Trade_Tailoring",
}

function UI.ProfessionIcon(id)
  return "Interface\\Icons\\" .. (UI.professionIcons[id] or "INV_Misc_Book_09")
end

function UI.Population(character, profession)
  return { characters = character and { character } or nil, professions = profession and { profession } or nil }
end

function UI.Choices(facet, character)
  local result = { { label = "All", value = false } }
  local entries = facet == "characters" and ArtisanLogbookAPI.GetCharacters() or
    ArtisanLogbookAPI.GetProfessions(character or nil)
  for _, entry in ipairs(entries or {}) do
    result[#result + 1] = { label = UI.Name(entry), value = entry.key or entry.skillLineId,
      classFile = entry.classFile }
  end
  table.sort(result, function(left, right)
    if left.value == false then return right.value ~= false end
    if right.value == false then return false end
    if left.label == right.label then return tostring(left.value) < tostring(right.value) end
    return left.label:lower() < right.label:lower()
  end)
  return result
end

function UI.HistoryColumns(width)
  local available = width - 24
  return {
    { title = "Recipe", width = available * .30, value = function(row) return UI.Name(row.recipe) end,
      icon = function(row) return UI.RecipeIcon(row.recipe) end },
    { title = "Character", width = available * .18, value = function(row) return UI.Name(row.character) end,
      color = function(row) return UI.ClassColor(row.character and row.character.classFile) end },
    { title = "Profession", width = available * .17, value = function(row) return UI.Name(row.profession) end },
    { title = "Qty", width = available * .07, value = function(row) return UI.Value(row.outputQuantity) end },
    { title = "Highlights", width = available * .28, activity = true },
  }
end

function UI.LazyList(list, fetch)
  local cursor, loading, finished
  function list:LoadNext()
    if loading or finished then return end
    loading = true
    local page, nextCursor = fetch(cursor)
    if page then
      self:Append(page)
      cursor, finished = nextCursor, nextCursor == nil
      if finished then self:SetFinished() end
    else
      finished = true
      self.empty:SetText(nextCursor or "Unavailable")
      self.empty:SetShown(#self.items == 0)
    end
    loading = false
  end
  list.onNearEnd = function() list:LoadNext() end
  function list:Reload(preserve)
    local offset, count = self.scroll:GetVerticalScroll(), #self.items
    cursor, finished = nil, false
    self:Reset()
    self:LoadNext()
    self.restoreCount = preserve and count or nil
    self.restoreOffset = preserve and offset or nil
    self:SetScript("OnUpdate", function(self)
      if self.restoreCount and #self.items < self.restoreCount and not finished then
        self:LoadNext()
      else
        if self.restoreOffset then self.scroll:SetVerticalScroll(self.restoreOffset) end
        self.restoreCount, self.restoreOffset = nil, nil
        self:SetScript("OnUpdate", nil)
      end
    end)
    if not preserve or count <= #self.items then self:GetScript("OnUpdate")(self) end
  end
  function list:Save()
    return { items = self.items, cursor = cursor, finished = finished, offset = self.scroll:GetVerticalScroll() }
  end
  function list:Restore(state)
    self:SetScript("OnUpdate", nil)
    self:Reset()
    cursor, finished = state.cursor, state.finished
    self:Append(state.items)
    if finished then self:SetFinished() end
    self.scroll:SetVerticalScroll(state.offset)
  end
  return list
end

function UI.PageScroll(parent, width, height, contentHeight)
  local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, 0)
  scroll:SetSize(width - 24, height)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(width - 28, math.max(height, contentHeight))
  scroll:SetScrollChild(content)
  return content, scroll
end

function UI.Button(parent, title, x, y, width, action)
  local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  button:SetSize(width, 24)
  button:SetPoint("TOPLEFT", x, y)
  button:SetText(title)
  button:SetScript("OnClick", action)
  return button
end

function UI.Elide(value, maxCharacters)
  local text = tostring(value or "")
  local characters = 0
  for index = 1, #text do
    local byte = text:byte(index)
    if byte < 128 or byte >= 192 then
      characters = characters + 1
      if characters > maxCharacters then return text:sub(1, index - 1) .. "..." end
    end
  end
  return text
end

function UI.Selector(parent, x, y, width, choices, onChoose, title)
  local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
  if title then UI.Text(parent, x, y, width, 16, "GameFontNormalSmall"):SetText(title) end
  dropdown:SetPoint("TOPLEFT", x - 15, y + (title and -13 or 2))
  UIDropDownMenu_SetWidth(dropdown, width)
  dropdown.choices = choices
  local function display(self, label, classFile)
    self.fullLabel = label
    local color = UI.ClassColor(classFile)
    local text = UI.Elide(label, math.max(6, math.floor(width / 7)))
    UIDropDownMenu_SetText(self, color and color.colorStr and
      ("|c" .. color.colorStr .. text .. "|r") or text)
  end
  function dropdown:Choose(value)
    self.value = value
    for _, choice in ipairs(self.choices) do
      if choice.value == value then display(self, choice.label, choice.classFile); break end
    end
    onChoose(value)
  end
  function dropdown:Update(available, selected)
    self.choices = available
    self.value = selected
    local label, classFile = "None", nil
    for _, choice in ipairs(available) do
      if choice.value == selected then label, classFile = choice.label, choice.classFile; break end
    end
    display(self, label, classFile)
  end
  dropdown:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.fullLabel)
    GameTooltip:Show()
  end)
  dropdown:SetScript("OnLeave", function() GameTooltip:Hide() end)
  UIDropDownMenu_Initialize(dropdown, function(self)
    for _, choice in ipairs(self.choices) do
      local info = UIDropDownMenu_CreateInfo()
      local color = UI.ClassColor(choice.classFile)
      info.text = color and color.colorStr and ("|c" .. color.colorStr .. choice.label .. "|r") or choice.label
      info.checked = self.value == choice.value
      info.func = function() self:Choose(choice.value) end
      UIDropDownMenu_AddButton(info)
    end
  end)
  dropdown:Update(choices, choices[1] and choices[1].value)
  return dropdown
end

function UI.HasChoice(choices, selected)
  for _, choice in ipairs(choices) do
    if choice.value == selected then return true end
  end
  return false
end

function UI.Value(value)
  if value == nil then return "Unknown" end
  if type(value) == "boolean" then return value and "Yes" or "No" end
  return tostring(value)
end

function UI.Name(value, fallback)
  return value and (value.name or (value.id and "#" .. value.id)) or fallback or "Unknown"
end

function UI.ClassColor(classFile)
  return classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] or nil
end

function UI.CharacterName(character)
  local name = UI.Name(character)
  local color = character and UI.ClassColor(character.classFile)
  return color and color.colorStr and ("|c" .. color.colorStr .. name .. "|r") or name
end

function UI.QualityAtlas(recipeID, quality, maxQuality)
  if type(recipeID) ~= "number" or type(quality) ~= "number" or type(maxQuality) ~= "number" or
      quality < 1 or quality > maxQuality or maxQuality < 2 then return nil end
  if C_TradeSkillUI and type(C_TradeSkillUI.GetRecipeItemQualityInfo) == "function" then
    local ok, qualityInfo = pcall(C_TradeSkillUI.GetRecipeItemQualityInfo, recipeID, quality)
    return ok and qualityInfo and qualityInfo.icon or nil
  end
end

function UI.Activity(craft)
  local indicators = {}
  local function add(icon, text, tooltip, atlas)
    indicators[#indicators + 1] = { icon = icon, text = text or "", tooltip = tooltip, atlas = atlas }
  end
  local recipe = craft.recipe
  local atlas = UI.QualityAtlas(recipe and recipe.id, craft.outputQuality, recipe and recipe.maxQuality)
  if atlas then add(nil, "", "Crafting quality " .. craft.outputQuality .. " of " .. recipe.maxQuality, atlas) end
  local output = UI.CraftOutput(craft)
  if output ~= "" then
    local item = craft.outputItem
    local icon = item and item.id and type(GetItemIcon) == "function" and GetItemIcon(item.id)
    add(icon or "Interface\\Icons\\INV_Misc_QuestionMark", "",
      "Output: " .. output .. " (" .. UI.Value(craft.outputQuantity) .. " total)")
  end
  if craft.concentrationSpent and craft.concentrationSpent > 0 then
    add("Interface\\Icons\\Spell_Arcane_Arcane01", tostring(craft.concentrationSpent),
      "Concentration: " .. craft.concentrationSpent .. " spent")
  end
  if craft.multicraftBonus and craft.multicraftBonus > 0 then
    add("Interface\\Icons\\Trade_Engineering", "+" .. craft.multicraftBonus,
      "Multicraft: produced " .. craft.multicraftBonus .. " additional items")
  end
  if craft.hasIngenuityProc then
    add("Interface\\Icons\\Spell_Holy_MindVision", craft.ingenuityRefund and craft.ingenuityRefund > 0 and
      "+" .. craft.ingenuityRefund or "", craft.ingenuityRefund and craft.ingenuityRefund > 0 and
      "Ingenuity: refunded " .. craft.ingenuityRefund .. " concentration" or "Ingenuity proc")
  end
  local returned = 0
  for _, reagent in ipairs(craft.reagents or {}) do
    returned = returned + math.max(0, reagent.returnedQuantity or 0)
  end
  if returned > 0 then
    local lines = { "Reagents returned: " .. returned }
    for _, reagent in ipairs(craft.reagents or {}) do
      if reagent.returnedQuantity and reagent.returnedQuantity > 0 then
        lines[#lines + 1] = UI.ReagentDescription(reagent)
      end
    end
    add("Interface\\Icons\\INV_Misc_Herb_19", tostring(returned), table.concat(lines, "\n"))
  end
  return indicators
end

function UI.ScrollList(parent, x, y, width, height, columns, onOpen, emptyMessage)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetSize(width, height)
  frame:SetPoint("TOPLEFT", x, y)
  frame.rows, frame.items = {}, {}
  local header = frame:CreateTexture(nil, "BACKGROUND")
  header:SetPoint("TOPLEFT", 0, 0)
  header:SetSize(width - 24, 24)
  header:SetColorTexture(.45, .34, .18, .12)
  local position = 0
  for _, column in ipairs(columns) do
    UI.Text(frame, position + 3, -3, column.width - 6, 20, "GameFontNormalSmall"):SetText(column.title)
    position = position + column.width
  end
  local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -26)
  scroll:SetSize(width - 24, height - 26)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(width - 24, height - 26)
  scroll:SetScrollChild(child)
  frame.scroll, frame.child = scroll, child
  frame.empty = UI.Text(frame, 8, -48, width - 40, 30)
  frame.empty:SetText(emptyMessage or "No entries yet")
  frame.empty:Hide()
  frame.finish = UI.Text(child, 8, -8, width - 40, 24)
  frame.finish:SetText("End of results")
  frame.finish:Hide()

  function frame:Reset(message)
    for _, row in ipairs(self.rows) do row.item = nil; row:Hide() end
    self.items = {}
    self.empty:SetText(message or emptyMessage or "No entries yet")
    self.empty:Show()
    self.finish:Hide()
    self.child:SetHeight(self.scroll:GetHeight())
    self.scroll:SetVerticalScroll(0)
  end

  function frame:SetFinished()
    if #self.items == 0 then return end
    self.finish:ClearAllPoints()
    self.finish:SetPoint("TOPLEFT", 8, -#self.items * 30 - 8)
    self.finish:Show()
    self.child:SetHeight(math.max(self.scroll:GetHeight(), #self.items * 30 + 35))
  end

  function frame:Append(items)
    for _, item in ipairs(items) do
      local index = #self.items + 1
      self.items[index] = item
      local row = self.rows[index]
      if not row then
        row = CreateFrame("Button", nil, child)
        row:SetSize(width - 24, 28)
        row:SetPoint("TOPLEFT", 0, -(index - 1) * 30)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local rule = row:CreateTexture(nil, "BACKGROUND")
        rule:SetPoint("BOTTOMLEFT", 0, 0); rule:SetSize(width - 24, 1)
        rule:SetColorTexture(.45, .34, .18, .16)
        row.cells, row.widgets = {}, {}
        local left = 0
        for _, column in ipairs(columns) do
          if column.create then
            row.widgets[#row.widgets + 1] = { widget = column.create(row, left), column = column }
          elseif column.activity then
            row.activity = CreateFrame("Frame", nil, row)
            row.activity:SetSize(column.width - 4, 24)
            row.activity:SetPoint("TOPLEFT", left + 2, -2)
          else
            local icon
            if column.icon then
              icon = row:CreateTexture(nil, "ARTWORK")
              icon:SetSize(20, 20)
              icon:SetPoint("TOPLEFT", left + 2, -4)
            end
            local padding = icon and 24 or 2
            local label = UI.Text(row, left + padding, -5, column.width - padding - 4, 20)
            label:SetWordWrap(false)
            label:SetMaxLines(1)
            row.cells[#row.cells + 1] = { label = label, column = column, icon = icon }
          end
          left = left + column.width
        end
        row:SetScript("OnClick", function(self) onOpen(self.item) end)
        row:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:SetText(UI.Name(self.item.recipe or self.item.item, "Artisan Logbook"))
          for _, column in ipairs(columns) do
            if column.value and column.title ~= "Recipe" then
              GameTooltip:AddLine(column.title .. ": " .. tostring(column.value(self.item)), 1, 1, 1)
            end
          end
          if self.activity then
            for _, indicator in ipairs(UI.Activity(self.item)) do
              GameTooltip:AddLine(indicator.tooltip, 1, 1, 1)
            end
          end
          GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.rows[index] = row
      end
      row.item = item
      for _, cell in ipairs(row.widgets) do cell.column.update(cell.widget, item) end
      for _, cell in ipairs(row.cells) do
        local text = cell.column.value(item)
        cell.label:SetText(UI.Elide(text, math.max(3, math.floor((cell.column.width - (cell.icon and 30 or 9)) / 7))))
        if cell.icon then
          cell.icon:SetTexture(cell.column.icon(item) or "Interface\\Icons\\INV_Misc_QuestionMark")
        end
        local color = cell.column.color and cell.column.color(item)
        if color then cell.label:SetTextColor(color.r, color.g, color.b)
        elseif UI.IsParchment(frame) then cell.label:SetTextColor(unpack(UI.ink))
        else cell.label:SetTextColor(1, 1, 1) end
      end
      if row.activity then
        for _, indicator in ipairs(row.indicators or {}) do indicator:Hide() end
        row.indicators = row.indicators or {}
        local left = 0
        local indicators, desired = UI.Activity(item), 0
        for _, indicator in ipairs(indicators) do desired = desired + (indicator.text ~= "" and 50 or 26) end
        local compact = desired > row.activity:GetWidth()
        for indicatorIndex, indicator in ipairs(indicators) do
          local indicatorWidth = not compact and indicator.text ~= "" and 50 or 26
          if left + indicatorWidth > row.activity:GetWidth() then break end
          local button = row.indicators[indicatorIndex]
          if not button then
            button = CreateFrame("Frame", nil, row.activity)
            button:SetSize(24, 24)
            button.icon = button:CreateTexture(nil, "ARTWORK")
            button.icon:SetSize(17, 17)
            button.icon:SetPoint("LEFT", 0, 0)
            button.label = UI.Text(button, 18, -4, 34, 18)
            button:SetScript("OnEnter", function(self)
              GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
              GameTooltip:SetText(self.tooltip)
              GameTooltip:Show()
            end)
            button:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row.indicators[indicatorIndex] = button
          end
          button:SetWidth(indicatorWidth)
          button:SetPoint("LEFT", row.activity, "LEFT", left, 0)
          button.tooltip = indicator.tooltip
          if indicator.atlas then button.icon:SetAtlas(indicator.atlas)
          else button.icon:SetTexture(indicator.icon) end
          button.label:SetText(compact and "" or indicator.text)
          button:Show()
          left = left + indicatorWidth
        end
      end
      row:Show()
    end
    self.empty:SetShown(#self.items == 0)
    self.child:SetHeight(math.max(self.scroll:GetHeight(), #self.items * 30))
  end
  scroll:HookScript("OnVerticalScroll", function(self)
    if frame.onNearEnd and self:GetVerticalScroll() + self:GetHeight() >= child:GetHeight() - 100 then
      frame.onNearEnd()
    end
  end)
  frame:Reset()
  return frame
end

function UI.Chart(parent, x, y, width)
  local chart = CreateFrame("Frame", nil, parent)
  chart:SetSize(width, 168)
  chart:SetPoint("TOPLEFT", x, y)
  chart.title = UI.Text(chart, 14, -10, width - 170, 22, "GameFontNormal")
  chart.title:SetText("Craft activity")
  chart.total = UI.Text(chart, width - 152, -10, 136, 22, "GameFontHighlightSmall")
  chart.total:SetJustifyH("RIGHT")
  chart.plot = CreateFrame("Frame", nil, chart)
  chart.plot:SetSize(width - 32, 100)
  chart.plot:SetPoint("TOPLEFT", 16, -36)
  chart.start = UI.Text(chart, 16, -140, 110, 20)
  chart.finish = UI.Text(chart, width - 126, -140, 110, 20)
  chart.finish:SetJustifyH("RIGHT")
  chart.empty = UI.Text(chart, 16, -80, width - 32, 24)
  chart.empty:SetText("No crafts in this period")
  chart.empty:SetJustifyH("CENTER")
  chart.bars = {}
  local baseline = chart.plot:CreateTexture(nil, "BACKGROUND")
  baseline:SetColorTexture(.35, .27, .14, .4)
  baseline:SetPoint("BOTTOMLEFT", 0, 0); baseline:SetSize(width - 32, 1)

  function chart:Render(series, from, to, bucketSeconds)
    bucketSeconds = bucketSeconds or 86400
    bucketSeconds = math.max(bucketSeconds, math.ceil((to - from) / 86400 / 60) * 86400)
    local daily, total, peak = {}, 0, 0
    for _, row in ipairs(series or {}) do
      local bucket = from + math.floor((row.bucketStart - from) / bucketSeconds) * bucketSeconds
      daily[bucket] = (daily[bucket] or 0) + row.craftCount
      total = total + row.craftCount
    end
    local days = math.max(1, math.ceil((to - from) / bucketSeconds))
    for day = 0, days - 1 do peak = math.max(peak, daily[from + day * bucketSeconds] or 0) end
    self.total:SetText(string.format("%d crafts", total))
    self.empty:SetShown(total == 0)
    self.start:SetText(date("!%d %b %Y", from))
    self.finish:SetText(date("!%d %b %Y", to - 86400))
    for _, bar in ipairs(self.bars) do bar:Hide() end
    local barWidth = (width - 32) / days
    for day = 0, days - 1 do
      local count = daily[from + day * bucketSeconds] or 0
      local bar = self.bars[day + 1]
      if not bar then
        bar = CreateFrame("Frame", nil, self.plot)
        bar.texture = bar:CreateTexture(nil, "ARTWORK")
        bar.texture:SetAllPoints(bar)
        bar.texture:SetColorTexture(.17, .43, .29, .9)
        bar:EnableMouse(true)
        bar:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(self.tooltip); GameTooltip:Show()
        end)
        bar:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.bars[day + 1] = bar
      end
      bar:SetPoint("BOTTOMLEFT", self.plot, "BOTTOMLEFT", day * barWidth, 0)
      bar:SetSize(math.max(2, barWidth - 3), math.max(1, count * 94 / math.max(1, peak)))
      bar.tooltip = date("!%d %b %Y", from + day * bucketSeconds) .. ": " .. count .. " crafts"
      if bucketSeconds > 86400 then bar.tooltip = bar.tooltip .. " / " .. (bucketSeconds / 86400) .. " days" end
      bar:SetShown(count > 0)
    end
  end
  return chart
end

function UI.CraftOutput(craft)
  local output = UI.Name(craft.outputItem, "")
  if craft.recipe and craft.recipe.name and craft.recipe.name == output then return "" end
  return output
end

function UI.CraftHighlights(craft)
  local details = {}
  if craft.concentrationSpent and craft.concentrationSpent > 0 then
    details[#details + 1] = "Concentration " .. craft.concentrationSpent
  end
  if craft.multicraftBonus and craft.multicraftBonus > 0 then
    details[#details + 1] = "Multicraft +" .. craft.multicraftBonus
  end
  if craft.hasIngenuityProc then
    details[#details + 1] = craft.ingenuityRefund and craft.ingenuityRefund > 0 and
      "Ingenuity +" .. craft.ingenuityRefund or "Ingenuity proc"
  end
  local returned = 0
  for _, reagent in ipairs(craft.reagents or {}) do
    if reagent.returnedQuantity and reagent.returnedQuantity > 0 then
      returned = returned + reagent.returnedQuantity
    end
  end
  if returned > 0 then details[#details + 1] = "Reagents returned: " .. returned end
  return details
end

function UI.ReagentDescription(reagent)
  local description = UI.Name(reagent.item) .. ": "
  if reagent.allocatedQuantity ~= nil then
    description = description .. reagent.allocatedQuantity .. " allocated"
    if reagent.returnedQuantity ~= nil then
      description = description .. ", " .. reagent.returnedQuantity .. " returned"
    end
  elseif reagent.returnedQuantity ~= nil then
    description = description .. reagent.returnedQuantity .. " returned (allocation unknown)"
  else
    description = description .. "quantity unknown"
  end
  if reagent.quality ~= nil then description = description .. " (quality " .. reagent.quality .. ")" end
  return description
end

function UI.Range(now, days)
  local today = math.floor(now / 86400) * 86400
  return today - (days - 1) * 86400, today + 86400
end

UI.ranges = {
  { label = "Today", value = 1 },
  { label = "7 days", value = 7 },
  { label = "30 days", value = 30 },
  { label = "90 days", value = 90 },
  { label = "365 days", value = 365 },
}
