local _, addon = ...

local craftFunctions = {
  "CraftRecipe",
  "CraftEnchant",
  "CraftSalvage",
  "RecraftRecipe",
  "RecraftRecipeForOrder",
}

local quoteFunctions = { "GetCraftingOperationInfo", "GetCraftingOperationInfoForOrder" }

local function copyReagentInfo(info)
  if type(info) ~= "table" then return nil end
  local copied = {}
  for _, field in ipairs({ "dataSlotIndex", "quantity" }) do
    if type(info[field]) == "number" then copied[field] = info[field] end
  end
  local reagent = info.reagent
  if type(reagent) == "table" then
    local item = {}
    if type(reagent.itemID) == "number" then item.itemID = reagent.itemID end
    if type(reagent.currencyID) == "number" then item.currencyID = reagent.currencyID end
    if next(item) then copied.reagent = item end
  end
  return next(copied) and copied or nil
end

local function copyClaimedOrder(order)
  if type(order) ~= "table" then return nil end
  local copied = {}
  for _, field in ipairs({
    "orderID", "itemID", "spellID", "skillLineAbilityID", "orderType", "orderState",
    "expirationTime", "claimEndTime", "minQuality", "tipAmount", "consortiumCut",
    "reagentState", "npcCustomerCreatureID", "npcCraftingOrderSetID", "npcTreasureID",
  }) do
    if type(order[field]) == "number" then copied[field] = order[field] end
  end
  for _, field in ipairs({ "isRecraft", "isFulfillable" }) do
    if type(order[field]) == "boolean" then copied[field] = order[field] end
  end
  if type(order.reagents) == "table" then
    copied.reagents = {}
    for index, reagent in ipairs(order.reagents) do
      if type(reagent) == "table" then
        local row = {}
        for _, field in ipairs({ "slotIndex", "source" }) do
          if type(reagent[field]) == "number" then row[field] = reagent[field] end
        end
        if type(reagent.isBasicReagent) == "boolean" then row.isBasicReagent = reagent.isBasicReagent end
        local info = copyReagentInfo(reagent.reagentInfo)
        if info then row.reagentInfo = info end
        if next(row) then copied.reagents[index] = row end
      end
    end
    if not next(copied.reagents) then copied.reagents = nil end
  end
  return copied
end

local function registerHooks(api, emit, isVerbose)
  local tradeSkill = api.C_TradeSkillUI
  addon.capabilities.hooks = {}
  if type(tradeSkill) ~= "table" or type(api.hooksecurefunc) ~= "function" then
    for _, name in ipairs(craftFunctions) do addon.capabilities.hooks[name] = false end
    for _, name in ipairs(quoteFunctions) do addon.capabilities.hooks[name] = false end
    return
  end

  local function observeClaimedOrder(orderID, observation)
    local orders = api.C_CraftingOrders
    if orderID == nil or type(orders) ~= "table" or type(orders.GetClaimedOrder) ~= "function" then return end
    local ok, order = pcall(orders.GetClaimedOrder)
    observation.claimedOrderStatus = ok and (order == nil and "nil" or "other-order") or "error"
    if ok and type(order) == "table" and order.orderID == orderID then
      observation.claimedOrderStatus = "matched"
      observation.claimedOrder = copyClaimedOrder(order)
    end
  end

  local probingQuote = false
  local function probe(name, ...)
    if not isVerbose() then return end
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
      emit("REQUEST_PROBE:C_TradeSkillUI." .. name, observation)
      return
    end
    local observation = { operation = "not-queried", reagentQuality = {} }
    observeClaimedOrder(orderID, observation)
    if type(reagents) == "table" and type(tradeSkill.GetItemReagentQualityByItemInfo) == "function" then
      for index, selection in ipairs(reagents) do
        local itemID = type(selection) == "table" and type(selection.reagent) == "table" and
          selection.reagent.itemID
        if type(itemID) == "number" then
          local ok, quality = pcall(tradeSkill.GetItemReagentQualityByItemInfo, itemID)
          observation.reagentQuality[index] = { status = ok and "ok" or "error", quality = ok and quality or nil }
        end
      end
    end
    if targetDependent then
      observation.operation = "unavailable"
      emit("REQUEST_PROBE:C_TradeSkillUI." .. name, observation)
      return
    end
    if type(recipeID) == "number" and type(reagents) == "table" and type(concentration) == "boolean" then
      local method = orderID ~= nil and "GetCraftingOperationInfoForOrder" or "GetCraftingOperationInfo"
      if type(tradeSkill[method]) == "function" then
        probingQuote = true
        local ok, info
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
    emit("REQUEST_PROBE:C_TradeSkillUI." .. name, observation)
  end

  for _, name in ipairs(craftFunctions) do
    local hookedName = name
    local method = tradeSkill[name]
    if type(method) == "function" then
      addon.capabilities.hooks[name] = pcall(api.hooksecurefunc, tradeSkill, name, function(...)
        emit("CALL_POST:C_TradeSkillUI." .. hookedName, ...)
        if isVerbose() then
          local ok = pcall(probe, hookedName, ...)
          if not ok then emit("REQUEST_PROBE:C_TradeSkillUI." .. hookedName, { operation = "error" }) end
        end
      end)
    else
      addon.capabilities.hooks[name] = false
    end
  end

  for _, name in ipairs(quoteFunctions) do
    local hookedName = name
    if type(tradeSkill[name]) == "function" then
      addon.capabilities.hooks[name] = pcall(api.hooksecurefunc, tradeSkill, name, function(...)
        if not isVerbose() or probingQuote then return end
        emit("QUOTE_CALL_POST:C_TradeSkillUI." .. hookedName, ...)
        probingQuote = true
        local ok, info = pcall(tradeSkill[hookedName], ...)
        probingQuote = false
        emit("QUOTE_PROBE:C_TradeSkillUI." .. hookedName, {
          status = ok and (info == nil and "nil" or "ok") or "error",
          info = ok and info or nil,
        })
      end)
    else
      addon.capabilities.hooks[name] = false
    end
  end
end

function addon.RegisterDiagnosticProbes(api, emit, isVerbose)
  registerHooks(api, emit, isVerbose)
end
