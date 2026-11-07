local root = arg[1] or "src/ArtisanLogbook_Core"
local passed = 0
local function test(name, run)
  run()
  passed = passed + 1
  print("PASS " .. name)
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end
local function equal(left, right)
  if type(left) ~= "table" then assert(left == right); return end
  assert(type(right) == "table")
  for key, value in pairs(left) do equal(value, right[key]) end
  for key in pairs(right) do assert(left[key] ~= nil) end
end

local function environment(flavor, legacyResize)
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.SlashCmdList, env.UISpecialFrames, env.frames, env.messages = {}, {}, {}, {}
  env.ChatFontNormal = {}
  local methods = {}
  for _, name in ipairs({ "SetPoint", "ClearAllPoints", "SetClampedToScreen", "SetMovable", "SetResizable",
    "EnableMouse", "RegisterForDrag", "SetAllPoints", "SetColorTexture", "SetJustifyH",
    "SetAutoFocus", "SetMaxLetters", "SetMultiLine", "SetFontObject", "SetTextInsets",
    "SetCursorPosition", "SetOrientation", "SetThumbTexture", "SetValueStep", "EnableMouseWheel",
    "SetFrameStrata", "SetNormalTexture", "SetHighlightTexture", "SetWordWrap" }) do
    methods[name] = function() end
  end
  function methods:SetScript(name, callback) self.scripts[name] = callback end
  function methods:RegisterEvent(event) self.events[event] = true end
  function methods:RegisterUnitEvent(event) self.events[event] = true end
  function methods:IsEventRegistered(event) return self.events[event] == true end
  function methods:UnregisterEvent(event) self.events[event] = nil end
  function methods:SetResizeBounds(...) self.bounds = { ... } end
  function methods:SetMinResize(w, h) self.bounds = { w, h } end
  function methods:SetMaxResize(w, h) self.bounds[3], self.bounds[4] = w, h end
  function methods:SetSize(w, h)
    self.width, self.height = w, h
    if self.scripts.OnSizeChanged then self.scripts.OnSizeChanged(self, w, h) end
  end
  function methods:SetWidth(w) self.width = w end
  function methods:SetHeight(h) self.height = h end
  function methods:GetWidth() return self.width or 1024 end
  function methods:GetHeight() return self.height or (self.kind == "ScrollFrame" and 250 or 768) end
  function methods:GetCenter() return 510, 400 end
  function methods:SetFontString(value) self.fontString = value end
  function methods:SetText(value)
    self.text = value
    if self.kind == "EditBox" then
      local _, lines = value:gsub("\n", "")
      self:SetHeight(18 * math.max(lines + 1, math.ceil(#value / 80)))
    end
  end
  function methods:GetText() return self.text end
  function methods:Hide()
    local wasShown = self.shown
    self.shown = false
    if wasShown and self.scripts.OnHide then self.scripts.OnHide(self) end
  end
  function methods:Show()
    local wasShown = self.shown
    self.shown = true
    if not wasShown and self.scripts.OnShow then self.scripts.OnShow(self) end
  end
  function methods:IsShown() return self.shown end
  function methods:SetEnabled(enabled) self.enabled = enabled end
  function methods:SetScrollChild(child) self.child = child end
  function methods:SetVerticalScroll(value) self.offset = value end
  function methods:GetVerticalScroll() return self.offset or 0 end
  function methods:SetMinMaxValues(low, high) self.low, self.high = low, high end
  function methods:SetValue(value)
    self.value = math.max(self.low or 0, math.min(self.high or 0, value))
    if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, self.value) end
  end
  function methods:SetFocus() self.focused = true end
  function methods:ClearFocus() self.focused = false end
  function methods:HighlightText() self.selectedText = self.text end
  function methods:StartMoving() self.moving = true end
  function methods:StopMovingOrSizing() self.moving, self.sizing = false, false end
  function methods:StartSizing(point) self.sizing = point end
  function methods:CreateTexture() return env.CreateFrame("Texture", nil, self) end
  function methods:CreateFontString() return env.CreateFrame("FontString", nil, self) end
  env.CreateFrame = function(kind, name, parent, template)
    assert(template == nil, "inspector must not need Blizzard templates")
    local frame = setmetatable({ kind = kind, name = name, parent = parent,
      scripts = {}, events = {}, shown = true }, { __index = methods })
    if legacyResize then frame.SetResizeBounds = false end
    env.frames[#env.frames + 1] = frame
    return frame
  end
  env.UIParent = env.CreateFrame("Frame")
  env.UIParent:SetSize(1280, 800)
  env.GetServerTime = function() return 1800000000 end
  env.GetBuildInfo = function() return flavor == "forever" and "1.60.1" or "12.1.5", "70862", "mock",
    flavor == "forever" and 16001 or 120105 end
  env.GetLocale = function() return "enUS" end
  env.UnitName = function() return "Test" end
  env.UnitGUID = function() return "Player-Test" end
  env.GetRealmName = function() return "Realm" end
  env.C_AddOns = { GetAddOnMetadata = function() return "test-version" end }
  env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) env.messages[#env.messages + 1] = message end }
  env.WOW_PROJECT_MAINLINE, env.WOW_PROJECT_CAMELOT = 1, 18
  env.WOW_PROJECT_ID = flavor == "forever" and 18 or 1
  env.C_TradeSkillUI = { CraftRecipe = function() end,
    GetAllRecipeIDs = function() return {} end,
    GetRecipeInfo = function() return nil end, GetRecipeSchematic = function() return nil end }
  env.hooksecurefunc = function() end
  local addon = {}
  for line in io.lines(root .. "/ArtisanLogbook_Core.toc") do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      setfenv(assert(loadfile(root .. "/" .. line)), env)("ArtisanLogbook_Core", addon)
    end
  end
  local lifecycle = env.frames[2]
  lifecycle.scripts.OnEvent(lifecycle, "ADDON_LOADED", "ArtisanLogbook_Core")
  assert(addon.ledger, addon.ledgerError)
  return addon, env
end
local function render(inspector, value)
  local renderer = inspector.Format(value)
  local steps = 0
  while not renderer.done do
    renderer:Step()
    steps = steps + 1
    assert(steps < 40000, "renderer must terminate")
  end
  return table.concat(renderer.pages), renderer
end
local function settle(window)
  local count = 0
  while window.scripts.OnUpdate do
    window.scripts.OnUpdate(window, 0.016)
    count = count + 1
    assert(count < 10000)
  end
end
local function click(control) control.scripts.OnClick(control) end

test("Core is lazy and slash toggles one template-free instance on both clients", function()
  for _, flavor in ipairs({ "retail", "forever" }) do
    local addon, env = environment(flavor)
    assert(not addon.debugWindow and env.SLASH_ARTISANLOGBOOKDEBUG1 == "/al_debug")
    assert(not env.ArtisanLogbookTraceDB and not env.ArtisanLogbookUISettings)
    assert(env.ArtisanLogbookAPI.GetCapabilities().flavor == flavor)
    env.SlashCmdList.ARTISANLOGBOOKDEBUG()
    local window, count = addon.debugWindow, #env.frames
    assert(window:IsShown() and not window.scripts.OnUpdate)
    env.SlashCmdList.ARTISANLOGBOOKDEBUG()
    assert(not window:IsShown())
    env.SlashCmdList.ARTISANLOGBOOKDEBUG()
    assert(window:IsShown() and count == #env.frames and addon.debugWindow == window)
    assert(#env.messages == 0)
  end
end)

test("structured output is deterministic, typed, nested and does not run functions or metamethods", function()
  local addon = environment("retail")
  local a = { z = true, a = { [3] = "three", [1] = false }, [false] = 9, [2] = "two" }
  local b = { [2] = "two", [false] = 9, a = { [1] = false, [3] = "three" }, z = true }
  local expected = '{\n  [2] = "two",\n  ["a"] = {\n    [1] = false,\n    [3] = "three",\n  },\n  ["z"] = true,\n  [false] = 9,\n}'
  assert(render(addon.Inspector, a) == expected and render(addon.Inspector, b) == expected)
  assert(render(addon.Inspector, nil) == "nil")
  assert(render(addon.Inspector, "true") == '"true"' and render(addon.Inspector, true) == "true")
  local dangerous = setmetatable({ callback = function() error("must never run") end }, {
    __index = function() error("no __index") end, __tostring = function() error("no tostring") end,
    __pairs = function() error("no pairs") end })
  assert(render(addon.Inspector, dangerous):find("<function>", 1, true))
end)

test("cycles, deep tables and traversal budgets terminate with explicit notices", function()
  local addon = environment("retail")
  local cycle = {}; cycle.self = cycle
  assert(render(addon.Inspector, cycle):find("<cycle>", 1, true))
  local deep, node = {}, nil; node = deep
  for _ = 1, 30 do node.child = {}; node = node.child end
  local value, renderer = render(addon.Inspector, deep)
  assert(value:find("<depth limit", 1, true) and renderer.limited)
  local huge = {}
  for index = 1, 5001 do huge[index] = index end
  value, renderer = render(addon.Inspector, huge)
  assert(value:find("safe key budget", 1, true) and renderer.limited)
  value, renderer = render(addon.Inspector, string.rep("x", 1600000))
  assert(value:find("total inspection budget", 1, true) and renderer.limited)
  assert(#renderer.pages < 130)
end)

test("secret and inaccessible values and keys are never traversed or coerced", function()
  local addon, env = environment("retail")
  local secret, inaccessible = {}, {}
  setmetatable(secret, { __tostring = function() error("secret coercion") end })
  env.issecretvalue = function(value) return rawequal(value, secret) end
  env.canaccesstable = function(value) return not rawequal(value, inaccessible) end
  assert(render(addon.Inspector, secret) == "<secret or inaccessible value>")
  assert(render(addon.Inspector, inaccessible) == "<inaccessible table>")
  local value, renderer = render(addon.Inspector, { allowed = 1, private = secret, [secret] = "hidden" })
  assert(value:find("secret", 1, true) and not value:find("hidden", 1, true) and renderer.limited)
  env.issecretvalue = function() error("guard failed") end
  assert(render(addon.Inspector, "unreadable") == "<secret or inaccessible value>")
end)

test("large raw values use complete bounded chunks with reversible text escaping", function()
  local addon = environment("retail")
  local original = string.rep("a\n|", 10000)
  local value, renderer = render(addon.Inspector, original)
  assert(value == '"' .. addon.Inspector.Escape(original) .. '"' and #renderer.pages > 1)
  assert(not renderer.limited)
  for _, page in ipairs(renderer.pages) do assert(#page <= 12000 and not page:find("|", 1, true)) end
  assert(original == string.rep("a\n|", 10000))
  value, renderer = render(addon.Inspector, string.rep("x", 11998))
  assert(#value == 12000 and #renderer.pages == 1 and renderer.done)
end)

test("missing, thrown, nil, wrong-shaped and secret API responses are shown actionably", function()
  local addon, env = environment("forever")
  env.SlashCmdList.ARTISANLOGBOOKDEBUG()
  local window, api = addon.debugWindow, env.ArtisanLogbookAPI
  api.GetDiagnostics = nil
  window:Section("Diagnostics")
  assert(window.text:GetText():find("unavailable", 1, true))
  api.GetDiagnostics = function() error("test failure") end
  window:Refresh()
  assert(window.text:GetText():find("failed", 1, true))
  api.GetDiagnostics = function() return nil, "not-ready" end
  window:Refresh()
  assert(window.text:GetText():find("not-ready", 1, true))
  api.GetDiagnostics = function() return "wrong" end
  window:Refresh()
  assert(window.text:GetText():find("unexpected", 1, true))
  local secret = {}
  env.issecretvalue = function(value) return rawequal(value, secret) end
  api.GetDiagnostics = function() return secret end
  window:Refresh()
  assert(window.text:GetText():find("secret", 1, true))
end)

test("session queries are detached, paged, current-aware and connected to craft projections", function()
  local addon, env = environment("retail")
  local ledger, api = addon.ledger, env.ArtisanLogbookAPI
  for index = 1, 30 do
    ledger:CreateSession({ startedAt = index, wowBuild = "build-" .. index,
      capabilities = { flavor = "retail", events = { EVENT = true } } })
  end
  local first = api.GetSessions({ limit = 3 })
  assert(#first.sessions == 3 and first.sessions[1].id == ledger.currentSessionId)
  assert(first.currentSessionId == ledger.currentSessionId and first.nextCursor)
  local nextPage = api.GetSessions({ limit = 3, cursor = first.nextCursor })
  assert(nextPage.sessions[1].id < first.sessions[3].id)
  first.sessions[1].capabilities.events.EVENT = false
  assert(api.GetSession(ledger.currentSessionId).capabilities.events.EVENT == true)
  assert(select(2, api.GetSession(0)) == "invalid-id")
  assert(select(2, api.GetSession(99999)) == "not-found")
  for _, options in ipairs({ { limit = 0 }, { limit = 201 }, { limit = false }, { cursor = 1 },
      { cursor = "wrong" }, { cursor = "sessions:1:99999:1" }, { direction = "asc" } }) do
    assert(api.GetSessions(options) == nil)
  end
  assert(api.GetSessions(false) == nil)
  ledger:CreateSession({ startedAt = 1000 })
  local seen, cursor = {}, first.nextCursor
  repeat
    local page = assert(api.GetSessions({ limit = 3, cursor = cursor }))
    for _, row in ipairs(page.sessions) do assert(not seen[row.id]); seen[row.id] = true end
    cursor = page.nextCursor
  until not cursor
  assert(not seen[ledger.currentSessionId], "new sessions must not leak into an older page snapshot")
  addon.ledger = nil
  assert(select(2, api.GetSessions()) == "not-ready" and select(2, api.GetSession(1)) == "not-ready")
end)

test("large craft history stays paged, newest is easy to inspect and all public reagents are present", function()
  local addon, env = environment("retail")
  local ledger = addon.ledger
  for index = 1, 150 do
    assert(ledger:SubmitCraft(2331, 1, false))
    assert(ledger:RecordResult({ operationID = index, itemID = 2455, quantity = 1 }))
  end
  local original = copy(ledger.database)
  env.SlashCmdList.ARTISANLOGBOOKDEBUG()
  local window, count = addon.debugWindow, #env.frames
  window:Section("Crafts")
  assert(#window.records == 12 and window.records[1].id == 150)
  click(window.rows[1])
  assert(window.selectedId == 150 and window.selected.reagents and window.selected.request)
  assert(window.selected.sessionId == ledger.currentSessionId)
  click(window.controls.mode); settle(window)
  assert(window.text:GetText():find('"reagents"', 1, true))
  click(window.controls.session)
  assert(window.section == "Sessions" and window.selected.id == ledger.currentSessionId)
  window:Section("Crafts")
  local seen, total = {}, 0
  repeat
    for _, record in ipairs(window.records) do assert(not seen[record.id]); seen[record.id] = true; total = total + 1 end
    if not window.response.nextCursor then break end
    click(window.controls.next)
  until false
  assert(total == 150 and #env.frames == count)
  click(window.controls.previous)
  assert(window.dataPage == 12)
  click(window.rows[1])
  click(window.controls.session)
  click(window.controls.previous)
  assert(window.section == "Sessions" and window.dataPage == 1 and not window.failure)
  window:Section("Crafts")
  assert(window.records[1].id == 150)
  equal(original, ledger.database)
end)

test("copy/export covers whole text pages, paging is bounded, scrolling and resizing work", function()
  local addon, env = environment("forever", true)
  env.SlashCmdList.ARTISANLOGBOOKDEBUG()
  local window = addon.debugWindow
  env.ArtisanLogbookAPI.GetDiagnostics = function() return { large = string.rep("x\n", 16000) } end
  window:Section("Diagnostics")
  click(window.controls.export); settle(window)
  assert(window.mode == "Export" and window.renderer)
  local pages = {}
  repeat
    click(window.controls.copy)
    assert(window.text.focused and window.text.selectedText == window.displayText)
    assert(#window.text.selectedText <= 12000)
    pages[#pages + 1] = window.text.selectedText
    if window.renderer.done and window.rawPage == #window.renderer.pages then break end
    click(window.controls.textNext); settle(window)
  until false
  assert(table.concat(pages) == render(addon.Inspector, window.selected))
  click(window.controls.textPrevious); settle(window)
  assert(window.rawPage == #pages - 1)
  window.scroll.scripts.OnMouseWheel(window.scroll, -1)
  assert(window.scroll:GetVerticalScroll() > 0)
  window.text.scripts.OnTextChanged(window.text, true)
  assert(window.text:GetText() == window.displayText)
  window.titleBar.scripts.OnDragStart(window.titleBar)
  assert(window.moving)
  window.titleBar.scripts.OnDragStop(window.titleBar)
  assert(not window.moving and env.ArtisanLogbookDebugSettings.width == window:GetWidth())
  window.resize.scripts.OnMouseDown(window.resize, "LeftButton")
  assert(window.sizing == "BOTTOMRIGHT" and window.bounds[1] == 620)
  window:SetSize(1000, 700)
  window.resize.scripts.OnMouseUp(window.resize, "LeftButton")
  assert(not window.sizing and env.ArtisanLogbookDebugSettings.width == 1000)
  click(window.close)
  assert(not window:IsShown() and not window.scripts.OnUpdate and not window.text.focused)
end)

test("opening, refreshing and exporting all sections never executes management, observers or mutations", function()
  local addon, env = environment("retail")
  local before = copy(addon.ledger.database)
  local function forbidden() error("inspection executed a mutation") end
  env.ArtisanLogbookManagement = setmetatable({}, { __index = function() return forbidden end })
  addon.ledger.onCraftCommitted, addon.diagnosticObserver = forbidden, forbidden
  env.ArtisanLogbookAPI.SetDiagnosticObserver = forbidden
  env.ArtisanLogbookAPI.RegisterCallback = forbidden
  env.ArtisanLogbookAPI.Execute = forbidden
  env.SlashCmdList.ARTISANLOGBOOKDEBUG()
  for _, section in ipairs({ "Capabilities", "Diagnostics", "Crafts", "Sessions" }) do
    addon.debugWindow:Section(section)
    click(addon.debugWindow.controls.refresh)
    click(addon.debugWindow.controls.export); settle(addon.debugWindow)
  end
  equal(before, addon.ledger.database)
  assert(#env.messages == 0)
end)

test("raw rendering never polls APIs and closing or switching to Summary stops pending work", function()
  local addon, env = environment("forever")
  env.SlashCmdList.ARTISANLOGBOOKDEBUG()
  local window, calls = addon.debugWindow, 0
  env.ArtisanLogbookAPI.GetDiagnostics = function()
    calls = calls + 1
    return { large = string.rep("x", 50000) }
  end
  window:Section("Diagnostics")
  click(window.controls.mode)
  assert(window.scripts.OnUpdate)
  settle(window)
  assert(calls == 1 and not window.scripts.OnUpdate)
  click(window.controls.textNext)
  click(window.close)
  assert(not window.scripts.OnUpdate and calls == 1)
  env.SlashCmdList.ARTISANLOGBOOKDEBUG()
  assert(calls == 2)
  click(window.controls.mode)
  assert(window.mode == "Summary" and not window.scripts.OnUpdate)
  click(window.controls.refresh)
  assert(calls == 3)
end)

test("geometry preferences are separate, validated and reused without modifying ledger or command registrations", function()
  local addon, env = environment("retail")
  env.ArtisanLogbookDebugSettings = { width = -1, height = math.huge, x = -9999, y = 9999 }
  local original = copy(addon.ledger.database)
  local dump = function() end
  env.SlashCmdList.DUMP = dump
  env.SlashCmdList.ARTISANLOGBOOKDEBUG()
  local window = addon.debugWindow
  assert(window:GetWidth() == 620 and window:GetHeight() == 640)
  assert(env.SlashCmdList.DUMP == dump)
  window:SetSize(900, 600)
  window.resize.scripts.OnMouseUp(window.resize, "LeftButton")
  assert(env.ArtisanLogbookDebugSettings.width == 900 and env.ArtisanLogbookDebugSettings.height == 600)
  local settings = copy(env.ArtisanLogbookDebugSettings)
  local nextAddon, nextEnv = environment("retail")
  nextEnv.ArtisanLogbookDebugSettings = settings
  nextEnv.SlashCmdList.ARTISANLOGBOOKDEBUG()
  assert(nextAddon.debugWindow:GetWidth() == 900 and nextAddon.debugWindow:GetHeight() == 600)
  equal(settings, nextEnv.ArtisanLogbookDebugSettings)
  equal(original, addon.ledger.database)
end)

print(passed .. " diagnostics tests passed")
