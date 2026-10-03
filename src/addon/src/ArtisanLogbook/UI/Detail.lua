local _, addon = ...
local UI = addon.UI

function UI.CraftDetail(parent, width, height, goBack)
  local detail = CreateFrame("Frame", nil, parent)
  detail:SetAllPoints(parent)
  local heading = UI.Text(detail, 16, -8, width - 120, 28, "GameFontNormalLarge")
  UI.Button(detail, "Back", width - 92, -8, 76, goBack)
  local scroll = CreateFrame("ScrollFrame", nil, detail, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 18, -44)
  scroll:SetPoint("BOTTOMRIGHT", -36, 16)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetWidth(width - 75)
  local text = UI.Text(content, 0, 0, width - 75, height, "GameFontHighlight")
  scroll:SetScrollChild(content)

  function detail:ShowCraft(id)
    local craft, reason = ArtisanLogbookAPI.GetCraft(id)
    if not craft then
      heading:SetText("Craft unavailable")
      text:SetText(reason or "Unknown craft")
      content:SetHeight(40)
      return
    end
    heading:SetText(UI.Name(craft.recipe, "Unattributed craft") .. "  #" .. craft.id)
    local lines = {}
    local function section(title)
      lines[#lines + 1] = ""
      lines[#lines + 1] = title
    end
    local function field(title, value)
      lines[#lines + 1] = title .. ": " .. UI.Value(value)
    end
    section("Craft")
    field("Time", date("%Y-%m-%d %H:%M:%S", craft.timestamp))
    field("Character", UI.CharacterName(craft.character))
    field("Realm", UI.Name(craft.realm))
    field("Profession", UI.Name(craft.profession))
    field("Recipe", UI.Name(craft.recipe))
    field("Expansion", UI.Name(craft.expansion))
    field("Output", UI.Name(craft.outputItem))
    field("Quantity", craft.outputQuantity)
    field("Quality", craft.outputQuality)
    field("Item level", craft.outputItemLevel)
    local highlights = UI.CraftHighlights(craft)
    if #highlights > 0 then
      section("Craft activity")
      for _, highlight in ipairs(highlights) do lines[#lines + 1] = highlight end
    end
    if craft.request then
      section("Personal craft request")
      field("Request ID", craft.request.id)
      field("Submitted", date("%Y-%m-%d %H:%M:%S", craft.request.timestamp))
      field("Requested recipe", UI.Name(craft.request.recipe))
      field("Requested count", craft.request.requestedCount)
      field("Use concentration", craft.request.useConcentration)
      field("Quoted concentration", craft.request.concentrationCost)
      field("Base skill", craft.request.baseSkill)
      field("Base difficulty", craft.request.baseDifficulty)
      field("Expected quality", craft.request.craftingQuality)
    end
    if #craft.reagents > 0 then
      section("Reagents and returns")
      for _, reagent in ipairs(craft.reagents) do
        lines[#lines + 1] = UI.ReagentDescription(reagent)
      end
    end
    section("Identity")
    field("Game operation ID", craft.gameOperationId)
    text:SetText(table.concat(lines, "\n"))
    local contentHeight = math.max(scroll:GetHeight(), text:GetStringHeight() + 24)
    content:SetHeight(contentHeight)
    text:SetHeight(contentHeight)
    scroll:UpdateScrollChildRect()
    scroll:SetVerticalScroll(0)
  end
  detail:Hide()
  return detail
end