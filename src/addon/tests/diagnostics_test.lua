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
    "SetNormalTexture", "SetHighlightTexture", "SetWordWrap" }) do
    methods[name] = function() end
  end
  function methods:SetPoint(point, relative, relativePoint, x, y)
    if type(relative) ~= "table" then
      relative, relativePoint, x, y = nil, nil, relative, relativePoint
    end
    self.anchors[#self.anchors + 1] = { point = point, relative = relative or self.parent,
      relativePoint = relativePoint or point, x = x or 0, y = y or 0 }
  end
  function methods:ClearAllPoints() self.anchors, self.all = {}, nil end
  function methods:SetAllPoints(relative) self.anchors, self.all = {}, relative or self.parent end
  function methods:EnableMouse(enabled) self.mouse = enabled end
  function methods:RegisterForClicks(...) self.clicks = { ... } end
  function methods:RegisterForDrag(...) self.drag = { ... } end
  function methods:SetFrameStrata(strata) self.strata = strata end
  function methods:GetFrameStrata()
    return self.strata or (self.parent and self.parent:GetFrameStrata()) or "MEDIUM"
  end
  function methods:SetFrameLevel(level) self.level = level end
  function methods:GetFrameLevel() return self.level end
  function methods:SetTextColor(...) self.color = { ... } end
  function methods:LockHighlight() self.highlightLocked = true end
  function methods:UnlockHighlight() self.highlightLocked = false end
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
    local frame = setmetatable({ kind = kind, name = name, parent = parent, anchors = {},
      scripts = {}, events = {}, shown = true, level = parent and parent.level and parent.level + 1 or 0,
      -- WoW buttons and edit boxes receive mouse input and left-button-up clicks by default.
      mouse = kind == "Button" or kind == "EditBox",
      clicks = kind == "Button" and { "LeftButtonUp" } or nil }, { __index = methods })
    if name then env[name] = frame end
    if legacyResize then frame.SetResizeBounds = false end
    env.frames[#env.frames + 1] = frame
    return frame
  end
  env.UIParent = env.CreateFrame("Frame")
  env.UIParent:SetSize(1280, 800)
  env.date = os.date
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

-- Minimal anchor geometry and hit-testing model: the topmost shown, mouse-enabled
-- frame under the cursor wins by strata then frame level; equal tops are ambiguous.
local strata = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, TOOLTIP = 7 }
local horizontal = { TOPLEFT = "left", LEFT = "left", BOTTOMLEFT = "left", TOPRIGHT = "right",
  RIGHT = "right", BOTTOMRIGHT = "right", TOP = "center", BOTTOM = "center", CENTER = "center" }
local vertical = { TOPLEFT = "top", TOP = "top", TOPRIGHT = "top", BOTTOMLEFT = "bottom",
  BOTTOM = "bottom", BOTTOMRIGHT = "bottom", LEFT = "middle", RIGHT = "middle", CENTER = "middle" }
local function rect(env, frame)
  if frame == env.UIParent then return { left = 0, bottom = 0, right = frame.width, top = frame.height } end
  if frame.all then return rect(env, frame.all) end
  local x, y = {}, {}
  for _, anchor in ipairs(frame.anchors) do
    local relative = assert(rect(env, anchor.relative), "relative frame is unanchored")
    local h, v = horizontal[anchor.relativePoint], vertical[anchor.relativePoint]
    local px = h == "left" and relative.left or h == "right" and relative.right or (relative.left + relative.right) / 2
    local py = v == "top" and relative.top or v == "bottom" and relative.bottom or (relative.top + relative.bottom) / 2
    x[horizontal[anchor.point]], y[vertical[anchor.point]] = px + anchor.x, py + anchor.y
  end
  local width, height = frame.width or 0, frame.height or 0
  local left = x.left or (x.right and x.right - width) or (x.center and x.center - width / 2)
  local right = x.right or (left and left + width)
  local top = y.top or (y.bottom and y.bottom + height) or (y.middle and y.middle + height / 2)
  local bottom = y.bottom or (top and top - height)
  if not (left and right and top and bottom) then return nil end
  return { left = left, right = right, top = top, bottom = bottom }
end
local function visibleOnScreen(frame)
  while frame do
    if not frame.shown then return false end
    frame = frame.parent
  end
  return true
end
local function center(env, frame)
  local area = assert(rect(env, frame))
  return (area.left + area.right) / 2, (area.top + area.bottom) / 2
end
local function hit(env, x, y)
  local best, bestKey, tied
  for _, frame in ipairs(env.frames) do
    local area = frame.kind ~= "Texture" and frame.kind ~= "FontString" and frame.mouse and
      visibleOnScreen(frame) and rect(env, frame)
    if area and x >= area.left and x <= area.right and y >= area.bottom and y <= area.top then
      local key = strata[frame:GetFrameStrata()] * 10000 + frame.level
      if not bestKey or key > bestKey then best, bestKey, tied = frame, key, false
      elseif key == bestKey then tied = true end
    end
  end
  assert(not tied, "mouse target is ambiguous: overlapping frames share strata and frame level")
  return best
end
local function mouseClick(env, control)
  local target = hit(env, center(env, control))
  if target.scripts.OnMouseDown then target.scripts.OnMouseDown(target, "LeftButton") end
  if target.scripts.OnMouseUp then target.scripts.OnMouseUp(target, "LeftButton") end
  if target.kind == "Button" and target.enabled ~= false and target.clicks and
      target.clicks[1] == "LeftButtonUp" and target.scripts.OnClick then
    target.scripts.OnClick(target, "LeftButton")
  end
  return target
end

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
  local craftId = window.selectedId
  click(window.controls.session)
  assert(window.section == "Sessions" and window.breadcrumb.text:find("from craft #" .. craftId, 1, true))
  click(window.controls.back)
  assert(window.section == "Crafts" and window.selectedId == craftId and window.dataPage == 12 and not window.failure)
  click(window.controls.back)
  assert(not window.selectedId and window.dataPage == 12 and window.rows[1].selected)
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
  assert(window.sizing == "BOTTOMRIGHT" and window.bounds[1] == 560)
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
  assert(window:GetWidth() == 560 and window:GetHeight() == 520)
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

test("X closes through mouse hit-testing above the draggable title bar and all close paths share cleanup", function()
  for _, flavor in ipairs({ "retail", "forever" }) do
    local addon, env = environment(flavor)
    env.SlashCmdList.ARTISANLOGBOOKDEBUG()
    local window = addon.debugWindow
    local titleBar, close = window.titleBar, window.close
    assert(close:GetFrameLevel() > titleBar:GetFrameLevel())
    local bar, x = rect(env, titleBar), rect(env, close)
    assert(bar.right <= x.left, "drag region must not overlap the close button")
    assert(hit(env, center(env, titleBar)) == titleBar)
    window:Section("Diagnostics")
    click(window.controls.mode)
    assert(window.scripts.OnUpdate)
    window.text:SetFocus()
    assert(mouseClick(env, close) == close)
    assert(not window:IsShown() and not window.scripts.OnUpdate and not window.text.focused)
    env.SlashCmdList.ARTISANLOGBOOKDEBUG()
    assert(window:IsShown() and addon.debugWindow == window and window.section == "Diagnostics" and window.mode == "Raw")
    settle(window)
    -- Close while dragging: movement stops and geometry is saved exactly as on drag stop.
    titleBar.scripts.OnDragStart(titleBar)
    assert(window.moving)
    assert(mouseClick(env, close) == close)
    assert(not window.moving and env.ArtisanLogbookDebugSettings.width == window:GetWidth())
    -- Escape uses UISpecialFrames, and /al_debug toggles: both hide the same instance.
    env.SlashCmdList.ARTISANLOGBOOKDEBUG()
    window:Section("Crafts")
    for _, name in ipairs(env.UISpecialFrames) do env[name]:Hide() end
    assert(not window:IsShown() and not window.scripts.OnUpdate)
    env.SlashCmdList.ARTISANLOGBOOKDEBUG()
    assert(window:IsShown() and window.section == "Crafts")
    env.SlashCmdList.ARTISANLOGBOOKDEBUG()
    assert(not window:IsShown())
    -- Every visible control is a unique mouse target.
    env.SlashCmdList.ARTISANLOGBOOKDEBUG()
    for _, control in pairs(window.controls) do
      if control.kind == "Button" and control:IsShown() then assert(hit(env, center(env, control)) == control) end
    end
    assert(hit(env, center(env, window.resize)) == window.resize)
  end
end)

test("tabs, selections and contextual controls follow list and detail navigation", function()
  local addon, env = environment("forever")
  local ledger = addon.ledger
  for index = 1, 14 do
    assert(ledger:SubmitCraft(2331, 1, false))
    assert(ledger:RecordResult({ operationID = index, itemID = 2455, quantity = 1 }))
  end
  env.SlashCmdList.ARTISANLOGBOOKDEBUG()
  local window = addon.debugWindow
  local controls = window.controls
  local function shown(name) return controls[name]:IsShown() end
  assert(controls.Capabilities.active and controls.Capabilities.highlightLocked and controls.Capabilities.underline:IsShown())
  assert(not controls.Crafts.active and not controls.Crafts.underline:IsShown())
  assert(not shown("back") and not shown("previous") and not shown("next") and not shown("session"))
  assert(not shown("textPrevious") and not shown("textNext") and not shown("textPage"))
  assert(window.breadcrumb.text == "Capabilities" and window.scroll:IsShown() and not window.list:IsShown())
  click(controls.Crafts)
  assert(controls.Crafts.active and not controls.Capabilities.active)
  assert(window.list:IsShown() and not window.scroll:IsShown() and controls.copy.enabled == false)
  assert(shown("previous") and shown("next") and controls.previous.enabled == false and controls.next.enabled)
  assert(not shown("session") and not shown("back"))
  assert(window.breadcrumb.text == "Crafts  >  Page 1 (newest first)")
  assert(window.rows[1]:IsShown() and window.rows[1].text:find("#14", 1, true) and not window.rows[1].selected)
  click(controls.next)
  assert(controls.previous.enabled and not controls.next.enabled and window.rows[2]:IsShown() and not window.rows[3]:IsShown())
  click(controls.previous)
  click(window.rows[2])
  assert(window.selectedId == 13 and window.breadcrumb.text == "Crafts  >  Page 1  >  Craft #13")
  assert(shown("back") and controls.back.text == "Back to list" and shown("session") and controls.session.enabled)
  assert(not shown("previous") and not shown("next") and not window.list:IsShown() and window.scroll:IsShown())
  assert(controls.copy.enabled)
  click(controls.mode)
  settle(window)
  assert(shown("textPrevious") and shown("textNext") and controls.textPage.text == "Page 1 / 1")
  assert(window.breadcrumb.text:find("Raw View", 1, true))
  click(controls.mode)
  click(controls.session)
  assert(controls.Sessions.active and controls.back.text == "Back to craft #13" and not shown("session"))
  click(controls.back)
  assert(window.section == "Crafts" and window.selectedId == 13 and controls.Crafts.active)
  click(controls.back)
  assert(window.list:IsShown() and window.rows[2].selected and window.rows[2].highlightLocked)
  assert(not window.rows[1].selected and not window.rows[1].highlightLocked)
  click(controls.Sessions)
  assert(window.rows[1]:IsShown() and window.rows[1].text:find("(current)", 1, true))
  click(controls.Capabilities)
  assert(not shown("previous") and not shown("session") and not shown("back"))
end)

test("summaries use readable local time and accurate provenance while Raw View keeps original values", function()
  local addon, env = environment("forever")
  local stamp = 1800000123
  local craft = { id = 7, timestamp = stamp, sessionId = 3, outcomeSource = "unverified", outputQuantity = 1,
    recipe = { id = 2331, name = "Minor Mana Potion" }, outputItem = { id = 2455 }, request = { id = 4 },
    inputComplete = true, reagents = { { itemId = 785, quantity = 1 }, { itemId = 2447, quantity = 1 } } }
  env.ArtisanLogbookAPI.GetCrafts = function() return { crafts = { craft } } end
  env.ArtisanLogbookAPI.GetCraft = function() return craft end
  env.SlashCmdList.ARTISANLOGBOOKDEBUG()
  local window = addon.debugWindow
  window:Section("Crafts")
  local readable = os.date("%Y-%m-%d %H:%M:%S", stamp)
  assert(window.rows[1].text:find(readable, 1, true) and not window.rows[1].text:find(tostring(stamp), 1, true))
  click(window.rows[1])
  local summary = window.text:GetText()
  assert(summary:find(readable, 1, true) and not summary:find(tostring(stamp), 1, true))
  assert(summary:find("does not mean the craft failed", 1, true) and summary:find("2 recorded", 1, true))
  assert(not summary:find("nil", 1, true) and summary:find("requirements complete: unknown", 1, true))
  click(window.controls.mode); settle(window)
  assert(window.text:GetText():find("[\"timestamp\"] = " .. stamp, 1, true))
  assert(window.text:GetText():find('"unverified"', 1, true))
  click(window.controls.mode)
  for source, phrase in pairs({ native = "completely observed", partial = "only some returned", [false] = "not recorded" }) do
    craft.outcomeSource = source or nil
    click(window.controls.refresh)
    assert(window.text:GetText():find(phrase, 1, true), source)
  end
  craft.timestamp = "not-a-time"
  click(window.controls.refresh)
  assert(window.text:GetText():find('Crafted:     not-a-time', 1, true))
  env.date = nil
  craft.timestamp = stamp
  click(window.controls.refresh)
  assert(window.text:GetText():find(tostring(stamp), 1, true))
  click(window.controls.Capabilities)
  local capabilities = window.text:GetText()
  assert(capabilities:find("Flavor:              forever", 1, true) and capabilities:find("this is not an error", 1, true))
  assert(capabilities:find("Events:", 1, true) and #capabilities < 4000)
  click(window.controls.Diagnostics)
  assert(window.text:GetText():find("Capture health:      OK", 1, true))
end)

test("layout stays inside the window at minimum, default and large sizes", function()
  local addon, env = environment("retail")
  local ledger = addon.ledger
  for index = 1, 12 do
    assert(ledger:SubmitCraft(2331, 1, false))
    assert(ledger:RecordResult({ operationID = index, itemID = 2455, quantity = 1 }))
  end
  env.SlashCmdList.ARTISANLOGBOOKDEBUG()
  local window = addon.debugWindow
  assert(window:GetWidth() == 720 and window:GetHeight() == 520)
  local function inside(frame, area)
    local box = rect(env, frame)
    return box.left >= area.left - 0.01 and box.right <= area.right + 0.01 and
      box.bottom >= area.bottom - 0.01 and box.top <= area.top + 0.01
  end
  local function noOverlap(a, b)
    local first, second = rect(env, a), rect(env, b)
    return first.right <= second.left or second.right <= first.left or
      first.top <= second.bottom or second.top <= first.bottom
  end
  for _, size in ipairs({ { 560, 420 }, { 720, 520 }, { 1260, 780 } }) do
    window:SetSize(size[1], size[2])
    for _, section in ipairs({ "Crafts", "Capabilities" }) do
      window:Section(section)
      for _, control in ipairs({ window.controls.Capabilities, window.controls.Sessions, window.controls.refresh,
          window.controls.export, window.close, window.resize }) do
        assert(inside(control, rect(env, window)), section .. " control outside at " .. size[1])
      end
      if section == "Crafts" then
        local list = rect(env, window.list)
        for index = 1, 12 do
          assert(window.rows[index]:IsShown() and inside(window.rows[index], list), "row outside at " .. size[1])
          for other = index + 1, 12 do assert(noOverlap(window.rows[index], window.rows[other])) end
        end
        assert(inside(window.controls.next, rect(env, window)) and noOverlap(window.controls.next, window.controls.previous))
        assert(noOverlap(window.list, window.controls.refresh))
      else
        assert(inside(window.scroll, rect(env, window)) and noOverlap(window.scroll, window.controls.refresh))
      end
    end
    window:Section("Crafts")
    click(window.rows[1])
    click(window.controls.mode); settle(window)
    assert(noOverlap(window.controls.export, window.controls.textPrevious) and inside(window.controls.textNext, rect(env, window)))
    assert(noOverlap(window.controls.back, window.controls.session) and inside(window.controls.back, rect(env, window)))
    click(window.controls.mode)
  end
  window:SetSize(1260, 780)
  window:Section("Crafts")
  assert(rect(env, window.rows[1]).left == rect(env, window.rows[2]).left, "tall windows use one column")
  window:SetSize(560, 420)
  window:Section("Crafts")
  assert(rect(env, window.rows[2]).left > rect(env, window.rows[1]).left, "short windows reflow into columns")
end)

print(passed .. " diagnostics tests passed")
