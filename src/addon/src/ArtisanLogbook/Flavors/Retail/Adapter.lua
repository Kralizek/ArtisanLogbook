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

local quoteFunctions = { "GetCraftingOperationInfo", "GetCraftingOperationInfoForOrder" }

local function copyCraftingReagent(reagent)
  if type(reagent) ~= "table" then return nil end
  local snapshot = {}
  if type(reagent.itemID) == "number" then snapshot.itemID = reagent.itemID end
  if type(reagent.currencyID) == "number" then snapshot.currencyID = reagent.currencyID end
  return next(snapshot) ~= nil and snapshot or nil
end

local function copyCraftingReagentInfo(info)
  if type(info) ~= "table" then return nil end
  local snapshot = {}
  if type(info.dataSlotIndex) == "number" then snapshot.dataSlotIndex = info.dataSlotIndex end
  if type(info.quantity) == "number" then snapshot.quantity = info.quantity end
  local reagent = copyCraftingReagent(info.reagent)
  if reagent ~= nil then snapshot.reagent = reagent end
  return next(snapshot) ~= nil and snapshot or nil
end

local function copyClaimedOrderReagents(reagents)
  if type(reagents) ~= "table" then return nil end
  local snapshot = {}
  for index, reagent in ipairs(reagents) do
    if type(reagent) == "table" then
      local copied = {}
      if type(reagent.slotIndex) == "number" then copied.slotIndex = reagent.slotIndex end
      if type(reagent.source) == "number" then copied.source = reagent.source end
      if type(reagent.isBasicReagent) == "boolean" then copied.isBasicReagent = reagent.isBasicReagent end
      local reagentInfo = copyCraftingReagentInfo(reagent.reagentInfo)
      if reagentInfo ~= nil then copied.reagentInfo = reagentInfo end
      if next(copied) ~= nil then snapshot[index] = copied end
    end
  end
  return next(snapshot) ~= nil and snapshot or nil
end

local function copyClaimedOrder(order)
  if type(order) ~= "table" then return nil end
  local snapshot = {}
  local numberFields = {
    "orderID", "itemID", "spellID", "skillLineAbilityID", "orderType", "orderState",
    "expirationTime", "claimEndTime", "minQuality", "tipAmount", "consortiumCut",
    "reagentState", "npcCustomerCreatureID", "npcCraftingOrderSetID", "npcTreasureID",
  }
  for _, field in ipairs(numberFields) do
    if type(order[field]) == "number" then snapshot[field] = order[field] end
  end
  local booleanFields = { "isRecraft", "isFulfillable" }
  for _, field in ipairs(booleanFields) do
    if type(order[field]) == "boolean" then snapshot[field] = order[field] end
  end
  local reagents = copyClaimedOrderReagents(order.reagents)
  if reagents ~= nil then snapshot.reagents = reagents end
  return next(snapshot) ~= nil and snapshot or nil
end

local function createRetailAdapter(api, emit, isRecording, submitCraft, invalidateCraft)
  local capabilities = { events = {}, hooks = {}, quoteHooks = {}, measurements = {} }
  local adapter = { capabilities = capabilities }
  capabilities.flavor = "retail"
  capabilities.secretValueDetection = type(api.issecretvalue) == "function"

  local function forward(event, ...)
    local ok = pcall(emit, event, ...)
    if not ok then
      capabilities.captureError = true
    end
  end

  local probingQuote = false
  local latestPersonalQuote
  local function snapshotSelections(selections)
    if type(selections) ~= "table" then return nil end
    local snapshot = {}
    for _, selection in ipairs(selections) do
      snapshot[#snapshot + 1] = copyCraftingReagentInfo(selection)
    end
    return snapshot
  end

  local function submitPersonalCraft(recipeId, count, orderId, concentration)
    if orderId ~= nil or type(submitCraft) ~= "function" then return end
    local cached = latestPersonalQuote
    latestPersonalQuote = nil
    local selections
    if cached and cached.recipeId == recipeId and cached.concentration == concentration then
      selections = cached.selections
    end
    local quote
    local tradeSkill = api.C_TradeSkillUI
    if selections and type(tradeSkill.GetCraftingOperationInfo) == "function" then
      probingQuote = true
      local ok, info = pcall(tradeSkill.GetCraftingOperationInfo, recipeId, selections, nil, concentration)
      probingQuote = false
      if ok and type(info) == "table" then quote = info end
    end
    if selections and type(tradeSkill.GetItemReagentQualityByItemInfo) == "function" then
      for _, selection in ipairs(selections) do
        local itemId = selection and selection.reagent and selection.reagent.itemID
        if itemId and type(selection.quantity) == "number" and selection.quantity > 0 then
          local qualityOk, quality = pcall(tradeSkill.GetItemReagentQualityByItemInfo, itemId)
          if qualityOk and type(quality) == "number" then selection.quality = quality end
        end
      end
    end
    submitCraft(recipeId, count, concentration, quote, selections)
  end
  local function observeClaimedOrder(orderID, observation)
    local orders = api.C_CraftingOrders
    if orderID == nil or type(orders) ~= "table" or type(orders.GetClaimedOrder) ~= "function" then
      return
    end
    local ok, order = pcall(orders.GetClaimedOrder)
    observation.claimedOrderStatus = ok and (order == nil and "nil" or "other-order") or "error"
    if ok and type(order) == "table" and order.orderID == orderID then
      observation.claimedOrderStatus = "matched"
      observation.claimedOrder = copyClaimedOrder(order)
    end
  end

  local function probe(name, ...)
    if not isRecording or not isRecording() then return end
    local arguments = { ... }
    local recipeID, reagents, orderID, concentration, targetDependent
    if name == "CraftRecipe" then
      recipeID, reagents, orderID, concentration = arguments[1], arguments[3], arguments[5], arguments[6]
    elseif name == "CraftEnchant" then
      recipeID, reagents, concentration = arguments[1], arguments[3], arguments[5]
      targetDependent = true
    elseif name == "CraftSalvage" then
      recipeID, reagents, concentration = arguments[1], arguments[4], arguments[5]
      targetDependent = true
    else
      local observation = { operation = "no-recipe-id-in-call" }
      if name == "RecraftRecipeForOrder" then observeClaimedOrder(arguments[1], observation) end
      forward("REQUEST_PROBE:C_TradeSkillUI." .. name, observation)
      return
    end

    local observation = { operation = "not-queried", reagentQuality = {} }
    observeClaimedOrder(orderID, observation)
    local tradeSkill = api.C_TradeSkillUI
    if type(reagents) == "table" and type(tradeSkill.GetItemReagentQualityByItemInfo) == "function" then
      for index, selection in ipairs(reagents) do
        if type(selection) == "table" and type(selection.reagent) == "table" and
            type(selection.reagent.itemID) == "number" then
          local ok, quality = pcall(tradeSkill.GetItemReagentQualityByItemInfo, selection.reagent.itemID)
          observation.reagentQuality[index] = { status = ok and "ok" or "error", quality = ok and quality or nil }
        end
      end
    end
    if targetDependent then
      observation.operation = "unavailable"
      forward("REQUEST_PROBE:C_TradeSkillUI." .. name, observation)
      return
    end
    if type(recipeID) == "number" and type(reagents) == "table" and type(concentration) == "boolean" then
      local method = orderID ~= nil and "GetCraftingOperationInfoForOrder" or "GetCraftingOperationInfo"
      if type(tradeSkill[method]) == "function" then
        local ok, info
        probingQuote = true
        if orderID ~= nil then
          ok, info = pcall(tradeSkill[method], recipeID, reagents, orderID, concentration)
        else
          ok, info = pcall(tradeSkill[method], recipeID, reagents, nil, concentration)
        end
        probingQuote = false
        observation.operation = ok and (info == nil and "nil" or "ok") or "error"
        if ok then observation.info = info end
      else
        observation.operation = "unavailable"
      end
    end
    forward("REQUEST_PROBE:C_TradeSkillUI." .. name, observation)
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
        if hookedName == "CraftRecipe" and select(5, ...) == nil then
          local ok = pcall(submitPersonalCraft, select(1, ...), select(2, ...),
            select(5, ...), select(6, ...))
          if not ok then capabilities.captureError = true end
        elseif type(invalidateCraft) == "function" then
          local ok = pcall(invalidateCraft)
          if not ok then capabilities.captureError = true end
        end
        forward("CALL_POST:C_TradeSkillUI." .. hookedName, ...)
        local ok = pcall(probe, hookedName, ...)
        if not ok then
          forward("REQUEST_PROBE:C_TradeSkillUI." .. hookedName, { operation = "error" })
        end
      end)
    else
      capabilities.hooks[name] = false
    end
  end
  for _, name in ipairs(quoteFunctions) do
    local hookedName = name
    if type(api.hooksecurefunc) == "function" and type(api.C_TradeSkillUI) == "table" and
        type(api.C_TradeSkillUI[name]) == "function" then
      capabilities.quoteHooks[name] = pcall(api.hooksecurefunc, api.C_TradeSkillUI, name, function(...)
        local ok = pcall(function(...)
          if not probingQuote then
            latestPersonalQuote = nil
            local recipeId, selections, orderId, concentration = ...
            if hookedName == "GetCraftingOperationInfo" and orderId == nil and
                type(recipeId) == "number" and type(concentration) == "boolean" then
              latestPersonalQuote = {
                recipeId = recipeId,
                concentration = concentration,
                selections = snapshotSelections(selections),
              }
            end
          end
          if not probingQuote and isRecording and isRecording() then
            forward("QUOTE_CALL_POST:C_TradeSkillUI." .. hookedName, ...)
            probingQuote = true
            local queried, info = pcall(api.C_TradeSkillUI[hookedName], ...)
            probingQuote = false
            forward("QUOTE_PROBE:C_TradeSkillUI." .. hookedName, {
              status = queried and (info == nil and "nil" or "ok") or "error",
              info = queried and info or nil,
            })
          end
        end, ...)
        if not ok then
          probingQuote = false
          forward("QUOTE_PROBE:C_TradeSkillUI." .. hookedName, { status = "error" })
        end
      end)
    else
      capabilities.quoteHooks[name] = false
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
