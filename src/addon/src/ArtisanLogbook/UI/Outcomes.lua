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

function UI.CraftHasNonTrivialReturn(craft)
  if craft.resourcefulnessComplete == true then return false end
  for _, reagent in ipairs(craft.reagents or {}) do
    local itemId = reagent.item and reagent.item.id
    if itemId and reagent.returnedQuantity and reagent.returnedQuantity > 0 and not UI.IsTrivial(itemId) then
      return true
    end
  end
  return false
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

local function outcomeText(count, observed, crafts, noun, partialLabel)
  count = count or 0
  noun = count == 1 and noun or noun .. "s"
  if crafts > 0 and observed == crafts then
    return string.format("%.1f%% | %d %s", 100 * count / crafts, count, noun)
  end
  return count > 0 and string.format(partialLabel .. " %d %s", count, noun) or "-"
end

function UI.CompactOutcome(totals, proc, amount, denominator, amountLabel, shareLabel)
  local observed, count = totals[proc .. "ObservedCount"], totals[proc] or 0
  local procText
  if observed == totals.craftCount and totals.craftCount > 0 then
    procText = string.format("%.1f%% | %d procs", 100 * count / totals.craftCount, count)
  else
    procText = count > 0 and string.format("Proc recorded for %d %s", count, count == 1 and "craft" or "crafts") or "-"
  end
  local lines = { procText }
  local amountText = amountLabel .. ": " .. (totals[amount] ~= nil and tostring(totals[amount]) or "-")
  local share = UI.MeasuredShare(totals, amount, denominator)
  if share ~= "Unknown" then amountText = amountText .. " | " .. share .. " " .. shareLabel end
  lines[#lines + 1] = amountText
  if observed < totals.craftCount or totals[amount .. "ObservedCount"] < totals.craftCount or
      totals[denominator .. "ObservedCount"] < totals.craftCount then
    lines[#lines + 1] = "|cffffcc66Some crafts have no details|r"
  end
  return table.concat(lines, "\n")
end

function UI.ResourcefulnessSummary(totals, nonTrivial)
  local crafts = totals.craftCount
  local observed = totals.resourcefulnessProcCountObservedCount
  local positive = totals.resourcefulnessProcCount or 0
  local complete = totals.resourcefulnessCompleteProcCountObservedCount
  local result = { complete = "" }
  if crafts == 0 then
    return { any = "No crafts", complete = "", nonTrivial = "-" }
  end
  if observed == crafts then
    result.any = outcomeText(positive, observed, crafts, "craft")
  else
    local missing = crafts - observed
    result.any = positive > 0 and string.format("Returns recorded for %d %s", positive,
      positive == 1 and "craft" or "crafts") or "-"
    result.complete = string.format("|cffffcc66Return results missing for %d %s|r", missing,
      missing == 1 and "craft" or "crafts")
  end
  if nonTrivial == nil then
    result.nonTrivial = "Calculating..."
  elseif complete == crafts and crafts > 0 then
    result.nonTrivial = outcomeText(nonTrivial, complete, crafts, "craft")
  elseif nonTrivial > 0 then
    result.nonTrivial = string.format("Non-trivial returns recorded for %d %s", nonTrivial,
      nonTrivial == 1 and "craft" or "crafts")
  else
    result.nonTrivial = "-"
  end
  if complete < crafts and complete > 0 then
    local missing = crafts - complete
    result.complete = string.format("|cffffcc66Return details missing for %d %s|r", missing,
      missing == 1 and "craft" or "crafts")
  end
  return result
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
  pane:SetSize(width, 654)
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
  for position, entry in ipairs({ { "Crafts", 1 }, { "Multicraft", 2 }, { "Ingenuity", 4 } }) do
    local x = (position - 1) * width / 3
    UI.Text(pane, x, -88, width / 3 - 16, 22, "GameFontNormal"):SetText(entry[1])
    stats[entry[2]] = UI.Text(pane, x, -112, width / 3 - 16, 76)
  end
  pane.stats = stats
  local chart = UI.Chart(pane, 0, -196, width)
  pane.chart = chart
  UI.Text(pane, 0, -374, width, 22, "GameFontNormal"):SetText("Resourcefulness")
  pane.resourcefulness = {}
  for position, entry in ipairs({ { "Reagents saved", "any" }, { "Non-trivial savings", "nonTrivial" } }) do
    local x = (position - 1) * width / 2
    UI.Text(pane, x, -402, width / 2 - 16, 20, "GameFontNormalSmall"):SetText(entry[1])
    pane.resourcefulness[entry[2]] = UI.Text(pane, x, -426, width / 2 - 16, 48)
  end
  pane.resourcefulness.complete = UI.Text(pane, 0, -480, width, 24)
  stats[3] = pane.resourcefulness.any
  UI.Text(pane, 0, -518, width - 230, 22, "GameFontNormal"):SetText("Returned materials")
  local materialRows, cursors, currentCursor, nextCursor = {}, {}, nil, nil
  pane.materialRows = materialRows
  local materialStatus = UI.Text(pane, 0, -552, width, 26)
  local function loadMaterials(cursor)
    local page, reason = api.GetRecipeReturnedReagents(recipeId, pane:Filter(), { limit = 3, cursor = cursor })
    nextCursor = page and page.nextCursor
    for position, row in ipairs(materialRows) do
      local returned = page and page.returns[position]
      row.item = returned and returned.item
      row.returnedQuantity = returned and returned.returnedQuantity
      row:SetShown(returned ~= nil)
      row.check:SetItem(row.item and row.item.id)
      if returned then
        row.label:SetText(UI.Elide(UI.Name(row.item), math.max(8, math.floor(row.label:GetWidth() / 7))))
        row.identity:SetText("#" .. row.item.id)
        row.quantity:SetText(UI.Elide(tostring(returned.returnedQuantity), 10))
        local icon = type(GetItemIcon) == "function" and GetItemIcon(row.item.id)
        row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local qualityInfo
        if C_TradeSkillUI and type(C_TradeSkillUI.GetItemReagentQualityInfo) == "function" then
          local ok, info = pcall(C_TradeSkillUI.GetItemReagentQualityInfo, row.item.id)
          if ok then qualityInfo = info end
        end
        row.quality:SetShown(qualityInfo ~= nil and qualityInfo.icon ~= nil)
        if qualityInfo and qualityInfo.icon then row.quality:SetAtlas(qualityInfo.icon) end
      end
    end
    materialStatus:SetText(not page and (reason or "Unavailable") or
      (#page.returns == 0 and "No saved reagents to show" or ""))
    pane.previous:SetEnabled(#cursors > 0); pane.next:SetEnabled(nextCursor ~= nil)
  end
  pane.previous = UI.Button(pane, "Previous", width - 190, -514, 85, function()
    currentCursor = table.remove(cursors)
    if currentCursor == false then currentCursor = nil end
    loadMaterials(currentCursor)
  end)
  pane.next = UI.Button(pane, "Next", width - 95, -514, 85, function()
    if not nextCursor then return end
    cursors[#cursors + 1] = currentCursor or false
    currentCursor = nextCursor
    loadMaterials(currentCursor)
  end)
  local nameWidth = math.min(300, width - 250)
  UI.Text(pane, nameWidth + 44, -522, 84, 18, "GameFontNormalSmall"):SetText("Total returned")
  for position = 1, 3 do
    local row = CreateFrame("Frame", nil, pane)
    row:SetSize(nameWidth + 240, 32)
    row:SetPoint("TOPLEFT", 0, -548 - (position - 1) * 34)
    row:EnableMouse(true)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(28, 28); row.icon:SetPoint("TOPLEFT", 0, 0)
    row.quality = row:CreateTexture(nil, "OVERLAY")
    row.quality:SetSize(16, 16); row.quality:SetPoint("TOPLEFT", 14, -14)
    row.label = UI.Text(row, 36, 0, nameWidth, 16)
    row.identity = UI.Text(row, 36, -16, nameWidth, 14)
    row.identity:SetTextColor(0.65, 0.65, 0.65)
    row.quantity = UI.Text(row, nameWidth + 44, -6, 84, 22)
    row.check = UI.TrivialCheckbox(row, nameWidth + 144, -2, function() pane:Refresh(true) end)
    row:SetScript("OnEnter", function(self)
      if not self.item then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if type(GameTooltip.SetItemByID) == "function" then GameTooltip:SetItemByID(self.item.id)
      else GameTooltip:SetText(UI.Name(self.item)) end
      GameTooltip:AddLine("Item ID: " .. self.item.id)
      GameTooltip:AddLine("Total returned: " .. self.returnedQuantity)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    materialRows[position] = row
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

  function pane:Refresh(keepMaterialPage)
    self:SetScript("OnUpdate", nil)
    local filter = self:Filter()
    local result, reason = api.GetRecipeOutcomes(recipeId, filter, { buckets = 60 })
    status:SetText(reason or "")
    if not result then
      for _, label in ipairs(stats) do label:SetText("Unavailable") end
      for _, label in pairs(self.resourcefulness) do label:SetText("Unavailable") end
      for _, row in ipairs(materialRows) do row.item = nil; row:Hide() end
      self.previous:SetEnabled(false); self.next:SetEnabled(false)
      chart:Render({}, 0, 86400, 86400)
      return
    end
    local totals = result.totals
    stats[1]:SetText(tostring(totals.craftCount))
    stats[2]:SetText(UI.CompactOutcome(totals, "multicraftProcCount", "multicraftBonus", "outputQuantity", "Bonus", "of output"))
    stats[4]:SetText(UI.CompactOutcome(totals, "ingenuityProcCount", "ingenuityRefund", "concentrationSpent", "Refund", "of spent"))
    local function showReturns(nonTrivial)
      for key, text in pairs(UI.ResourcefulnessSummary(totals, nonTrivial)) do
        self.resourcefulness[key]:SetText(text)
      end
    end
    showReturns(nil)
    local craftFilter = { recipes = { recipeId } }
    for key, value in pairs(filter) do craftFilter[key] = value end
    local cursor, craftCursor, nonTrivial = nil, nil, 0
    local function nextCrafts()
      local page, pageReason = api.GetCrafts(craftFilter, { limit = 100, cursor = craftCursor })
      if not page then
        self.resourcefulness.nonTrivial:SetText("Unavailable"); status:SetText(pageReason or "Unavailable")
        self:SetScript("OnUpdate", nil); return
      end
      for _, craft in ipairs(page.crafts) do
        if UI.CraftHasNonTrivialReturn(craft) then nonTrivial = nonTrivial + 1 end
      end
      craftCursor = page.nextCursor
      if not craftCursor then
        showReturns(nonTrivial)
        self:SetScript("OnUpdate", nil)
      else self:SetScript("OnUpdate", nextCrafts) end
    end
    local function nextSets()
      local page, pageReason = api.GetRecipeReturnSets(recipeId, filter, { limit = 100, cursor = cursor })
      if not page then
        self.resourcefulness.nonTrivial:SetText("Unavailable"); status:SetText(pageReason or "Unavailable")
        self:SetScript("OnUpdate", nil); return
      end
      nonTrivial = nonTrivial + UI.NonTrivialCount(page.returns)
      cursor = page.nextCursor
      if not cursor then
        craftCursor = nil
        self:SetScript("OnUpdate", nextCrafts)
      else self:SetScript("OnUpdate", nextSets) end
    end
    nextSets()
    local start, finish = result.from, result.to
    if not start then start, finish = UI.Range(GetServerTime(), 1) end
    chart:Render(result.series, start, finish, result.bucketSeconds)
    if not keepMaterialPage then cursors, currentCursor = {}, nil end
    loadMaterials(currentCursor)
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