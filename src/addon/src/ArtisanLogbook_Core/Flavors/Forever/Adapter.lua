local _, addon = ...

local function positiveInteger(value)
  return type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0
end

local function query(api, method, ...)
  if type(method) ~= "function" then return nil end
  local ok, value = pcall(method, ...)
  if not ok or (type(api.issecretvalue) == "function" and api.issecretvalue(value)) then return nil end
  if type(value) == "table" and type(api.canaccesstable) == "function" and not api.canaccesstable(value) then
    return nil
  end
  return value
end

local function resolveOrdinaryCraft(api, recipeId, count, selections, recipeLevel, orderId, concentration, inputs, schematic)
  if not positiveInteger(recipeId) or not positiveInteger(count) or recipeLevel ~= nil or
      orderId ~= nil or concentration ~= false or type(selections) ~= "table" or next(selections) ~= nil then
    return nil, "Only personal, fixed-input CraftRecipe requests without selections are supported."
  end
  local tradeSkill = api.C_TradeSkillUI
  local info = query(api, tradeSkill.GetRecipeInfo, recipeId)
  local recipeTypes = api.Enum and api.Enum.TradeskillRecipeType
  if type(info) ~= "table" or info.recipeID ~= recipeId or info.supportsQualities ~= false or
      info.supportsCraftingStats ~= false or info.isRecraft ~= false or
      info.isEnchantingRecipe ~= false or info.isSalvageRecipe ~= false or
      info.isGatheringRecipe ~= false or info.isDummyRecipe ~= false or
      (count > 1 and info.canCreateMultiple ~= true) or
      type(schematic) ~= "table" or schematic.recipeID ~= recipeId or
      schematic.isRecraft ~= false or schematic.hasCraftingOperationInfo ~= false or
      not recipeTypes or recipeTypes.Item == nil or schematic.recipeType ~= recipeTypes.Item or
      not positiveInteger(schematic.outputItemID) or not positiveInteger(schematic.quantityMin) or
      schematic.quantityMin ~= schematic.quantityMax then
    return nil, "Recipe metadata is unavailable or is not a deterministic ordinary item craft."
  end
  if type(inputs) ~= "table" or inputs.complete ~= true or inputs.slotIdentityUncertain or
      inputs.grossRequirementsComplete ~= true or #inputs.requirements ~= 0 or
      #inputs.fixed == 0 or #inputs.fixed ~= #schematic.reagentSlotSchematics then
    return nil, "Required reagent identities or quantities are unresolved."
  end
  for _, slot in ipairs(schematic.reagentSlotSchematics) do
    if slot.required ~= true or type(slot.reagents) ~= "table" or #slot.reagents ~= 1 or
        not positiveInteger(slot.reagents[1].itemID) or slot.reagents[1].currencyID ~= nil then
      return nil, "Optional, substituted, currency or ambiguous reagent slots are unsupported."
    end
  end
  return { recipeId = recipeId, outputItemId = schematic.outputItemID,
    outputQuantity = schematic.quantityMin, requestedCount = count }
end

local function createForeverAdapter(api, handleEvent, submitCraft, invalidateCraft)
  local adapter, candidate, request, activeCast
  local completed, head, tail = {}, 1, 0
  local function reset()
    request, activeCast, candidate = nil, nil, nil
    completed, head, tail = {}, 1, 0
  end
  local function notify(event, context)
    if type(handleEvent) == "function" then handleEvent(event, context) end
  end
  local function unavailable(reason)
    if adapter then adapter.capabilities.lastUnsupportedReason = reason end
    notify("FOREVER_CAPTURE_DIAGNOSTIC", { accepted = false, reason = reason })
  end
  local function cancel(reason)
    if not request then return end
    reset()
    notify("CRAFT_CANCELLED", { reason = reason })
  end
  local function dispatch(event, ...)
    if event == "UNIT_SPELLCAST_START" then
      local unit, guid, recipeId = ...
      -- Forever emits additional nil-GUID starts; these do not replace a matched cast.
      if unit == "player" and request and recipeId == request.recipeId and
          type(guid) == "string" and guid ~= "" then
        if activeCast and not activeCast.succeeded and activeCast.guid ~= guid then
          cancel("Overlapping player casts are ambiguous.")
        elseif not activeCast or activeCast.guid ~= guid then
          activeCast = { guid = guid, recipeId = recipeId }
        end
      end
      return
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
      local unit, guid, recipeId = ...
      if unit == "player" and request and activeCast and activeCast.guid == guid and
          activeCast.recipeId == recipeId and not activeCast.succeeded then
        activeCast.succeeded = true
        if tail >= head then
          cancel("Multiple completed casts awaiting indistinguishable zero-ID results.")
          return
        end
        tail = tail + 1
        completed[tail] = { guid = guid, requestId = request.id, recipeId = recipeId }
      end
      return
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" or
        event == "UNIT_SPELLCAST_FAILED_QUIET" then
      local unit, guid = ...
      if unit == "player" and activeCast and activeCast.guid == guid and not activeCast.succeeded then
        cancel("Matched craft cast was interrupted or failed.")
      end
      return
    elseif event == "UPDATE_TRADESKILL_CAST_STOPPED" or event == "UNIT_SPELLCAST_STOP" or
        event == "UI_ERROR_MESSAGE" then
      -- false is also emitted on normal batch completion, before the final result.
      return
    elseif event == "TRADE_SKILL_CLOSE" or event == "PLAYER_LOGOUT" then
      reset()
    elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
      local result = ...
      local token = completed[head]
      if type(result) ~= "table" or not request or not token or token.requestId ~= request.id then
        unavailable("Result has no matched submitted request and completed player cast.")
        return
      end
      if result.operationID ~= 0 or result.itemID ~= request.outputItemId or
          result.quantity ~= request.outputQuantity or result.bonusCraft == true or
          result.firstCraftReward == true or result.isEnchant == true or result.recraftable == true then
        cancel("Result does not match the supported deterministic request.")
        unavailable("Unsupported or conflicting craft result.")
        return
      end
      local correlation = { kind = "confirmed-cast", requestId = request.id, recipeId = request.recipeId,
        outputItemId = request.outputItemId, outputQuantity = request.outputQuantity, castGUID = token.guid }
      -- Zero-valued Retail-only fields are not evidence of Forever mechanics.
      local observed = { operationID = result.operationID, itemID = result.itemID, quantity = result.quantity }
      local fact = handleEvent(event, observed, correlation)
      if not fact then
        unavailable("Ledger rejected the matched result; earlier evidence is preserved.")
        return
      end
      completed[head], head = nil, head + 1
      request.remaining = request.remaining - 1
      if request.remaining == 0 then reset() end
      return
    end
    if type(handleEvent) == "function" then return handleEvent(event, ...) end
  end
  adapter = addon.CreateModernCraftAdapter(api, dispatch, function(...)
    local resolved = candidate
    reset()
    local stored = submitCraft(...)
    if stored and resolved then
      request = resolved
      request.id, request.remaining = stored.id, stored.requestedCount
    else
      unavailable("Ledger did not accept the ordinary craft request.")
    end
    return stored
  end, function(operationKind)
    reset()
    if operationKind then unavailable("Only ordinary CraftRecipe operations are supported.") end
    if type(invalidateCraft) == "function" then return invalidateCraft() end
  end, {
    flavor = "forever", fixedOnly = true,
    ValidateRequest = function(...)
      if adapter and not adapter.capabilities.captureReady then
        return false, "Required Forever event registrations, recipe getters or request hook are unavailable."
      end
      if request then return false, "Overlapping submitted requests are unsupported." end
      local resolved, reason = resolveOrdinaryCraft(...)
      candidate = resolved
      return resolved ~= nil, reason
    end,
  })
  adapter.capabilities.measurements = {
    resourcefulness = false, concentrationSpent = false, ingenuityRefund = false,
    multicraft = false, quality = false,
  }
  adapter.capabilities.resultCorrelation = "submitted-request-and-confirmed-cast"
  adapter.capabilities.support = "ordinary-fixed-input-crafts"
  local events = adapter.capabilities.events
  local tradeSkill = api.C_TradeSkillUI
  adapter.capabilities.captureReady = events.TRADE_SKILL_ITEM_CRAFTED_RESULT == true and
    events.UNIT_SPELLCAST_START == true and events.UNIT_SPELLCAST_SUCCEEDED == true and
    events.UNIT_SPELLCAST_INTERRUPTED == true and events.TRADE_SKILL_CLOSE == true and
    adapter.capabilities.hooks.CraftRecipe == true and type(tradeSkill) == "table" and
    type(tradeSkill.GetRecipeInfo) == "function" and type(tradeSkill.GetRecipeSchematic) == "function"
  return adapter
end

function addon.RegisterForeverAdapter(api)
  if api.WOW_PROJECT_CAMELOT ~= nil and api.WOW_PROJECT_ID == api.WOW_PROJECT_CAMELOT then
    addon.RegisterFlavorAdapter(api.WOW_PROJECT_CAMELOT, "forever", createForeverAdapter)
  end
end
