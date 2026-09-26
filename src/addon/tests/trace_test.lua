local root = arg[1] or "."
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

test("capacity stops recording without evicting earlier evidence", function()
  local original = Trace.maxRecords
  Trace.maxRecords = 2
  local recorder = assert(Trace.New(nil, clock))
  recorder:Start({})
  recorder:Capture("ONE")
  local ok, reason = recorder:Capture("TWO")
  assert(not ok and reason and not recorder.recording)
  assert(#recorder.database.records == 2 and recorder.database.stoppedReason == "capacity")
  assert(recorder.database.nextSequence == 3)
  Trace.maxRecords = original
end)

test("byte capacity is enforced", function()
  local original = Trace.maxBytes
  Trace.maxBytes = 1
  local recorder = assert(Trace.New(nil, clock))
  assert(not recorder:Start({}))
  assert(#recorder.database.records == 0 and not recorder.recording)
  Trace.maxBytes = original
end)

test("large payloads count toward the byte budget without truncating accounting", function()
  local original = Trace.maxBytes
  Trace.maxBytes = 5000
  local recorder = assert(Trace.New(nil, clock))
  recorder:Start({})
  assert(recorder:Capture("LARGE", { string.rep("x", 1900), string.rep("y", 1900) }))
  assert(recorder.database.bytes > 4000)
  assert(not recorder:Capture("OVERFLOW", string.rep("z", 1000)))
  Trace.maxBytes = original
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
  assert(decode(exported).records[2].arguments[1] == "quote\"\nline\000end\\")
end)

test("unsupported table keys cannot bypass the traversal budget", function()
  local wide, inspected = {}, 0
  for index = 1, 2000 do wide[function() return index end] = true end
  local _, warnings = Trace.Serialize(wide, function() inspected = inspected + 1; return false end)
  assert(inspected < 600 and warnings:find("table-limit", 1, true))
end)

test("synthetic Retail scenarios preserve every supplied result field", function()
  local scenarios = dofile(root .. "/tests/fixtures/retail-synthetic.lua")
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
