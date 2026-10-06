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