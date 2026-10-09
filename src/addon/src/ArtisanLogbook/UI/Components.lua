local _, addon = ...
local UI = {}
addon.UI = UI

UI.ink = { .20, .16, .10 }

function UI.Number(value, exact, lowerBound)
  if type(value) ~= "number" then return "-" end
  if exact then return tostring(value) end
  local absolute, divisor, suffix = math.abs(value), 1, ""
  for _, unit in ipairs({ { 1e9, "B" }, { 1e6, "M" }, { 1e3, "k" } }) do
    if absolute >= unit[1] then divisor, suffix = unit[1], unit[2]; break end
  end
  local scaled = value / divisor
  if lowerBound then scaled = math.floor(scaled * 10) / 10 end
  local text = string.format("%.1f", scaled):gsub("%.0$", "")
  if suffix == "k" and math.abs(tonumber(text)) >= 1000 then return string.format("%.1f", value / 1e6):gsub("%.0$", "") .. "M" end
  if suffix == "M" and math.abs(tonumber(text)) >= 1000 then return string.format("%.1f", value / 1e9):gsub("%.0$", "") .. "B" end
  return text .. suffix
end

function UI.Percent(numerator, denominator)
  if type(numerator) ~= "number" or type(denominator) ~= "number" or denominator <= 0 then return "-" end
  return string.format("%.1f%%", numerator / denominator * 100)
end

function UI.Count(value, singular, plural)
  return UI.Number(value) .. " " .. (value == 1 and singular or plural or singular .. "s")
end

function UI.Amount(value, complete)
  if value == nil or value == 0 and not complete then return "-" end
  return UI.Number(value)
end

function UI.AmountTooltip(value, complete)
  if value == nil or value == 0 and not complete then return "Quantity unavailable" end
  return tostring(value) .. (complete and "" or "\nSome crafts have no quantity; the total may be higher.")
end

function UI.Rate(totals, metric)
  if not totals or totals[metric .. "ObservedCount"] ~= totals.craftCount then return "-" end
  return UI.Percent(totals[metric], totals.craftCount)
end

function UI.ProcValue(totals, metric)
  local rate = UI.Rate(totals, metric)
  if rate ~= "-" then return rate end
  local count = totals and totals[metric]
  return count and count > 0 and UI.Count(count, "proc") or "-"
end

function UI.ProcTooltip(totals, metric)
  if not totals then return "Results unavailable" end
  local count, crafts = totals[metric] or 0, totals.craftCount or 0
  local known = totals[metric .. "ObservedCount"] or 0
  if crafts == 0 then return "No crafts in this selection" end
  if known == crafts then
    return UI.Rate(totals, metric) .. "\n" .. count .. (count == 1 and " proc / " or " procs / ") ..
      crafts .. (crafts == 1 and " craft" or " crafts")
  end
  local missing = crafts - known
  local outcome = metric == "resourcefulnessProcCount" and "return outcome" or "proc result"
  return UI.Count(count, "known proc") .. " from " .. UI.Count(crafts, "craft") .. "\n" ..
    "Rate unavailable: " .. UI.Count(missing, "craft") .. (missing == 1 and " has" or " have") .. " no " .. outcome .. "."
end

function UI.DateTime(timestamp, exact)
  return timestamp and date(exact and "%Y-%m-%d %H:%M:%S" or "%d %b\n%H:%M", timestamp) or "-"
end

function UI.Surface(parent, parchment)
  parent.parchment, parent.dark = parchment, not parchment
  local texture = parent:CreateTexture(nil, "BACKGROUND")
  texture:SetAllPoints(parent)
  if parchment then
    texture:SetColorTexture(.86, .76, .56, 1)
    local grain = parent:CreateTexture(nil, "BORDER")
    grain:SetAllPoints(parent)
    grain:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal")
    grain:SetAlpha(.16)
    texture.grain = grain
  else
    texture:SetColorTexture(.075, .075, .07, 1)
  end
  return texture
end

function UI.Section(parent, title, x, y, width)
  local label = UI.Text(parent, x, y, width, 24, "QuestTitleFont")
  if not UI.IsParchment(parent) then label:SetTextColor(.94, .82, .55) end
  label:SetShadowOffset(0, 0)
  label:SetText(title)
  local rule = parent:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(.35, .27, .14, .3)
  rule:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -1)
  rule:SetPoint("TOPRIGHT", label, "BOTTOMRIGHT", 0, -1)
  rule:SetHeight(1)
  return label
end

function UI.NavItem(parent, width, action)
  local button = CreateFrame("Button", nil, parent)
  button:SetSize(width, 24)
  button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  button.selection = button:CreateTexture(nil, "BACKGROUND")
  button.selection:SetAllPoints(button)
  button.selection:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  button.selection:SetBlendMode("ADD")
  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetSize(16, 16)
  button.icon:SetPoint("TOPLEFT", 6, -4)
  button.label = UI.Text(button, 28, -4, width - 34, 18)
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
  if UI.IsParchment(parent) then
    label:SetTextColor(unpack(UI.ink))
    label:SetShadowOffset(0, 0)
  end
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

function UI.ItemTooltip(owner, item)
  if not item then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  if item.id and type(GameTooltip.SetItemByID) == "function" then GameTooltip:SetItemByID(item.id)
  else GameTooltip:SetText(UI.Name(item)) end
  if item.id then GameTooltip:AddLine("Item ID: " .. item.id, 1, 1, 1) end
  GameTooltip:Show()
end

function UI.ItemCell(parent, left, width)
  local cell = CreateFrame("Frame", nil, parent)
  cell:SetPoint("TOPLEFT", left, 0); cell:SetSize(width, 28)
  cell:EnableMouse(true)
  cell:SetPropagateMouseClicks(true)
  cell:SetScript("OnEnter", function(self) UI.ItemTooltip(self, self.item) end)
  cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
  cell.icon = cell:CreateTexture(nil, "ARTWORK")
  cell.icon:SetSize(22, 22); cell.icon:SetPoint("TOPLEFT", 2, -3)
  cell.quality = cell:CreateTexture(nil, "OVERLAY")
  cell.quality:SetSize(14, 14); cell.quality:SetPoint("TOPLEFT", 13, -15)
  cell.label = UI.Text(cell, 30, -5, width - 34, 22)
  cell.label:SetWordWrap(false)
  function cell:Update(item, atlas, icon)
    self.item = item
    self.icon:SetTexture(icon or (item and type(GetItemIcon) == "function" and GetItemIcon(item.id)) or
      "Interface\\Icons\\INV_Misc_QuestionMark")
    self.quality:SetShown(atlas ~= nil)
    if atlas then self.quality:SetAtlas(atlas) end
    self.label:SetText(UI.Elide(UI.Name(item), math.max(4, math.floor((width - 34) / 6))))
  end
  return cell
end

function UI.HistoryColumns(width, context)
  local available, columns = width - 24, {}
  local fixed = 38 + 88 + (context == "Logbook" and 0 or 72)
  local textWeight = (context ~= "Recipe" and 1.15 or 0) + 1.25 +
    (context ~= "Character" and .65 or 0) + (context ~= "Profession" and context ~= "Recipe" and .70 or 0)
  local unit = (available - fixed) / textWeight
  if context ~= "Recipe" then
    columns[#columns + 1] = { title = "Recipe", width = unit * 1.15,
      value = function(row) return UI.Name(row.recipe) end }
  end
  columns[#columns + 1] = { title = "Result", width = unit * 1.25,
    value = function(row) return UI.Name(row.outputItem) .. (row.outputQuality and " (quality " .. row.outputQuality .. ")" or "") end,
    create = function(parent, left) return UI.ItemCell(parent, left, unit * 1.25) end,
    update = function(cell, row)
      cell:Update(row.outputItem, UI.QualityAtlas(row.recipe and row.recipe.id, row.outputQuality, row.recipe and row.recipe.maxQuality))
    end }
  if context ~= "Character" then
    columns[#columns + 1] = { title = "Character", width = unit * .65,
      value = function(row) return UI.Name(row.character) end,
      color = function(row) return UI.ClassColor(row.character and row.character.classFile) end }
  end
  if context ~= "Profession" and context ~= "Recipe" then
    columns[#columns + 1] = { title = "Profession", width = unit * .70, value = function(row) return UI.Name(row.profession) end }
  end
  columns[#columns + 1] = { title = "Qty", width = 38, value = function(row) return UI.Number(row.outputQuantity) end,
    exact = function(row) return UI.Value(row.outputQuantity) end }
  columns[#columns + 1] = { title = "Highlights", width = 88, activity = true, extrasOnly = true }
  if context ~= "Logbook" then
    columns[#columns + 1] = { title = "When", width = 72, lines = 2,
      value = function(row) return UI.DateTime(row.timestamp) end, exact = function(row) return UI.DateTime(row.timestamp, true) end }
  end
  return columns
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

function UI.RecipeHistoryColumns(width)
  return UI.HistoryColumns(width, "Recipe")
end

function UI.PageScroll(parent, width, height, contentHeight)
  local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, 0)
  scroll:SetSize(width - 24, height)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(width - 28, math.max(height, contentHeight))
  scroll:SetScrollChild(content)
  scroll:HookScript("OnScrollRangeChanged", function(self, _, range)
    if self.ScrollBar then self.ScrollBar:SetShown((range or 0) > 0) end
  end)
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

function UI.Tab(parent, title, x, y, width, action)
  local tab = CreateFrame("Button", nil, parent, "TabSystemButtonArtTemplate")
  tab.isTabOnTop = true
  tab:HandleRotation()
  tab:SetSize(width, 28)
  tab:SetPoint("TOPLEFT", x, y)
  tab:SetText(title)
  tab.Text:SetWidth(width - 12)
  tab.Text:SetWordWrap(false)
  tab:SetScript("OnClick", action)
  tab:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(title); GameTooltip:Show()
  end)
  tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
  function tab:Select(selected)
    self.selected = selected
    self:SetTabSelected(selected)
  end
  tab:Select(false)
  return tab
end

function UI.FilterBar(parent, width, y)
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetPoint("TOPLEFT", 0, y or 0); bar:SetSize(width, 46)
  bar.controls, bar.nextX, bar.row = {}, 0, 0
  function bar:Slot(size)
    if self.nextX + size > width then self.nextX, self.row = 0, self.row + 1 end
    local left, top = self.nextX, -self.row * 46
    self.nextX = self.nextX + size + 14
    self:SetHeight((self.row + 1) * 46)
    return left, top
  end
  function bar:Select(title, choices, onChoose, size)
    size = math.min(size or 156, 176)
    local left, top = self:Slot(size)
    local control = UI.Selector(self, left, top, size, choices, onChoose, title)
    self.controls[#self.controls + 1] = control
    return control
  end
  function bar:Search(onSearch)
    local size = 190
    local left, top = self:Slot(size)
    UI.Text(self, left, top, size, 16, "GameFontNormalSmall"):SetText("Search")
    local input = CreateFrame("EditBox", nil, self, "InputBoxTemplate")
    input:SetPoint("TOPLEFT", left + 4, top - 16); input:SetSize(128, 24)
    input:SetAutoFocus(false); input:SetMaxLetters(120)
    local function apply() input:SetScript("OnUpdate", nil); input:ClearFocus(); onSearch(input:GetText()) end
    input:SetScript("OnEnterPressed", apply)
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    input:SetScript("OnTextChanged", function(self)
      self.delay = .2
      self:SetScript("OnUpdate", function(self, elapsed)
        self.delay = self.delay - elapsed
        if self.delay <= 0 then self:SetScript("OnUpdate", nil); onSearch(self:GetText()) end
      end)
    end)
    local function actionButton(x, texture, action)
      local button = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
      button:SetSize(24, 24); button:SetPoint("TOPLEFT", x, top - 16)
      local icon = button:CreateTexture(nil, "ARTWORK")
      icon:SetSize(16, 16); icon:SetPoint("CENTER"); icon:SetTexture(texture)
      button:SetScript("OnClick", action)
      return button
    end
    local search = actionButton(left + 136, "Interface\\Common\\UI-Searchbox-Icon", apply)
    local clear = actionButton(left + 164, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", function() input:SetText(""); apply() end)
    clear:SetScript("OnClick", function() input:SetText(""); apply() end)
    for button, text in pairs({ [search] = "Search", [clear] = "Clear search" }) do
      button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(text); GameTooltip:Show()
      end)
      button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    input.searchButton, input.clearButton = search, clear
    return input
  end
  function bar:Period(state, onChange, includeAll, size)
    local choices = includeAll and { { label = "All time", value = false } } or {}
    for _, choice in ipairs(UI.ranges) do choices[#choices + 1] = choice end
    choices[#choices + 1] = { label = "Custom dates", value = "custom" }
    local control
    control = self:Select("Period", choices, function(value)
      control.state.days = value; control:UpdateState(); onChange()
    end, size)
    local dates = CreateFrame("Frame", nil, self)
    dates:SetSize(width, 46); dates:Hide()
    local inputs = {}
    for index, title in ipairs({ "From (UTC)", "Through (UTC)" }) do
      local left = (index - 1) * 138
      UI.Text(dates, left, 0, 130, 16, "GameFontNormalSmall"):SetText(title)
      local input = CreateFrame("EditBox", nil, dates, "InputBoxTemplate")
      input:SetPoint("TOPLEFT", left + 4, -16); input:SetSize(124, 24)
      input:SetAutoFocus(false); input:SetMaxLetters(10)
      inputs[index] = input
    end
    local errorText = UI.Text(dates, 284, -18, width - 284, 24)
    local function apply(input)
      input:ClearFocus()
      local from, through = UI.ParseUTCDate(inputs[1]:GetText()), UI.ParseUTCDate(inputs[2]:GetText())
      if not from or not through or from > through then errorText:SetText("Enter valid dates: YYYY-MM-DD"); return end
      control.state.customFrom, control.state.customTo = from, through + 86400
      errorText:SetText(""); onChange()
    end
    inputs[1]:SetScript("OnEnterPressed", apply); inputs[2]:SetScript("OnEnterPressed", apply)
    function control:UpdateState(replacement)
      if replacement then self.state = replacement end
      local from, to = UI.Range(GetServerTime(), 30)
      self.state.customFrom, self.state.customTo = self.state.customFrom or from, self.state.customTo or to
      inputs[1]:SetText(date("!%Y-%m-%d", self.state.customFrom))
      inputs[2]:SetText(date("!%Y-%m-%d", self.state.customTo - 86400))
      self:Update(choices, self.state.days)
      dates:SetShown(self.state.days == "custom")
      dates:ClearAllPoints(); dates:SetPoint("TOPLEFT", 0, -(bar.row + 1) * 46)
      bar:SetHeight((bar.row + 1) * 46 + (self.state.days == "custom" and 46 or 0))
      if bar.onLayout then bar.onLayout(bar:GetHeight()) end
    end
    function control:Time()
      if self.state.days == false then return nil end
      if self.state.days == "custom" then return { from = self.state.customFrom, to = self.state.customTo } end
      local from, to = UI.Range(GetServerTime(), self.state.days or 30)
      return { from = from, to = to }
    end
    control.state, control.inputs = state, inputs
    control:UpdateState()
    return control
  end
  return bar
end

function UI.TabbedContent(parent, width, height, y, names, onSelect)
  local tabs = CreateFrame("Frame", nil, parent)
  tabs:SetPoint("TOPLEFT", 0, y); tabs:SetSize(width, height)
  tabs.buttons, tabs.views = {}, {}
  tabs.body = CreateFrame("Frame", nil, tabs, "BackdropTemplate")
  tabs.body:SetPoint("TOPLEFT", 0, -27); tabs.body:SetSize(width, height - 27)
  tabs.body:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  tabs.body:SetBackdropColor(.86, .76, .56, .6)
  tabs.body:SetBackdropBorderColor(.45, .36, .20, .8)
  function tabs:Select(name)
    self.activeView = name
    for title, view in pairs(self.views) do view:SetShown(title == name) end
    for title, button in pairs(self.buttons) do button:Select(title == name) end
    if onSelect then onSelect(name) end
  end
  for index, name in ipairs(names) do
    tabs.buttons[name] = UI.Tab(tabs, name, (index - 1) * 128 + 4, 0, 124, function() tabs:Select(name) end)
    local view = CreateFrame("Frame", nil, tabs.body)
    view:SetPoint("TOPLEFT", 12, -12); view:SetSize(width - 24, height - 51)
    tabs.views[name] = view
  end
  function tabs:Resize(newHeight)
    self:SetHeight(newHeight); self.body:SetHeight(newHeight - 27)
    for _, view in pairs(self.views) do view:SetHeight(newHeight - 51) end
  end
  tabs:Select(names[1])
  return tabs
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
  if title then
    dropdown.caption = UI.Text(dropdown, 15, 13, width, 16, "GameFontNormalSmall")
    dropdown.caption:SetText(title)
  end
  dropdown:SetPoint("TOPLEFT", x - 15, y + (title and -13 or 2))
  UIDropDownMenu_SetWidth(dropdown, width - 35)
  UIDropDownMenu_JustifyText(dropdown, "LEFT")
  dropdown.choices = choices
  local function display(self, label, classFile)
    self.fullLabel = label
    local color = UI.ClassColor(classFile)
    local text = UI.Elide(label, math.max(6, math.floor((width - 60) / 6)))
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

function UI.ReadableColor(color, parent)
  if not color or not UI.IsParchment(parent) then return color end
  local function linear(value)
    return value <= .04045 and value / 12.92 or ((value + .055) / 1.055) ^ 2.4
  end
  local function luminance(red, green, blue)
    return .2126 * linear(red) + .7152 * linear(green) + .0722 * linear(blue)
  end
  local background = luminance(.86 * .84, .76 * .84, .56 * .84)
  local red, green, blue = color.r, color.g, color.b
  while (background + .05) / (luminance(red, green, blue) + .05) < 4.5 do
    red, green, blue = red * .85, green * .85, blue * .85
  end
  return { r = red, g = green, b = blue,
    colorStr = string.format("ff%02x%02x%02x", math.floor(red * 255), math.floor(green * 255), math.floor(blue * 255)) }
end

function UI.CharacterName(character, parent)
  local name = UI.Name(character)
  local color = character and UI.ReadableColor(UI.ClassColor(character.classFile), parent)
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

function UI.Activity(craft, extrasOnly)
  local indicators = {}
  local function add(icon, text, tooltip, atlas)
    indicators[#indicators + 1] = { icon = icon, text = text or "", tooltip = tooltip, atlas = atlas }
  end
  local recipe = craft.recipe
  local atlas = UI.QualityAtlas(recipe and recipe.id, craft.outputQuality, recipe and recipe.maxQuality)
  if atlas and not extrasOnly then add(nil, "", "Crafting quality " .. craft.outputQuality .. " of " .. recipe.maxQuality, atlas) end
  local output = UI.CraftOutput(craft)
  if output ~= "" and not extrasOnly then
    local item = craft.outputItem
    local icon = item and item.id and type(GetItemIcon) == "function" and GetItemIcon(item.id)
    add(icon or "Interface\\Icons\\INV_Misc_QuestionMark", "",
      "Output: " .. output .. " (" .. UI.Value(craft.outputQuantity) .. " total)")
  end
  if craft.concentrationSpent and craft.concentrationSpent > 0 then
    add("Interface\\Icons\\Spell_Arcane_Arcane01", UI.Number(craft.concentrationSpent),
      "Concentration: " .. craft.concentrationSpent .. " spent")
  end
  if craft.multicraftBonus and craft.multicraftBonus > 0 then
    add("Interface\\Icons\\Trade_Engineering", "+" .. UI.Number(craft.multicraftBonus),
      "Multicraft: produced " .. craft.multicraftBonus .. " additional items")
  end
  if craft.hasIngenuityProc then
    add("Interface\\Icons\\Spell_Holy_MindVision", craft.ingenuityRefund and craft.ingenuityRefund > 0 and
      "+" .. UI.Number(craft.ingenuityRefund) or "", craft.ingenuityRefund and craft.ingenuityRefund > 0 and
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
    add("Interface\\Icons\\INV_Misc_Herb_19", UI.Number(returned), table.concat(lines, "\n"))
  end
  return indicators
end

function UI.ScrollList(parent, x, y, width, height, columns, onOpen, emptyMessage, dark)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetSize(width, height)
  frame:SetPoint("TOPLEFT", x, y)
  if dark then UI.Surface(frame, false) end
  frame.rows, frame.items = {}, {}
  function frame:SetSelection(itemId)
    self.selectedItemId = itemId
    for _, row in ipairs(self.rows) do
      row.selection:SetShown(row.item and row.item.item and row.item.item.id == itemId or false)
    end
  end
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
  scroll:HookScript("OnScrollRangeChanged", function(self, _, range)
    if self.ScrollBar then self.ScrollBar:SetShown((range or 0) > 0) end
  end)
  frame.scroll, frame.child = scroll, child
  frame.empty = UI.Text(frame, 8, -48, width - 40, 30)
  frame.empty:SetText(emptyMessage or "No entries yet")
  frame.empty:Hide()
  frame.finish = UI.Text(child, 8, -8, width - 40, 24)
  frame.finish:SetText("End of results")
  frame.finish:Hide()

  function frame:SetViewportHeight(value)
    if self:GetHeight() == value then return end
    self:SetHeight(value)
    self.scroll:SetHeight(value - 26)
    self.child:SetHeight(math.max(value - 26, #self.items * 30 + (self.finish:IsShown() and 35 or 0)))
    self.scroll:SetVerticalScroll(math.min(self.scroll:GetVerticalScroll(), self.child:GetHeight() - self.scroll:GetHeight()))
  end

  function frame:Repaint()
    self:Append(self.items, true)
  end

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

  function frame:Append(items, repaint)
    for position, item in ipairs(items) do
      local index = repaint and position or #self.items + 1
      if not repaint then self.items[index] = item end
      local row = self.rows[index]
      if not row then
        row = CreateFrame("Button", nil, child)
        row:SetSize(width - 24, 28)
        row:SetPoint("TOPLEFT", 0, -(index - 1) * 30)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.selection = row:CreateTexture(nil, "BACKGROUND")
        row.selection:SetAllPoints(row)
        row.selection:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.selection:SetBlendMode("ADD")
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
            row.activity.extrasOnly = column.extrasOnly
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
            label:SetWordWrap(column.lines == 2)
            label:SetMaxLines(column.lines or 1)
            if column.lines == 2 then label:SetHeight(28); label:ClearAllPoints(); label:SetPoint("TOPLEFT", left + padding, 0) end
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
              GameTooltip:AddLine(column.title .. ": " .. tostring((column.exact or column.value)(self.item)), 1, 1, 1, true)
            end
          end
          if self.activity then
            for _, indicator in ipairs(UI.Activity(self.item, self.activity.extrasOnly)) do
              GameTooltip:AddLine(indicator.tooltip, 1, 1, 1)
            end
          end
          if self.item.timestamp then GameTooltip:AddLine("Crafted: " .. UI.DateTime(self.item.timestamp, true), 1, 1, 1) end
          GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.rows[index] = row
      end
      row.item = item
      row.selection:SetShown(item.item and item.item.id == self.selectedItemId or false)
      for _, cell in ipairs(row.widgets) do cell.column.update(cell.widget, item) end
      for _, cell in ipairs(row.cells) do
        local text = cell.column.value(item)
        cell.label:SetText(cell.column.lines == 2 and text or
          UI.Elide(text, math.max(3, math.floor((cell.column.width - (cell.icon and 30 or 9)) / 6))))
        if cell.icon then
          cell.icon:SetTexture(cell.column.icon(item) or "Interface\\Icons\\INV_Misc_QuestionMark")
        end
        local color = UI.ReadableColor(cell.column.color and cell.column.color(item), frame)
        if color then cell.label:SetTextColor(color.r, color.g, color.b)
        elseif UI.IsParchment(frame) then cell.label:SetTextColor(unpack(UI.ink))
        else cell.label:SetTextColor(1, 1, 1) end
      end
      if row.activity then
        for _, indicator in ipairs(row.indicators or {}) do indicator:Hide() end
        row.indicators = row.indicators or {}
        local left = 0
        local indicators = UI.Activity(item, row.activity.extrasOnly)
        for indicatorIndex, indicator in ipairs(indicators) do
          local indicatorWidth = 20
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
          button.label:SetText("")
          button:Show()
          left = left + indicatorWidth
        end
      end
      row:Show()
    end
    if not repaint then
      self.empty:SetShown(#self.items == 0)
      self.child:SetHeight(math.max(self.scroll:GetHeight(), #self.items * 30))
    end
  end
  scroll:HookScript("OnVerticalScroll", function(self)
    if frame.onNearEnd and self:GetVerticalScroll() + self:GetHeight() >= child:GetHeight() - 100 then
      frame.onNearEnd()
    end
  end)
  frame:Reset()
  return frame
end

function UI.Chart(parent, x, y, width, quantities)
  local chart = CreateFrame("Frame", nil, parent)
  chart:SetSize(width, 168)
  chart:SetPoint("TOPLEFT", x, y)
  chart.title = UI.Text(chart, 14, -10, width - 170, 22, "GameFontNormal")
  chart.title:SetText(quantities and "Reagent use" or "Craft activity")
  if quantities then chart.title:SetWidth(width - 28) end
  chart.total = UI.Text(chart, width - 152, -10, 136, 22, "GameFontHighlightSmall")
  chart.total:SetJustifyH("RIGHT")
  chart.plot = CreateFrame("Frame", nil, chart)
  chart.plot:SetSize(width - 64, 100)
  chart.plot:SetPoint("TOPLEFT", 46, -36)
  chart.start = UI.Text(chart, 46, -140, 100, 20)
  chart.finish = UI.Text(chart, width - 126, -140, 110, 20)
  chart.finish:SetJustifyH("RIGHT")
  chart.empty = UI.Text(chart, 16, -80, width - 32, 24)
  chart.empty:SetText(quantities and "No reagent quantities for this period" or "No crafts in this period")
  chart.empty:SetJustifyH("CENTER")
  chart.bars, chart.axisLabels, chart.dateLabels, chart.gridLines = {}, {}, {}, {}
  for index = 0, 2 do
    local line = chart.plot:CreateTexture(nil, "BACKGROUND")
    line:SetColorTexture(.35, .27, .14, .25)
    line:SetPoint("BOTTOMLEFT", 0, index * 47); line:SetSize(width - 64, 1)
    chart.gridLines[index + 1] = line
    local label = UI.Text(chart, 0, -130 + index * 47, 38, 16)
    label:SetJustifyH("RIGHT")
    chart.axisLabels[index + 1] = label
  end
  for index = 1, 2 do
    local label = UI.Text(chart, 46 + (width - 64) * index / 3 - 40, -140, 80, 20)
    label:SetJustifyH("CENTER")
    chart.dateLabels[index] = label
  end

  function chart:Layout(newHeight)
    self:SetHeight(newHeight); self.plot:SetHeight(newHeight - 68)
    self.empty:ClearAllPoints(); self.empty:SetPoint("TOPLEFT", 16, -newHeight / 2)
    for index, label in ipairs(self.axisLabels) do
      label:ClearAllPoints(); label:SetPoint("TOPLEFT", 0, -newHeight + 38 + (index - 1) * (newHeight - 74) / 2)
      self.gridLines[index]:ClearAllPoints()
      self.gridLines[index]:SetPoint("BOTTOMLEFT", 0, (index - 1) * (newHeight - 74) / 2)
    end
    self.start:ClearAllPoints(); self.start:SetPoint("TOPLEFT", 46, -newHeight + 28)
    self.finish:ClearAllPoints(); self.finish:SetPoint("TOPLEFT", width - 126, -newHeight + 28)
    for index, label in ipairs(self.dateLabels) do
      label:ClearAllPoints(); label:SetPoint("TOPLEFT", 46 + (width - 64) * index / 3 - 40, -newHeight + 28)
    end
  end

  function chart:Render(series, from, to, bucketSeconds)
    bucketSeconds = bucketSeconds or 86400
    bucketSeconds = math.max(bucketSeconds, math.ceil((to - from) / 86400 / 60) * 86400)
    local daily, returned, total, peak = {}, {}, 0, 0
    for _, row in ipairs(series or {}) do
      local bucket = from + math.floor((row.bucketStart - from) / bucketSeconds) * bucketSeconds
      local value = quantities and row.allocatedQuantity or (not quantities and row.craftCount or nil)
      if value ~= nil then daily[bucket] = (daily[bucket] or 0) + value; total = total + value end
      if quantities and row.returnedQuantity ~= nil then
        returned[bucket] = (returned[bucket] or 0) + row.returnedQuantity
        total = total + row.returnedQuantity
      end
    end
    local days = math.max(1, math.ceil((to - from) / bucketSeconds))
    for day = 0, days - 1 do
      peak = math.max(peak, daily[from + day * bucketSeconds] or 0, returned[from + day * bucketSeconds] or 0)
    end
    self.total:SetText(quantities and "" or UI.Count(total, "craft"))
    self.plot:SetShown(days > 1 and total > 0)
    self.empty:SetShown(days == 1 or total == 0)
    if days == 1 and total > 0 then
      self.empty:SetText(quantities and ("Used: " .. UI.Number(daily[from]) .. "   Returned: " .. UI.Number(returned[from])) or
        UI.Count(total, "craft") .. " on " .. date("!%d %b", from))
    else self.empty:SetText(quantities and "No reagent quantities for this period" or "No crafts in this period") end
    self.start:SetText(date(width < 400 and "!%d %b" or "!%d %b %Y", from))
    self.finish:SetText(date(width < 400 and "!%d %b" or "!%d %b %Y", to - 86400))
    local maximum = math.max(2, math.ceil(peak / 2) * 2)
    for index, label in ipairs(self.axisLabels) do
      label:SetText(UI.Number((index - 1) * maximum / 2)); label:SetShown(days > 1 and total > 0)
    end
    for index, label in ipairs(self.dateLabels) do
      label:SetText(date("!%d %b", from + math.floor((days - 1) * index / 3) * bucketSeconds))
      label:SetShown(days >= 4 and width >= 400)
    end
    for _, bar in ipairs(self.bars) do bar:Hide(); if bar.returned then bar.returned:Hide() end end
    local barWidth = (width - 64) / days
    local groupWidth = math.min(quantities and 26 or 28, barWidth * .62)
    local groupGap = quantities and math.min(3, groupWidth * .1) or 0
    for day = 0, days - 1 do
      local count = daily[from + day * bucketSeconds] or 0
      local bar = self.bars[day + 1]
      if not bar then
        bar = CreateFrame("Frame", nil, self.plot)
        bar.texture = bar:CreateTexture(nil, "ARTWORK")
        bar.texture:SetAllPoints(bar)
        bar.texture:SetColorTexture(.17, .43, .29, .9)
        if quantities then
          bar.texture:SetColorTexture(.12, .42, .68, .9)
          bar.returned = CreateFrame("Frame", nil, self.plot)
          bar.returned.texture = bar.returned:CreateTexture(nil, "ARTWORK")
          bar.returned.texture:SetAllPoints(bar.returned)
          bar.returned.texture:SetColorTexture(.17, .43, .29, .9)
          bar.returned:EnableMouse(true)
          bar.returned:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(self.tooltip); GameTooltip:Show()
          end)
          bar.returned:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        bar:EnableMouse(true)
        bar:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(self.tooltip); GameTooltip:Show()
        end)
        bar:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.bars[day + 1] = bar
      end
      local groupLeft = day * barWidth + (barWidth - groupWidth) / 2
      local visibleWidth = quantities and (groupWidth - groupGap) / 2 or groupWidth
      bar:SetPoint("BOTTOMLEFT", self.plot, "BOTTOMLEFT", groupLeft, 0)
      bar:SetSize(math.max(.5, visibleWidth), math.max(1, count * (self.plot:GetHeight() - 6) / maximum))
      bar.tooltip = date("!%d %b %Y", from + day * bucketSeconds) .. ": " .. count .. (count == 1 and " craft" or " crafts")
      if quantities then
        local amount = returned[from + day * bucketSeconds]
        bar.tooltip = date("!%d %b %Y", from + day * bucketSeconds) ..
          "\nUsed: " .. UI.Value(daily[from + day * bucketSeconds]) ..
          "\nReturned: " .. UI.Value(amount)
        bar.returned.tooltip = bar.tooltip
        bar.returned:SetPoint("BOTTOMLEFT", self.plot, "BOTTOMLEFT", groupLeft + visibleWidth + groupGap, 0)
        bar.returned:SetSize(math.max(.5, visibleWidth), math.max(1, (amount or 0) * (self.plot:GetHeight() - 6) / maximum))
        bar.returned:SetShown(amount ~= nil and amount > 0)
      end
      if bucketSeconds > 86400 then bar.tooltip = bar.tooltip .. " / " .. (bucketSeconds / 86400) .. " days" end
      bar:SetShown(count > 0)
    end
  end
  return chart
end

function UI.RecipeTable(parent, x, y, width, height, openRecipe)
  local available = width - 24
  local columns = {
    { title = "Recipe", width = available * .22, value = function(row) return UI.Name(row.recipe) end,
      icon = function(row) return UI.RecipeIcon(row.recipe) end },
    { title = "Latest result", width = available * .22, value = function(row) return UI.Name(row.result and row.result.outputItem) end,
      create = function(owner, left) return UI.ItemCell(owner, left, available * .22) end,
      update = function(cell, row)
        local craft = row.result
        cell:Update(craft and craft.outputItem, craft and UI.QualityAtlas(row.recipe.id, craft.outputQuality, row.recipe.maxQuality))
      end },
    { title = "Crafts", width = available * .08, value = function(row) return UI.Number(row.craftCount) end,
      exact = function(row) return UI.Value(row.craftCount) end },
    { title = "Items", width = available * .10, value = function(row)
      local totals = row.totals
      return totals and UI.Amount(totals.outputQuantity, totals.outputQuantityObservedCount == totals.craftCount) or "-"
    end, exact = function(row)
      local totals = row.totals
      return UI.AmountTooltip(totals and totals.outputQuantity, totals and totals.outputQuantityObservedCount == totals.craftCount)
    end },
  }
    for _, entry in ipairs({ { "Multicraft", "multicraftProcCount" },
      { "Resourcefulness", "resourcefulnessProcCount" }, { "Ingenuity", "ingenuityProcCount" } }) do
    local title, metric = entry[1], entry[2]
    columns[#columns + 1] = { title = title, width = available * (.38 / 3),
      value = function(row)
        if metric ~= "resourcefulnessProcCount" and row.totals and row.totals[metric] == 0 and
            row.totals[metric .. "ObservedCount"] == row.totals.craftCount then return "" end
        return UI.ProcValue(row.totals, metric)
      end,
      exact = function(row) return UI.ProcTooltip(row.totals, metric) end }
  end
  local list = UI.ScrollList(parent, x, y, width, height, columns,
    function(row) if row.recipe then openRecipe(row.recipe) end end, "No recipes in this period")
  list.worker = CreateFrame("Frame", nil, list)
  function list:Enrich(filter)
    local index = 1
    self.worker:SetScript("OnUpdate", function(worker)
      local row = list.items[index]
      if not row then worker:SetScript("OnUpdate", nil); return end
      index = index + 1
      if row.recipe and not row.enriched then
        row.enriched = true
        local outcome = ArtisanLogbookAPI.GetRecipeOutcomes(row.recipe.id,
          { time = filter.time, characters = filter.characters }, { buckets = 1 })
        row.totals = outcome and outcome.totals
        local result = ArtisanLogbookAPI.GetCrafts({ recipes = { row.recipe.id },
          time = filter.time, characters = filter.characters }, { limit = 1 })
        row.result = result and result.crafts[1]
        list:Repaint()
      end
    end)
  end
  function list:Render(rows, filter)
    UI.LazyList(self, function(cursor)
      local offset, page = cursor or 0, {}
      for index = offset + 1, math.min(offset + 40, #rows) do page[#page + 1] = rows[index] end
      self:Enrich(filter)
      return page, offset + 40 < #rows and offset + 40 or nil
    end)
    self:Reload()
  end
  return list
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
    description = description .. reagent.allocatedQuantity .. " used"
    if reagent.returnedQuantity ~= nil then
      description = description .. ", " .. reagent.returnedQuantity .. " returned"
    end
  elseif reagent.returnedQuantity ~= nil then
    description = description .. reagent.returnedQuantity .. " returned (quantity used unavailable)"
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
  { label = "60 days", value = 60 },
  { label = "90 days", value = 90 },
  { label = "365 days", value = 365 },
}
