local root = arg[1] or "src/ArtisanLogbook"
local testsRoot = arg[2] or "tests"
local addon = {}
assert(loadfile(root .. "/Capture/Trace.lua"))("ArtisanLogbook", addon)
local Trace = addon.Trace
local elapsed = 0
local clock = {
  wall = function() return 1800000000 end,
  elapsed = function() elapsed = elapsed + 0.01; return elapsed end,
}
local passed = 0

local function test(name, callback)
  callback()
  passed = passed + 1
  print("PASS " .. name)
end

local function decode(text)
  local chunk = assert(loadstring(text))
  setfenv(chunk, {})
  return chunk()
end

test("capture is opt-in and preserves nil arguments, false, and zero", function()
  local recorder = assert(Trace.New(nil, clock))
  assert(not recorder:Capture("IGNORED"))
  assert(recorder:Start({ build = "mock" }))
  assert(recorder:Capture("EVENT", 7, nil, false, 0, nil))
  local arguments = decode(recorder:Export(2, 1)).records[1].arguments
  assert(arguments.n == 5 and arguments[1] == 7 and arguments[2] == nil)
  assert(arguments[3] == false and arguments[4] == 0 and arguments[5] == nil)
end)

test("callbacks remain separate and snapshots do not mutate", function()
  local recorder = assert(Trace.New(nil, clock))
  recorder:Start({})
  local result = { operationID = 42, resources = { { itemID = 123, quantity = 2 } } }
  recorder:Capture("TRADE_SKILL_CRAFT_BEGIN", 456)
  recorder:Capture("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 456)
  recorder:Capture("TRADE_SKILL_ITEM_CRAFTED_RESULT", result)
  recorder:Capture("TRADE_SKILL_ITEM_CRAFTED_RESULT", result)
  result.resources[1].quantity = 99
  recorder:Capture("TRADE_SKILL_CRAFT_BEGIN", 456)
  recorder:Capture("UNIT_SPELLCAST_INTERRUPTED", "player", "Cast-2", 456)
  recorder:Capture("TRADE_SKILL_ITEM_CRAFTED_RESULT", result)
  local records = decode(recorder:Export(1, 100)).records
  assert(#records == 8)
  assert(records[4].arguments[1].resources[1].quantity == 2)
  assert(records[5].arguments[1].operationID == 42)
  assert(records[8].arguments[1].resources[1].quantity == 99)
  for index, record in ipairs(records) do
    assert(record.sequence == index)
  end
end)

test("capacity lets the current trace finish but blocks a new one until cleared", function()
  local original = Trace.maxRecords
  Trace.maxRecords = 2
  local recorder = assert(Trace.New(nil, clock))
  assert(recorder:Start({}))
  assert(recorder:Capture("ONE") and recorder:Capture("TWO"))
  assert(recorder.recording and #recorder.database.records == 3)
  recorder:Stop()
  local ok, reason = recorder:Start({})
  assert(not ok and reason and not recorder.recording)
  assert(#recorder.database.records == 4 and recorder.database.stoppedReason == "capacity")
  assert(recorder.database.nextSequence == 5)
  local reloaded = assert(Trace.New(recorder.database, clock))
  assert(not reloaded:Start({}) and #reloaded.database.records == 4)
  assert(recorder:Clear() and recorder:Start({}))
  Trace.maxRecords = original
end)

test("previous record limit can resume after reload without clearing evidence", function()
  assert(Trace.maxRecords == 10000)
  local records = {}
  for sequence = 1, 2000 do
    records[sequence] = { sequence = sequence, event = "QUOTE_PROBE", payload = "{}" }
  end
  local database = { traceSchemaVersion = Trace.schemaVersion,
    traceExportVersion = Trace.exportVersion, nextSequence = 2001,
    records = records, bytes = 1958110, stoppedReason = "capacity" }
  local recorder = assert(Trace.New(database, clock))
  assert(not recorder.recording and recorder:Start({ character = "mock" }))
  assert(database.stoppedReason == nil and #database.records == 2001)
  assert(database.records[1] == records[1] and database.records[2001].sequence == 2001)
end)

test("recording continues past the old total byte limit", function()
  local recorder = assert(Trace.New(nil, clock))
  recorder.database.bytes = 12 * 1024 * 1024 - 100
  assert(recorder:Start({}) and recorder:Capture("EVENT"))
  assert(recorder.recording and #recorder.database.records == 2)
  assert(recorder.database.bytes > 12 * 1024 * 1024)
end)

test("large payloads still count toward the estimated byte total", function()
  local recorder = assert(Trace.New(nil, clock))
  recorder:Start({})
  local before = recorder.database.bytes
  assert(recorder:Capture("LARGE", { string.rep("x", 1900), string.rep("y", 1900) }))
  assert(recorder.database.bytes - before == #recorder.database.records[2].payload + #"LARGE" + 512)
end)

test("reload is paused and clear does not reuse event sequence numbers", function()
  local recorder = assert(Trace.New(nil, clock))
  recorder:Start({})
  assert(not recorder:Clear())
  recorder:Stop()
  local reloaded = assert(Trace.New(recorder.database, clock))
  assert(not reloaded.recording)
  assert(#reloaded.database.records == 2)
  assert(reloaded:Clear())
  reloaded:Start({})
  assert(reloaded.database.records[1].sequence == 3)
end)

test("legacy trace contract names migrate without mutating the source table", function()
  local legacy = {
    traceSchemaVersion = 1,
    exportContractVersion = 1,
    nextSequence = 4,
    records = { { sequence = 3, event = "OLD", payload = "{}", timestamp = 1, elapsed = 1 } },
    bytes = 10,
  }
  local recorder = assert(Trace.New(legacy, clock))
  assert(recorder.database.traceSchemaVersion == Trace.schemaVersion)
  assert(recorder.database.traceExportVersion == Trace.exportVersion)
  assert(recorder.database.exportContractVersion == nil)
  assert(recorder.database.records[1].event == "OLD" and recorder.database.nextSequence == 4)
  assert(legacy.traceSchemaVersion == 1 and legacy.exportContractVersion == 1)
  assert(legacy.traceExportVersion == nil)
end)

test("unknown schemas are not overwritten", function()
  local database = { traceSchemaVersion = 99, evidence = "keep" }
  local recorder, reason = Trace.New(database, clock)
  assert(not recorder and reason and database.evidence == "keep")
end)

test("unsafe or oversized payloads produce explicit diagnostics", function()
  local cyclic = {}; cyclic.self = cyclic
  local payload, warnings = Trace.Serialize({ cyclic, string.rep("x", 2049), function() end })
  assert(warnings:find("cycle", 1, true) and warnings:find("string-limit", 1, true) and warnings:find("function", 1, true))
  assert(decode("return " .. payload)[1].self.traceOmitted == "cycle")
  local secret = {}
  payload, warnings = Trace.Serialize({ secret }, function(value) return value == secret end)
  assert(warnings == "secret" and decode("return " .. payload)[1].traceOmitted == "secret")
  local wide = {}
  for index = 1, 1000 do wide[index] = index end
  payload, warnings = Trace.Serialize(wide)
  assert(#payload <= Trace.maxPayloadBytes and warnings ~= "")
end)

test("exports are deterministic and preserve control characters", function()
  local recorder = assert(Trace.New(nil, clock))
  recorder:Start({})
  recorder:Capture("TEXT", "quote\"\nline\000end\\")
  local exported = recorder:Export(1, 2)
  assert(exported == recorder:Export(1, 2))
  local decoded = decode(exported)
  assert(decoded.traceSchemaVersion == Trace.schemaVersion)
  assert(decoded.traceExportVersion == Trace.exportVersion)
  assert(decoded.exportContractVersion == nil)
  assert(decoded.records[2].arguments[1] == "quote\"\nline\000end\\")
end)

test("unsupported table keys cannot bypass the traversal budget", function()
  local wide, inspected = {}, 0
  for index = 1, 2000 do wide[function() return index end] = true end
  local _, warnings = Trace.Serialize(wide, function() inspected = inspected + 1; return false end)
  assert(inspected < 600 and warnings:find("table-limit", 1, true))
end)

test("sanitized Retail build 69933 evidence replays without identity inference", function()
  local fixture = dofile(testsRoot .. "/fixtures/retail-build-69933.lua")
  assert(fixture.build == "69933" and fixture.version == "12.1.0")
  local cases = {}

  for _, scenario in ipairs(fixture.cases) do
    cases[scenario.name] = scenario
    local recorder = assert(Trace.New(nil, clock))
    recorder:Start({ fixture = scenario.name, build = fixture.build })
    for _, observedEvent in ipairs(scenario.events) do
      recorder:Capture(observedEvent.name, unpack(observedEvent.arguments, 1, observedEvent.arguments.n))
    end
    local records = decode(recorder:Export(2, #scenario.events)).records
    assert(#records == #scenario.events)
    for index, observedEvent in ipairs(scenario.events) do
      assert(records[index].event == observedEvent.name)
      assert(Trace.Serialize(records[index].arguments) == Trace.Serialize(observedEvent.arguments))
      assert(records[index].warnings == nil)
    end
  end

  local function recordsNamed(scenario, eventName)
    local matching = {}
    for _, observedEvent in ipairs(scenario.events) do
      if observedEvent.name == eventName then matching[#matching + 1] = observedEvent end
    end
    return matching
  end

  local basicResults = recordsNamed(cases["basic-and-multicraft"], "TRADE_SKILL_ITEM_CRAFTED_RESULT")
  assert(#basicResults == 2)
  local firstBasic = basicResults[1].arguments[1]
  local multicraft = basicResults[2].arguments[1]
  assert(firstBasic.operationID ~= multicraft.operationID)
  assert(firstBasic.itemID == multicraft.itemID)
  assert(firstBasic.itemGUID == nil and multicraft.itemGUID == nil)
  assert(multicraft.multicraft == 10 and multicraft.quantity == 15)

  local batch = cases["concentration-batch-two"]
  local enchantCalls = recordsNamed(batch, "CALL_POST:C_TradeSkillUI.CraftEnchant")
  local batchResults = recordsNamed(batch, "TRADE_SKILL_ITEM_CRAFTED_RESULT")
  assert(#enchantCalls == 1 and enchantCalls[1].arguments[2] == 2)
  assert(#recordsNamed(batch, "TRADE_SKILL_CRAFT_BEGIN") == 2 and #batchResults == 2)
  local firstBatchResult = batchResults[1].arguments[1]
  local secondBatchResult = batchResults[2].arguments[1]
  assert(firstBatchResult.operationID ~= secondBatchResult.operationID)
  assert(firstBatchResult.concentrationSpent == 185 and firstBatchResult.hasIngenuityProc == false)
  assert(firstBatchResult.ingenuityRefund == 93)
  assert(secondBatchResult.concentrationSpent == 185 and secondBatchResult.hasIngenuityProc == false)
  assert(secondBatchResult.ingenuityRefund == 93)
  local currencyUpdates = recordsNamed(batch, "CURRENCY_DISPLAY_UPDATE")
  assert(#currencyUpdates == 2 and currencyUpdates[1].arguments[3] == -185)
  assert(currencyUpdates[2].arguments[3] == -185)

  local starts = recordsNamed(batch, "UNIT_SPELLCAST_START")
  local hasStartWithoutCastGUID, hasStartWithCastGUID = false, false
  for _, start in ipairs(starts) do
    if start.arguments[2] == nil then hasStartWithoutCastGUID = true else hasStartWithCastGUID = true end
  end
  assert(hasStartWithoutCastGUID and hasStartWithCastGUID)

  local resourceResults = recordsNamed(cases["resource-returns"], "TRADE_SKILL_ITEM_CRAFTED_RESULT")
  assert(#resourceResults == 3)
  local returned = resourceResults[1].arguments[1].resourcesReturned
  assert(#returned == 3)
  assert(returned[1].reagent.itemID == 236761 and returned[1].quantity == 4)
  assert(returned[2].reagent.itemID == 238511 and returned[2].quantity == 5)
  assert(returned[3].reagent.itemID == 238513 and returned[3].quantity == 6)
  assert(#resourceResults[3].arguments[1].resourcesReturned == 3)

  local detailsUpdates = recordsNamed(cases["crafting-details-update-burst"], "CRAFTING_DETAILS_UPDATE")
  assert(#detailsUpdates == 127)
  local serializedFixture = Trace.Serialize(fixture)
  assert(not serializedFixture:find("Player%-1309"))
  assert(not serializedFixture:find("Item%-1309"))
  assert(not serializedFixture:find("Cast%-3%-3890"))
  assert(not serializedFixture:find("Pozzo"))
  assert(not serializedFixture:find("Kral"))
  assert(not serializedFixture:find("hyperlink"))
  assert(not serializedFixture:find("itemGUID"))
end)

test("synthetic Retail scenarios preserve every supplied result field", function()
  local scenarios = dofile(testsRoot .. "/fixtures/retail-synthetic.lua")
  for _, scenario in ipairs(scenarios) do
    local recorder = assert(Trace.New(nil, clock))
    recorder:Start({ fixture = scenario.name, synthetic = true })
    for _, event in ipairs(scenario.events) do
      recorder:Capture(event.name, unpack(event.arguments, 1, event.arguments.n))
    end
    local records = decode(recorder:Export(2, #scenario.events)).records
    assert(#records == #scenario.events)
    for index, event in ipairs(scenario.events) do
      assert(records[index].event == event.name)
      assert(Trace.Serialize(records[index].arguments) == Trace.Serialize(event.arguments))
      assert(records[index].warnings == nil)
    end
  end
end)

print(string.format("%d tracer tests passed", passed))
