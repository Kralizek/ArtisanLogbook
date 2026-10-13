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
  local checkbox = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
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
  local state, recipeId = { days = 30, character = false }, nil
  local function refresh()
    if recipeId then pane:Refresh(); onFilterChanged() end
  end
  local filters = UI.FilterBar(pane, width)
  local period = filters:Period(state, refresh, true)
  local characters = filters:Select("Character", {}, function(value) state.character = value; refresh() end)
  pane.filters, pane.period = filters, period
  local status = UI.Text(pane, 370, -16, width - 370, 24)
  local summary = UI.SummaryRow(pane, width, -52, { { "Crafts", "Trade_BlackSmithing" }, { "Total output", "INV_Misc_Bag_10" },
      { "Concentration spent", "Spell_Arcane_Arcane01" }, { "Multicraft bonus", "Trade_Engineering" },
      { "Returned units", "INV_Misc_Herb_19" }, { "Ingenuity refund", "Spell_Holy_MindVision" } })
  pane.tiles, pane.summary = summary.tiles, summary
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
  pane.qualityWorker = CreateFrame("Frame", nil, pane)
  local qualityTitle = UI.Text(overview, 0, -170, inner, 24, "GameFontNormal")
  qualityTitle:SetText("Output by quality")
  local qualityWidth = inner - 24
  local qualityList = UI.ScrollList(overview, 0, -202, inner, 130, {
    { title = "Result", width = qualityWidth * .35, value = function(row)
      return UI.Name(row.item) .. (row.quality and " (Q" .. row.quality .. ")" or " (quality unknown)")
    end, create = function(owner, left) return UI.ItemCell(owner, left, qualityWidth * .35) end,
      update = function(cell, row)
        cell:Update(row.item and { id = row.item.id,
          name = UI.Name(row.item) .. (row.quality and " (Q" .. row.quality .. ")" or " (quality unknown)") } or nil,
          UI.QualityAtlas(recipeId, row.quality, pane.maxQuality))
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
  }, function(row) UI.ItemTooltip(overview, row.item) end, "No output quantities for this period")
  local qualityStatus = UI.Text(overview, 0, -340, inner, 32)
  pane.qualityList, pane.qualityTitle, pane.qualityStatus = qualityList, qualityTitle, qualityStatus
  function pane:QualityBreakdown(filter, totals)
    self.qualityWorker:SetScript("OnUpdate", nil)
    qualityList:Reset("Loading output qualities...")
    qualityStatus:SetText("")
    qualityList:Hide(); qualityTitle:Hide()
    local groups, cursor, crafts, splitCrafts, qualities = {}, nil, 0, 0, {}
    self.qualityWorker:SetScript("OnUpdate", function(worker)
      local page, reason = api.GetCrafts({ recipes = { recipeId }, time = filter.time, characters = filter.characters },
        { limit = 100, cursor = cursor })
      if not page then worker:SetScript("OnUpdate", nil); qualityStatus:SetText(reason or "Output quality unavailable"); return end
      for _, craft in ipairs(page.crafts) do
        crafts = crafts + 1
        local quality = craft.outputQuality
        local key = tostring(quality or "unknown") .. ":" .. tostring(craft.outputItem and craft.outputItem.id or "unknown")
        local group = groups[key] or { quality = quality, item = craft.outputItem, complete = true,
          craftCount = 0, concentrationSpent = 0, concentrationObservedCount = 0 }
        groups[key] = group
        group.craftCount = group.craftCount + 1
        if quality ~= nil then qualities[quality] = true end
        if quality ~= nil and craft.outputQuantity ~= nil then splitCrafts = splitCrafts + 1 end
        if craft.outputQuantity ~= nil then group.quantity = (group.quantity or 0) + craft.outputQuantity
        else group.complete = false end
        if craft.concentrationSpent ~= nil then
          group.concentrationSpent = group.concentrationSpent + craft.concentrationSpent
          group.concentrationObservedCount = group.concentrationObservedCount + 1
        end
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
  stats[3]:SetHeight(50)
  UI.Text(statistics, inner / 3, -154, inner / 3 - 14, 20, "GameFontNormalSmall"):SetText("Useful Resourcefulness")
  pane.resourcefulness = { any = stats[3], nonTrivial = UI.Text(statistics, inner / 3, -178, inner / 3 - 14, 48),
    complete = UI.Text(statistics, 0, -232, inner, 40) }
  pane.returnQuantity = UI.Text(statistics, 0, -208, inner / 3 - 14, 22)
  local materialList = UI.ScrollList(materials, 0, 0, inner, height - 253, {
    { title = "Reagent", width = inner - 454, value = function(row) return UI.Name(row.item) end,
      create = function(owner, left) return UI.ItemCell(owner, left, inner - 454) end,
      update = function(cell, row)
        UI.ReagentCell(cell, row.item)
      end },
    { title = "Quantity", width = 110, value = function(row)
      return row.allocatedQuantity ~= nil and UI.Number(row.allocatedQuantity) or "-"
    end, exact = function(row)
      if row.allocatedQuantity == nil then return "No quantity was recorded for this item." end
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
  }, function(row) if openReagent then openReagent(row.item) end end, "No reagent measurements in this period")
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
    statisticsScroll:SetHeight(viewHeight)
    qualityList:SetViewportHeight(math.max(58, viewHeight - 242))
    qualityStatus:ClearAllPoints(); qualityStatus:SetPoint("TOPLEFT", 0, -viewHeight + 34)
    if pane.OnLayout then pane:OnLayout(viewHeight) end
  end

  function pane:Filter()
    return { characters = state.character and { state.character } or nil, time = period:Time() }
  end

  function pane:Refresh(keepMaterialPage)
    self:SetScript("OnUpdate", nil)
    self.returnWorker:SetScript("OnUpdate", nil)
    self.qualityWorker:SetScript("OnUpdate", nil)
    self.calculationGeneration = self.calculationGeneration + 1
    local generation = self.calculationGeneration
    local filter = self:Filter()
    local result, reason = api.GetRecipeOutcomes(recipeId, filter, { buckets = 60 })
    status:SetText(reason or "")
    if not result then
      for _, tile in ipairs(self.tiles) do tile.value:SetText("Unavailable"); tile.note:SetText("") end
      self.returnQuantity:SetText("Unavailable")
      requirementNote:SetText("")
      requirementNote:Hide()
      pane.requirementFamilies, pane.requirementMore, pane.requirementVisible = {}, false, false
      layoutMaterialList()
      for _, label in ipairs(stats) do label:SetText("Unavailable") end
      for _, label in pairs(self.resourcefulness) do label:SetText("Unavailable") end
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
      requirementNote:SetText("Some ingredients aren't listed by quality. Hover for recipe totals.")
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
    for index, metric in pairs({ [4] = "multicraftBonus", [6] = "ingenuityRefund" }) do
      local known = totals[metric .. "ObservedCount"]
      self.tiles[index]:SetNumber(known > 0 and totals[metric] or nil, known == totals.craftCount)
    end
    local share = UI.MeasuredShare(totals, "multicraftBonus", "outputQuantity")
    local procRate = UI.Rate(totals, "multicraftProcCount")
    self.tiles[4].note:SetText((procRate ~= "-" and procRate .. " procs" or "") ..
      (share ~= "Unknown" and "\n" .. share .. " of output" or ""))
    self.tiles[6].note:SetText(UI.Rate(totals, "ingenuityProcCount") .. " proc rate")
    production.averageOutput:SetText(totals.outputQuantityObservedCount == totals.craftCount and totals.craftCount > 0 and
      UI.Number(totals.outputQuantity / totals.craftCount) or "-")
    production.averageConcentration:SetText(totals.concentrationSpentObservedCount == totals.craftCount and totals.craftCount > 0 and
      UI.Number(totals.concentrationSpent / totals.craftCount) or "-")
    production.netConcentration:SetText(totals.craftCount > 0 and totals.concentrationSpentObservedCount == totals.craftCount and
      totals.ingenuityRefundObservedCount == totals.craftCount and UI.Number(totals.concentrationSpent - totals.ingenuityRefund) or "-")
    self.tiles[5].value:SetText("..."); self.tiles[5].note:SetText("")
    self.returnQuantity:SetText("Calculating returned quantity...")
    UI.ReturnTotals(self.returnWorker, { { id = recipeId } }, filter, function(total)
      local verified = totals.resourcefulnessAuthoritativeProcCountObservedCount
      local complete = total ~= nil and totals.craftCount > 0 and verified == totals.craftCount
      self.tiles[5]:SetNumber(total, complete)
      self.returnQuantity:SetText(UI.Amount(total, complete) .. " material units returned")
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
      state = saved or { days = 30, character = false }
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