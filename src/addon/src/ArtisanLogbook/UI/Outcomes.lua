local _, addon = ...
local UI = addon.UI
local trivialCallbacks = {}

function UI.RegisterTrivialCallback(callback)
  trivialCallbacks[#trivialCallbacks + 1] = callback
end

function UI.TrivialItemIds()
  local ids = {}
  if type(ArtisanLogbookUISettings) == "table" and type(ArtisanLogbookUISettings.trivialReagents) == "table" then
    for id, selected in pairs(ArtisanLogbookUISettings.trivialReagents) do
      if selected == true and type(id) == "number" and id > 0 and id < math.huge and id % 1 == 0 then
        ids[#ids + 1] = id
      end
    end
  end
  table.sort(ids)
  return ids
end

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
  local changed = UI.IsTrivial(itemId) ~= trivial
  trivialItems()[itemId] = trivial and true or nil
  if changed then
    for _, callback in ipairs(trivialCallbacks) do callback(itemId, trivial) end
  end
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
  if not observed or observed == 0 then return "-" end
  return UI.Percent(count, observed) .. "\n" .. UI.Number(count) .. " / " .. UI.Number(observed) .. " crafts"
end

function UI.MeasuredShare(totals, numerator, denominator)
  if totals.craftCount == 0 or totals[numerator .. "ObservedCount"] ~= totals.craftCount or
      totals[denominator .. "ObservedCount"] ~= totals.craftCount or
      not totals[denominator] or totals[denominator] <= 0 then return "Unknown" end
  return UI.Percent(totals[numerator], totals[denominator])
end

local function outcomeText(count, observed, crafts, noun, partialLabel)
  count = count or 0
  noun = count == 1 and noun or noun .. "s"
  if crafts > 0 and observed == crafts then
    return UI.Percent(count, crafts) .. " | " .. UI.Number(count) .. " " .. noun
  end
  return count > 0 and string.format(partialLabel .. " %d %s", count, noun) or "-"
end

function UI.CompactOutcome(totals, proc, amount, denominator, amountLabel, shareLabel)
  local observed, count = totals[proc .. "ObservedCount"], totals[proc] or 0
  local procText
  if observed == totals.craftCount and totals.craftCount > 0 then
    procText = UI.Percent(count, totals.craftCount) .. " | " .. UI.Number(count) .. " procs"
  else
    procText = count > 0 and "At least " .. UI.Count(count, "proc") or "-"
  end
  local lines = { procText }
  local amountText = amountLabel .. ": " .. UI.Amount(totals[amount .. "ObservedCount"] > 0 and totals[amount] or nil,
    totals[amount .. "ObservedCount"] == totals.craftCount)
  local share = UI.MeasuredShare(totals, amount, denominator)
  if share ~= "Unknown" then amountText = amountText .. " | " .. share .. " " .. shareLabel end
  lines[#lines + 1] = amountText
  if observed < totals.craftCount then
    local missing = totals.craftCount - observed
    lines[#lines + 1] = "Rate unavailable: " .. UI.Count(missing, "craft") .. (missing == 1 and " has" or " have") .. " no proc result."
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
    result.any = positive > 0 and "At least " .. UI.Count(positive, "craft") .. " returned reagents" or "-"
    result.complete = "Resourcefulness rate unavailable: " .. UI.Count(missing, "craft") ..
      (missing == 1 and " has" or " have") .. " no return outcome."
  end
  if nonTrivial == nil then
    result.nonTrivial = "Calculating..."
  elseif complete == crafts and crafts > 0 then
    result.nonTrivial = outcomeText(nonTrivial, complete, crafts, "craft")
  elseif nonTrivial > 0 then
    result.nonTrivial = "Savings in at least " .. UI.Count(nonTrivial, "craft")
  else
    result.nonTrivial = "-"
  end
  if complete < crafts and observed == crafts then
    local missing = crafts - complete
    result.complete = "Savings rate unavailable: " .. UI.Count(missing, "craft") ..
      (missing == 1 and " has" or " have") .. " no ingredient breakdown."
  end
  return result
end

function UI.TrivialCheckbox(parent, x, y, onChange)
  local checkbox = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  checkbox:SetSize(24, 24)
  checkbox:SetPoint("TOPLEFT", x, y)
  UI.Text(checkbox, 26, -5, 218, 32):SetText("Ignore in savings statistics")
  checkbox:SetScript("OnClick", function(self)
    if self.itemId then
      UI.SetTrivial(self.itemId, self:GetChecked() == true)
      onChange()
    end
  end)
  checkbox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Ignore in savings statistics")
    GameTooltip:AddLine("Exclude this reagent when counting crafts with useful returns. Quantities and the overall Resourcefulness rate stay unchanged.", 1, 1, 1, true)
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

function UI.RecipeOutcomes(parent, width, onFilterChanged, height, openReagent)
  local pane = CreateFrame("Frame", nil, parent)
  height = height or 620
  pane:SetSize(width, height)
  pane:SetPoint("TOPLEFT", 0, -62)
  pane.calculationGeneration = 0
  local api = ArtisanLogbookAPI
  local state, recipeId = { days = false, character = false }, nil
  local function refresh()
    if recipeId then pane:Refresh(); onFilterChanged() end
  end
  local filters = UI.FilterBar(pane, width)
  local period = filters:Period(state, refresh, true)
  local characters = filters:Select("Character", {}, function(value) state.character = value; refresh() end)
  pane.filters, pane.period = filters, period
  local status = UI.Text(pane, 370, -16, width - 370, 24)
  local summary = CreateFrame("Frame", nil, pane)
  summary:SetSize(width, 142); summary:SetPoint("TOPLEFT", 0, -52)
  pane.tiles = {}
  for index, entry in ipairs({ { "Crafts", "Trade_BlackSmithing" }, { "Total output", "INV_Misc_Bag_10" },
      { "Concentration spent", "Spell_Arcane_Arcane01" }, { "Multicraft bonus", "Trade_Engineering" },
      { "Reagents returned", "INV_Misc_Herb_19" }, { "Ingenuity refund", "Spell_Holy_MindVision" } }) do
    pane.tiles[index] = UI.Stat(summary, entry[1], "Interface\\Icons\\" .. entry[2],
      ((index - 1) % 3) * width / 3, -math.floor((index - 1) / 3) * 70, width / 3 - 10)
  end
  local tabs = UI.TabbedContent(pane, width, height - 202, -202,
    { "Overview", "Statistics", "Craft History", "Reagents" }, function(name)
      pane.activeView = name
      if pane.OnSelect then pane:OnSelect(name) end
    end)
  pane.tabbed, pane.views = tabs, tabs.views
  function pane:SelectView(name) tabs:Select(name) end
  local overview, statistics, materials = pane.views.Overview, pane.views.Statistics, pane.views.Reagents
  local inner = width - 24
  local statisticsContent, statisticsScroll = UI.PageScroll(statistics, inner, height - 253, 288)
  statistics, pane.statisticsScroll = statisticsContent, statisticsScroll
  local chart = UI.Chart(overview, 0, 0, inner)
  pane.chart = chart
  local production = {}
  for index, entry in ipairs({ { "Items / craft", "averageOutput" }, { "Concentration / craft", "averageConcentration" },
      { "Net concentration", "netConcentration" } }) do
    local left = (index - 1) * inner / 3
    UI.Text(statistics, left, 0, inner / 3 - 12, 20, "GameFontNormal"):SetText(entry[1])
    production[entry[2]] = UI.Text(statistics, left, -26, inner / 3 - 12, 28, "GameFontNormalLarge")
  end
  pane.production = production
  local stats = { [1] = pane.tiles[1].value }
  for index, entry in ipairs({ { "Multicraft", 2 }, { "Resourcefulness", 3 }, { "Ingenuity", 4 } }) do
    local left = (index - 1) * inner / 3
    UI.Section(statistics, entry[1], left, -68, inner / 3 - 14)
    stats[entry[2]] = UI.Text(statistics, left, -102, inner / 3 - 14, 100)
  end
  pane.stats = stats
  pane.returnWorker = CreateFrame("Frame", nil, pane)
  pane.resourcefulness = { any = stats[3], nonTrivial = UI.Text(statistics, inner / 3, -160, inner / 3 - 14, 64),
    complete = UI.Text(statistics, 0, -232, inner, 40) }
  pane.returnQuantity = UI.Text(statistics, 0, -208, inner / 3 - 14, 22)
  local materialList = UI.ScrollList(materials, 0, 0, inner, height - 253, {
    { title = "Reagent", width = (inner - 24) * .68, value = function(row) return UI.Name(row.item) end,
      create = function(owner, left) return UI.ItemCell(owner, left, (inner - 24) * .68) end,
      update = function(cell, row)
        cell:Update(row.item)
        UI.ReagentVisual(cell, row.item.id)
      end },
    { title = "Returned", width = (inner - 24) * .18, value = function(row) return UI.Number(row.returnedQuantity) end,
      exact = function(row) return tostring(row.returnedQuantity) end },
    { title = "Item ID", width = (inner - 24) * .14, value = function(row) return tostring(row.item.id) end },
  }, function(row) if openReagent then openReagent(row.item) end end, "No reagents returned in this period")
  pane.materialList = materialList
  UI.LazyList(materialList, function(cursor)
    local result, reason = api.GetRecipeReturnedReagents(recipeId, pane:Filter(), { limit = 40, cursor = cursor })
    return result and result.returns, result and result.nextCursor or reason
  end)
  function filters.onLayout(filterHeight)
    summary:ClearAllPoints(); summary:SetPoint("TOPLEFT", 0, -filterHeight - 6)
    tabs:ClearAllPoints(); tabs:SetPoint("TOPLEFT", 0, -filterHeight - 156)
    tabs:Resize(height - filterHeight - 156)
    materialList:SetViewportHeight(height - filterHeight - 207)
    statisticsScroll:SetHeight(height - filterHeight - 207)
    if pane.OnLayout then pane:OnLayout(height - filterHeight - 207) end
  end

  function pane:Filter()
    return { characters = state.character and { state.character } or nil, time = period:Time() }
  end

  function pane:Refresh(keepMaterialPage)
    self:SetScript("OnUpdate", nil)
    self.returnWorker:SetScript("OnUpdate", nil)
    self.calculationGeneration = self.calculationGeneration + 1
    local generation = self.calculationGeneration
    local filter = self:Filter()
    local result, reason = api.GetRecipeOutcomes(recipeId, filter, { buckets = 60 })
    status:SetText(reason or "")
    if not result then
      for _, tile in ipairs(self.tiles) do tile.value:SetText("Unavailable"); tile.note:SetText("") end
      self.returnQuantity:SetText("Unavailable")
      for _, label in ipairs(stats) do label:SetText("Unavailable") end
      for _, label in pairs(self.resourcefulness) do label:SetText("Unavailable") end
      materialList:Reset("Reagents unavailable")
      chart:Render({}, 0, 86400, 86400)
      return
    end
    local totals = result.totals
    self.tiles[1]:SetNumber(totals.craftCount, true)
    for index, metric in pairs({ [2] = "outputQuantity", [3] = "concentrationSpent",
        [4] = "multicraftBonus", [6] = "ingenuityRefund" }) do
      local known = totals[metric .. "ObservedCount"]
      self.tiles[index]:SetNumber(known > 0 and totals[metric] or nil, known == totals.craftCount)
    end
    local share = UI.MeasuredShare(totals, "multicraftBonus", "outputQuantity")
    if share ~= "Unknown" then self.tiles[4].note:SetText(share .. " of total output") end
    self.tiles[6].note:SetText(UI.Rate(totals, "ingenuityProcCount") .. " proc rate")
    production.averageOutput:SetText(totals.outputQuantityObservedCount == totals.craftCount and totals.craftCount > 0 and
      UI.Number(totals.outputQuantity / totals.craftCount) or "-")
    production.averageConcentration:SetText(totals.concentrationSpentObservedCount == totals.craftCount and totals.craftCount > 0 and
      UI.Number(totals.concentrationSpent / totals.craftCount) or "-")
    production.netConcentration:SetText(totals.concentrationSpentObservedCount == totals.craftCount and
      totals.ingenuityRefundObservedCount == totals.craftCount and UI.Number(totals.concentrationSpent - totals.ingenuityRefund) or "-")
    self.tiles[5].value:SetText("..."); self.tiles[5].note:SetText("")
    self.returnQuantity:SetText("Calculating returned quantity...")
    UI.ReturnTotals(self.returnWorker, { { id = recipeId } }, filter, function(total, crafts, complete)
      self.tiles[5]:SetNumber(total, total ~= nil and complete == crafts)
      self.returnQuantity:SetText(UI.Amount(total, total ~= nil and complete == crafts) .. " reagents returned")
    end)
    stats[1]:SetText(UI.Number(totals.craftCount))
    stats[2]:SetText(UI.CompactOutcome(totals, "multicraftProcCount", "multicraftBonus", "outputQuantity", "Bonus", "of output"))
    stats[4]:SetText(UI.CompactOutcome(totals, "ingenuityProcCount", "ingenuityRefund", "concentrationSpent", "Refund", "of spent"))
    local function showReturns(nonTrivial)
      for key, text in pairs(UI.ResourcefulnessSummary(totals, nonTrivial)) do
        self.resourcefulness[key]:SetText(text)
      end
    end
    showReturns(nil)
    if generation ~= self.calculationGeneration then return end
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
        if UI.CraftHasNonTrivialReturn(craft) then
          nonTrivial = nonTrivial + 1
        end
      end
      craftCursor = page.nextCursor
      if not craftCursor then
        showReturns(nonTrivial)
        self:SetScript("OnUpdate", nil)
      else self:SetScript("OnUpdate", nextCrafts) end
    end
    local function nextSets()
      if generation ~= self.calculationGeneration then return end
      local page, pageReason = api.GetRecipeReturnSets(recipeId, filter, { limit = 100, cursor = cursor })
      if not page then
        self.resourcefulness.nonTrivial:SetText("Unavailable"); status:SetText(pageReason or "Unavailable")
        self:SetScript("OnUpdate", nil); return
      end
      local setCount = UI.NonTrivialCount(page.returns)
      nonTrivial = nonTrivial + setCount
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
    materialList:Reload(keepMaterialPage)
  end

  function pane:State()
    state.materials = materialList:Save()
    return state
  end

  function pane:Open(id, saved)
    if id ~= recipeId then
      state = saved or { days = false, character = false }
      if state.materials then materialList:Restore(state.materials) end
    end
    recipeId = id
    local available = { { label = "All", value = false } }
    for _, entry in ipairs(api.GetCharacters() or {}) do
      available[#available + 1] = { label = UI.Name(entry), value = entry.key, classFile = entry.classFile }
    end
    characters:Update(available, state.character)
    period:UpdateState(state)
    self:Refresh(saved ~= nil)
  end
  UI.RegisterTrivialCallback(function()
    if recipeId then pane:Refresh(true) end
  end)
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