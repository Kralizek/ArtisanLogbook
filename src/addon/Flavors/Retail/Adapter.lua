local _, addon = ...

local events = {
  "TRADE_SKILL_CRAFT_BEGIN",
  "TRADE_SKILL_ITEM_CRAFTED_RESULT",
  "TRADE_SKILL_CURRENCY_REWARD_RESULT",
  "UPDATE_TRADESKILL_CAST_STOPPED",
  "TRADE_SKILL_SHOW",
  "TRADE_SKILL_CLOSE",
  "CRAFTING_DETAILS_UPDATE",
  "UNIT_SPELLCAST_SENT",
  "UNIT_SPELLCAST_START",
  "UNIT_SPELLCAST_SUCCEEDED",
  "UNIT_SPELLCAST_STOP",
  "UNIT_SPELLCAST_FAILED",
  "UNIT_SPELLCAST_FAILED_QUIET",
  "UNIT_SPELLCAST_INTERRUPTED",
  "UNIT_SPELLCAST_DELAYED",
  "UNIT_SPELLCAST_CHANNEL_START",
  "UNIT_SPELLCAST_CHANNEL_STOP",
  "CURRENCY_DISPLAY_UPDATE",
  "UI_ERROR_MESSAGE",
  "PLAYER_LOGOUT",
}

local craftFunctions = {
  "CraftRecipe",
  "CraftEnchant",
  "CraftSalvage",
  "RecraftRecipe",
  "RecraftRecipeForOrder",
}

local function createRetailAdapter(api, emit)
  local capabilities = { events = {}, hooks = {}, measurements = {} }
  local adapter = { capabilities = capabilities }
  capabilities.flavor = "retail"
  capabilities.secretValueDetection = type(api.issecretvalue) == "function"

  local function forward(event, ...)
    local ok = pcall(emit, event, ...)
    if not ok then
      capabilities.captureError = true
    end
  end

  local frame = api.CreateFrame("Frame")
  adapter.frame = frame
  for _, event in ipairs(events) do
    local ok
    if event:sub(1, 5) == "UNIT_" then
      ok = pcall(frame.RegisterUnitEvent, frame, event, "player")
    else
      ok = pcall(frame.RegisterEvent, frame, event)
    end
    capabilities.events[event] = ok and frame:IsEventRegistered(event) == true
  end
  frame:SetScript("OnEvent", function(_, event, ...)
    forward(event, ...)
  end)

  for _, name in ipairs(craftFunctions) do
    local hookedName = name
    if type(api.hooksecurefunc) == "function" and type(api.C_TradeSkillUI) == "table" and
        type(api.C_TradeSkillUI[name]) == "function" then
      capabilities.hooks[name] = pcall(api.hooksecurefunc, api.C_TradeSkillUI, name, function(...)
        forward("CALL_POST:C_TradeSkillUI." .. hookedName, ...)
      end)
    else
      capabilities.hooks[name] = false
    end
  end
  return adapter
end

function addon.RegisterRetailAdapter(api)
  if addon.RegisterFlavorAdapter and api.WOW_PROJECT_MAINLINE ~= nil and
      api.WOW_PROJECT_ID == api.WOW_PROJECT_MAINLINE then
    addon.RegisterFlavorAdapter(api.WOW_PROJECT_MAINLINE, "retail", createRetailAdapter)
  end
end