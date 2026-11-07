-- Sanitized reproduction of historical schematic variance, not a live SavedVariables export.
ArtisanLogbookDB = {
  schemaVersion = 5, schemaIdentity = "ArtisanLogbookLedger",
  crafts = {
    { id = 858, sessionId = 1, recipeId = 1236483, requestId = 205, timestamp = 1791829216,
      reagentRequirements = {} },
    { id = 1434, sessionId = 1, recipeId = 1236483, requestId = 526, timestamp = 1792433714,
      reagentRequirements = { { source = "schematic", dataSlotIndex = 1,
        requiredQuantity = 2, candidateItemIDs = { 243599, 243600 } } } },
    { id = 1478, sessionId = 1, recipeId = 1236483, timestamp = 1792530782,
      reagentRequirements = { { source = "schematic", dataSlotIndex = 1,
        requiredQuantity = 2, candidateItemIDs = { 243599, 243600 } } } }
  },
  requests = {
    { id = 205, sessionId = 1, recipeId = 1236483, timestamp = 1791829214,
      requirements = { { source = "schematic", dataSlotIndex = 1,
        requiredQuantity = 1, candidateItemIDs = { 236951 } } } },
    { id = 526, sessionId = 1, recipeId = 1236483, timestamp = 1792433712,
      requirements = { { source = "schematic", dataSlotIndex = 1,
        requiredQuantity = 2, candidateItemIDs = { 243599, 243600 } } } }
  },
  dimensions = {
    sessions = { { id = 1, key = "sanitized-session", projectId = 1, characterDimensionId = 1 } },
    characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-Sanitized" } }
  }
}
