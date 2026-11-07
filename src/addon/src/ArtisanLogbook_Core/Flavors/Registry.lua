local _, addon = ...

local adapters = {}
local projectConstants = {
  { "WOW_PROJECT_CAMELOT", "forever" },
  { "WOW_PROJECT_MAINLINE", "retail" },
  { "WOW_PROJECT_CLASSIC", "classic" },
  { "WOW_PROJECT_BURNING_CRUSADE_CLASSIC", "burning-crusade-classic" },
  { "WOW_PROJECT_WRATH_CLASSIC", "wrath-classic" },
  { "WOW_PROJECT_CATACLYSM_CLASSIC", "cataclysm-classic" },
  { "WOW_PROJECT_MISTS_CLASSIC", "mists-classic" },
}

function addon.RegisterFlavorAdapter(projectID, name, factory)
  if projectID ~= nil and type(factory) == "function" then
    adapters[projectID] = { name = name, factory = factory }
  end
end

function addon.DetectFlavor(api)
  for _, project in ipairs(projectConstants) do
    local projectID = api[project[1]]
    if projectID ~= nil and api.WOW_PROJECT_ID == projectID then
      return project[2], projectID
    end
  end
  return "other", api.WOW_PROJECT_ID
end

function addon.CreateFlavorAdapter(api, handleEvent, submitCraft, invalidateCraft)
  if addon.RegisterRetailAdapter then
    addon.RegisterRetailAdapter(api)
  end
  if addon.RegisterForeverAdapter then
    addon.RegisterForeverAdapter(api)
  end
  local flavor, projectID = addon.DetectFlavor(api)
  local registered = adapters[projectID]
  if registered and registered.name == flavor then
    return registered.factory(api, handleEvent, submitCraft, invalidateCraft)
  end
  return {
    capabilities = {
      flavor = flavor,
      projectID = projectID,
      events = {},
      hooks = {},
      measurements = {},
    },
  }
end
