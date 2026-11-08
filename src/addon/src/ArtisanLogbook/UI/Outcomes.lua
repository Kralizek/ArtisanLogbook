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
      if not UI.IsTrivial(itemId) then count = count + (returned.craftCount or 0); break end
    end
  end
  return count
end

function UI.ProcRate(count, observed)
  if not observed or observed == 0 then return "-" end
  return UI.Percent(count, observed) .. "\n" .. UI.Number(count) .. " / " .. UI.Number(observed) .. " crafts"
end

function UI.MatchedSavings(row)
  if not UI.Supports("resourcefulness") then return "Unavailable" end
  if not row or not row.matchedCraftCount or row.matchedCraftCount <= 0 or
      not row.matchedAllocatedQuantity or row.matchedAllocatedQuantity <= 0 or
      row.matchedReturnedQuantity == nil then return "Unavailable" end
  return UI.Percent(row.matchedReturnedQuantity, row.matchedAllocatedQuantity)
end

function UI.MatchedSavingsText(row)
  local savings = UI.MatchedSavings(row)
  return savings == "Unavailable" and "-" or savings
end

function UI.RecipeReturnedQuantity(row)
  if not row or row.returnedQuantity == nil then return "-" end
  return UI.Number(row.returnedQuantity)
end

function UI.MeasuredShare(totals, numerator, denominator)
  if not UI.Supports(numerator) or not UI.Supports(denominator) then return "Unknown" end
  if totals.craftCount == 0 or totals[numerator .. "ObservedCount"] ~= totals.craftCount or
      totals[denominator .. "ObservedCount"] ~= totals.craftCount or
      not totals[denominator] or totals[denominator] <= 0 then return "Unknown" end
  return UI.Percent(totals[numerator], totals[denominator])
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
  local crafts = totals.craftCount or 0
  local positive = totals.resourcefulnessProcCount or 0
  local result = { complete = "" }
  if crafts == 0 then
    return { any = "No crafts", complete = "", nonTrivial = "-" }
  end
  result.any = UI.Percent(positive, crafts):gsub("%.0%%", "%%") .. " | " .. UI.Number(positive) .. " of " ..
    UI.Number(crafts) .. " crafts"
  if nonTrivial == nil then
    result.nonTrivial = "Calculating..."
  else
    nonTrivial = math.min(nonTrivial, positive)
    result.nonTrivial = UI.Percent(nonTrivial, crafts):gsub("%.0%%", "%%") .. " | " .. UI.Number(nonTrivial) .. " of " ..
      UI.Number(crafts) .. " crafts"
  end
  return result
end

function UI.TrivialCheckbox(parent, x, y, onChange, compact)
  local checkbox = UI.TemplateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  checkbox:SetSize(24, 24)
  checkbox:SetPoint("TOPLEFT", x, y)
  if not compact then UI.Text(checkbox, 26, -5, 218, 32):SetText("Ignore in savings statistics") end
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
  UI.RegisterTrivialCallback(function(itemId)
    if checkbox.itemId == itemId then checkbox:SetItem(itemId) end
  end)
  return checkbox
end

function UI.RecipeOutcomes(parent, width, onFilterChanged, height, openReagent)
  local pane = CreateFrame("Frame", nil, parent)
  height = height or 620
  pane:SetSize(width, height)
  pane:SetPoint("TOPLEFT", 0, -62)
  pane.calculationGeneration = 0
  local api = ArtisanLogbookAPI
  local state, recipeId = { days = 30, character = false, craftType = UI.DefaultCraftType() }, nil
  local function refresh()
    if recipeId then pane:Refresh(); onFilterChanged() end
  end
  local filters = UI.FilterBar(pane, width)
  local period = filters:Period(state, refresh, true)
  local craftType = filters:CraftType(state, refresh)
  local characters = filters:Select("Character", {}, function(value) state.character = value; refresh() end)
  pane.filters, pane.period, pane.craftType = filters, period, craftType
  local status = UI.Text(pane, 370, -16, width - 370, 24)
  local outcomeMetrics = { [3] = "concentrationSpent", [4] = "multicraft", [5] = "resourcefulness", [6] = "ingenuityRefund" }
  local entries, tileIndices = {}, {}
  for index, entry in ipairs({ { "Crafts", "Trade_BlackSmithing" }, { "Total output", "INV_Misc_Bag_10" },
      { "Concentration spent", "Spell_Arcane_Arcane01" }, { "Multicraft bonus", "Trade_Engineering" },
      { "Returned units", "INV_Misc_Herb_19" }, { "Ingenuity refund", "Spell_Holy_MindVision" } }) do
    if not outcomeMetrics[index] or UI.Supports(outcomeMetrics[index]) then
      entries[#entries + 1], tileIndices[#tileIndices + 1] = entry, index
    end
  end
  local summary = UI.SummaryRow(pane, width, -52, entries)
  pane.tiles, pane.summary = {}, summary
  for index, original in ipairs(tileIndices) do pane.tiles[original] = summary.tiles[index] end
  local hasStatistics = UI.Supports("multicraft") or UI.Supports("resourcefulness") or
    UI.Supports("concentrationSpent") or UI.Supports("ingenuityRefund")
  local tabNames = { "Overview" }
  if hasStatistics then tabNames[#tabNames + 1] = "Statistics" end
  tabNames[#tabNames + 1], tabNames[#tabNames + 2] = "Craft History", "Reagents"
  local tabs = UI.TabbedContent(pane, width, height - 202, -202, tabNames, function(name)
      pane.activeView = name
      if pane.OnSelect then pane:OnSelect(name) end
    end)
  pane.tabbed, pane.views = tabs, tabs.views
  function pane:SelectView(name) tabs:Select(tabs.views[name] and name or "Overview") end
  local overview, statistics, materials = pane.views.Overview, pane.views.Statistics, pane.views.Reagents
  local inner = width - 24
  local statisticsContent, statisticsScroll
  if statistics then
    statisticsContent, statisticsScroll = UI.PageScroll(statistics, inner, height - 253, 288)
  end
  statistics, pane.statisticsScroll = statisticsContent, statisticsScroll
  local chart = UI.Chart(overview, 0, 0, inner)
  pane.chart = chart
  pane.qualityWorker = CreateFrame("Frame", nil, pane)
  local explanationHeight = UI.FixedInputs() and 56 or 0
  local qualityTitle = UI.Text(overview, 0, -170 - explanationHeight, inner, 24, "GameFontNormal")
  qualityTitle:SetText("Output by quality")
  local qualityWidth = inner - 24
  local resultWidth = qualityWidth * (UI.Supports("concentrationSpent") and .35 or .63)
  local qualityColumns = {
    { title = "Result", width = resultWidth, value = function(row) return UI.Name(row.item) end,
      create = function(owner, left) return UI.ItemCell(owner, left, resultWidth) end,
      update = function(cell, row)
        cell:Update(row.item, UI.QualityAtlas(recipeId, row.quality, pane.maxQuality))
      end },
    { title = "Crafts", width = qualityWidth * .10, value = function(row) return UI.Number(row.craftCount) end,
      exact = function(row) return UI.Count(row.craftCount, "craft") end },
    { title = "Items", width = qualityWidth * .13, value = function(row) return UI.Amount(row.quantity, row.complete) end,
      exact = function(row) return UI.AmountTooltip(row.quantity, row.complete) end },
    { title = "Items / craft", width = qualityWidth * .14, value = function(row)
      return row.complete and row.craftCount > 0 and UI.Number(row.quantity / row.craftCount) or "-"
    end, exact = function(row)
      return row.complete and row.craftCount > 0 and (UI.Number(row.quantity / row.craftCount) ..
        " items per craft across " .. UI.Count(row.craftCount, "craft")) or "Average unavailable because some results are missing."
    end },
    { title = "Concentration", width = qualityWidth * .14, value = function(row)
      return UI.Amount(row.concentrationSpent, row.concentrationObservedCount == row.craftCount)
    end, exact = function(row)
      return UI.AmountTooltip(row.concentrationSpent, row.concentrationObservedCount == row.craftCount)
    end },
    { title = "Concentration / craft", width = qualityWidth * .14, value = function(row)
      return row.concentrationObservedCount == row.craftCount and row.craftCount > 0 and
        UI.Number(row.concentrationSpent / row.craftCount) or "-"
    end, exact = function(row)
      return row.concentrationObservedCount == row.craftCount and row.craftCount > 0 and
        (UI.Number(row.concentrationSpent / row.craftCount) .. " concentration per craft across " ..
          UI.Count(row.craftCount, "craft")) or "Average unavailable because some costs are missing."
    end },
  }
  if not UI.Supports("concentrationSpent") then
    table.remove(qualityColumns, 6); table.remove(qualityColumns, 5)
  end
  local qualityList = UI.ScrollList(overview, 0, -202 - explanationHeight, inner, 130, qualityColumns,
    function(row) UI.ItemTooltip(overview, row.item) end, "No output quantities for this period")
  qualityList.tooltipKind = "recipe"
  qualityList.tooltipFilter = function() return pane:Filter() end
  local qualityStatus = UI.Text(overview, 0, -340, inner, 32)
  pane.qualityList, pane.qualityTitle, pane.qualityStatus = qualityList, qualityTitle, qualityStatus
  qualityList:Hide(); qualityTitle:Hide()
  local explanation = UI.Text(overview, 0, -174, inner, 52)
  explanation:SetText(UI.FixedInputs() and UI.InputExplanation() or "")
  explanation:SetShown(UI.FixedInputs())
  function pane:QualityBreakdown(filter, totals)
    self.qualityWorker:SetScript("OnUpdate", nil)
    if not UI.Supports("quality") then
      qualityList:Hide(); qualityTitle:Hide(); qualityStatus:SetText("")
      return
    end
    qualityList:Reset("Loading output qualities...")
    qualityStatus:SetText("")
    qualityList:Hide(); qualityTitle:Hide()
    local groups, cursor, crafts, splitCrafts, qualities = {}, nil, 0, 0, {}
    self.qualityWorker:SetScript("OnUpdate", function(worker)
      local page, reason = api.GetCrafts({ recipes = { recipeId }, time = filter.time, characters = filter.characters,
        craftType = filter.craftType },
        { limit = 100, cursor = cursor })
      if not page then worker:SetScript("OnUpdate", nil); qualityStatus:SetText(reason or "Output quality unavailable"); return end
      for _, craft in ipairs(page.crafts) do
        crafts = crafts + 1
        local outputs = craft.outputs or { { quality = craft.outputQuality, item = craft.outputItem,
          quantity = craft.outputQuantity } }
        local seenGroups, complete = {}, true
        for _, output in ipairs(outputs) do
          local quality = output.quality
          local key = tostring(quality or "unknown") .. ":" .. tostring(output.item and output.item.id or "unknown")
          local group = groups[key] or { quality = quality, item = output.item, complete = true,
            craftCount = 0, concentrationSpent = 0, concentrationObservedCount = 0 }
          groups[key] = group
          if not seenGroups[key] then
            group.craftCount = group.craftCount + 1
            if craft.concentrationSpent ~= nil then
              group.concentrationSpent = group.concentrationSpent + craft.concentrationSpent
              group.concentrationObservedCount = group.concentrationObservedCount + 1
            end
          end
          seenGroups[key] = true
          if quality ~= nil then qualities[quality] = true else complete = false end
          if output.quantity ~= nil and not output.quantityAmbiguous then
            group.quantity = (group.quantity or 0) + output.quantity
          else group.complete, complete = false, false end
        end
        if complete then splitCrafts = splitCrafts + 1 end
      end
      cursor = page.nextCursor
      if cursor then return end
      worker:SetScript("OnUpdate", nil)
      local rows, qualityCount = {}, 0
      for _ in pairs(qualities) do qualityCount = qualityCount + 1 end
      for _, row in pairs(groups) do rows[#rows + 1] = row end
      table.sort(rows, function(left, right)
        if left.quality ~= right.quality then
          if left.quality == nil then return false end
          if right.quality == nil then return true end
          return left.quality < right.quality
        end
        return (left.item and left.item.id or 0) < (right.item and right.item.id or 0)
      end)
      self.qualityRows, self.qualityCraftCount = rows, splitCrafts
      qualityList:Append(rows)
      local show = (self.maxQuality or 0) > 1 or qualityCount > 1
      qualityList:SetShown(show); qualityTitle:SetShown(show)
      if show then
        if splitCrafts < totals.craftCount then
          qualityStatus:SetText("Output quality available for " .. UI.Count(splitCrafts, "craft") .. " of " .. UI.Number(totals.craftCount) .. ".")
        end
      end
      self.tiles[2]:SetScript("OnEnter", function(tile)
        GameTooltip:SetOwner(tile, "ANCHOR_RIGHT")
        GameTooltip:SetText("Output: " .. UI.AmountTooltip(totals.outputQuantity,
          totals.outputQuantityObservedCount == totals.craftCount))
        local average = UI.MulticraftAverage(totals)
        if average then GameTooltip:AddLine(UI.Number(average) .. " items per craft across " ..
          UI.Count(totals.craftCount, "craft") .. ".", 1, 1, 1, true) end
        for _, row in ipairs(rows) do
          GameTooltip:AddLine((row.quality and "Quality " .. row.quality or "Quality unavailable") .. ": " .. UI.AmountTooltip(row.quantity, row.complete), 1, 1, 1, true)
        end
        if splitCrafts < totals.craftCount then GameTooltip:AddLine("The quality split cannot be reconstructed for all older crafts.", 1, 1, 1, true) end
        GameTooltip:Show()
      end)
    end)
  end
  local production = {}
  local productionEntries = {}
  if statistics then productionEntries[#productionEntries + 1] = { "Items / craft", "averageOutput" } end
  if UI.Supports("concentrationSpent") then
    productionEntries[#productionEntries + 1] = { "Concentration / craft", "averageConcentration" }
    if UI.Supports("ingenuityRefund") then
      productionEntries[#productionEntries + 1] = { "Net concentration", "netConcentration" }
    end
  end
  for index, entry in ipairs(productionEntries) do
    local columnWidth = inner / #productionEntries
    local left = (index - 1) * columnWidth
    UI.Text(statistics, left, 0, columnWidth - 12, 20, "GameFontNormal"):SetText(entry[1])
    production[entry[2]] = UI.Text(statistics, left, -26, columnWidth - 12, 28, "GameFontNormalLarge")
  end
  pane.production = production
  local stats = { [1] = pane.tiles[1].value }
  local statEntries = {}
  for _, entry in ipairs({ { "Multicraft", 2, "multicraft" }, { "Resourcefulness", 3, "resourcefulness" },
      { "Ingenuity", 4, "ingenuityRefund" } }) do
    if UI.Supports(entry[3]) then statEntries[#statEntries + 1] = entry end
  end
  local resourceLeft, resourceWidth
  for index, entry in ipairs(statEntries) do
    local columnWidth = inner / #statEntries
    local left = (index - 1) * columnWidth
    UI.Section(statistics, entry[1], left, -68, columnWidth - 14)
    stats[entry[2]] = UI.Text(statistics, left, -102, columnWidth - 14, 100)
    if entry[2] == 3 then resourceLeft, resourceWidth = left, columnWidth - 14 end
  end
  pane.stats = stats
  pane.returnWorker = CreateFrame("Frame", nil, pane)
  pane.resourcefulness = {}
  if stats[3] then
    stats[3]:SetHeight(50)
    UI.Text(statistics, resourceLeft, -154, resourceWidth, 20, "GameFontNormalSmall"):SetText("Useful Resourcefulness")
    pane.resourcefulness = { any = stats[3], nonTrivial = UI.Text(statistics, resourceLeft, -178, resourceWidth, 48),
      complete = UI.Text(statistics, 0, -232, inner, 40) }
    pane.returnQuantity = UI.Text(statistics, 0, -208, resourceWidth, 22)
  end
  local materialQuantityWidth = UI.FixedInputs() and 160 or 110
  local materialNameWidth = inner - 24 - materialQuantityWidth - (UI.Supports("resourcefulness") and 320 or 0)
  local materialColumns = {
    { title = "Reagent", width = materialNameWidth, value = function(row) return UI.Name(row.item) end,
      create = function(owner, left) return UI.ItemCell(owner, left, materialNameWidth) end,
      update = function(cell, row)
        UI.ReagentCell(cell, row.item)
      end },
    { title = UI.FixedInputs() and UI.InputLabel() or "Quantity", width = materialQuantityWidth, value = function(row)
      return row.allocatedQuantity ~= nil and UI.Number(row.allocatedQuantity) or "-"
    end, exact = function(row)
      if row.allocatedQuantity == nil then return "No quantity was recorded for this item." end
      if UI.FixedInputs() then return UI.Number(row.allocatedQuantity) .. ". " .. UI.InputExplanation() end
      local text = UI.Number(row.allocatedQuantity) ..
        " recorded for this item across these crafts. Returns are shown separately."
      if row.matchedCraftCount and row.matchedCraftCount > 0 then
        text = text .. " Savings compare " .. UI.Count(row.matchedCraftCount, "craft") .. " where both amounts are known."
      end
      return text
    end },
    { title = "Returned", width = 90, value = UI.RecipeReturnedQuantity,
      exact = function(row)
      return row.returnedQuantity ~= nil and UI.Number(row.returnedQuantity) or "No per-item returned quantity is available."
    end },
    { title = "Saved share", width = 160, value = function(row)
      if UI.IsTrivial(row.item.id) then return "-" end
      return UI.MatchedSavingsText(row)
    end, exact = function(row)
      if UI.IsTrivial(row.item.id) then return "Excluded from savings by your preference; quantities are unchanged." end
      if UI.MatchedSavings(row) == "Unavailable" then
        return "No comparable crafts have both required and returned quantities known for this item."
      end
      return UI.Number(row.matchedReturnedQuantity) .. " saved of " .. UI.Number(row.matchedAllocatedQuantity) ..
      " required across " .. UI.Count(row.matchedCraftCount, "comparable craft") ..
      ". The share uses this item in the same crafts."
    end },
    { title = "Ignore", width = 64, value = function(row) return UI.IsTrivial(row.item.id) and "Yes" or "No" end,
      create = function(owner, left) return UI.TrivialCheckbox(owner, left + 8, -2, function() end, true) end,
      update = function(check, row) check:SetItem(row.item.id) end },
  }
  if not UI.Supports("resourcefulness") then
    for index = #materialColumns, 3, -1 do table.remove(materialColumns, index) end
  end
  local materialList = UI.ScrollList(materials, 0, 0, inner, height - 253, materialColumns,
    function(row) if openReagent then openReagent(row.item) end end,
    UI.FixedInputs() and "No reagent requirements in this period" or "No reagent measurements in this period")
  pane.materialList = materialList
  local requirementNote = UI.Text(materials, 0, -4, inner, 18, "GameFontNormalSmall")
  requirementNote:SetJustifyH("LEFT")
  requirementNote:SetWordWrap(false); requirementNote:SetMaxLines(1); requirementNote:Hide()
  pane.requirementNote = requirementNote
  pane.requirementFamilies = {}
  pane.requirementMore = false
  local function showRequirementDetails()
    if #pane.requirementFamilies == 0 then return end
    GameTooltip:SetOwner(requirementNote, "ANCHOR_RIGHT")
    GameTooltip:SetText("Recipe requirements")
    if UI.FixedInputs() then GameTooltip:AddLine(UI.InputExplanation(), 1, 1, 1, true) end
    for _, family in ipairs(pane.requirementFamilies) do
      local names, seen = {}, {}
      for _, candidate in ipairs(family.candidateItems) do
        local name = UI.Name(candidate)
        if not seen[name] then seen[name] = true; names[#names + 1] = name end
      end
      GameTooltip:AddLine(table.concat(names, " or ") .. ": " .. UI.Number(family.requiredQuantity) .. " across " ..
        UI.Count(family.craftCount, "craft") .. (#family.candidateItems > 1 and " (quality not recorded)" or ""),
        1, 1, 1, true)
    end
    if pane.requirementMore then
      GameTooltip:AddLine("More ingredients aren't shown.", 1, 1, 1, true)
    end
    GameTooltip:Show()
  end
  requirementNote:SetScript("OnEnter", showRequirementDetails)
  requirementNote:SetScript("OnLeave", function() GameTooltip:Hide() end)
  materialList:ClearAllPoints(); materialList:SetPoint("TOPLEFT", 0, -4)
  UI.LazyList(materialList, function(cursor)
    local result, reason = api.GetRecipeReagentStatistics(recipeId, pane:Filter(), { limit = 40, cursor = cursor })
    return result and result.reagents, result and result.nextCursor or reason
  end)
  local materialViewHeight
  local function layoutMaterialList()
    if not materialViewHeight then return end
    local offset = pane.requirementVisible and 26 or 0
    materialList:ClearAllPoints()
    materialList:SetPoint("TOPLEFT", 0, -4 - offset)
    materialList:SetViewportHeight(math.max(0, materialViewHeight - offset))
  end
  function filters.onLayout(filterHeight)
    summary:ClearAllPoints(); summary:SetPoint("TOPLEFT", 0, -filterHeight - 6)
    local top = filterHeight + summary:GetHeight() + 14
    local viewHeight = height - top - 51
    tabs:ClearAllPoints(); tabs:SetPoint("TOPLEFT", 0, -top)
    tabs:Resize(height - top)
    materialViewHeight = viewHeight
    layoutMaterialList()
    if statisticsScroll then statisticsScroll:SetHeight(viewHeight) end
    qualityList:SetViewportHeight(math.max(58, viewHeight - 242 - explanationHeight))
    qualityStatus:ClearAllPoints(); qualityStatus:SetPoint("TOPLEFT", 0, -viewHeight + 34)
    if pane.OnLayout then pane:OnLayout(viewHeight) end
  end

  function pane:Filter()
    return { characters = state.character and { state.character } or nil, time = period:Time(),
      craftType = UI.CraftTypeFilter(state) }
  end

  function pane:Refresh(keepMaterialPage)
    UI.Tooltip.ReleaseTree(self)
    self:SetScript("OnUpdate", nil)
    self.returnWorker:SetScript("OnUpdate", nil)
    self.qualityWorker:SetScript("OnUpdate", nil)
    self.calculationGeneration = self.calculationGeneration + 1
    local generation = self.calculationGeneration
    local filter = self:Filter()
    local result, reason = api.GetRecipeOutcomes(recipeId, filter, { buckets = 60 })
    status:SetText(reason or "")
    if not result then
      for _, tile in pairs(self.tiles) do tile.value:SetText("Unavailable"); tile.note:SetText("") end
      if self.returnQuantity then self.returnQuantity:SetText("Unavailable") end
      requirementNote:SetText("")
      requirementNote:Hide()
      pane.requirementFamilies, pane.requirementMore, pane.requirementVisible = {}, false, false
      layoutMaterialList()
      for _, label in pairs(stats) do label:SetText("Unavailable") end
      for _, label in pairs(production) do label:SetText("Unavailable") end
      for _, label in pairs(self.resourcefulness) do label:SetText("Unavailable") end
      qualityList:Hide(); qualityTitle:Hide(); qualityStatus:SetText("")
      materialList:Reset("Reagents unavailable")
      chart:Render({}, 0, 86400, 86400)
      return
    end
    local totals = result.totals
    local requirements = api.GetRecipeReagentRequirements(recipeId, filter, { limit = 200 })
    pane.requirementFamilies = requirements and requirements.requirements or {}
    pane.requirementMore = requirements and requirements.nextCursor ~= nil or false
    pane.requirementVisible = #pane.requirementFamilies > 0
    requirementNote:SetShown(pane.requirementVisible)
    if pane.requirementVisible then
      requirementNote:SetText(UI.FixedInputs() and "Hover for expected recipe totals." or
        "Some ingredients aren't listed by quality. Hover for recipe totals.")
    else
      requirementNote:SetText("")
    end
    layoutMaterialList()
    self:QualityBreakdown(filter, totals)
    self.tiles[1]:SetNumber(totals.craftCount, true)
    local outputAverage = UI.MulticraftAverage(totals)
    self.tiles[2].title:SetText(outputAverage and "Avg output" or "Total output")
    if outputAverage then
      self.tiles[2]:SetNumber(outputAverage, true, "items per craft")
    else
      self.tiles[2]:SetNumber(totals.outputQuantityObservedCount > 0 and totals.outputQuantity or nil,
        totals.outputQuantityObservedCount == totals.craftCount)
    end
    if self.tiles[3] then
      self.tiles[3].title:SetText("Avg concentration")
      local concentrationCount = totals.concentrationSpentObservedCount or 0
      if concentrationCount > 0 then
        local averageConcentration = totals.concentrationSpent / concentrationCount
        self.tiles[3]:SetNumber(averageConcentration, true,
          "per craft" .. (concentrationCount < totals.craftCount and " with a recorded cost" or ""))
        self.tiles[3]:SetScript("OnEnter", function(tile)
          GameTooltip:SetOwner(tile, "ANCHOR_RIGHT")
          GameTooltip:SetText(UI.Number(averageConcentration) .. " concentration per craft")
          GameTooltip:AddLine(UI.Number(totals.concentrationSpent) .. " total across " ..
            UI.Count(concentrationCount, "craft") .. ".", 1, 1, 1, true)
          if concentrationCount < totals.craftCount then
            GameTooltip:AddLine(UI.Count(totals.craftCount - concentrationCount, "craft") ..
              " without a recorded concentration cost.", 1, 1, 1, true)
          end
          GameTooltip:Show()
        end)
      else
        self.tiles[3]:SetNumber(nil, false, "No recorded costs")
      end
    end
    for index, metric in pairs({ [4] = "multicraftBonus", [6] = "ingenuityRefund" }) do
      if self.tiles[index] then
        local known = totals[metric .. "ObservedCount"]
        self.tiles[index]:SetNumber(known > 0 and totals[metric] or nil, known == totals.craftCount)
      end
    end
    if self.tiles[4] then
      local share = UI.MeasuredShare(totals, "multicraftBonus", "outputQuantity")
      local procRate = UI.Rate(totals, "multicraftProcCount")
      self.tiles[4].note:SetText((procRate ~= "-" and procRate .. " procs" or "") ..
        (share ~= "Unknown" and "\n" .. share .. " of output" or ""))
    end
    if self.tiles[6] then self.tiles[6].note:SetText(UI.Rate(totals, "ingenuityProcCount") .. " proc rate") end
    if production.averageOutput then
      production.averageOutput:SetText(totals.outputQuantityObservedCount == totals.craftCount and totals.craftCount > 0 and
        UI.Number(totals.outputQuantity / totals.craftCount) or "-")
    end
    if production.averageConcentration then
      production.averageConcentration:SetText(totals.concentrationSpentObservedCount == totals.craftCount and totals.craftCount > 0 and
        UI.Number(totals.concentrationSpent / totals.craftCount) or "-")
    end
    if production.netConcentration then
      production.netConcentration:SetText(totals.craftCount > 0 and totals.concentrationSpentObservedCount == totals.craftCount and
        totals.ingenuityRefundObservedCount == totals.craftCount and UI.Number(totals.concentrationSpent - totals.ingenuityRefund) or "-")
    end
    if self.tiles[5] then
      self.tiles[5].value:SetText("..."); self.tiles[5].note:SetText("")
      self.returnQuantity:SetText("Calculating returned quantity...")
      UI.ReturnTotals(self.returnWorker, { { id = recipeId } }, filter, function(total)
        local verified = totals.resourcefulnessAuthoritativeProcCountObservedCount
        local complete = total ~= nil and totals.craftCount > 0 and verified == totals.craftCount
        self.tiles[5]:SetNumber(total, complete, "")
        self.returnQuantity:SetText(UI.Amount(total, complete) .. " material units returned")
      end)
    end
    stats[1]:SetText(UI.Number(totals.craftCount))
    if stats[2] then
      stats[2]:SetText(UI.CompactOutcome(totals, "multicraftProcCount", "multicraftBonus", "outputQuantity", "Bonus", "of output"))
    end
    if stats[4] then
      stats[4]:SetText(UI.CompactOutcome(totals, "ingenuityProcCount", "ingenuityRefund", "concentrationSpent", "Refund", "of spent"))
    end
    if stats[3] then
      local function showReturns(nonTrivial)
        for key, text in pairs(UI.ResourcefulnessSummary(totals, nonTrivial)) do
          self.resourcefulness[key]:SetText(text)
        end
      end
      showReturns(nil)
      if generation ~= self.calculationGeneration then return end
      local cursor, nonTrivial = nil, 0
      if #UI.TrivialItemIds() == 0 then
        showReturns(totals.resourcefulnessProcCount or 0)
      else
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
            showReturns(nonTrivial)
            self:SetScript("OnUpdate", nil)
          else self:SetScript("OnUpdate", nextSets) end
        end
        nextSets()
      end
    end
    local start, finish = result.from, result.to
    if filter.time then start, finish = filter.time.from, filter.time.to end
    if not start then start, finish = UI.Range(GetServerTime(), 30) end
    chart:Render(result.series, start, finish, result.bucketSeconds)
    materialList:Reload(keepMaterialPage)
  end

  function pane:State()
    state.materials = materialList:Save()
    return state
  end

  function pane:Open(id, saved)
    if id ~= recipeId then
      state = saved or { days = 30, character = false, craftType = UI.DefaultCraftType() }
      if state.materials then materialList:Restore(state.materials) end
    end
    craftType:UpdateState(state)
    recipeId = id
    qualityList.tooltipRecipe = pane.recipe or { id = id }
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