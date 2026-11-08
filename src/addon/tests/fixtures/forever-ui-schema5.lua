-- Sanitized Forever 1.60.1 fixture; Populate uses the production Ledger to build schema 5.
-- Recipe 2329 intentionally has no name metadata to exercise safe UI fallback.
local fixture = {
  schemaVersion = 5,
  flavor = "forever",
  build = "70862",
  records = {
    { recipeId = 2331, recipeName = "Minor Mana Potion", outputItemId = 2455,
      outputName = "Minor Mana Potion", reagents = { 785, 2447, 3371 }, quantity = 1 },
    { recipeId = 7183, recipeName = "Minor Defense Potion", outputItemId = 5997,
      outputName = "Minor Defense Potion", reagents = { 765, 2447, 3371 }, quantity = 1 },
    { recipeId = 7183, recipeName = "Minor Defense Potion", outputItemId = 5997,
      outputName = "Minor Defense Potion", reagents = { 765, 2447, 3371 }, quantity = 1 },
    { recipeId = 2329, outputItemId = 2454,
      outputName = "Minor Strength Potion", reagents = { 785, 2452, 3371 }, quantity = 1 },
  },
  itemNames = {
    [785] = "Mageroyal",
    [765] = "Silverleaf",
    [2447] = "Peacebloom",
    [2452] = "Swiftthistle",
    [3371] = "Crystal Vial",
    [2454] = "Minor Strength Potion",
    [2455] = "Minor Mana Potion",
    [5997] = "Minor Defense Potion",
  },
}

function fixture.Populate(ledger)
  assert(ledger.database.schemaVersion == fixture.schemaVersion)
  local alchemy = assert(ledger:AddDimension("profession", 171, { name = "Alchemy" }))
  local inputsByRecipe = {}
  for _, record in ipairs(fixture.records) do
    assert(ledger:AddDimension("recipe", record.recipeId, {
      name = record.recipeName, professionId = alchemy,
    }))
    assert(ledger:AddDimension("item", record.outputItemId, { name = record.outputName }))
    for _, itemId in ipairs(record.reagents) do
      assert(ledger:AddDimension("item", itemId, { name = fixture.itemNames[itemId] }))
    end
    inputsByRecipe[record.recipeId] = inputsByRecipe[record.recipeId] or {
      evidenceVersion = 1, complete = true, grossRequirementsComplete = true,
      completeItemIDs = {}, fixed = {},
    }
    local inputs = inputsByRecipe[record.recipeId]
    for slot, itemId in ipairs(record.reagents) do
      if not inputs.completeItemIDs[slot] then
        inputs.completeItemIDs[slot] = { itemID = itemId }
        inputs.fixed[slot] = { dataSlotIndex = slot, itemID = itemId, quantity = 1 }
      end
    end
  end

  local batchSizes = { [2331] = 1, [7183] = 2, [2329] = 1 }
  local operationId = 1
  local submitted = {}
  for _, record in ipairs(fixture.records) do
    if not submitted[record.recipeId] then
      local request = assert(ledger:SubmitCraft(record.recipeId, batchSizes[record.recipeId], false, nil,
        {}, inputsByRecipe[record.recipeId], false,
        { context = { kind = "personal", source = "submitted-call" } }))
      submitted[record.recipeId] = request
    end
    assert(ledger:RecordResult({ operationID = 0, itemID = record.outputItemId, quantity = record.quantity },
      nil, { kind = "confirmed-cast", castGUID = "ForeverFixture-" .. operationId,
        requestId = submitted[record.recipeId].id, recipeId = record.recipeId,
        outputItemId = record.outputItemId, outputQuantity = record.quantity }))
    operationId = operationId + 1
  end

  assert(ledger.database.schemaVersion == fixture.schemaVersion and #ledger.database.crafts == #fixture.records)
  return ledger.database
end

return fixture
