local _, addon = ...
local UI = addon.UI

local function measured(total, observed, crafts)
  if observed == 0 then return "Unknown" end
  if observed < crafts then return total .. " measured of " .. observed .. " crafts" end
  return tostring(total)
end

function UI.CreateLogbookSummary(parent, width)
  local cards = {}
  local titles = { "Crafts", "Concentration spent", "Multicraft bonus", "Most crafted" }
  local cardWidth = (width - 30) / 4
  for index, title in ipairs(titles) do
    local card = CreateFrame("Frame", nil, parent, "InsetFrameTemplate3")
    card:SetSize(cardWidth, 76)
    card:SetPoint("TOPLEFT", (index - 1) * (cardWidth + 10), -250)
    UI.Text(card, 10, -9, cardWidth - 20, 18, "GameFontNormalSmall"):SetText(title)
    cards[index] = UI.Text(card, 10, -31, cardWidth - 20, 35, "GameFontHighlight")
    cards[index]:SetWordWrap(false)
    cards[index]:SetMaxLines(1)
  end

  return function(series)
    local crafts, spent, spentKnown, multi, multiKnown = 0, 0, 0, 0, 0
    local recipes = {}
    for _, row in ipairs(series or {}) do
      crafts = crafts + row.craftCount
      spent = spent + (row.concentrationSpent or 0)
      spentKnown = spentKnown + (row.concentrationSpentObservedCount or 0)
      multi = multi + (row.multicraftBonus or 0)
      multiKnown = multiKnown + (row.multicraftBonusObservedCount or 0)
      if row.recipe and row.recipe.id then
        local entry = recipes[row.recipe.id] or { name = UI.Name(row.recipe), count = 0 }
        entry.count = entry.count + row.craftCount
        recipes[row.recipe.id] = entry
      end
    end
    local top
    for _, entry in pairs(recipes) do
      if not top or entry.count > top.count or
          (entry.count == top.count and entry.name < top.name) then top = entry end
    end
    cards[1]:SetText(tostring(crafts))
    cards[2]:SetText(UI.Elide(measured(spent, spentKnown, crafts), 25))
    cards[3]:SetText(UI.Elide(measured(multi, multiKnown, crafts), 25))
    cards[4]:SetText(top and UI.Elide(top.name, 22) or "None yet")
  end
end