local addonName, addon = ...
local lifecycle = CreateFrame("Frame")
local unknownRecipeRecoveryNotified
local initialized
local unavailableReason

function addon.Notify(message)
  DEFAULT_CHAT_FRAME:AddMessage("Artisan Logbook: " .. message)
end

function addon.NotifyCraft(craft)
  local item = craft.outputItem
  local output = addon.UI.Name(item, "Unknown item")
  if item and item.id then
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local link
    if type(getInfo) == "function" then
      local ok, _, cachedLink = pcall(getInfo, item.id)
      if ok then link = cachedLink end
    end
    output = link or ("|Hitem:" .. item.id .. "|h[" .. output .. "]|h")
  end
  if craft.outputQuantity ~= nil then output = output .. "x" .. craft.outputQuantity end
  local message = "Crafted " .. output .. " from " .. addon.UI.Name(craft.recipe, "Unknown recipe")
  if not craft.recipe and not unknownRecipeRecoveryNotified then
    unknownRecipeRecoveryNotified = true
    message = message .. " (Recipe unknown; if it remains unresolved, recovery will be attempted after /reload.)"
  end
  local highlights = addon.UI.CraftHighlights(craft)
  if #highlights > 0 then message = message .. " (" .. table.concat(highlights, "; ") .. ")" end
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Artisan Logbook:|r " .. message)
end

lifecycle:RegisterEvent("ADDON_LOADED")
lifecycle:SetScript("OnEvent", function(_, _, loadedName)
  if loadedName ~= addonName or initialized then return end
  lifecycle:UnregisterEvent("ADDON_LOADED")
  local api = ArtisanLogbookAPI
  local management = ArtisanLogbookManagement
  local ok, version = pcall(function() return api.GetVersion() end)
  if not ok or version ~= 1 or type(management) ~= "table" then
    addon.Notify("Compatible Artisan Logbook Core API v1 is required.")
    return
  end
  local ready, reason = addon.UI.CheckPrimitives()
  if not ready then
    unavailableReason = reason .. ". Enable Blizzard UI addons, disable UI replacements and /reload."
    addon.Notify(unavailableReason); return
  end
  local created, errorMessage = pcall(addon.CreateProductionWindow)
  if not created then
    if addon.productionWindow then addon.productionWindow:Hide(); addon.productionWindow = nil end
    unavailableReason = "Production UI could not initialize: " .. tostring(errorMessage) ..
      " Enable Blizzard UI addons, disable UI replacements and /reload."
    addon.Notify(unavailableReason); return
  end
  api.RegisterCallback("CRAFT_COMMITTED", addon.NotifyCraft)
  initialized = true
  local metadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
  local addonVersion = type(metadata) == "function" and metadata(addonName, "Version") or nil
  addon.Notify("Loaded (version " .. (addonVersion or "Unknown") .. ").")
end)

SLASH_ARTISANLOGBOOK1 = "/al"
SLASH_ARTISANLOGBOOK2 = "/artisanlogbook"
SlashCmdList.ARTISANLOGBOOK = function()
  if addon.productionWindow then
    addon.productionWindow:Show()
  else
    addon.Notify(unavailableReason or "Compatible Artisan Logbook Core API v1 is required.")
  end
end