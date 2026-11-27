local addonName, addon = ...
local lifecycle = CreateFrame("Frame")
local unknownCraftNotified
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
  local unknown = not craft.recipe or craft.requestCorrelationReason == "ownership-quarantine"
  local dialog = unknown and not unknownCraftNotified and type(StaticPopupDialogs) == "table" and
    type(StaticPopup_Show) == "function"
  if unknown and not unknownCraftNotified and not dialog then
    message = message .. " (Recipe unknown; if it remains unresolved, recovery will be attempted after /reload.)"
  end
  local highlights = addon.UI.CraftHighlights(craft)
  if #highlights > 0 then message = message .. " (" .. table.concat(highlights, "; ") .. ")" end
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Artisan Logbook:|r " .. message)
  if unknown and not unknownCraftNotified then
    unknownCraftNotified = true
    if dialog then addon.ShowUnknownCraftDialog(craft) end
  end
end

function addon.UnknownCraftMessage(craft)
  if craft.requestCorrelationReason == "ownership-quarantine" then
    return "Artisan Logbook couldn't match a craft to the request that made it, so it was recorded as " ..
      "unknown. This can happen after an interrupted or replaced craft. Until you reload, this " ..
      "character's crafts are recorded without verified recipe and outcome details.\n\nReload now?"
  end
  return "Artisan Logbook couldn't identify the recipe for a craft, so it was recorded as Unknown. " ..
    "It will try to identify the recipe again after a reload.\n\nReload now?"
end

-- Shown once per UI session, for the first craft recorded as unknown.
function addon.ShowUnknownCraftDialog(craft)
  StaticPopupDialogs.ARTISANLOGBOOK_UNKNOWN_CRAFT = StaticPopupDialogs.ARTISANLOGBOOK_UNKNOWN_CRAFT or {
    text = "%s",
    button1 = "Reload now",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
  StaticPopup_Show("ARTISANLOGBOOK_UNKNOWN_CRAFT", addon.UnknownCraftMessage(craft))
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