-- Synthetic, isolated browser acceptance history. Not player data or a live capture.
ArtisanLogbookDB = {
  schemaVersion = 5, schemaIdentity = "ArtisanLogbookLedger",
  crafts = {
    { id = 1, sessionId = 1, recipeId = 1230868, requestId = 1, timestamp = 1793836800,
      configurationKey = 1, configurationScope = "request", statsCoverage = "reported",
      outputItemId = 241307, outputQuantity = 3, outputQuality = 2,
      inputsComplete = true, outputsComplete = true, resourcefulnessComplete = true,
      hasResourcefulnessProc = false, multicraftBonus = 0, concentrationSpent = 0,
      hasIngenuityProc = false, ingenuityRefund = 0 },
    { id = 2, sessionId = 1, recipeId = 1230868, requestId = 2, timestamp = 1793923200,
      configurationKey = 2, configurationScope = "request", statsCoverage = "reported",
      outputItemId = 241307, outputQuantity = 5, outputQuality = 3,
      inputsComplete = true, outputsComplete = true, resourcefulnessComplete = true,
      hasResourcefulnessProc = true, multicraftBonus = 2, concentrationSpent = 40,
      hasIngenuityProc = true, ingenuityRefund = 10 },
    { id = 3, sessionId = 2, recipeId = 1230868, requestId = 3, timestamp = 1794009600,
      configurationKey = 1, configurationScope = "request", statsCoverage = "reported",
      outputItemId = 241307, outputQuantity = 4, outputQuality = 3,
      inputsComplete = true, outputsComplete = true, hasResourcefulnessProc = false,
      multicraftBonus = 1, concentrationSpent = 0, hasIngenuityProc = false, ingenuityRefund = 0 },
    { id = 4, sessionId = 1, recipeId = 1236083, timestamp = 1778803200,
      outputItemId = 244005, outputQuantity = 1 },
    { id = 5, sessionId = 3, recipeId = 1237557, timestamp = 1794096000,
      outputItemId = 244615, outputQuantity = 1 },
    { id = 6, sessionId = 4, recipeId = 1230868, timestamp = 1794182400,
      outputItemId = 241307, outputQuantity = 1, inputsComplete = true,
      reagentRequirements = { { source = "schematic", dataSlotIndex = 1,
        requiredQuantity = 2, candidateItemIDs = { 240991 } } } }
  },
  requests = {
    { id = 1, sessionId = 1, recipeId = 1230868, timestamp = 1793836799, requestedCount = 1,
      baseSkill = 120, baseDifficulty = 200, craftingQuality = 2, useConcentration = false,
      allocations = { { itemId = 240991, allocatedQuantity = 3, dataSlotIndex = 1, quality = 1 },
        { itemId = 238511, allocatedQuantity = 2, dataSlotIndex = 2, quality = 2 } } },
    { id = 2, sessionId = 1, recipeId = 1230868, timestamp = 1793923199, requestedCount = 1,
      baseSkill = 150, baseDifficulty = 200, craftingQuality = 3, useConcentration = true,
      allocations = { { itemId = 240991, allocatedQuantity = 3, dataSlotIndex = 1, quality = 1 },
        { itemId = 238511, allocatedQuantity = 2, dataSlotIndex = 2, quality = 2 } } },
    { id = 3, sessionId = 2, recipeId = 1230868, timestamp = 1794009599, requestedCount = 1,
      baseSkill = 160, baseDifficulty = 200, craftingQuality = 3, useConcentration = false,
      allocations = { { itemId = 240991, allocatedQuantity = 3, dataSlotIndex = 1, quality = 1 },
        { itemId = 238511, allocatedQuantity = 2, dataSlotIndex = 2, quality = 2 } } }
  },
  configurations = {
    [1] = { useConcentration = false, stats = { baseSkill = 120, baseDifficulty = 200 } },
    [2] = { useConcentration = true, stats = { baseSkill = 150, baseDifficulty = 200 } }
  },
  reagents = {
    { craftId = 1, itemId = 240991, allocatedQuantity = 3, returnedQuantity = 0, dataSlotIndex = 1 },
    { craftId = 1, itemId = 238511, allocatedQuantity = 2, returnedQuantity = 0, dataSlotIndex = 2 },
    { craftId = 2, itemId = 240991, allocatedQuantity = 3, returnedQuantity = 1, dataSlotIndex = 1 },
    { craftId = 2, itemId = 238511, allocatedQuantity = 2, returnedQuantity = 0, dataSlotIndex = 2 },
    { craftId = 3, itemId = 240991, allocatedQuantity = 3, dataSlotIndex = 1 },
    { craftId = 3, itemId = 238511, allocatedQuantity = 2, dataSlotIndex = 2 },
    { craftId = 6, itemId = 240991, allocatedQuantity = 2, dataSlotIndex = 1 }
  },
  dimensions = {
    sessions = {
      { id = 1, key = "c12-alchemist-a", projectId = 1, characterDimensionId = 1 },
      { id = 2, key = "c12-alchemist-b", projectId = 1, characterDimensionId = 2 },
      { id = 3, key = "c12-jeweler", projectId = 1, characterDimensionId = 3 },
      { id = 4, key = "c12-forever", projectId = 18, characterDimensionId = 4 }
    },
    characters = {
      { id = 1, key = "project:1:region:3:realm:1309:guid:Player-C12-A", name = "Elara" },
      { id = 2, key = "project:1:region:3:realm:1309:guid:Player-C12-B", name = "Torren" },
      { id = 3, key = "project:1:region:3:realm:1309:guid:Player-C12-C", name = "Mira" },
      { id = 4, key = "project:18:region:3:realm:1309:guid:Player-C12-D", name = "Era Alchemist" }
    },
    recipes = {
      [1230868] = { id = 1230868, name = "Artisan Potion", professionId = 171 },
      [1236083] = { id = 1236083, name = "Archived Elixir", professionId = 171 },
      [1237557] = { id = 1237557, name = "Silver Ring", professionId = 755 }
    },
    professions = { [171] = { id = 171, name = "Alchemy" }, [755] = { id = 755, name = "Jewelcrafting" } },
    items = {
      [241307] = { id = 241307, name = "Artisan Potion" },
      [240991] = { id = 240991, name = "Wild Mote" },
      [238511] = { id = 238511, name = "Bloom" },
      [244005] = { id = 244005, name = "Archived Elixir" },
      [244615] = { id = 244615, name = "Silver Ring" }
    }
  }
}
