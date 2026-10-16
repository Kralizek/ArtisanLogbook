local function roundTrip(value, digits)
  if type(value) == "number" then return tonumber(string.format("%." .. digits .. "g", value)) end
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, child in pairs(value) do copy[key] = roundTrip(child, digits) end
  return copy
end

return function(Ledger, clock, digits)
  digits = digits or 16
  local observation = { context = { kind = "personal", source = "submitted-call" },
    configuration = { scope = "request", statsCoverage = "partial",
      stats = { ingenuity = { ratingPct = 1.2345678901234567 } } } }
  local inputs = { evidenceVersion = 1, complete = false, grossRequirementsComplete = true,
    fixed = {}, completeItemIDs = { { itemID = 8 } },
    requirements = { { dataSlotIndex = 1, candidateItemIDs = { 8 }, requiredQuantity = 5, source = "schematic" } } }
  local keys = {}
  local ledger = assert(Ledger.New(nil, clock))
  for operationId = 1, 2 do
    assert(ledger:CreateSession({ characterName = "Synthetic", characterGUID = "Synthetic",
      realmName = "Synthetic", projectId = 1, regionId = 1, gameRealmId = 1 }))
    -- Model historical allocation before percentage canonicalization, not current capture.
    if operationId == 2 and digits < 17 then ledger.configurationIndex = {} end
    local request = assert(ledger:SubmitCraft(123, 1, false, nil,
      { { dataSlotIndex = 1, quantity = 5, reagent = { itemID = 8 } } }, inputs, true, observation))
    keys[operationId] = request.configurationKey
    assert(ledger:RecordResult({ operationID = operationId, itemID = 456, quantity = 1,
      resourcesReturned = { { reagent = { itemID = 8 }, quantity = 1 } } }))
    assert(ledger:RecordResult({ operationID = operationId, itemID = 600, quantity = 1, firstCraftReward = true }))
    if operationId == 1 then ledger = assert(Ledger.New(roundTrip(ledger.database, digits), clock)) end
  end
  return roundTrip(ledger.database, digits), keys, observation
end
