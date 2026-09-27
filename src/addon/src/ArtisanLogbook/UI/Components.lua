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

function UI.Selector(parent, x, y, width, choices, onChoose)
  local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
  dropdown:SetPoint("TOPLEFT", x - 15, y + 2)
  UIDropDownMenu_SetWidth(dropdown, width)
  dropdown.choices = choices
  function dropdown:Choose(value)
    self.value = value
    for _, choice in ipairs(self.choices) do
      if choice.value == value then UIDropDownMenu_SetText(self, choice.label); break end
    end
    onChoose(value)
  end
  function dropdown:Update(available, selected)
    self.choices = available
    self.value = selected
    local label = "None"
    for _, choice in ipairs(available) do
      if choice.value == selected then label = choice.label; break end
    end
    UIDropDownMenu_SetText(self, label)
  end
  UIDropDownMenu_Initialize(dropdown, function(self)
    for _, choice in ipairs(self.choices) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = choice.label
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

function UI.Chart(parent, x, y, width)
  local chart = CreateFrame("Frame", nil, parent)
  chart:SetSize(width, 176)
  chart:SetPoint("TOPLEFT", x, y)
  chart.title = UI.Text(chart, 0, 0, width, 22, "GameFontNormal")
  chart.plot = CreateFrame("Frame", nil, chart)
  chart.plot:SetSize(width - 12, 114)
  chart.plot:SetPoint("TOPLEFT", 0, -27)
  chart.start = UI.Text(chart, 0, -150, 110, 20)
  chart.finish = UI.Text(chart, width - 110, -150, 110, 20)
  chart.finish:SetJustifyH("RIGHT")
  chart.lines = {}

  function chart:Render(series, from, to)
    local daily, total, peak = {}, 0, 0
    for _, row in ipairs(series or {}) do
      daily[row.bucketStart] = (daily[row.bucketStart] or 0) + row.craftCount
      total = total + row.craftCount
    end
    local days = math.max(1, math.ceil((to - from) / 86400))
    for day = 0, days - 1 do peak = math.max(peak, daily[from + day * 86400] or 0) end
    self.title:SetText(string.format("Crafts per day  |  %d crafts", total))
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
        (day - 1) * (width - 12) / (days - 1), (daily[from + (day - 1) * 86400] or 0) * 108 / math.max(1, peak))
      line:SetEndPoint("BOTTOMLEFT", self.plot,
        day * (width - 12) / (days - 1), (daily[from + day * 86400] or 0) * 108 / math.max(1, peak))
      line:Show()
    end
  end
  return chart
end

function UI.Table(parent, x, y, width, columns, size, onOpen)
  local tableView = CreateFrame("Frame", nil, parent)
  tableView:SetSize(width, 30 + size * 28)
  tableView:SetPoint("TOPLEFT", x, y)
  tableView.rows = {}
  local position = 0
  for _, column in ipairs(columns) do
    local cell = UI.Text(tableView, position, 0, column.width, 22, "GameFontNormalSmall")
    cell:SetText(column.title)
    position = position + column.width
  end
  for index = 1, size do
    local button = CreateFrame("Button", nil, tableView)
    button:SetSize(width, 26)
    button:SetPoint("TOPLEFT", 0, -24 - (index - 1) * 28)
    button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    button.cells = {}
    position = 0
    for _, column in ipairs(columns) do
      button.cells[#button.cells + 1] = UI.Text(button, position + 2, -4, column.width - 5, 22)
      position = position + column.width
    end
    button:SetScript("OnClick", function(self) if self.item then onOpen(self.item) end end)
    tableView.rows[index] = button
  end
  function tableView:Render(items)
    for index, button in ipairs(self.rows) do
      local item = items[index]
      button.item = item
      if item then
        for cell, column in ipairs(columns) do
          button.cells[cell]:SetText(tostring(column.value(item) or ""))
        end
        button:Show()
      else
        button:Hide()
      end
    end
  end
  return tableView
end

function UI.CraftTable(parent, x, y, width, openCraft)
  local ratio = width / 840
  local function column(title, size, value)
    return { title = title, width = size * ratio, value = value }
  end
  return UI.Table(parent, x, y, width, {
    column("Recipe", 185, function(craft) return UI.Name(craft.recipe) end),
    column("Character", 125, function(craft) return UI.Name(craft.character) end),
    column("Profession", 135, function(craft) return UI.Name(craft.profession) end),
    column("Output", 145, function(craft) return UI.Name(craft.outputItem) end),
    column("Quantity", 65, function(craft) return UI.Value(craft.outputQuantity) end),
    column("Details", 185, function(craft)
      local details = {}
      if craft.outputQuality ~= nil then details[#details + 1] = "Q" .. craft.outputQuality end
      if craft.outputItemLevel ~= nil then details[#details + 1] = "IL" .. craft.outputItemLevel end
      if craft.concentrationSpent ~= nil then details[#details + 1] = "Conc " .. craft.concentrationSpent end
      if craft.multicraftBonus ~= nil then details[#details + 1] = "Multi " .. craft.multicraftBonus end
      for _, reagent in ipairs(craft.reagents) do
        if reagent.returnedQuantity and reagent.returnedQuantity > 0 then
          details[#details + 1] = "Returned"; break
        end
      end
      if craft.hasIngenuityProc then details[#details + 1] = "Ingenuity" end
      return table.concat(details, " | ")
    end),
  }, 10, function(craft) openCraft(craft.id) end)
end

function UI.Range(now, days)
  local today = math.floor(now / 86400) * 86400
  return today - (days - 1) * 86400, today + 86400
end

UI.ranges = {
  { label = "30 days", value = 30 },
  { label = "90 days", value = 90 },
  { label = "365 days", value = 365 },
}

function UI.History(parent, width, withChart, filter, openCraft)
  local history = CreateFrame("Frame", nil, parent)
  history:SetAllPoints(parent)
  history.days, history.page, history.cursors = 30, 1, { false }
  local range = UI.Selector(history, 0, -4, 115, UI.ranges, function(days)
    history.days = days
    history:Refresh(true)
  end)
  local chart
  if withChart then chart = UI.Chart(history, 8, -48, width - 16) end
  local tableTop = withChart and -234 or -46
  local craftTable = UI.CraftTable(history, 0, tableTop, width, openCraft)
  local pageText = UI.Text(history, 88, tableTop - 312, 160, 24)
  local previous = UI.Button(history, "<", 0, tableTop - 308, 35, function()
    if history.page > 1 then history.page = history.page - 1; history:Refresh() end
  end)
  local nextPage = UI.Button(history, ">", 240, tableTop - 308, 35, function()
    if history.nextCursor then
      history.page = history.page + 1
      history.cursors[history.page] = history.nextCursor
      history:Refresh()
    end
  end)
  local status = UI.Text(history, 290, tableTop - 312, width - 300, 24)
  history.range = range
  history.chart = chart
  history.table = craftTable

  function history:Refresh(reset)
    if reset then self.page, self.cursors = 1, { false } end
    local selected = filter()
    local from, to = UI.Range(GetServerTime(), self.days)
    selected.time = { from = from, to = to }
    local page, reason = ArtisanLogbookAPI.GetCrafts(selected,
      { limit = 10, cursor = self.cursors[self.page] or nil })
    self.nextCursor = page and page.nextCursor
    self.table:Render(page and page.crafts or {})
    pageText:SetText("Page " .. self.page)
    previous:SetEnabled(self.page > 1)
    nextPage:SetEnabled(self.nextCursor ~= nil)
    status:SetText(page and (#page.crafts == 0 and "No crafts" or "Newest first") or (reason or "Unavailable"))
    if self.chart then
      local series = ArtisanLogbookAPI.GetCraftSeries(selected)
      self.chart:Render(series and series.series or {}, from, to)
    end
  end
  return history
end