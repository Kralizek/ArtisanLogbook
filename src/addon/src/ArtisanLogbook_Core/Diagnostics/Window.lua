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
local function text(value, key)
  return Inspector.SafeText(field(value, key))
end
local function cursor(value)
  local candidate = field(value, "nextCursor")
  if Inspector.Readable(candidate) and type(candidate) == "string" then return candidate end
end
local function label(value)
  local id, recipe, output = field(value, "id"), field(value, "recipe"), field(value, "outputItem")
  if Inspector.Readable(field(value, "startedAt")) and type(field(value, "startedAt")) == "number" then
    return "Session " .. Inspector.SafeText(id) .. " | " ..
      text(field(value, "capabilities"), "flavor") .. " | " .. text(value, "wowBuild")
  end
  return "#" .. Inspector.SafeText(id) .. " | " .. text(recipe, "name") ..
    " (" .. text(recipe, "id") .. ") | item " .. text(output, "id") ..
    " x" .. text(value, "outputQuantity")
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
  background:SetColorTexture(0.06, 0.07, 0.08, 0.97)
  if type(UISpecialFrames) == "table" then
    table.insert(UISpecialFrames, "ArtisanLogbookDiagnosticsWindow")
  end

  local function caption(parent, size)
    local value = parent:CreateFontString(nil, "OVERLAY", size or "GameFontHighlightSmall")
    value:SetJustifyH("LEFT")
    return value
  end
  local function button(name, parent, width, callback)
    local control = CreateFrame("Button", nil, parent)
    control:SetSize(width, 24)
    local backdrop = control:CreateTexture(nil, "BACKGROUND")
    backdrop:SetAllPoints()
    backdrop:SetColorTexture(0.16, 0.18, 0.21, 1)
    local title = caption(control)
    title:SetAllPoints()
    title:SetJustifyH("CENTER")
    title:SetWordWrap(false)
    control:SetFontString(title)
    control:SetText(name)
    control:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2")
    control:SetScript("OnClick", callback)
    return control
  end

  local titleBar = CreateFrame("Frame", nil, window)
  window.titleBar = titleBar
  titleBar:SetPoint("TOPLEFT", 0, 0)
  titleBar:SetPoint("TOPRIGHT", 0, 0)
  titleBar:SetHeight(32)
  titleBar:EnableMouse(true)
  titleBar:RegisterForDrag("LeftButton")
  titleBar:SetScript("OnDragStart", function() window:StartMoving() end)
  local title = caption(titleBar, "GameFontNormal")
  title:SetPoint("LEFT", 14, 0)
  title:SetText("Artisan Logbook - Diagnostics")
  local close = button("X", window, 28, function() window:Hide() end)
  close:SetPoint("TOPRIGHT", -8, -4)
  window.close = close
  local status = caption(window)
  window.status = status
  status:SetPoint("TOPLEFT", 14, -70)
  status:SetPoint("TOPRIGHT", -14, -70)
  status:SetHeight(32)

  local controls = {}
  window.controls = controls
  local list = CreateFrame("Frame", nil, window)
  window.list = list
  list:SetPoint("TOPLEFT", 14, -106)
  list:SetPoint("TOPRIGHT", -14, -106)
  list:SetHeight(104)
  local rows = {}
  window.rows = rows
  for index = 1, pageSize do
    local row = button("", list, 100, function()
      window:SelectRecord(index)
    end)
    row:SetHeight(24)
    rows[index] = row
  end

  local scroll = CreateFrame("ScrollFrame", nil, window)
  window.scroll = scroll
  scroll:SetPoint("BOTTOMRIGHT", -38, 76)
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
  slider:SetWidth(16)
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
  window.cursors = { [1] = false }
  local function showText(value)
    window.displayText = value
    edit:SetText(value)
    edit:SetCursorPosition(0)
    edit:ClearFocus()
    slider:SetMinMaxValues(0, range())
    slider:SetValue(0)
    setScroll(0)
  end
  function window:Display()
    if self.failure then
      status:SetText(self.failure)
      showText(self.failure)
      return
    end
    local renderer = self.renderer
    if self.mode == "Summary" then
      showText(self.summary or "No results.")
      status:SetText(self.section .. " | data page " .. self.dataPage .. " | Refresh to query again.")
    else
      local value = renderer and renderer.pages[self.rawPage]
      if value then showText(value) else showText("Preparing structured text...") end
      local pageCount = renderer and #renderer.pages or 0
      status:SetText(string.format("%s | %s | text page %d / %d%s%s", self.section, self.mode,
        self.rawPage, pageCount, renderer and renderer.done and "" or "+",
        renderer and renderer.limited and " | LIMIT: see text notices" or ""))
    end
    controls.textPrevious:SetEnabled(self.mode ~= "Summary" and self.rawPage > 1)
    controls.textNext:SetEnabled(self.mode ~= "Summary" and renderer ~= nil and
      (self.rawPage < #renderer.pages or not renderer.done))
    controls.previous:SetEnabled(self.selectedId ~= nil or self.dataPage > 1)
    controls.next:SetEnabled(self.selectedId == nil and cursor(self.response) ~= nil)
  end
  local function recordSummary(record)
    if window.section == "Sessions" then
      return label(record) .. "\nStarted: " .. text(record, "startedAt") ..
        "\nClient: " .. text(record, "wowVersion") .. " / " .. text(record, "wowBuild") ..
        "\nInterface: " .. text(record, "interface") .. " | Project: " .. text(record, "projectId") ..
        "\nAddon: " .. text(record, "addonVersion") ..
        "\nRaw View includes saved capture capabilities and identity."
    end
    return label(record) .. "\nTimestamp: " .. text(record, "timestamp") ..
      "\nRequest: " .. text(field(record, "request"), "id") .. " | Session: " .. text(record, "sessionId") ..
      "\nInputs complete: " .. text(record, "inputComplete") ..
      " | Requirements complete: " .. text(record, "grossRequirementsComplete") ..
      "\nOutcome source: " .. text(record, "outcomeSource") ..
      "\nRaw View includes reagents, requirements, outputs and correlated request."
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
    for _, row in ipairs(rows) do row:Hide() end
    self.records = {}
    if not response then
      self.selected, self.renderer = nil, nil
      self:Display()
      self:Layout()
      return
    end
    if self.selectedId then
      self:Inspect(response, recordSummary(response))
    elseif self.section == "Crafts" or self.section == "Sessions" then
      local records = field(response, self.section == "Crafts" and "crafts" or "sessions")
      if not Inspector.Readable(records) or type(records) ~= "table" then
        self.failure = "Record list is unavailable."
        self:Display()
        return
      end
      local lines = { self.section .. " - newest first. Select a row for details." }
      if self.section == "Sessions" then
        lines[#lines + 1] = "Current session: " .. text(response, "currentSessionId")
      end
      for index = 1, pageSize do
        local record = rawget(records, index)
        if not Inspector.Readable(record) then
          lines[#lines + 1] = "Record is secret or inaccessible."
          break
        end
        if record == nil then break end
        self.records[index] = record
        rows[index]:SetText(label(record))
        rows[index]:Show()
        lines[#lines + 1] = recordSummary(record) .. "\n"
      end
      if #self.records == 0 then lines[#lines + 1] = "No recorded " .. self.section:lower() .. "." end
      self:Inspect(response, table.concat(lines, "\n\n"))
    else
      local lines = { self.section .. " (nil means unavailable; false is an observed flag)." }
      if self.section == "Capabilities" then
        for _, key in ipairs({ "flavor", "captureReady", "support", "resultCorrelation",
            "craftResults", "personalRequests", "reagentAllocations", "craftingStats", "qualities",
            "orders", "salvage", "recrafts", "operationInfo", "fixedReagents" }) do
          lines[#lines + 1] = key .. ": " .. text(response, key)
        end
        lines[#lines + 1] = "\nMechanics (false = unavailable; nil = not declared):"
        for _, name in ipairs({ "resourcefulness", "concentrationSpent", "ingenuityRefund", "multicraft", "quality" }) do
          lines[#lines + 1] = name .. ": " .. text(field(response, "measurements"), name)
        end
        lines[#lines + 1] = "\nUnsupported mechanics are not errors. Raw View includes event registrations and request hooks."
      else
        for _, section in ipairs({ "captureHealth", "correlation", "recipeOutputs" }) do
          lines[#lines + 1] = "\n" .. section
          local group = field(response, section)
          local keys = section == "captureHealth" and { "captureError", "diagnosticObserverError", "unsupportedReason" } or
            section == "correlation" and { "operationOwnershipUncertain", "requestAmbiguous", "ambiguousRecipe",
              "authoritativeCaptureSuspended", "pendingRecipeId", "pendingRequestId", "pendingOrderRequestId" } or
            { "relationshipCount", "unattributedCraftCount", "recoveryDiagnostic", "knowledgeDiagnostic", "maintenanceDiagnostic" }
          for _, key in ipairs(keys) do lines[#lines + 1] = key .. ": " .. text(group, key) end
        end
        lines[#lines + 1] = "\nRaw View includes all returned fields, including repair analysis and recovery status."
      end
      self:Inspect(response, table.concat(lines, "\n"))
    end
    self:Layout()
  end
  function window:SelectRecord(index)
    local id = field(self.records[index], "id")
    if not Inspector.Readable(id) or type(id) ~= "number" then
      self.failure = "Selected record identity is unavailable."
      self:Display()
      return
    end
    self.selectedId = id
    self:Refresh()
  end
  function window:Section(section)
    self.section, self.selectedId, self.dataPage, self.cursors = section, nil, 1, { [1] = false }
    self:Refresh()
  end

  for index, section in ipairs(sections) do
    local control = button(section, window, 112, function() window:Section(section) end)
    control:SetPoint("TOPLEFT", 14 + (index - 1) * 118, -38)
    controls[section] = control
  end
  controls.previous = button("Back", window, 62, function()
    if window.selectedId then window.selectedId = nil
    else window.dataPage = math.max(1, window.dataPage - 1) end
    window:Refresh()
  end)
  controls.previous:SetPoint("BOTTOMLEFT", 14, 42)
  controls.next = button("Next records", window, 98, function()
    local nextCursor = cursor(window.response)
    if nextCursor and not window.selectedId then
      window.dataPage = window.dataPage + 1
      window.cursors[window.dataPage] = nextCursor
      window:Refresh()
    end
  end)
  controls.next:SetPoint("LEFT", controls.previous, "RIGHT", 6, 0)
  controls.textPrevious = button("< Text", window, 62, function()
    window:RequestText(math.max(1, window.rawPage - 1)); window:Display()
  end)
  controls.textPrevious:SetPoint("LEFT", controls.next, "RIGHT", 6, 0)
  controls.textNext = button("Text >", window, 62, function()
    window:RequestText(window.rawPage + 1); window:Display()
  end)
  controls.textNext:SetPoint("LEFT", controls.textPrevious, "RIGHT", 6, 0)
  controls.session = button("Craft session", window, 100, function()
    local id = window.section == "Crafts" and window.selectedId and field(window.selected, "sessionId")
    if Inspector.Readable(id) and type(id) == "number" then
      window.section, window.selectedId, window.dataPage, window.cursors = "Sessions", id, 1, { [1] = false }
      window:Refresh()
    else
      status:SetText("Select a craft with a known session first.")
    end
  end)
  controls.session:SetPoint("LEFT", controls.textNext, "RIGHT", 6, 0)

  controls.refresh = button("Refresh", window, 76, function() window:Refresh() end)
  controls.refresh:SetPoint("BOTTOMLEFT", 14, 12)
  controls.mode = button("Raw View", window, 86, function()
    window.mode = window.mode == "Summary" and "Raw" or "Summary"
    controls.mode:SetText(window.mode == "Summary" and "Raw View" or "Summary")
    if window.mode ~= "Summary" then window:RequestText(1)
    else window:SetScript("OnUpdate", nil) end
    window:Display()
  end)
  controls.mode:SetPoint("LEFT", controls.refresh, "RIGHT", 6, 0)
  controls.copy = button("Copy", window, 64, function()
    edit:SetFocus()
    edit:HighlightText()
    status:SetText("Ctrl+A then Ctrl+C copies this complete text page. Text > exposes more pages.")
  end)
  controls.copy:SetPoint("LEFT", controls.mode, "RIGHT", 6, 0)
  controls.export = button("Export", window, 72, function()
    window.mode = "Export"
    controls.mode:SetText("Summary")
    window:RequestText(1)
    window:Display()
    status:SetText("Export: copy each raw text page in order; concatenate without added separators. Next records exports older records.")
  end)
  controls.export:SetPoint("LEFT", controls.copy, "RIGHT", 6, 0)
  local help = caption(window)
  help:SetPoint("LEFT", controls.export, "RIGHT", 10, 0)
  help:SetText("Read-only | no automatic refresh")

  local resize = button("\\", window, 20, function() end)
  resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  window.resize = resize
  resize:SetPoint("BOTTOMRIGHT", -4, 4)
  resize:SetScript("OnMouseDown", function(_, mouse)
    if mouse == "LeftButton" then window:StartSizing("BOTTOMRIGHT") end
  end)
  local function bounds()
    return math.max(1, UIParent:GetWidth() - 20), math.max(1, UIParent:GetHeight() - 20)
  end
  local function save()
    window:StopMovingOrSizing()
    local x, y = window:GetCenter()
    local width, height = bounds()
    ArtisanLogbookDebugSettings = { width = math.min(width, window:GetWidth()),
      height = math.min(height, window:GetHeight()), x = x, y = y }
  end
  titleBar:SetScript("OnDragStop", save)
  resize:SetScript("OnMouseUp", save)
  function window:Layout()
    local listVisible = not self.selectedId and (self.section == "Crafts" or self.section == "Sessions") and not self.failure
    if listVisible then list:Show() else list:Hide() end
    local width = self:GetWidth()
    local columns = width >= 900 and 3 or 2
    local rowWidth = (width - 28 - (columns - 1) * 6) / columns
    for index, row in ipairs(rows) do
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", ((index - 1) % columns) * (rowWidth + 6), -math.floor((index - 1) / columns) * 26)
      row:SetWidth(rowWidth)
    end
    list:SetHeight(math.ceil(pageSize / columns) * 26)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", 14, -(listVisible and (114 + list:GetHeight()) or 106))
    scroll:SetPoint("BOTTOMRIGHT", -38, 76)
    edit:SetWidth(math.max(100, width - 56))
    slider:SetMinMaxValues(0, range())
  end
  window:SetScript("OnSizeChanged", function() window:Layout() end)
  window:SetScript("OnHide", function()
    window:SetScript("OnUpdate", nil)
    edit:ClearFocus()
  end)
  window:SetScript("OnShow", function()
    window:Refresh()
  end)
  local maximumWidth, maximumHeight = bounds()
  local minimumWidth, minimumHeight = math.min(620, maximumWidth), math.min(500, maximumHeight)
  if type(window.SetResizeBounds) == "function" then
    window:SetResizeBounds(minimumWidth, minimumHeight, maximumWidth, maximumHeight)
  elseif type(window.SetMinResize) == "function" then
    window:SetMinResize(minimumWidth, minimumHeight)
    if type(window.SetMaxResize) == "function" then window:SetMaxResize(maximumWidth, maximumHeight) end
  else
    resize:Hide()
    status:SetText("Resize bounds are unavailable on this client.")
  end
  local settings = type(ArtisanLogbookDebugSettings) == "table" and ArtisanLogbookDebugSettings or {}
  local function number(value, fallback, lower, upper)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return fallback end
    return math.max(lower, math.min(upper, value))
  end
  window:SetSize(number(settings.width, math.min(840, maximumWidth), minimumWidth, maximumWidth),
    number(settings.height, math.min(640, maximumHeight), minimumHeight, maximumHeight))
  if type(settings.x) == "number" and type(settings.y) == "number" then
    window:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
      number(settings.x, maximumWidth / 2, 0, maximumWidth),
      number(settings.y, maximumHeight / 2, 0, maximumHeight))
  else
    window:SetPoint("CENTER")
  end
  return window
end

SLASH_ARTISANLOGBOOKDEBUG1 = "/al_debug"
SlashCmdList.ARTISANLOGBOOKDEBUG = function()
  local window = addon.debugWindow or Inspector.CreateWindow()
  if window:IsShown() then window:Hide() else window:Show() end
end
