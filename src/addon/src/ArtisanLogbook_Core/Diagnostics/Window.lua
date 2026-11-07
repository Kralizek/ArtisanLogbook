local _, addon = ...
local Inspector = addon.Inspector
local pageSize = 12
local sections = { "Capabilities", "Diagnostics", "Crafts", "Sessions" }
local allowed = { GetCapabilities = true, GetDiagnostics = true, GetCrafts = true,
  GetCraft = true, GetSessions = true, GetSession = true }

local function read(method, ...)
  if not allowed[method] then return nil, "Read API is not allowed." end
  local api = ArtisanLogbookAPI
  if type(api) ~= "table" or type(api[method]) ~= "function" then
    return nil, method .. " is unavailable."
  end
  local ok, response, reason = pcall(api[method], ...)
  if not ok then return nil, method .. " failed: " .. Inspector.SafeText(response) end
  local readable, unavailable = Inspector.Readable(response)
  if not readable then return nil, method .. ": " .. unavailable end
  if response == nil then return nil, method .. ": " .. Inspector.SafeText(reason) end
  if type(response) ~= "table" then return nil, method .. " returned an unexpected response." end
  return response
end

local function field(value, key)
  if Inspector.Readable(value) and type(value) == "table" then return rawget(value, key) end
end
local function cursor(value)
  local candidate = field(value, "nextCursor")
  if Inspector.Readable(candidate) and type(candidate) == "string" then return candidate end
end
local function readable(value)
  return (Inspector.Readable(value))
end
local function number(value)
  if readable(value) and type(value) == "number" and value == value and
      value ~= math.huge and value ~= -math.huge then
    return value
  end
end
-- Summary-only wording; Raw View always keeps the original value.
local function show(value)
  if not readable(value) then return Inspector.SafeText(value) end
  if value == nil then return "unknown" end
  if value == true then return "yes" end
  if value == false then return "no" end
  return Inspector.SafeText(value)
end
local function when(value)
  local seconds = number(value)
  if seconds and seconds > 0 and type(date) == "function" then
    local ok, formatted = pcall(date, "%Y-%m-%d %H:%M:%S", math.floor(seconds))
    if ok and type(formatted) == "string" then return formatted end
  end
  return show(value)
end
local provenance = {
  native = "native - craft recorded; returned reagents were completely observed (none listed means none returned).",
  partial = "partial - craft recorded; only some returned reagents could be proven.",
  unverified = "unverified - craft recorded. The request context could not be verified, so returned " ..
    "reagents are not claimed complete. This does not mean the craft failed.",
}
local function outcome(value)
  if value == nil then return "not recorded (captured before provenance tracking)." end
  if readable(value) and type(value) == "string" and provenance[value] then return provenance[value] end
  return show(value)
end
-- Raw iteration avoids metamethods and keeps summary order deterministic.
local function names(value, wanted)
  local result = {}
  if not readable(value) or type(value) ~= "table" then return result end
  for key, child in next, value do
    if #result >= 200 then break end
    if readable(key) and type(key) == "string" and readable(child) and child == wanted then
      result[#result + 1] = key
    end
  end
  table.sort(result)
  return result
end
local function count(value)
  local total = 0
  if not readable(value) or type(value) ~= "table" then return nil end
  for _ in next, value do total = total + 1 end
  return total
end
local function rowLabel(value, sessions, currentSessionId)
  local id = field(value, "id")
  if sessions then
    local flavor, build = field(field(value, "capabilities"), "flavor"), field(value, "wowBuild")
    return "Session " .. show(id) .. "   " .. show(flavor) .. " build " .. show(build) ..
      "   started " .. when(field(value, "startedAt")) ..
      (id ~= nil and rawequal(id, currentSessionId) and "   (current)" or "")
  end
  local recipe, output = field(value, "recipe"), field(value, "outputItem")
  local name = field(recipe, "name")
  return "#" .. show(id) .. "   " .. (name ~= nil and show(name) or "recipe " .. show(field(recipe, "id"))) ..
    "   item " .. show(field(output, "id")) .. " x" .. show(field(value, "outputQuantity")) ..
    "   " .. when(field(value, "timestamp"))
end

function Inspector.CreateWindow()
  local window = CreateFrame("Frame", "ArtisanLogbookDiagnosticsWindow", UIParent)
  addon.debugWindow = window
  window:Hide()
  window:SetFrameStrata("DIALOG")
  window:SetClampedToScreen(true)
  window:SetMovable(true)
  window:SetResizable(true)
  window:EnableMouse(true)
  local background = window:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints()
  background:SetColorTexture(0.06, 0.07, 0.08, 0.96)
  if type(UISpecialFrames) == "table" then
    table.insert(UISpecialFrames, "ArtisanLogbookDiagnosticsWindow")
  end

  local margin, gap, controlHeight = 12, 6, 22
  local colors = {
    button = { 0.16, 0.18, 0.21, 1 }, active = { 0.18, 0.34, 0.52, 1 },
    row = { 0.11, 0.12, 0.14, 1 }, selected = { 0.18, 0.34, 0.52, 1 },
    text = { 0.92, 0.92, 0.92 }, accent = { 1, 0.82, 0 }, disabled = { 0.45, 0.45, 0.45 },
    muted = { 0.65, 0.68, 0.72 }, failure = { 1, 0.45, 0.4 },
  }
  local function caption(parent, font)
    local value = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    value:SetJustifyH("LEFT")
    value:SetWordWrap(false)
    return value
  end
  local function paint(control, background, foreground)
    control.backdrop:SetColorTexture(background[1], background[2], background[3], background[4])
    control.label:SetTextColor(foreground[1], foreground[2], foreground[3])
  end
  local function button(name, parent, width, callback, justify)
    local control = CreateFrame("Button", nil, parent)
    control:SetSize(width, controlHeight)
    control:EnableMouse(true)
    control:RegisterForClicks("LeftButtonUp")
    control.backdrop = control:CreateTexture(nil, "BACKGROUND")
    control.backdrop:SetAllPoints()
    control.label = caption(control)
    control.label:SetPoint("LEFT", justify and 8 or 2, 0)
    control.label:SetPoint("RIGHT", justify and -8 or -2, 0)
    control.label:SetJustifyH(justify or "CENTER")
    control:SetFontString(control.label)
    control:SetText(name)
    control:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2")
    control:SetScript("OnClick", callback)
    paint(control, justify and colors.row or colors.button, colors.text)
    return control
  end
  local function enable(control, enabled)
    control:SetEnabled(enabled)
    control.label:SetTextColor(unpack(enabled and colors.text or colors.disabled))
  end
  local function visible(control, shown)
    if shown then control:Show() else control:Hide() end
  end

  -- The drag region stops short of the close button and the close button is
  -- explicitly layered above it, so hit-testing never depends on sibling order.
  local titleBar = CreateFrame("Frame", nil, window)
  window.titleBar = titleBar
  titleBar:SetFrameLevel(window:GetFrameLevel() + 1)
  titleBar:SetPoint("TOPLEFT", 0, 0)
  titleBar:SetPoint("TOPRIGHT", -34, 0)
  titleBar:SetHeight(28)
  titleBar:EnableMouse(true)
  titleBar:RegisterForDrag("LeftButton")
  local titleBackground = titleBar:CreateTexture(nil, "BACKGROUND")
  titleBackground:SetAllPoints()
  titleBackground:SetColorTexture(0.1, 0.11, 0.13, 1)
  local title = caption(titleBar, "GameFontNormal")
  title:SetPoint("LEFT", margin, 0)
  title:SetText("Artisan Logbook - Diagnostics")
  local readOnly = caption(titleBar)
  readOnly:SetPoint("RIGHT", -8, 0)
  readOnly:SetJustifyH("RIGHT")
  readOnly:SetTextColor(unpack(colors.muted))
  readOnly:SetText("Read-only")
  local close = button("X", window, 24, function() window:Hide() end)
  window.close = close
  close:SetHeight(20)
  close:SetPoint("TOPRIGHT", -6, -4)
  close:SetFrameLevel(titleBar:GetFrameLevel() + 2)

  local controls, tabs = {}, {}
  window.controls, window.tabs = controls, tabs
  for _, section in ipairs(sections) do
    local control = button(section, window, 110, function() window:Section(section) end)
    controls[section], tabs[#tabs + 1] = control, control
    control.section = section
    control.underline = control:CreateTexture(nil, "ARTWORK")
    control.underline:SetPoint("BOTTOMLEFT", 0, 0)
    control.underline:SetPoint("BOTTOMRIGHT", 0, 0)
    control.underline:SetHeight(2)
    control.underline:SetColorTexture(colors.accent[1], colors.accent[2], colors.accent[3], 1)
  end

  local breadcrumb = caption(window, "GameFontNormalSmall")
  window.breadcrumb = breadcrumb
  breadcrumb:SetPoint("TOPLEFT", margin, -66)
  local status = caption(window)
  window.status = status
  status:SetPoint("TOPLEFT", margin, -88)
  status:SetPoint("TOPRIGHT", -margin, -88)
  status:SetHeight(16)

  local list = CreateFrame("Frame", nil, window)
  window.list = list
  local rows = {}
  window.rows = rows
  for index = 1, pageSize do
    rows[index] = button("", list, 100, function() window:SelectRecord(index) end, "LEFT")
  end

  local scroll = CreateFrame("ScrollFrame", nil, window)
  window.scroll = scroll
  local edit = CreateFrame("EditBox", nil, scroll)
  window.text = edit
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject(ChatFontNormal)
  edit:SetMaxLetters(0)
  edit:SetTextInsets(4, 4, 4, 4)
  edit:SetScript("OnEscapePressed", function() edit:ClearFocus() end)
  edit:SetScript("OnTextChanged", function(_, userInput)
    if userInput then edit:SetText(window.displayText or "") end
  end)
  scroll:SetScrollChild(edit)
  local slider = CreateFrame("Slider", nil, window)
  window.slider = slider
  slider:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
  slider:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
  slider:SetWidth(14)
  slider:SetOrientation("VERTICAL")
  local track = slider:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(0.14, 0.16, 0.18, 1)
  slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
  slider:SetValueStep(16)
  slider:SetMinMaxValues(0, 0)
  local function range()
    return math.max(0, edit:GetHeight() - scroll:GetHeight())
  end
  local function setScroll(offset)
    scroll:SetVerticalScroll(math.max(0, math.min(range(), offset)))
  end
  slider:SetScript("OnValueChanged", function(_, value) setScroll(value) end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(_, delta)
    slider:SetValue(math.max(0, math.min(range(), scroll:GetVerticalScroll() - delta * 48)))
  end)
  edit:SetScript("OnCursorChanged", function(_, _, y, _, height)
    local position, offset = -y, scroll:GetVerticalScroll()
    if position < offset then slider:SetValue(position)
    elseif position + height > offset + scroll:GetHeight() then
      slider:SetValue(math.min(range(), position + height - scroll:GetHeight()))
    end
  end)
  edit:SetScript("OnSizeChanged", function()
    slider:SetMinMaxValues(0, range())
    setScroll(scroll:GetVerticalScroll())
  end)

  window.section, window.mode, window.dataPage, window.rawPage = "Capabilities", "Summary", 1, 1
  window.cursors, window.lastSelected = { [1] = false }, {}
  local function showText(value)
    window.displayText = value
    edit:SetText(value)
    edit:SetCursorPosition(0)
    edit:ClearFocus()
    slider:SetMinMaxValues(0, range())
    slider:SetValue(0)
    setScroll(0)
  end
  function window:IsListView()
    return not self.selectedId and not self.failure and (self.section == "Crafts" or self.section == "Sessions")
  end
  function window:ShowsText()
    return not self:IsListView() or self.mode ~= "Summary"
  end
  function window:Crumbs()
    local parts = { self.section }
    if self.section == "Crafts" or self.section == "Sessions" then
      if self.origin then
        parts[#parts + 1] = "Session " .. show(self.selectedId) .. " (from craft #" .. show(self.origin.selectedId) .. ")"
      else
        parts[#parts + 1] = "Page " .. self.dataPage .. (self.selectedId and "" or " (newest first)")
        if self.selectedId then
          parts[#parts + 1] = (self.section == "Crafts" and "Craft #" or "Session ") .. show(self.selectedId)
        end
      end
    end
    if self.mode == "Raw" then parts[#parts + 1] = "Raw View"
    elseif self.mode == "Export" then parts[#parts + 1] = "Export" end
    return table.concat(parts, "  >  ")
  end
  function window:UpdateControls()
    local listView, detail, renderer = self:IsListView(), self.selectedId ~= nil, self.renderer
    for _, control in ipairs(tabs) do
      local active = control.section == self.section
      control.active = active
      paint(control, active and colors.active or colors.button, active and colors.accent or colors.text)
      visible(control.underline, active)
      if active then control:LockHighlight() else control:UnlockHighlight() end
    end
    local selected = self.lastSelected[self.section]
    for index, row in ipairs(rows) do
      local id = field(self.records and self.records[index], "id")
      row.selected = selected ~= nil and rawequal(id, selected)
      paint(row, row.selected and colors.selected or colors.row, colors.text)
      if row.selected then row:LockHighlight() else row:UnlockHighlight() end
    end
    visible(controls.back, detail)
    controls.back:SetText(self.origin and ("Back to craft #" .. show(self.origin.selectedId)) or "Back to list")
    controls.back:SetWidth(self.origin and 150 or 96)
    local pages = listView or (not detail and (self.section == "Crafts" or self.section == "Sessions") and self.dataPage > 1)
    visible(controls.previous, pages)
    visible(controls.next, pages)
    enable(controls.previous, self.dataPage > 1)
    enable(controls.next, listView and cursor(self.response) ~= nil)
    local craftDetail = detail and self.section == "Crafts" and not self.failure
    visible(controls.session, craftDetail)
    enable(controls.session, craftDetail and number(field(self.selected, "sessionId")) ~= nil)
    local textPages = self.mode ~= "Summary"
    visible(controls.textPrevious, textPages)
    visible(controls.textNext, textPages)
    visible(controls.textPage, textPages)
    local pageCount = renderer and #renderer.pages or 0
    enable(controls.textPrevious, textPages and self.rawPage > 1)
    enable(controls.textNext, textPages and renderer ~= nil and (self.rawPage < pageCount or not renderer.done))
    controls.textPage:SetText(string.format("Page %d / %d%s", self.rawPage, pageCount,
      renderer and renderer.done and "" or "+"))
    controls.mode:SetText(self.mode == "Summary" and "Raw View" or "Summary")
    enable(controls.copy, self:ShowsText())
  end
  function window:Display()
    breadcrumb:SetText(self:Crumbs())
    local message
    if self.failure then
      showText(self.failure)
      message = self.failure
      status:SetTextColor(unpack(colors.failure))
    else
      status:SetTextColor(unpack(colors.muted))
      local renderer = self.renderer
      if self.mode == "Summary" then
        showText(self.summary or "No results.")
        message = self:IsListView() and "Select a row to inspect it. Refresh queries again; nothing updates automatically." or
          "Summary shows key fields. Raw View shows the complete API response."
      else
        local value = renderer and renderer.pages[self.rawPage]
        showText(value or "Preparing structured text...")
        message = "Complete API response, one text page at a time." ..
          (renderer and renderer.limited and " LIMIT reached: see notices in the text." or "")
      end
    end
    status:SetText(self.notice or message)
    self.notice = nil
    self:UpdateControls()
    self:Layout()
  end
  local function recordSummary(record)
    if window.section == "Sessions" then
      local current = record ~= nil and rawequal(field(record, "id"), window.currentSessionId)
      return "Session " .. show(field(record, "id")) .. (current and " (current session)" or "") ..
        "\nStarted:     " .. when(field(record, "startedAt")) ..
        "\nClient:      " .. show(field(record, "wowVersion")) .. "  build " .. show(field(record, "wowBuild")) ..
        "\nInterface:   " .. show(field(record, "interface")) .. "  project " .. show(field(record, "projectId")) ..
        "\nFlavor:      " .. show(field(field(record, "capabilities"), "flavor")) ..
        "\nAddon:       " .. show(field(record, "addonVersion")) ..
        "\n\nRaw View includes the saved capture capabilities for this session."
    end
    local recipe, output = field(record, "recipe"), field(record, "outputItem")
    local reagents = count(field(record, "reagents"))
    return "Craft #" .. show(field(record, "id")) .. "   " .. show(field(recipe, "name")) ..
      " (recipe " .. show(field(recipe, "id")) .. ")" ..
      "\nCrafted:     " .. when(field(record, "timestamp")) .. " (local time)" ..
      "\nOutput:      item " .. show(field(output, "id")) .. " x" .. show(field(record, "outputQuantity")) ..
      "\nRequest:     " .. show(field(field(record, "request"), "id")) ..
      "    Session: " .. show(field(record, "sessionId")) ..
      "\nInputs:      complete: " .. show(field(record, "inputComplete")) ..
      "    requirements complete: " .. show(field(record, "grossRequirementsComplete")) ..
      "\nReagents:    " .. (reagents and (reagents .. " recorded") or "none returned") ..
      "\nProvenance:  " .. outcome(field(record, "outcomeSource")) ..
      "\n\nRaw View includes reagents, requirements, outputs and the correlated request."
  end
  local function capabilitySummary(response)
    local lines = { "Flavor:              " .. show(field(response, "flavor")) }
    for _, item in ipairs({ { "captureReady", "Capture ready" }, { "support", "Supported crafts" },
        { "resultCorrelation", "Result correlation" } }) do
      local value = field(response, item[1])
      if value ~= nil then lines[#lines + 1] = string.format("%-21s%s", item[2] .. ":", show(value)) end
    end
    local available, unavailable = names(response, true), names(response, false)
    lines[#lines + 1] = "\nAvailable features:  " .. (#available > 0 and table.concat(available, ", ") or "none")
    lines[#lines + 1] = "Not available:       " .. (#unavailable > 0 and table.concat(unavailable, ", ") or "none") ..
      (#unavailable > 0 and "\n  (not supported by this client or capture mode; this is not an error)" or "")
    for _, group in ipairs({ { "measurements", "Mechanics" }, { "events", "Events" }, { "hooks", "API hooks" } }) do
      local values = field(response, group[1])
      local yes, no = names(values, true), names(values, false)
      if #yes + #no > 0 then
        lines[#lines + 1] = string.format("\n%s: %d of %d available", group[2], #yes, #yes + #no)
        if #no > 0 then lines[#lines + 1] = "  Unavailable: " .. table.concat(no, ", ") end
      end
    end
    lines[#lines + 1] = "\nRaw View lists every capability value."
    return table.concat(lines, "\n")
  end
  local function diagnosticSummary(response)
    local lines = {}
    local health = field(response, "captureHealth")
    local problems = names(health, true)
    lines[#lines + 1] = "Capture health:      " .. (#problems > 0 and ("problem - " .. table.concat(problems, ", ")) or "OK")
    local reason = field(health, "unsupportedReason")
    if reason ~= nil then lines[#lines + 1] = "Last unsupported:    " .. show(reason) end
    local correlation = field(response, "correlation")
    local flags = names(correlation, true)
    lines[#lines + 1] = "Correlation:         " .. (#flags > 0 and ("uncertain - " .. table.concat(flags, ", ")) or "no ambiguity")
    local pending = {}
    for _, item in ipairs({ { "pendingRecipeId", "recipe" }, { "pendingRequestId", "request" },
        { "pendingOrderRequestId", "order request" }, { "pendingSalvageRecipeId", "salvage recipe" } }) do
      local value = field(correlation, item[1])
      if value ~= nil then pending[#pending + 1] = item[2] .. " " .. show(value) end
    end
    lines[#lines + 1] = "Pending:             " .. (#pending > 0 and table.concat(pending, ", ") or "nothing")
    local outputs = field(response, "recipeOutputs")
    lines[#lines + 1] = "\nRecipe knowledge:    " .. show(field(outputs, "relationshipCount")) .. " recipe/output relationships"
    lines[#lines + 1] = "Unknown recipe:      " .. show(field(outputs, "unattributedCraftCount")) .. " crafts without a recipe"
    lines[#lines + 1] = "Repair analysis:     " .. (field(outputs, "lastAnalysis") ~= nil and "available in Raw View" or "not run this session")
    lines[#lines + 1] = "Recovery:            " .. (field(outputs, "recovery") ~= nil and "available in Raw View" or "not run this session")
    for _, item in ipairs({ { "recoveryDiagnostic", "Recovery note" }, { "knowledgeDiagnostic", "Knowledge note" },
        { "maintenanceDiagnostic", "Maintenance note" } }) do
      local value = field(outputs, item[1])
      if value ~= nil then lines[#lines + 1] = string.format("%-21s%s", item[2] .. ":", show(value)) end
    end
    lines[#lines + 1] = "\nRaw View includes every returned diagnostic field."
    return table.concat(lines, "\n")
  end
  function window:Inspect(value, summary)
    self.rawPage, self.summary = 1, summary
    self.renderer = nil
    self.selected = value
    if self.mode ~= "Summary" then self.renderer = Inspector.Format(value); self:RequestText(1) end
    self:Display()
  end
  function window:RequestText(page)
    self.rawPage = page
    if not self.renderer then self.renderer = Inspector.Format(self.selected) end
    if #self.renderer.pages < page and not self.renderer.done then
      -- Only rendering is scheduled. This never polls APIs or capture state.
      self:SetScript("OnUpdate", function()
        for _ = 1, 8 do
          self.renderer:Step()
          if #self.renderer.pages >= self.rawPage or self.renderer.done then break end
        end
        if #self.renderer.pages >= self.rawPage or self.renderer.done then
          self:SetScript("OnUpdate", nil)
          self.rawPage = math.max(1, math.min(self.rawPage, #self.renderer.pages))
          self:Display()
        end
      end)
    end
  end
  function window:Refresh()
    self:SetScript("OnUpdate", nil)
    self.failure = nil
    local response, reason
    if self.selectedId then
      response, reason = read(self.section == "Crafts" and "GetCraft" or "GetSession", self.selectedId)
    elseif self.section == "Crafts" then
      response, reason = read("GetCrafts", nil, { limit = pageSize, direction = "desc", cursor = self.cursors[self.dataPage] or nil })
    elseif self.section == "Sessions" then
      response, reason = read("GetSessions", { limit = pageSize, cursor = self.cursors[self.dataPage] or nil })
    else
      response, reason = read(self.section == "Capabilities" and "GetCapabilities" or "GetDiagnostics")
    end
    self.failure, self.response = reason, response
    self.records = {}
    if not response then
      self.selected, self.renderer = nil, nil
      self:Display()
      return
    end
    if self.selectedId then
      self:Inspect(response, recordSummary(response))
    elseif self.section == "Crafts" or self.section == "Sessions" then
      local sessions = self.section == "Sessions"
      local records = field(response, sessions and "sessions" or "crafts")
      if not readable(records) or type(records) ~= "table" then
        self.failure = "Record list is unavailable."
        self:Display()
        return
      end
      if sessions then self.currentSessionId = field(response, "currentSessionId") end
      local lines = {}
      for index = 1, pageSize do
        local record = rawget(records, index)
        if not readable(record) then
          lines[#lines + 1] = "Record is secret or inaccessible."
          break
        end
        if record == nil then break end
        self.records[index] = record
        lines[#lines + 1] = rowLabel(record, sessions, self.currentSessionId)
      end
      if #self.records == 0 then lines[#lines + 1] = "No recorded " .. self.section:lower() .. "." end
      self:Inspect(response, table.concat(lines, "\n"))
    else
      self:Inspect(response, self.section == "Capabilities" and capabilitySummary(response) or diagnosticSummary(response))
    end
  end
  function window:SelectRecord(index)
    local id = field(self.records[index], "id")
    if not readable(id) or type(id) ~= "number" then
      self.failure = "Selected record identity is unavailable."
      self:Display()
      return
    end
    self.selectedId, self.lastSelected[self.section] = id, id
    self:Refresh()
  end
  function window:Section(section)
    self.section, self.selectedId, self.dataPage, self.cursors, self.origin = section, nil, 1, { [1] = false }, nil
    self:Refresh()
  end
  function window:Back()
    local origin = self.origin
    if origin then
      self.section, self.selectedId, self.dataPage, self.cursors = origin.section, origin.selectedId, origin.dataPage, origin.cursors
      self.origin = nil
    else
      self.selectedId = nil
    end
    self:Refresh()
  end

  controls.back = button("Back to list", window, 96, function() window:Back() end)
  controls.previous = button("< Newer", window, 76, function()
    window.dataPage = math.max(1, window.dataPage - 1)
    window:Refresh()
  end)
  controls.next = button("Older >", window, 76, function()
    local nextCursor = cursor(window.response)
    if nextCursor and not window.selectedId then
      window.dataPage = window.dataPage + 1
      window.cursors[window.dataPage] = nextCursor
      window:Refresh()
    end
  end)
  controls.session = button("Open session", window, 100, function()
    local id = window.section == "Crafts" and window.selectedId and number(field(window.selected, "sessionId"))
    if id then
      window.origin = { section = "Crafts", selectedId = window.selectedId, dataPage = window.dataPage, cursors = window.cursors }
      window.section, window.selectedId, window.dataPage, window.cursors = "Sessions", id, 1, { [1] = false }
      window.lastSelected.Sessions = id
      window:Refresh()
    else
      window.notice = "This craft has no recorded session."
      window:Display()
    end
  end)

  controls.refresh = button("Refresh", window, 72, function() window:Refresh() end)
  controls.mode = button("Raw View", window, 80, function()
    window.mode = window.mode == "Summary" and "Raw" or "Summary"
    if window.mode ~= "Summary" then window:RequestText(1)
    else window:SetScript("OnUpdate", nil) end
    window:Display()
  end)
  controls.copy = button("Copy", window, 60, function()
    edit:SetFocus()
    edit:HighlightText()
    status:SetText("Text selected: press Ctrl+C to copy this page" ..
      (window.mode ~= "Summary" and " (use > for the next page)." or "."))
  end)
  controls.export = button("Export", window, 64, function()
    window.mode = "Export"
    window:RequestText(1)
    window.notice = "Export: copy every page in order and join them without separators." ..
      ((window.section == "Crafts" or window.section == "Sessions") and not window.selectedId and
        " Older > exports older records." or "")
    window:Display()
  end)
  controls.textPrevious = button("<", window, 24, function()
    window:RequestText(math.max(1, window.rawPage - 1)); window:Display()
  end)
  controls.textNext = button(">", window, 24, function()
    window:RequestText(window.rawPage + 1); window:Display()
  end)
  controls.textPage = caption(window)
  controls.textPage:SetJustifyH("CENTER")
  controls.textPage:SetTextColor(unpack(colors.muted))

  local resize = CreateFrame("Button", nil, window)
  window.resize = resize
  resize:SetSize(16, 16)
  resize:EnableMouse(true)
  resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  resize:SetPoint("BOTTOMRIGHT", -2, 2)
  local function bounds()
    return math.max(1, UIParent:GetWidth() - 20), math.max(1, UIParent:GetHeight() - 20)
  end
  local function save()
    window.dragging = nil
    window:StopMovingOrSizing()
    local x, y = window:GetCenter()
    local width, height = bounds()
    ArtisanLogbookDebugSettings = { width = math.min(width, window:GetWidth()),
      height = math.min(height, window:GetHeight()), x = x, y = y }
  end
  titleBar:SetScript("OnDragStart", function() window.dragging = true; window:StartMoving() end)
  titleBar:SetScript("OnDragStop", save)
  resize:SetScript("OnMouseDown", function(_, mouse)
    if mouse == "LeftButton" then window.dragging = true; window:StartSizing("BOTTOMRIGHT") end
  end)
  resize:SetScript("OnMouseUp", save)

  local top, bottom = 108, 40
  function window:Layout()
    local width, height = self:GetWidth(), self:GetHeight()
    local tabWidth = math.min(110, math.floor((width - 2 * margin - (#tabs - 1) * gap) / #tabs))
    for index, control in ipairs(tabs) do
      control:ClearAllPoints()
      control:SetPoint("TOPLEFT", margin + (index - 1) * (tabWidth + gap), -34)
      control:SetWidth(tabWidth)
    end
    -- Navigation is right-aligned on the breadcrumb row; hidden controls take no space.
    local anchor
    for _, name in ipairs({ "next", "previous", "session", "back" }) do
      local control = controls[name]
      control:ClearAllPoints()
      if control:IsShown() then
        if anchor then control:SetPoint("RIGHT", anchor, "LEFT", -gap, 0)
        else control:SetPoint("TOPRIGHT", -margin, -62) end
        anchor = control
      end
    end
    breadcrumb:ClearAllPoints()
    breadcrumb:SetPoint("TOPLEFT", margin, -66)
    if anchor then breadcrumb:SetPoint("RIGHT", anchor, "LEFT", -gap, 0)
    else breadcrumb:SetPoint("TOPRIGHT", -margin, -66) end

    local listView = self:IsListView() and self.mode == "Summary"
    visible(list, listView)
    visible(scroll, not listView)
    visible(slider, not listView)
    local available = math.max(controlHeight, height - top - bottom)
    local fit = math.max(1, math.floor((available + 2) / (controlHeight + 2)))
    local maxColumns = math.max(1, math.floor((width - 2 * margin + gap) / (220 + gap)))
    local columns = math.min(3, maxColumns, math.max(1, math.ceil(pageSize / fit)))
    local rowWidth = math.floor((width - 2 * margin - (columns - 1) * gap) / columns)
    list:ClearAllPoints()
    list:SetPoint("TOPLEFT", margin, -top)
    list:SetPoint("BOTTOMRIGHT", -margin, bottom)
    for index, row in ipairs(rows) do
      visible(row, listView and self.records ~= nil and self.records[index] ~= nil)
      if self.records and self.records[index] ~= nil then
        row:SetText(rowLabel(self.records[index], self.section == "Sessions", self.currentSessionId))
      end
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", ((index - 1) % columns) * (rowWidth + gap),
        -math.floor((index - 1) / columns) * (controlHeight + 2))
      row:SetSize(rowWidth, controlHeight)
    end
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", margin, -top)
    scroll:SetPoint("BOTTOMRIGHT", -(margin + 18), bottom)
    edit:SetWidth(math.max(100, width - 2 * margin - 18))
    slider:SetMinMaxValues(0, range())

    local previous
    for _, name in ipairs({ "refresh", "mode", "copy", "export" }) do
      local control = controls[name]
      control:ClearAllPoints()
      if previous then control:SetPoint("LEFT", previous, "RIGHT", gap, 0)
      else control:SetPoint("BOTTOMLEFT", margin, 10) end
      previous = control
    end
    controls.textNext:ClearAllPoints()
    controls.textNext:SetPoint("BOTTOMRIGHT", -24, 10)
    controls.textPage:ClearAllPoints()
    controls.textPage:SetPoint("RIGHT", controls.textNext, "LEFT", -gap, 0)
    controls.textPage:SetWidth(84)
    controls.textPrevious:ClearAllPoints()
    controls.textPrevious:SetPoint("RIGHT", controls.textPage, "LEFT", -gap, 0)
  end
  window:SetScript("OnSizeChanged", function() window:Layout() end)
  -- X, Escape (UISpecialFrames) and /al_debug all hide the frame, so they share this cleanup.
  window:SetScript("OnHide", function()
    window:SetScript("OnUpdate", nil)
    edit:ClearFocus()
    if window.dragging then save() end
  end)
  window:SetScript("OnShow", function()
    window:Refresh()
  end)
  local maximumWidth, maximumHeight = bounds()
  local minimumWidth, minimumHeight = math.min(560, maximumWidth), math.min(420, maximumHeight)
  if type(window.SetResizeBounds) == "function" then
    window:SetResizeBounds(minimumWidth, minimumHeight, maximumWidth, maximumHeight)
  elseif type(window.SetMinResize) == "function" then
    window:SetMinResize(minimumWidth, minimumHeight)
    if type(window.SetMaxResize) == "function" then window:SetMaxResize(maximumWidth, maximumHeight) end
  else
    resize:Hide()
    window.notice = "Resizing is unavailable on this client."
  end
  local settings = type(ArtisanLogbookDebugSettings) == "table" and ArtisanLogbookDebugSettings or {}
  local function clamp(value, fallback, lower, upper)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return fallback end
    return math.max(lower, math.min(upper, value))
  end
  window:SetSize(clamp(settings.width, math.max(minimumWidth, math.min(720, maximumWidth)), minimumWidth, maximumWidth),
    clamp(settings.height, math.max(minimumHeight, math.min(520, maximumHeight)), minimumHeight, maximumHeight))
  if type(settings.x) == "number" and type(settings.y) == "number" then
    window:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
      clamp(settings.x, maximumWidth / 2, 0, maximumWidth),
      clamp(settings.y, maximumHeight / 2, 0, maximumHeight))
  else
    window:SetPoint("CENTER")
  end
  window:UpdateControls()
  return window
end

SLASH_ARTISANLOGBOOKDEBUG1 = "/al_debug"
SlashCmdList.ARTISANLOGBOOKDEBUG = function()
  local window = addon.debugWindow or Inspector.CreateWindow()
  if window:IsShown() then window:Hide() else window:Show() end
end
