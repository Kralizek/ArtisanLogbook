local _, addon = ...
local UI = addon.UI
local Tooltip = {}
UI.Tooltip = Tooltip
local targets = setmetatable({}, { __mode = "k" })
local lifecycle

Tooltip.colors = {
  heading = { 1, .82, 0 }, value = { 1, 1, 1 }, muted = { .6, .6, .6 },
  label = { .5, .7, 1 },
  positive = { .2, 1, .4 }, partial = { 1, .65, .2 }, error = { 1, .2, .2 },
}

function Tooltip.Begin(owner, title)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  local color = Tooltip.colors.heading
  GameTooltip:SetText(UI.Elide(title, 90), color[1], color[2], color[3], 1, true)
  Tooltip.owner = owner
end

function Tooltip.Subtitle(text, style)
  if not text or text == "" then return end
  local color = Tooltip.colors[style or "value"]
  GameTooltip:AddLine(text, color[1], color[2], color[3], true)
end

function Tooltip.Section(title)
  GameTooltip:AddLine(" ")
  local color = Tooltip.colors.heading
  GameTooltip:AddLine(title, color[1], color[2], color[3])
end

function Tooltip.Row(label, value, style)
  local labelColor, valueColor = Tooltip.colors.label, Tooltip.colors[style or "value"]
  GameTooltip:AddDoubleLine(label .. ":", UI.Elide(tostring(value), 52),
    labelColor[1], labelColor[2], labelColor[3], valueColor[1], valueColor[2], valueColor[3])
end

function Tooltip.Show()
  GameTooltip:Show()
end

function Tooltip.Hide(owner)
  if Tooltip.owner ~= owner then return end
  if not GameTooltip.IsOwned or GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
  Tooltip.owner = nil
end

local function within(frame, ancestor)
  while frame do
    if frame == ancestor then return true end
    frame = frame:GetParent()
  end
  return false
end

function Tooltip.ReleaseTree(frame)
  if lifecycle and lifecycle.pendingOwner and within(lifecycle.pendingOwner, frame) then
    lifecycle:SetScript("OnUpdate", nil)
    lifecycle.pendingOwner = nil
  end
  local owner = Tooltip.owner
  if owner and within(owner, frame) then
    if targets[owner] then targets[owner].hovered = false end
    Tooltip.Hide(owner)
  end
end

function Tooltip.CanEnter(owner)
  local current = Tooltip.owner
  return not (current and current ~= owner and within(current, owner) and
    targets[current] and targets[current].hovered)
end

function Tooltip.Bind(owner, present)
  if not lifecycle then lifecycle = CreateFrame("Frame"); Tooltip.lifecycle = lifecycle end
  if targets[owner] then targets[owner].present = present; return end
  targets[owner] = { present = present }
  owner:SetScript("OnEnter", function(self)
    lifecycle:SetScript("OnUpdate", nil)
    lifecycle.pendingOwner = nil
    targets[self].hovered = true
    if Tooltip.CanEnter(self) then targets[self].present(self) end
  end)
  owner:SetScript("OnLeave", function(self)
    targets[self].hovered = false
    if Tooltip.owner ~= self then return end
    lifecycle.pendingOwner = self
    lifecycle:SetScript("OnUpdate", function(worker)
      worker:SetScript("OnUpdate", nil)
      worker.pendingOwner = nil
      if Tooltip.owner ~= self then return end
      local parent = self:GetParent()
      while parent do
        local state = targets[parent]
        if state and parent:IsShown() and type(parent.IsMouseOver) == "function" and parent:IsMouseOver() then
          state.hovered = true
          state.present(parent)
          return
        end
        parent = parent:GetParent()
      end
      Tooltip.Hide(self)
    end)
  end)
  owner:HookScript("OnHide", function(self) Tooltip.ReleaseTree(self) end)
end

function Tooltip.Scope(filter)
  filter = filter or {}
  local period = "All time"
  if filter.time then
    local from = filter.time.from and date("!%Y-%m-%d", filter.time.from) or "Start"
    local to = filter.time.to and date("!%Y-%m-%d", filter.time.to - 1) or "Present"
    period = from .. " to " .. to .. " (UTC)"
  end
  local function names(selection, entries, key, fallback)
    if not selection then return "All " .. fallback end
    if #selection == 0 then return "No " .. fallback end
    local selected = {}
    for index, id in ipairs(selection) do
      if index > 2 then selected[#selected + 1] = "+" .. (#selection - 2) .. " more"; break end
      local name = "Unknown"
      for _, entry in ipairs(entries or {}) do
        if entry[key] == id then
          name = UI.Elide(UI.Name(entry), 40)
          if key == "key" then name = UI.CharacterName({ name = name, classFile = entry.classFile }) end
          break
        end
      end
      selected[#selected + 1] = name
    end
    return table.concat(selected, ", ")
  end
  Tooltip.Subtitle("Period: " .. period)
  Tooltip.Subtitle("Character: " .. names(filter.characters, ArtisanLogbookAPI.GetCharacters(), "key", "characters"))
  Tooltip.Subtitle("Profession: " .. names(filter.professions, ArtisanLogbookAPI.GetProfessions(), "skillLineId", "professions"))
end

local function measuredTotal(totals, metric, label)
  local count, crafts = totals[metric .. "ObservedCount"] or 0, totals.craftCount or 0
  local value = totals[metric]
  if count == 0 or value == nil then Tooltip.Row(label, "Not available", "muted"); return end
  Tooltip.Row(label, UI.Number(value, true) .. (count < crafts and " known" or ""),
    count < crafts and "partial" or metric == "multicraftBonus" and value > 0 and "positive" or "value")
  if count < crafts then Tooltip.Subtitle(UI.Count(count, "measured craft") .. " of " .. UI.Number(crafts), "partial") end
end

local function procRate(totals, metric, label)
  local count, observed, crafts = totals[metric], totals[metric .. "ObservedCount"] or 0, totals.craftCount or 0
  if observed == 0 or count == nil then Tooltip.Row(label, "Not available", "muted"); return end
  Tooltip.Row(label, UI.Percent(count, observed), observed < crafts and "partial" or count > 0 and "positive" or "muted")
  if observed < crafts then
    Tooltip.Subtitle(UI.Count(observed, "measured craft") .. " of " .. UI.Number(crafts), "partial")
  end
end

function UI.RecipeTooltip(owner, recipe, filter)
  filter = filter or {}
  Tooltip.Begin(owner, UI.Name(recipe, "Unattributed recipe"))
  local context = {}
  if recipe and recipe.profession then context[#context + 1] = UI.Name(recipe.profession) end
  if recipe and recipe.expansion then context[#context + 1] = UI.Name(recipe.expansion) end
  Tooltip.Subtitle(table.concat(context, " - "))
  Tooltip.Scope(filter)
  if not recipe or not recipe.id then
    Tooltip.Subtitle("History not available", "muted"); Tooltip.Show(); return
  end
  local historyFilter = { recipes = { recipe.id }, time = filter.time,
    characters = filter.characters, professions = filter.professions }
  local history = ArtisanLogbookAPI.GetCraftSeries(historyFilter)
  if not history then Tooltip.Subtitle("History not available", "muted"); Tooltip.Show(); return end
  local characters, characterCount, unknownCharacters, crafts, lastDay = {}, 0, false, 0, nil
  for _, row in ipairs(history.series) do
    crafts = crafts + row.craftCount
    if not lastDay or row.bucketStart > lastDay then lastDay = row.bucketStart end
    local key = row.character and row.character.key
    if key then
      if not characters[key] then characters[key] = true; characterCount = characterCount + 1 end
    else unknownCharacters = true end
  end
  local outcome = crafts > 0 and ArtisanLogbookAPI.GetRecipeOutcomes(recipe.id,
    { time = filter.time, characters = filter.characters }, { buckets = 1 }) or nil
  local totals = outcome and outcome.totals.craftCount == crafts and outcome.totals or { craftCount = crafts }
  local latest = crafts > 0 and ArtisanLogbookAPI.GetCrafts(historyFilter, { limit = 1 }) or nil
  local craft = latest and latest.crafts[1]
  Tooltip.Section("Crafting History")
  Tooltip.Row("Total crafts", UI.Number(crafts, true))
  if craft then Tooltip.Row("Last crafted (retained)", UI.DateTime(craft.timestamp, true))
  elseif lastDay then Tooltip.Row("Last craft day (UTC)", date("!%Y-%m-%d", lastDay), "partial")
  else Tooltip.Row("Last crafted", "Not available", "muted") end
  Tooltip.Row("Characters", UI.Number(characterCount, true) .. (unknownCharacters and " known" or ""),
    unknownCharacters and "partial" or "value")
  measuredTotal(totals, "outputQuantity", "Total produced")
  if crafts > 0 then
    Tooltip.Section("Crafting Outcomes")
    procRate(totals, "multicraftProcCount", "Multicraft procs")
    measuredTotal(totals, "multicraftBonus", "Extra output")
    procRate(totals, "resourcefulnessAuthoritativeProcCount", "Resourcefulness")
    local raw = totals.resourcefulnessProcCount
    local authoritative = totals.resourcefulnessAuthoritativeProcCount
    if raw and raw > (authoritative or 0) then
      Tooltip.Subtitle(UI.Count(raw, "known return proc") .. "; includes unverified history", "partial")
    end
    procRate(totals, "ingenuityProcCount", "Ingenuity")
  end
  Tooltip.Show()
end

local function craftProc(label, observed, detail)
  if observed == nil then Tooltip.Row(label, "Not recorded", "muted")
  elseif observed then Tooltip.Row(label, detail or "Triggered", "positive")
  else Tooltip.Row(label, "No proc", "muted") end
end

function UI.CraftTooltip(owner, craft)
  Tooltip.Begin(owner, UI.Name(craft.recipe, "Unattributed craft"))
  Tooltip.Subtitle((craft.character and UI.CharacterName(craft.character) or "Character not recorded") .. " - " ..
    UI.Name(craft.profession, "Profession not recorded"))
  Tooltip.Section("Craft Details")
  Tooltip.Row("Date", craft.timestamp and UI.DateTime(craft.timestamp, true) or "Not recorded",
    craft.timestamp and "value" or "muted")
  Tooltip.Row("Quality", craft.outputQuality ~= nil and "Rank " .. craft.outputQuality or "Not recorded",
    craft.outputQuality ~= nil and "value" or "muted")
  Tooltip.Row("Concentration", craft.concentrationSpent ~= nil and UI.Number(craft.concentrationSpent, true) or "Not recorded",
    craft.concentrationSpent ~= nil and "value" or "muted")
  Tooltip.Section("Results")
  Tooltip.Row("Output", UI.Name(craft.outputItem, "Item not recorded"), craft.outputItem and "value" or "muted")
  Tooltip.Row("Produced", craft.outputQuantity ~= nil and UI.Number(craft.outputQuantity, true) or "Not recorded",
    craft.outputQuantity ~= nil and "value" or "muted")
  local multicraft
  if craft.multicraftBonus ~= nil then multicraft = craft.multicraftBonus > 0 end
  craftProc("Multicraft", multicraft,
    craft.multicraftBonus and "+" .. UI.Number(craft.multicraftBonus, true) .. " extra")
  local observed = craft.hasResourcefulnessProc
  local returns = {}
  for _, row in ipairs(UI.CraftIngredients(craft)) do
    if row.returned and row.returned > 0 then returns[#returns + 1] = row end
  end
  if #returns > 0 then observed = true end
  craftProc("Resourcefulness", observed)
  craftProc("Ingenuity", craft.hasIngenuityProc,
    craft.ingenuityRefund and craft.ingenuityRefund > 0 and "+" .. UI.Number(craft.ingenuityRefund, true) .. " refunded")
  if #returns > 0 then
    Tooltip.Section("Materials Returned")
    for index = 1, math.min(2, #returns) do
      local row = returns[index]
      Tooltip.Row(UI.Elide(row.name, 36), "x" .. UI.Number(row.returned, true), "positive")
    end
    if #returns > 2 then Tooltip.Subtitle("+" .. (#returns - 2) .. " more materials") end
  end
  if craft.resourcefulnessComplete ~= true and (observed == true or #returns > 0) then
    Tooltip.Subtitle("Partial return record; other returns may be missing", "partial")
  end
  Tooltip.Show()
end