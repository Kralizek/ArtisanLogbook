local _, addon = ...
local UI = {}
addon.UI = UI

function UI.Text(parent, x, y, width, height, font)
  local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", x, y)
  label:SetSize(width, height)
  label:SetJustifyH("LEFT")
  label:SetJustifyV("TOP")
  return label
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
        row.cells = {}
        local left = 0
        for _, column in ipairs(columns) do
          if column.activity then
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
          GameTooltip:SetText(UI.Name(self.item.recipe, "Artisan Logbook"))
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
      for _, cell in ipairs(row.cells) do
        local text = cell.column.value(item)
        cell.label:SetText(UI.Elide(text, math.max(3, math.floor((cell.column.width - 9) / 7))))
        if cell.icon then
          cell.icon:SetTexture(cell.column.icon(item) or "Interface\\Icons\\INV_Misc_QuestionMark")
        end
        local color = cell.column.color and cell.column.color(item)
        if color then cell.label:SetTextColor(color.r, color.g, color.b)
        else cell.label:SetTextColor(1, 1, 1) end
      end
      if row.activity then
        for _, indicator in ipairs(row.indicators or {}) do indicator:Hide() end
        row.indicators = row.indicators or {}
        local left = 0
        for indicatorIndex, indicator in ipairs(UI.Activity(item)) do
          local indicatorWidth = indicator.text ~= "" and 50 or 26
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
          button.label:SetText(indicator.text)
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
  local chart = CreateFrame("Frame", nil, parent, "InsetFrameTemplate3")
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
  chart.lines = {}

  function chart:Render(series, from, to, bucketSeconds)
    bucketSeconds = bucketSeconds or 86400
    local daily, total, peak = {}, 0, 0
    for _, row in ipairs(series or {}) do
      daily[row.bucketStart] = (daily[row.bucketStart] or 0) + row.craftCount
      total = total + row.craftCount
    end
    local days = math.max(1, math.ceil((to - from) / bucketSeconds))
    for day = 0, days - 1 do peak = math.max(peak, daily[from + day * bucketSeconds] or 0) end
    self.total:SetText(string.format("%d crafts", total))
    self.empty:SetShown(total == 0)
    self.start:SetText(date("!%d %b %Y", from))
    self.finish:SetText(date("!%d %b %Y", to - 86400))
    for _, line in ipairs(self.lines) do line:Hide() end
    local count = 0
    for day = 1, days - 1 do
      count = count + 1
      local line = self.lines[count]
      if not line then
        line = self.plot:CreateLine(nil, "ARTWORK")
        line:SetThickness(2)
        line:SetColorTexture(0.28, 0.72, 0.58, 1)
        self.lines[count] = line
      end
      line:SetStartPoint("BOTTOMLEFT", self.plot,
        (day - 1) * (width - 32) / (days - 1), (daily[from + (day - 1) * bucketSeconds] or 0) * 94 / math.max(1, peak))
      line:SetEndPoint("BOTTOMLEFT", self.plot,
        day * (width - 32) / (days - 1), (daily[from + day * bucketSeconds] or 0) * 94 / math.max(1, peak))
      if total > 0 then line:Show() end
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
