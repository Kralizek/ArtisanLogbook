local addonName, addon = ...
local lifecycle = CreateFrame("Frame")

function addon.Notify(message)
  DEFAULT_CHAT_FRAME:AddMessage("Artisan Logbook: " .. message)
end

lifecycle:RegisterEvent("ADDON_LOADED")
lifecycle:SetScript("OnEvent", function(_, _, loadedName)
  if loadedName ~= addonName then return end
  lifecycle:UnregisterEvent("ADDON_LOADED")
  local api = ArtisanLogbookAPI
  local management = ArtisanLogbookManagement
  local ok, version = pcall(function() return api.GetVersion() end)
  if not ok or version ~= 1 or type(management) ~= "table" then
    addon.Notify("Compatible Artisan Logbook Core API v1 is required.")
    return
  end
  addon.CreateProductionWindow()
end)

SLASH_ARTISANLOGBOOK1 = "/al"
SLASH_ARTISANLOGBOOK2 = "/artisanlogbook"
SlashCmdList.ARTISANLOGBOOK = function()
  if addon.productionWindow then
    addon.productionWindow:Show()
  else
    addon.Notify("Compatible Artisan Logbook Core API v1 is required.")
  end
end