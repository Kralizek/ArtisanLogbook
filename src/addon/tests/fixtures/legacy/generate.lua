-- Regenerates the schema-v1 migration fixtures with the historical Ledger code that wrote them.
-- Usage from the repository root:
--   git show 8d9bb24:src/addon/src/ArtisanLogbook_Core/Storage/Ledger.lua > /tmp/Ledger-pre21.lua
--   lua5.1 src/addon/tests/fixtures/legacy/generate.lua /tmp/Ledger-pre21.lua pre21 \
--     > src/addon/tests/fixtures/legacy/v1-pre21.lua
-- Revisions: 8d9bb24 (pre-#21, no outcomeVersion), 6c7f50b (PR #21 outcomeVersion=1),
-- b5e24c6 (outcomeVersion=2). Item and recipe IDs below 1238000 come from the sanitized
-- build-69933 fixtures; prospecting/crushing IDs are synthetic placeholders.
local ledgerPath, variant = arg[1], arg[2]
local addon = {}
assert(loadfile(ledgerPath))("ArtisanLogbook_Core", addon)
local Ledger = addon.Ledger

local day0 = 1790000000 - 1790000000 % 86400 + 3600
local clock = { current = day0 }
function clock.wall() return clock.current end

local function session(ledger, name)
  assert(ledger:CreateSession({ startedAt = clock.current, addonVersion = "0.1.0", wowVersion = "12.1.0",
    wowBuild = "69933", projectId = 1, regionId = 3, gameRealmId = 1309, realmName = "Sanitized Realm",
    characterName = name, characterGUID = "Player-Sanitized-" .. name, locale = "enUS",
    capabilities = { flavor = "retail", measurements = {} } }))
end

local function returns(list)
  local result = {}
  for index, entry in ipairs(list) do
    result[index] = { reagent = { itemID = entry[1] }, quantity = entry[2] }
  end
  return result
end

local operation = 5000
local function result(itemId, returned, extra)
  operation = operation + 1
  local value = { operationID = operation, itemID = itemId, quantity = 1, craftingQuality = 2,
    multicraft = 0, concentrationSpent = 0, concentrationCurrencyID = 3161,
    hasIngenuityProc = false, ingenuityRefund = 0, resourcesReturned = returned }
  for key, field in pairs(extra or {}) do value[key] = field end
  return value
end

local function personal(ledger, recipeId, count, selections, results)
  ledger:BeginCraft(recipeId)
  assert(ledger:SubmitCraft(recipeId, count, false,
    { concentrationCost = 0, baseSkill = 120, baseDifficulty = 200, craftingQuality = 2 }, selections))
  for _, value in ipairs(results) do assert(ledger:RecordResult(value)) end
end

local function slots(list)
  local result = {}
  for index, entry in ipairs(list) do
    result[index] = { dataSlotIndex = entry[1], quantity = entry[3], quality = entry[4],
      reagent = { itemID = entry[2] } }
  end
  return result
end

local function history(ledger)
  session(ledger, "Alchemist")
  for _, item in ipairs({ { 240991, "Mote" }, { 238511, "Bloom" }, { 236761, "Ore" },
      { 238513, "Flux" }, { 241307, "Potion" }, { 244615, "Ring" } }) do
    assert(ledger:AddDimension("item", item[1], { name = item[2] }))
  end
  local alchemy = assert(ledger:AddDimension("profession", 171, { name = "Alchemy" }))
  local jewelcrafting = assert(ledger:AddDimension("profession", 755, { name = "Jewelcrafting" }))
  assert(ledger:AddDimension("recipe", 1230868, { name = "Potion", professionId = alchemy }))
  assert(ledger:AddDimension("recipe", 1237557, { name = "Ring", professionId = jewelcrafting }))
  -- Positive, nil and duplicate-slot outcomes (later aged out by retention).
  personal(ledger, 1230868, 2, slots({ { 1, 240991, 3, 1 }, { 2, 238511, 2, 2 } }), {
    result(241307, returns({ { 240991, 1 } })), result(241307, nil) })
  personal(ledger, 1237557, 1, slots({ { 1, 236761, 5, 1 }, { 2, 236761, 7, 1 }, { 3, 238513, 2, 3 } }), {
    result(244615, returns({ { 236761, 2 } })) })
end

local function recent(ledger)
  session(ledger, "Alchemist")
  personal(ledger, 1230868, 3, slots({ { 1, 240991, 3, 1 }, { 2, 238511, 2, 2 } }), {
    result(241307, returns({ { 240991, 1 }, { 238511, 1 } })), result(241307, nil),
    result(241307, {}) })
  personal(ledger, 1237557, 1, slots({ { 1, 236761, 5, 1 }, { 2, 236761, 7, 1 }, { 3, 238513, 2, 3 } }), {
    result(244615, returns({ { 236761, 2 } })) })
  personal(ledger, 1237557, 1, slots({ { 1, 236761, 5, 1 }, { 2, 236761, 7, 1 }, { 3, 238513, 2, 3 } }), {
    result(244615, nil) })
  -- Request without a captured quote selection.
  personal(ledger, 1230868, 1, nil, { result(241307, nil) })
  -- Malformed list with one provable positive.
  personal(ledger, 1230868, 1, slots({ { 1, 240991, 3, 1 }, { 2, 238511, 2, 2 } }), {
    result(241307, { { reagent = { itemID = 240991 }, quantity = 1 }, { reagent = {} } }) })
  -- First-craft reward recorded by legacy capture as another result with the parent's ID.
  local parent = result(241307, nil)
  personal(ledger, 1230868, 1, slots({ { 1, 240991, 3, 1 }, { 2, 238511, 2, 2 } }), { parent })
  assert(ledger:RecordResult({ operationID = parent.operationID, itemID = 238511, quantity = 1,
    firstCraftReward = true }))
  -- Enchanting batch (CraftEnchant has no request snapshot) and an unknown-recipe result.
  ledger:InvalidateCraft()
  ledger:BeginCraft(1236083)
  assert(ledger:RecordResult(result(244005, nil, { concentrationSpent = 185, ingenuityRefund = 93,
    concentrationCurrencyID = 3163, isEnchant = true })))
  ledger:BeginCraft(1236083)
  assert(ledger:RecordResult(result(244005, nil, { concentrationSpent = 185, ingenuityRefund = 93,
    concentrationCurrencyID = 3163, isEnchant = true })))
  ledger:CancelCraft()
  assert(ledger:RecordResult(result(244615, nil)))
  session(ledger, "Jeweler")
  -- Synthetic prospecting/crushing salvage: one call, several item callbacks sharing an ID.
  ledger:InvalidateCraft()
  ledger:BeginCraft(1238000)
  local prospect = result(1238100, nil, { quantity = 2 })
  assert(ledger:RecordResult(prospect))
  assert(ledger:RecordResult({ operationID = prospect.operationID, itemID = 1238101, quantity = 1 }))
  ledger:CancelCraft()
  ledger:BeginCraft(1238001)
  assert(ledger:RecordResult(result(1238102, returns({ { 1238200, 1 } }), { quantity = 3 })))
  ledger:CancelCraft()
end

local ledger = assert(Ledger.New(nil, clock))
history(ledger)
clock.current = clock.current + 70 * 86400
ledger = assert(Ledger.New(ledger.database, clock))
recent(ledger)
clock.current = clock.current + 3600
ledger = assert(Ledger.New(ledger.database, clock))
local database = ledger.database

local function serialize(value, indent)
  if type(value) == "number" then
    if value % 1 == 0 and math.abs(value) < 2 ^ 53 then return string.format("%.0f", value) end
    return string.format("%.17g", value)
  elseif type(value) ~= "table" then
    return type(value) == "string" and string.format("%q", value) or tostring(value)
  end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(left, right)
    if type(left) ~= type(right) then return type(left) == "number" end
    return left < right
  end)
  local nextIndent = indent .. "  "
  local lines = {}
  for _, key in ipairs(keys) do
    local name = type(key) == "string" and key:match("^[%a_][%w_]*$") and key or "[" .. serialize(key, "") .. "]"
    lines[#lines + 1] = nextIndent .. name .. " = " .. serialize(value[key], nextIndent) .. ","
  end
  if #lines == 0 then return "{}" end
  return "{\n" .. table.concat(lines, "\n") .. "\n" .. indent .. "}"
end

io.write("-- Generated by tests/fixtures/legacy/generate.lua with the ", variant,
  " Ledger revision; do not edit by hand.\n")
io.write("-- Loaded at ", string.format("%.0f", clock.current), " UTC seconds; day-0 details were pruned on reload.\n")
io.write("return ", serialize(database, ""), "\n")
