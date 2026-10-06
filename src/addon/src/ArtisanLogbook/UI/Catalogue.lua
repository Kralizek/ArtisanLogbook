local _, addon = ...
local UI = addon.UI

function UI.CataloguePage(page, width, height, openRecipe)
  UI.Section(page, "Recipes", 0, -2, width)
  local character, profession, sort = false, false, "name"
  local filterWidth = math.min(174, (width - 72) / 3)
  local characters = UI.Selector(page, 0, -42, filterWidth, {}, function(value)
    character, profession = value, false; page:Refresh(true)
  end, "Character")
  local professions = UI.Selector(page, filterWidth + 32, -42, filterWidth, {}, function(value)
    profession = value; page:Refresh(true)
  end, "Profession")
  local sorts = UI.Selector(page, 2 * (filterWidth + 32), -42, filterWidth, {
    { label = "Recipe name", value = "name" }, { label = "Profession", value = "profession" },
    { label = "Most crafted", value = "count" },
  }, function(value) sort = value; page:Refresh(true) end, "Sort")
  local availableWidth = width - 24
  local list = UI.ScrollList(page, 0, -110, width, height - 110, {
    { title = "Recipe", width = availableWidth * .53, value = function(row) return UI.Name(row.recipe) end,
      icon = function(row) return UI.RecipeIcon(row.recipe) end },
    { title = "Profession", width = availableWidth * .32, value = function(row) return UI.Name(row.profession) end },
    { title = "Crafts", width = availableWidth * .15, value = function(row) return tostring(row.craftCount) end },
  }, function(row) openRecipe(row.recipe) end, "No recipes in this selection")
  page.catalogue = list
  UI.LazyList(list, function(cursor)
    local result, reason = ArtisanLogbookAPI.GetRecipeSummaries({ character = character or nil,
      profession = profession or nil, sort = sort, limit = 40, cursor = cursor })
    return result and result.recipes, result and result.nextCursor or reason
  end)
  function page:Refresh(reset, preserve)
    characters:Update(UI.Choices("characters"), character)
    local available = UI.Choices("professions", character)
    if not UI.HasChoice(available, profession) then profession = false end
    professions:Update(available, profession)
    sorts:Update(sorts.choices, sort)
    if reset or not self.loaded then list:Reload(preserve) end
    self.loaded = true
  end
  function page:Open()
    if not self.loaded or self.dirty then self:Refresh(self.dirty, true); self.dirty = false end
  end
end

function UI.ReagentAmount(row, amount, complete)
  if row[amount] == nil then return "Unknown" end
  return tostring(row[amount]) .. (row[complete] and "" or " (partial)")
end

function UI.ReagentsPage(page, width, height)
  UI.Section(page, "Reagents", 0, -2, width)
  local profession, trivial, sort, search = false, "all", "name", ""
  local filterWidth = (width - 84) / 4
  local professions = UI.Selector(page, 0, -42, filterWidth, {}, function(value)
    profession = value; page:Refresh(true)
  end, "Profession")
  local trivialChoices = {
    { label = "All", value = "all" }, { label = "Trivial", value = "trivial" },
    { label = "Non-trivial", value = "non-trivial" },
  }
  local trivialFilter = UI.Selector(page, filterWidth + 28, -42, filterWidth, trivialChoices, function(value)
    trivial = value; page:Refresh(true)
  end, "Trivial state")
  UI.Text(page, 2 * (filterWidth + 28), -42, filterWidth, 16, "GameFontNormalSmall"):SetText("Search")
  local searchInput = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
  searchInput:SetPoint("TOPLEFT", 2 * (filterWidth + 28) + 4, -60)
  searchInput:SetSize(filterWidth - 4, 24)
  searchInput:SetAutoFocus(false)
  searchInput:SetMaxLetters(120)
  searchInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  searchInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  searchInput:SetScript("OnTextChanged", function(self)
    page.pendingSearch = self:GetText()
    page.searchDelay = .2
    page:SetScript("OnUpdate", function(self, elapsed)
      self.searchDelay = self.searchDelay - elapsed
      if self.searchDelay <= 0 then self:SetScript("OnUpdate", nil); self:Refresh(true) end
    end)
  end)
  page.searchInput = searchInput
  local sorts = UI.Selector(page, 3 * (filterWidth + 28), -42, filterWidth, {
    { label = "Name", value = "name" }, { label = "Most allocated", value = "allocated" },
    { label = "Most returned", value = "returned" }, { label = "Recipe count", value = "recipes" },
  }, function(value) sort = value; page:Refresh(true) end, "Sort")
  local available = width - 24
  local nameWidth = available * .31
  local function professionNames(row)
    local names = {}
    for _, entry in ipairs(row.professions) do names[#names + 1] = UI.Name(entry) end
    return #names > 0 and table.concat(names, ", ") or "Unknown"
  end
  local list = UI.ScrollList(page, 0, -110, width, height - 144, {
    { title = "Reagent", width = nameWidth, value = function(row)
        return UI.Name(row.item) .. " (#" .. row.item.id .. ")"
      end,
      create = function(parent, left)
        local cell = CreateFrame("Frame", nil, parent)
        cell:SetPoint("TOPLEFT", left, 0); cell:SetSize(nameWidth, 28)
        cell.icon = cell:CreateTexture(nil, "ARTWORK")
        cell.icon:SetSize(22, 22); cell.icon:SetPoint("TOPLEFT", 2, -3)
        cell.quality = cell:CreateTexture(nil, "OVERLAY")
        cell.quality:SetSize(14, 14); cell.quality:SetPoint("TOPLEFT", 12, -14)
        cell.name = UI.Text(cell, 30, -1, nameWidth - 34, 14)
        cell.name:SetWordWrap(false)
        cell.identity = UI.Text(cell, 30, -15, nameWidth - 34, 13)
        return cell
      end,
      update = function(cell, row)
        local icon = type(GetItemIcon) == "function" and GetItemIcon(row.item.id)
        cell.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        cell.name:SetText(UI.Elide(UI.Name(row.item), math.max(3, math.floor((nameWidth - 34) / 7))))
        cell.identity:SetText("#" .. row.item.id .. (row.quality ~= nil and " | Quality " .. row.quality or ""))
        local quality
        if C_TradeSkillUI and type(C_TradeSkillUI.GetItemReagentQualityInfo) == "function" then
          local ok, info = pcall(C_TradeSkillUI.GetItemReagentQualityInfo, row.item.id)
          if ok then quality = info end
        end
        cell.quality:SetShown(quality ~= nil and quality.icon ~= nil)
        if quality and quality.icon then cell.quality:SetAtlas(quality.icon) end
      end },
    { title = "Profession(s)", width = available * .24, value = professionNames,
      icon = function(row) return UI.ProfessionIcon(row.professions[1] and row.professions[1].skillLineId) end },
    { title = "Recipes", width = available * .09, value = function(row) return tostring(row.recipeCount) end },
    { title = "Allocated", width = available * .14, value = function(row)
      return UI.ReagentAmount(row, "allocatedQuantity", "allocationComplete")
    end },
    { title = "Returned", width = available * .13, value = function(row)
      return UI.ReagentAmount(row, "returnedQuantity", "returnComplete")
    end },
    { title = "Trivial", width = available * .09, value = function(row) return UI.IsTrivial(row.item.id) and "Yes" or "No" end,
      create = function(parent, left)
        local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        check:SetPoint("TOPLEFT", left + 8, -2); check:SetSize(24, 24)
        check:SetScript("OnClick", function(self) UI.SetTrivial(self.itemId, self:GetChecked() == true) end)
        check:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:SetText("Trivial reagent #" .. self.itemId)
          GameTooltip:AddLine("Excluded from non-trivial return statistics", 1, 1, 1)
          GameTooltip:Show()
        end)
        check:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return check
      end,
      update = function(check, row) check.itemId = row.item.id; check:SetChecked(UI.IsTrivial(row.item.id)) end },
  }, function() end, "No recorded reagents in this selection")
  page.catalogue = list
  UI.Text(page, 0, -height + 26, width, 22):SetText("Allocated: retained craft facts. Returned: recorded totals.")
  local selectedItems, excludedItems
  UI.LazyList(list, function(cursor)
    local result, reason = ArtisanLogbookAPI.GetReagentSummaries({ profession = profession or nil,
      search = search, sort = sort, items = selectedItems, excludeItems = excludedItems, limit = 40, cursor = cursor })
    return result and result.reagents, result and result.nextCursor or reason
  end)
  function page:Refresh(reset, preserve)
    self:SetScript("OnUpdate", nil)
    if self.pendingSearch ~= nil then search = self.pendingSearch; self.pendingSearch = nil end
    professions:Update(UI.Choices("professions"), profession)
    trivialFilter:Update(trivialChoices, trivial)
    sorts:Update(sorts.choices, sort)
    selectedItems = trivial == "trivial" and UI.TrivialItemIds() or nil
    excludedItems = trivial == "non-trivial" and UI.TrivialItemIds() or nil
    if reset or not self.loaded then list:Reload(preserve) end
    self.loaded, self.dirty = true, false
  end
  function page:Open()
    if self.pendingSearch ~= nil then self:Refresh(true)
    elseif not self.loaded or self.dirty then self:Refresh(true, true) end
  end
  UI.RegisterTrivialCallback(function()
    page.dirty = true
    if page:IsShown() then page:Refresh(true, true) end
  end)
end