-- Sanitized build 69933 personal-craft shapes; no character, item, or cast GUIDs.
return {
  build = "69933",
  version = "12.1.0",
  cases = {
    {
      name = "low-quality mix without concentration",
      recipeId = 1230868, requestedCount = 1, useConcentration = false,
      quote = { concentrationCost = 0, baseSkill = 120, baseDifficulty = 200, craftingQuality = 1 },
      selections = {
        { dataSlotIndex = 1, quantity = 3, reagent = { itemID = 240991 }, quality = 1 },
        { dataSlotIndex = 1, quantity = 0, reagent = { itemID = 240992 } },
        { dataSlotIndex = 2, quantity = 2, reagent = { itemID = 238511 }, quality = 2 },
      },
      results = { { operationID = 1001, itemID = 241307, quantity = 5,
        concentrationSpent = 0, hasIngenuityProc = false, ingenuityRefund = 65,
        resourcesReturned = { { reagent = { itemID = 240991 }, quantity = 1 },
          { reagent = { itemID = 238511 }, quantity = 1 } } } },
    },
    {
      name = "higher-quality mix with concentration",
      recipeId = 1230868, requestedCount = 1, useConcentration = true,
      quote = { concentrationCost = 81, baseSkill = 135, baseDifficulty = 200, craftingQuality = 2 },
      selections = {
        { dataSlotIndex = 1, quantity = 3, reagent = { itemID = 240992 }, quality = 2 },
        { dataSlotIndex = 1, quantity = 0, reagent = { itemID = 240991 } },
        { dataSlotIndex = 2, quantity = 2, reagent = { itemID = 238511 }, quality = 2 },
      },
      results = { { operationID = 1002, itemID = 241307, quantity = 5,
        concentrationSpent = 80, hasIngenuityProc = false, ingenuityRefund = 65,
        resourcesReturned = {} } },
    },
    {
      name = "batch of three distinct results",
      recipeId = 1237557, requestedCount = 3, useConcentration = false,
      quote = { concentrationCost = 0, craftingQuality = 2 },
      selections = { { dataSlotIndex = 4, quantity = 4, reagent = { itemID = 236761 }, quality = 1 } },
      results = {
        { operationID = 2001, quantity = 1, resourcesReturned = {} },
        { operationID = 2002, quantity = 1, resourcesReturned = {} },
        { operationID = 2003, quantity = 1, resourcesReturned = {} },
      },
    },
    {
      name = "partial concentrated batch with failed queued operation",
      recipeId = 1236083, requestedCount = 3, useConcentration = true,
      quote = { concentrationCost = 185, craftingQuality = 2 },
      selections = { { dataSlotIndex = 3, quantity = 2, reagent = { itemID = 238513 }, quality = 3 } },
      results = { { operationID = 3001, quantity = 1, concentrationSpent = 185,
        resourcesReturned = {} } },
      failedQueuedOperation = true,
    },
  },
}