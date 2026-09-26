local root = arg[1] or "."
local addon = {}
assert(loadfile(root .. "/Flavors/Registry.lua"))("ArtisanLogbook", addon)
assert(loadfile(root .. "/Flavors/Retail/Adapter.lua"))("ArtisanLogbook", addon)
local passed = 0

local function test(name, callback)
  callback()
  passed = passed + 1
  print("PASS " .. name)
end

local function environment()
  local hooks = {}
  local frame = { events = {}, units = {} }
  function frame:RegisterEvent(event)
    if event == "TRADE_SKILL_CURRENCY_REWARD_RESULT" then error("unsupported") end
    self.events[event] = true
  end
  function frame:RegisterUnitEvent(event, unit)
    self.units[event] = unit
    self:RegisterEvent(event)
  end
  function frame:IsEventRegistered(event) return self.events[event] or false end
  function frame:SetScript(_, callback) self.onEvent = callback end
  local api = {
    WOW_PROJECT_ID = 1,
    WOW_PROJECT_MAINLINE = 1,
    CreateFrame = function() return frame end,
    C_TradeSkillUI = { CraftRecipe = function() end, CraftEnchant = function() end },
    hooksecurefunc = function(_, name, callback) hooks[name] = callback end,
  }
  return api, frame, hooks
end

test("Retail registers player-only unit events and reports unsupported events", function()
  local api, frame = environment()
  local received = {}
  local adapter = addon.CreateFlavorAdapter(api, function(event, ...)
    received[#received + 1] = { event = event, n = select("#", ...), ... }
  end)
  assert(adapter.capabilities.flavor == "retail")
  assert(frame.units.UNIT_SPELLCAST_SUCCEEDED == "player")
  assert(adapter.capabilities.events.TRADE_SKILL_ITEM_CRAFTED_RESULT)
  assert(adapter.capabilities.events.TRADE_SKILL_CURRENCY_REWARD_RESULT == false)
  assert(adapter.capabilities.measurements.concentrationSpent == nil)
  frame.onEvent(frame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 456, nil)
  assert(received[1].n == 4 and received[1][2] == "Cast-1")
end)

test("post-hooks preserve batch arguments and do not replace craft functions", function()
  local api, _, hooks = environment()
  local original = api.C_TradeSkillUI.CraftRecipe
  local received = {}
  local adapter = addon.CreateFlavorAdapter(api, function(event, ...)
    received[#received + 1] = { event = event, n = select("#", ...), ... }
  end)
  hooks.CraftRecipe(456, 3, { { itemID = 123, quantity = 2 } }, nil, nil, true)
  hooks.CraftEnchant(789, 1, nil, nil, false)
  assert(api.C_TradeSkillUI.CraftRecipe == original)
  assert(received[1].event == "CALL_POST:C_TradeSkillUI.CraftRecipe")
  assert(received[1].n == 6 and received[1][2] == 3 and received[1][6] == true)
  assert(received[2].event == "CALL_POST:C_TradeSkillUI.CraftEnchant")
  assert(adapter.capabilities.hooks.CraftSalvage == false)
end)

test("capture failures cannot propagate through a craft hook", function()
  local api, frame, hooks = environment()
  local adapter = addon.CreateFlavorAdapter(api, function() error("capture failure") end)
  hooks.CraftRecipe(456)
  frame.onEvent(frame, "TRADE_SKILL_CRAFT_BEGIN", 456)
  assert(adapter.capabilities.captureError == true)
end)

test("missing trade skill APIs or hooks do not break event registration", function()
  local api = environment()
  api.C_TradeSkillUI = nil
  api.hooksecurefunc = nil
  local adapter = addon.CreateFlavorAdapter(api, function() end)
  assert(adapter.capabilities.hooks.CraftRecipe == false)
  assert(adapter.capabilities.events.TRADE_SKILL_CRAFT_BEGIN)
end)

test("unsupported flavors never touch Retail APIs", function()
  local adapter = addon.CreateFlavorAdapter({ WOW_PROJECT_ID = 2, WOW_PROJECT_MAINLINE = 1 }, function() end)
  assert(adapter.capabilities.flavor == "other" and adapter.frame == nil)
  assert(next(adapter.capabilities.measurements) == nil)
end)

test("known non-Retail clients get an explicit empty flavor boundary", function()
  local api = { WOW_PROJECT_ID = 2, WOW_PROJECT_CLASSIC = 2 }
  local name, projectID = addon.DetectFlavor(api)
  local adapter = addon.CreateFlavorAdapter(api, function() end)
  assert(name == "classic" and projectID == 2)
  assert(adapter.capabilities.flavor == "classic")
  assert(next(adapter.capabilities.events) == nil and next(adapter.capabilities.measurements) == nil)
end)

print(string.format("%d adapter tests passed", passed))
