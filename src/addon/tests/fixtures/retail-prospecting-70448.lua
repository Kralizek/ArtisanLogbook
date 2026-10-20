return {
  evidence = "Issue #32, October 20: build 0.0.0-dev-4c74770; six operations, eight callbacks, submissions 1 + 5",
  provenance = "Evidence-derived scenario, not a verbatim trace. Unreported IDs/items/results and configuration contents are synthetic stand-ins.",
  recipeId = 1231127,
  configurationKey = 197,
  items = { tenuousStone = 900001, duskShroudedStone = 900002, refulgentCopperOre = 900003 },
  submissions = {
    { count = 1, results = {
      { operationID = 101, itemID = 900001, quantity = 1 },
    } },
    { count = 5, results = {
      { operationID = 3533599395, itemID = 900001, quantity = 1 },
      { operationID = 3533599395, itemID = 900002, quantity = 1 },
      { operationID = 102, itemID = 900001, quantity = 1 },
      { operationID = 3105221557, itemID = 900001, quantity = 1 },
      { operationID = 3105221557, itemID = 900002, quantity = 2 },
      { operationID = 103, itemID = 900001, quantity = 1 },
      { operationID = 104, itemID = 900001, quantity = 1 },
    } },
  },
  capture = {
    allocations = { { itemId = 900003, allocatedQuantity = 5 } },
    observation = { context = { kind = "personal", source = "submitted-call", isRecraft = false },
      configuration = { scope = "request", useConcentration = false, statsCoverage = "unavailable" } },
  },
}