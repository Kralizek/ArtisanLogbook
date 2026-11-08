local _, addon = ...
local management = ArtisanLogbookManagement
if type(management) ~= "table" then return end
local callbacks = {}

local function validId(id)
  return type(id) == "number" and id > 0 and id < math.huge and id % 1 == 0
end

local function settings()
  if type(ArtisanLogbookUISettings) ~= "table" then ArtisanLogbookUISettings = {} end
  return ArtisanLogbookUISettings
end

local function collection(name)
  local stored = settings()
  if type(stored[name]) ~= "table" then stored[name] = {} end
  return stored[name]
end

local function recipeCopy(recipe)
  local copy = { id = recipe.id, name = type(recipe.name) == "string" and recipe.name or nil, maxQuality = recipe.maxQuality }
  for _, key in ipairs({ "profession", "expansion" }) do
    local value = recipe[key]
    if type(value) == "table" then
      copy[key] = { name = value.name, key = value.key, skillLineId = value.skillLineId }
    end
  end
  return copy
end

function management.RegisterPreferenceCallback(callback)
  if type(callback) ~= "function" then return nil, "invalid-callback" end
  callbacks[#callbacks + 1] = callback
  return true
end

local function changed(kind, id)
  for index, callback in ipairs(callbacks) do
    if callback then
      local ok, reason = pcall(callback, kind, id)
      if not ok then
        callbacks[index] = false
        addon.Notify("Preference refresh failed: " .. tostring(reason))
      end
    end
  end
end

function management.GetPinnedRecipes()
  local pins = {}
  for id, recipe in pairs(collection("pinnedRecipes")) do
    if validId(id) and type(recipe) == "table" then
      local copy = recipeCopy(recipe)
      copy.id = id
      pins[#pins + 1] = copy
    end
  end
  table.sort(pins, function(left, right)
    local leftName, rightName = (left.name or ("#" .. left.id)):lower(), (right.name or ("#" .. right.id)):lower()
    return leftName == rightName and left.id < right.id or leftName < rightName
  end)
  return pins
end

function management.IsRecipePinned(id)
  for _, recipe in ipairs(management.GetPinnedRecipes()) do if recipe.id == id then return true end end
  return false
end

function management.ToggleRecipePin(recipe)
  if type(recipe) ~= "table" or not validId(recipe.id) then return nil, "Unavailable recipe" end
  local pins = management.GetPinnedRecipes()
  local stored, pinned = collection("pinnedRecipes"), management.IsRecipePinned(recipe.id)
  if pinned then stored[recipe.id] = nil
  else
    if #pins >= 5 then return nil, "Five recipes are already pinned" end
    stored[recipe.id] = recipeCopy(recipe)
  end
  changed("pin", recipe.id)
  return true
end

function management.UpdatePinnedRecipe(recipe)
  if type(recipe) ~= "table" or not validId(recipe.id) then return nil, "Unavailable recipe" end
  if not management.IsRecipePinned(recipe.id) then return true end
  collection("pinnedRecipes")[recipe.id] = recipeCopy(recipe)
  changed("pin", recipe.id)
  return true
end

function management.IsRecipeHidden(id)
  return collection("hiddenRecipes")[id] == true
end

function management.SetRecipeHidden(id, hidden)
  if not validId(id) or type(hidden) ~= "boolean" then return nil, "Invalid recipe preference" end
  local wasHidden = management.IsRecipeHidden(id)
  collection("hiddenRecipes")[id] = hidden and true or nil
  if hidden ~= wasHidden then changed("hidden", id) end
  return true
end

function management.GetIgnoredReagents()
  local ids = {}
  for id, ignored in pairs(collection("trivialReagents")) do
    if ignored == true and validId(id) then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

function management.IsReagentIgnored(id)
  return collection("trivialReagents")[id] == true
end

function management.SetReagentIgnored(id, ignored)
  if not validId(id) or type(ignored) ~= "boolean" then return nil, "Invalid reagent preference" end
  local wasIgnored = management.IsReagentIgnored(id)
  collection("trivialReagents")[id] = ignored and true or nil
  if ignored ~= wasIgnored then changed("ignored", id) end
  return true
end

addon.Preferences = management
