local _, addon = ...

local events = {
  "TRADE_SKILL_CRAFT_BEGIN",
  "TRADE_SKILL_ITEM_CRAFTED_RESULT",
  "TRADE_SKILL_CURRENCY_REWARD_RESULT",
  "UPDATE_TRADESKILL_CAST_STOPPED",
  "TRADE_SKILL_SHOW",
  "TRADE_SKILL_LIST_UPDATE",
  "TRADE_SKILL_CLOSE",
  "CRAFTING_DETAILS_UPDATE",
  "GET_ITEM_INFO_RECEIVED",
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
  local function isPositiveInteger(value)
    return type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0
  end
  local function readable(value)
    if type(api.issecretvalue) == "function" and api.issecretvalue(value) then return false end
    if type(value) == "table" and type(api.canaccesstable) == "function" then return api.canaccesstable(value) end
    return true
  end

  local function snapshotSelections(selections)
    if type(selections) ~= "table" or not readable(selections) then return nil end
    local snapshot = {}
    for index, selection in pairs(selections) do
      local copied = type(selection) == "table" and readable(selection) and readable(selection.reagent) and
        copyCraftingReagentInfo(selection)
      snapshot[index] = copied or false
    end
    return snapshot
  end

  local function dense(list)
    if type(list) ~= "table" or not readable(list) then return false end
    local count, maximum = 0, 0
    for index in pairs(list) do
      if not isPositiveInteger(index) then return false end
      count, maximum = count + 1, math.max(maximum, index)
    end
    return count == maximum
  end

  local function snapshotRecipeInputs(recipeId, recipeLevel, selections)
    local tradeSkill, enum = api.C_TradeSkillUI, api.Enum
    local slotTypes = type(enum) == "table" and enum.TradeskillSlotDataType
    local reagentTypes = type(enum) == "table" and enum.CraftingReagentType
    if type(tradeSkill.GetRecipeSchematic) ~= "function" or type(slotTypes) ~= "table" or
        type(reagentTypes) ~= "table" or slotTypes.Reagent == nil or slotTypes.ModifiedReagent == nil or
        slotTypes.Currency == nil or reagentTypes.Basic == nil then
      return nil
    end
    local ok, schematic = pcall(tradeSkill.GetRecipeSchematic, recipeId, false, recipeLevel)
    if not ok or type(schematic) ~= "table" or not readable(schematic) or schematic.recipeID ~= recipeId or
        type(schematic.reagentSlotSchematics) ~= "table" or not readable(schematic.reagentSlotSchematics) then
      return nil
    end
    local inputs = { fixed = {}, complete = true, evidenceVersion = 1, completeItemIDs = {} }
    local totals, blocked, slots, unknown = {}, {}, {}, false
    local selected = {}
    if not dense(selections) then unknown = true end
    for _, selection in pairs(selections or {}) do
      if type(selection) == "table" and isPositiveInteger(selection.dataSlotIndex) and
          type(selection.reagent) == "table" and isPositiveInteger(selection.reagent.itemID) and
          (selection.quantity == 0 or isPositiveInteger(selection.quantity)) then
        local list = selected[selection.dataSlotIndex] or {}
        list[#list + 1] = selection
        selected[selection.dataSlotIndex] = list
      else
        unknown = true
      end
    end
    if not dense(schematic.reagentSlotSchematics) then unknown = true end
    for _, slot in pairs(schematic.reagentSlotSchematics) do
      local slotType = type(slot) == "table" and readable(slot) and slot.dataSlotType
      if slotType ~= slotTypes.Currency then
        local candidates, known = {}, slotType and dense(slot.reagents)
        if known then
          for _, reagent in ipairs(slot.reagents) do
            if type(reagent) ~= "table" or not readable(reagent) or not isPositiveInteger(reagent.itemID) then
              known = false
            else
              candidates[reagent.itemID] = true
            end
          end
          if next(candidates) == nil then known = false end
        end
        local index = slotType and slot.dataSlotIndex
        if isPositiveInteger(index) and slots[index] then unknown = true end
        local supported = known and isPositiveInteger(index) and not slots[index] and
          slot.hiddenInCraftingForm ~= true and type(slot.required) == "boolean" and
          isPositiveInteger(slot.quantityRequired) and
          (slot.variableQuantities == nil or (dense(slot.variableQuantities) and #slot.variableQuantities == 0))
        local allocations, quantity = selected[index] or {}, 0
        if slotType == slotTypes.ModifiedReagent and supported and dense(selections) and
            (slot.reagentType == reagentTypes.Basic or
              (reagentTypes.Modifying ~= nil and slot.reagentType == reagentTypes.Modifying) or
              (reagentTypes.Finishing ~= nil and slot.reagentType == reagentTypes.Finishing)) then
          for _, selection in ipairs(allocations) do
            if not candidates[selection.reagent.itemID] then supported = false end
            quantity = quantity + selection.quantity
          end
          supported = supported and ((quantity == slot.quantityRequired) or (not slot.required and quantity == 0))
          if supported then
            for _, selection in ipairs(allocations) do
              if selection.quantity > 0 then totals[selection.reagent.itemID] = true end
            end
          end
        elseif slotType == slotTypes.Reagent and supported and slot.reagentType == reagentTypes.Basic and
            slot.required and #slot.reagents == 1 and #allocations == 0 then
          local only = slot.reagents[1]
          inputs.fixed[#inputs.fixed + 1] = { dataSlotIndex = slot.dataSlotIndex, itemID = only.itemID,
            quantity = slot.quantityRequired }
          totals[only.itemID] = true
        else
          supported = false
        end
        if isPositiveInteger(index) then slots[index] = true end
        if not supported then
          inputs.complete = false
          if not known then unknown = true end
          for itemId in pairs(candidates) do blocked[itemId] = true end
          for _, selection in ipairs(allocations) do blocked[selection.reagent.itemID] = true end
        end
      end
    end
    for index in pairs(selected) do if not slots[index] then unknown = true end end
    if unknown then inputs.complete = false end
    if not unknown then
      for itemId in pairs(totals) do
        if not blocked[itemId] then inputs.completeItemIDs[#inputs.completeItemIDs + 1] = { itemID = itemId } end
      end
    end
    return inputs
  end

  local function submitPersonalCraft(recipeId, count, orderId, concentration, recipeLevel, submitted)
    if orderId ~= nil or type(submitCraft) ~= "function" then return end
    local selections = snapshotSelections(submitted)
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
    submitCraft(recipeId, count, concentration, quote, selections, snapshotRecipeInputs(recipeId, recipeLevel, selections))
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
            select(5, ...), select(6, ...), select(4, ...), select(3, ...))
          if not ok then
            capabilities.captureError = true
            if type(invalidateCraft) == "function" then pcall(invalidateCraft) end
          end
        elseif type(invalidateCraft) == "function" then
          local ok = pcall(invalidateCraft, hookedName)
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
