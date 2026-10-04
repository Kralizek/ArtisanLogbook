local _, addon = ...
local UI = addon.UI

local function trivialItems()
  if type(ArtisanLogbookUISettings) ~= "table" then ArtisanLogbookUISettings = {} end
  if type(ArtisanLogbookUISettings.trivialReagents) ~= "table" then
    ArtisanLogbookUISettings.trivialReagents = {}
  end
  return ArtisanLogbookUISettings.trivialReagents
end

function UI.IsTrivial(itemId)
  return trivialItems()[itemId] == true
end

function UI.SetTrivial(itemId, trivial)
  if type(itemId) ~= "number" or itemId < 1 or itemId >= math.huge or itemId % 1 ~= 0 or
      type(trivial) ~= "boolean" then return nil end
  trivialItems()[itemId] = trivial and true or nil
  return true
end

function UI.NonTrivialCount(sets)
  local count = 0
  for _, returned in ipairs(sets) do
    for _, itemId in ipairs(returned.itemIds) do
      if not UI.IsTrivial(itemId) then count = count + returned.craftCount; break end
    end
  end
  return count
end

function UI.ProcRate(count, observed)
  if not observed or observed == 0 then return "Unknown\n0 observed crafts" end
  return string.format("%.1f%%\n%d / %d observed crafts", 100 * count / observed, count, observed)
end

function UI.MeasuredShare(totals, numerator, denominator)
  if totals.craftCount == 0 or totals[numerator .. "ObservedCount"] ~= totals.craftCount or
      totals[denominator .. "ObservedCount"] ~= totals.craftCount or
      not totals[denominator] or totals[denominator] <= 0 then return "Unknown" end
  return string.format("%.1f%%", 100 * totals[numerator] / totals[denominator])
end

function UI.TrivialCheckbox(parent, x, y, onChange)
  local checkbox = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  checkbox:SetSize(24, 24)
  checkbox:SetPoint("TOPLEFT", x, y)
  UI.Text(checkbox, 26, -5, 70, 18):SetText("Trivial")
  checkbox:SetScript("OnClick", function(self)
    if self.itemId then
      UI.SetTrivial(self.itemId, self:GetChecked() == true)
      onChange()
    end
  end)
  checkbox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Trivial reagent #" .. tostring(self.itemId or ""))
    GameTooltip:Show()
  end)
  checkbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
  function checkbox:SetItem(itemId)
    self.itemId = itemId
    self:SetChecked(itemId ~= nil and UI.IsTrivial(itemId))
    self:SetShown(itemId ~= nil)
  end
  return checkbox
end

function UI.RecipeOutcomes(parent, width, onFilterChanged)
  local pane = CreateFrame("Frame", nil, parent)
  pane:SetSize(width, 570)
  pane:SetPoint("TOPLEFT", 0, -62)
  local api = ArtisanLogbookAPI
  local days, character, recipeId = false, false, nil
  local fromInput, toInput, customFrom, customTo
  local periodChoices = { { label = "All time", value = false } }
  for _, choice in ipairs(UI.ranges) do periodChoices[#periodChoices + 1] = choice end
  periodChoices[#periodChoices + 1] = { label = "Custom (UTC)", value = "custom" }
  local function refresh()
    if recipeId then pane:Refresh(); onFilterChanged() end
  end
  local period = UI.Selector(pane, 0, 0, 125, periodChoices, function(value)
    days = value
    fromInput:SetShown(days == "custom"); toInput:SetShown(days == "custom")
    refresh()
  end, "Period")
  local characters = UI.Selector(pane, 165, 0, 185, {}, function(value)
    character = value; refresh()
  end, "Character")
  local status = UI.Text(pane, 250, -60, width - 250, 20)
  local function dateInput(x, label)
    local input = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    input:SetSize(105, 24)
    input:SetPoint("TOPLEFT", x, -56)
    input:SetAutoFocus(false)
    input:SetMaxLetters(10)
    input:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(label); GameTooltip:Show()
    end)
    input:SetScript("OnLeave", function() GameTooltip:Hide() end)
    input:Hide()
    return input
  end
  fromInput, toInput = dateInput(0, "From UTC (YYYY-MM-DD)"), dateInput(125, "Through UTC (YYYY-MM-DD)")
  local from, to = UI.Range(GetServerTime(), 30)
  customFrom, customTo = from, to
  fromInput:SetText(date("!%Y-%m-%d", from)); toInput:SetText(date("!%Y-%m-%d", to - 86400))
  local function applyDates(self)
    self:ClearFocus()
    local start = UI.ParseUTCDate(fromInput:GetText())
    local finish = UI.ParseUTCDate(toInput:GetText())
    if not start or not finish or start > finish then status:SetText("Invalid UTC date range"); return end
    customFrom, customTo = start, finish + 86400
    refresh()
  end
  fromInput:SetScript("OnEnterPressed", applyDates)
  toInput:SetScript("OnEnterPressed", applyDates)
  local stats = {}
  for position, title in ipairs({ "Crafts", "Multicraft", "Resourcefulness", "Ingenuity" }) do
    local x = (position - 1) * width / 4
    UI.Text(pane, x, -88, width / 4 - 12, 22, "GameFontNormal"):SetText(title)
    stats[position] = UI.Text(pane, x, -112, width / 4 - 12, 136)
  end
  pane.stats = stats
  local chart = UI.Chart(pane, 0, -252, width)
  pane.chart = chart
  UI.Text(pane, 0, -428, width - 230, 22, "GameFontNormal"):SetText("Returned materials")
  local materialRows, cursors, currentCursor, nextCursor = {}, {}, nil, nil
  local function loadMaterials(cursor)
    local page, reason = api.GetRecipeReturnedReagents(recipeId, pane:Filter(), { limit = 3, cursor = cursor })
    nextCursor = page and page.nextCursor
    for position, row in ipairs(materialRows) do
      local returned = page and page.returns[position]
      row.label:SetText(returned and UI.Elide(UI.Name(returned.item) .. "  +" .. returned.returnedQuantity,
        math.max(8, math.floor((width - 125) / 7))) or "")
      row.check:SetItem(returned and returned.item.id)
    end
    if not page then materialRows[1].label:SetText(reason or "Unavailable")
    elseif #page.returns == 0 then materialRows[1].label:SetText("No observed returned materials") end
    pane.previous:SetEnabled(#cursors > 0); pane.next:SetEnabled(nextCursor ~= nil)
  end
  pane.previous = UI.Button(pane, "Previous", width - 190, -424, 85, function()
    currentCursor = table.remove(cursors)
    if currentCursor == false then currentCursor = nil end
    loadMaterials(currentCursor)
  end)
  pane.next = UI.Button(pane, "Next", width - 95, -424, 85, function()
    if not nextCursor then return end
    cursors[#cursors + 1] = currentCursor or false
    currentCursor = nextCursor
    loadMaterials(currentCursor)
  end)
  for position = 1, 3 do
    local y = -456 - (position - 1) * 30
    materialRows[position] = {
      label = UI.Text(pane, 0, y, width - 125, 26),
      check = UI.TrivialCheckbox(pane, width - 105, y + 4, refresh),
    }
  end

  function pane:Filter()
    local filter = {}
    if character then filter.characters = { character } end
    if days == "custom" then filter.time = { from = customFrom, to = customTo }
    elseif days then
      local start, finish = UI.Range(GetServerTime(), days)
      filter.time = { from = start, to = finish }
    end
    return filter
  end

  function pane:Refresh()
    self:SetScript("OnUpdate", nil)
    local filter = self:Filter()
    local result, reason = api.GetRecipeOutcomes(recipeId, filter, { buckets = 60 })
    status:SetText(reason or "")
    if not result then
      for _, label in ipairs(stats) do label:SetText("Unavailable") end
      return
    end
    local totals = result.totals
    local function coverage(metric)
      return string.format("Coverage: %d / %d", totals[metric .. "ObservedCount"], totals.craftCount)
    end
    stats[1]:SetText(tostring(totals.craftCount))
    stats[2]:SetText(UI.ProcRate(totals.multicraftProcCount, totals.multicraftProcCountObservedCount) ..
      "\n" .. coverage("multicraftProcCount") .. "\nBonus: " .. UI.Value(totals.multicraftBonus) ..
      "\n" .. coverage("multicraftBonus") .. "\nOutput: " .. UI.Value(totals.outputQuantity) ..
      "\n" .. coverage("outputQuantity") .. "\nOutput share: " .. UI.MeasuredShare(totals, "multicraftBonus", "outputQuantity"))
    stats[4]:SetText(UI.ProcRate(totals.ingenuityProcCount, totals.ingenuityProcCountObservedCount) ..
      "\n" .. coverage("ingenuityProcCount") .. "\nRefund: " .. UI.Value(totals.ingenuityRefund) ..
      "\n" .. coverage("ingenuityRefund") .. "\nSpent: " .. UI.Value(totals.concentrationSpent) ..
      "\n" .. coverage("concentrationSpent") .. "\nRefund / spent: " .. UI.MeasuredShare(totals, "ingenuityRefund", "concentrationSpent"))
    local base = "Any: " .. UI.ProcRate(totals.resourcefulnessProcCount, totals.resourcefulnessProcCountObservedCount) ..
      "\n" .. coverage("resourcefulnessProcCount") .. "\nNon-trivial: "
    stats[3]:SetText(base .. "Calculating...")
    local cursor, nonTrivial = nil, 0
    local function nextSets()
      local page, pageReason = api.GetRecipeReturnSets(recipeId, filter, { limit = 100, cursor = cursor })
      if not page then
        stats[3]:SetText(base .. "Unavailable"); status:SetText(pageReason or "Unavailable")
        self:SetScript("OnUpdate", nil); return
      end
      nonTrivial = nonTrivial + UI.NonTrivialCount(page.returns)
      cursor = page.nextCursor
      if not cursor then
        stats[3]:SetText(base .. UI.ProcRate(nonTrivial, totals.resourcefulnessCompleteProcCountObservedCount))
        self:SetScript("OnUpdate", nil)
      else self:SetScript("OnUpdate", nextSets) end
    end
    nextSets()
    local start, finish = result.from, result.to
    if not start then start, finish = UI.Range(GetServerTime(), 1) end
    chart:Render(result.series, start, finish, result.bucketSeconds)
    cursors, currentCursor = {}, nil
    loadMaterials(nil)
  end

  function pane:Open(id)
    recipeId = id
    local available = { { label = "All", value = false } }
    for _, entry in ipairs(api.GetCharacters() or {}) do
      available[#available + 1] = { label = UI.Name(entry), value = entry.key, classFile = entry.classFile }
    end
    characters:Update(available, character)
    period:Update(periodChoices, days)
    self:Refresh()
  end
  return pane
end

function UI.ParseUTCDate(text)
  local year, month, day = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if not year or year < 1970 or year > 9999 or month < 1 or month > 12 or day < 1 or day > 31 then return nil end
  local guess = time({ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 })
  if not guess then return nil end
  local utcDay = math.floor(guess / 86400) * 86400
  for offset = -1, 1 do
    local candidate = utcDay + offset * 86400
    if date("!%Y-%m-%d", candidate) == text then return candidate end
  end
end