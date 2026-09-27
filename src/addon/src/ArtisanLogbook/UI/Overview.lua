local _, addon = ...
local UI = addon.UI
local API = ArtisanLogbookAPI

local function summary(series, from, to)
  local stats = { crafts = 0, spent = 0, spentKnown = 0, refund = 0, refundKnown = 0,
    multi = 0, multiKnown = 0, recipes = {} }
  for _, row in ipairs(series) do
    if row.bucketStart >= from and row.bucketStart < to then
      stats.crafts = stats.crafts + row.craftCount
      for _, measure in ipairs({ { "concentrationSpent", "spent", "spentKnown" },
        { "ingenuityRefund", "refund", "refundKnown" },
        { "multicraftBonus", "multi", "multiKnown" } }) do
        stats[measure[2]] = stats[measure[2]] + (row[measure[1]] or 0)
        stats[measure[3]] = stats[measure[3]] + row[measure[1] .. "ObservedCount"]
      end
      if row.recipe and row.recipe.id then
        local recipe = stats.recipes[row.recipe.id] or { name = UI.Name(row.recipe), count = 0 }
        recipe.count = recipe.count + row.craftCount
        stats.recipes[row.recipe.id] = recipe
      end
    end
  end
  return stats
end

local function measured(value, known, total)
  if known == 0 then return "Unknown" end
  if known ~= total then return string.format("%s (measured %d/%d)", value, known, total) end
  return tostring(value)
end

local function comparison(current, previous, key, coverage)
  if coverage and (current[coverage] ~= current.crafts or previous[coverage] ~= previous.crafts) then
    return "Unknown"
  end
  return string.format("%+d", current[key] - previous[key])
end

local function netComparison(current, previous)
  for _, value in ipairs({ current, previous }) do
    if value.spentKnown ~= value.crafts or value.refundKnown ~= value.crafts then return "Unknown" end
  end
  return string.format("%+d", (current.spent - current.refund) - (previous.spent - previous.refund))
end

function UI.CreateOverview(overview, width, choices, onChange)
  local character, profession, days = false, false, 30
  local range = UI.Selector(overview, 0, -4, 115, UI.ranges, function(value)
    days = value
    onChange()
  end)
  local characters = UI.Selector(overview, 154, -4, 168, {}, function(value)
    character = value
    onChange()
  end)
  local professions = UI.Selector(overview, 360, -4, 168, {}, function(value)
    profession = value
    onChange()
  end)
  range:Update(UI.ranges, days)
  local chart = UI.Chart(overview, 8, -64, width - 16)
  local cards = {}
  for index = 1, 4 do
    cards[index] = UI.Text(overview, (index - 1) * width / 4 + 8,
      -270, width / 4 - 18, 130, "GameFontHighlight")
  end
  local status = UI.Text(overview, 8, -420, width - 16, 60)

  local function refresh()
    characters:Update(choices("characters", nil, true), character)
    local selection = {}
    if character then selection.characters = { character } end
    local available = choices("professions", selection, true)
    if not UI.HasChoice(available, profession) then profession = false end
    professions:Update(available, profession)
    if profession then selection.professions = { profession } end
    local from, to = UI.Range(GetServerTime(), days)
    selection.time = { from = from, to = to }
    local chartData, errorMessage = API.GetCraftSeries(selection)
    chart:Render(chartData and chartData.series or {}, from, to)
    local today = to - 86400
    local utc = date("!*t", today)
    local monthStart = today - (utc.day - 1) * 86400
    local previousMonth = date("!*t", monthStart - 86400)
    local previousStart = monthStart - previousMonth.day * 86400
    local elapsed = math.min(utc.day, previousMonth.day) * 86400
    selection.time = { from = math.min(today - 14 * 86400, previousStart), to = to }
    local comparisonData = API.GetCraftSeries(selection)
    local comparisonSeries = comparisonData and comparisonData.series or {}
    local currentWeek = summary(comparisonSeries, today - 7 * 86400, today)
    local priorWeek = summary(comparisonSeries, today - 14 * 86400, today - 7 * 86400)
    local currentMonth = summary(comparisonSeries, monthStart, to)
    local priorMonth = summary(comparisonSeries, previousStart, previousStart + elapsed)
    local display = summary(chartData and chartData.series or {}, from, to)
    local top
    for _, recipe in pairs(display.recipes) do
      if not top or recipe.count > top.count or
          (recipe.count == top.count and recipe.name < top.name) then top = recipe end
    end
    cards[1]:SetText(string.format("CRAFTS IN RANGE\n%d\nWoW %s  |  MoM %s", display.crafts,
      comparison(currentWeek, priorWeek, "crafts"), comparison(currentMonth, priorMonth, "crafts")))
    local net = display.crafts > 0 and display.spentKnown == display.crafts and
      display.refundKnown == display.crafts and
      tostring(display.spent - display.refund) or "Unknown"
    cards[2]:SetText(string.format("CONCENTRATION IN RANGE\nSpent %s\nNet %s\nWoW S%s N%s\nMoM S%s N%s",
      measured(display.spent, display.spentKnown, display.crafts), net,
      comparison(currentWeek, priorWeek, "spent", "spentKnown"),
      netComparison(currentWeek, priorWeek),
      comparison(currentMonth, priorMonth, "spent", "spentKnown"),
      netComparison(currentMonth, priorMonth)))
    cards[3]:SetText(string.format("MULTICRAFT BONUS IN RANGE\n%s\nWoW %s  |  MoM %s",
      measured(display.multi, display.multiKnown, display.crafts),
      comparison(currentWeek, priorWeek, "multi", "multiKnown"),
      comparison(currentMonth, priorMonth, "multi", "multiKnown")))
    cards[4]:SetText("MOST CRAFTED IN RANGE\n" .. (top and (top.name .. " (" .. top.count .. ")") or "None"))
    status:SetText(errorMessage or "")
  end

  return refresh
end