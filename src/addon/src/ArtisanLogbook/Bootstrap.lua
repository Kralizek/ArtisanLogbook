local addonName, addon = ...
local lifecycle = CreateFrame("Frame")

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
  local highlights = addon.UI.CraftHighlights(craft)
  if #highlights > 0 then message = message .. " (" .. table.concat(highlights, "; ") .. ")" end
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Artisan Logbook:|r " .. message)
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
  api.RegisterCallback("CRAFT_COMMITTED", addon.NotifyCraft)
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