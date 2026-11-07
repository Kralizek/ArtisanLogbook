local _, addon = ...

function addon.CreateTraceWindow()
  local width = math.min(760, UIParent:GetWidth() - 40)
  local height = math.min(560, UIParent:GetHeight() - 40)
  local window = addon.CreateCompatibleFrame("Frame", "ArtisanLogbookTraceWindow", UIParent, "BasicFrameTemplateWithInset")
  addon.window = window
  window:SetSize(width, height)
  window:SetPoint("CENTER")
  window:SetClampedToScreen(true)
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  if not window.TitleText then
    local background = window:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0.08, 0.08, 0.08, 0.95)
    window.TitleText = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    window.TitleText:SetPoint("TOP", 0, -12)
  end
  window.TitleText:SetText("Artisan Logbook - Capture Tracer")
  if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "ArtisanLogbookTraceWindow") end

  local status = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("TOPLEFT", 20, -38)
  status:SetSize(width - 40, 30)
  status:SetJustifyH("LEFT")

  local function button(text, offset, vertical, callback, buttonWidth)
    local control = addon.CreateCompatibleFrame("Button", nil, window, "UIPanelButtonTemplate")
    if not control:GetFontString() then
      local caption = control:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      caption:SetAllPoints()
      control:SetFontString(caption)
    end
    control:SetSize(buttonWidth or 86, 24)
    control:SetPoint("TOPLEFT", offset, vertical)
    control:SetText(text)
    control:SetScript("OnClick", callback)
    return control
  end

  local label = addon.CreateCompatibleFrame("EditBox", nil, window, "InputBoxTemplate")
  label:SetFontObject(ChatFontNormal)
  label:SetSize(width - 150, 24)
  label:SetPoint("TOPLEFT", 26, -104)
  label:SetAutoFocus(false)
  label:SetMaxLetters(240)
  label:SetScript("OnEscapePressed", label.ClearFocus)

  local scroll = addon.CreateCompatibleFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 20, -142)
  scroll:SetPoint("BOTTOMRIGHT", -42, 98)
  local text = CreateFrame("EditBox", nil, scroll)
  text:SetMultiLine(true)
  text:SetAutoFocus(false)
  text:SetFontObject(ChatFontNormal)
  text:SetWidth(width - 70)
  text:SetMaxLetters(0)
  text:SetScript("OnEscapePressed", text.ClearFocus)
  -- Multiline EditBoxes grow with their contents; GetStringHeight belongs to FontString,
  -- not EditBox. Let the ScrollFrame track the child size without a resize script.
  text:SetScript("OnCursorChanged", function(_, _, cursorY, _, cursorHeight)
    local offset = scroll:GetVerticalScroll()
    local position = -cursorY
    if position < offset then
      scroll:SetVerticalScroll(position)
    elseif position + cursorHeight > offset + scroll:GetHeight() then
      scroll:SetVerticalScroll(position + cursorHeight - scroll:GetHeight())
    end
  end)
  scroll:SetScrollChild(text)

  local page, pageSize = nil, 10
  local pageLabel = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  pageLabel:SetPoint("BOTTOMLEFT", 214, 66)
  pageLabel:SetSize(width - 340, 24)
  pageLabel:SetJustifyH("LEFT")

  local function updateStatus()
    local recorder = addon.recorder
    local stopped = recorder.database.stoppedReason
    local state = recorder.recording and "Recording" or "Paused"
    if stopped == "capacity" then
      state = "FULL: record limit reached; clear the trace to restart."
    elseif stopped == "capacity-bytes" then
      state = "FULL: byte limit reached; clear the trace to restart."
    elseif stopped == "capture-error" then
      state = "Stopped after a capture error; existing records are preserved."
    end
    status:SetText(string.format("%s | %d / %d events | %.0f / %.0f KiB estimated",
      state, #recorder.database.records, addon.Trace.maxRecords,
      recorder.database.bytes / 1024, addon.Trace.maxBytes / 1024))
  end

  function window:Refresh(resetPage)
    local recordCount = #addon.recorder.database.records
    local pageCount = math.max(1, math.ceil(recordCount / pageSize))
    -- Never insert the entire trace into an EditBox: large recordings can freeze the UI.
    if resetPage or not page then page = pageCount end
    page = math.max(1, math.min(page, pageCount))
    local export, reason = addon.recorder:Export((page - 1) * pageSize + 1, pageSize)
    text:SetText(export or ("Trace export unavailable: " .. tostring(reason)))
    pageLabel:SetText(string.format("Export page %d / %d (%d events total)", page, pageCount, recordCount))
    text:SetCursorPosition(0)
    text:ClearFocus()
    scroll:SetVerticalScroll(0)
    updateStatus()
  end

  button("Start", 20, -72, function()
    addon.Start()
    if label:GetText() ~= "" then addon.Mark(label:GetText()) end
    window:Refresh()
  end)
  button("Stop", 112, -72, function() addon.Stop(); window:Refresh() end)
  button("Export", 204, -72, function() window:Refresh(true) end)
  local verboseButton
  verboseButton = button("Verbose: off", 388, -72, function()
    addon.verbose = not addon.verbose
    verboseButton:SetText(addon.verbose and "Verbose: on" or "Verbose: off")
    addon.Notify(addon.verbose and "Quote and probe capture enabled for the next recording." or
      "Quote and probe capture disabled.")
  end, 108)
  button("Diagnostics", 296, -72, function()
    local payload = addon.Trace.Serialize({
      tracer = {
        recording = addon.recorder.recording == true,
        verbose = addon.verbose == true,
        events = addon.capabilities.events,
        hooks = addon.capabilities.hooks,
        flavor = addon.capabilities.flavor,
        apis = addon.capabilities.apis,
        unavailable = addon.capabilities.unavailable,
      },
      core = addon.GetCoreDiagnostics(),
    })
    text:SetText("Tracer and Core diagnostics\n\n" .. payload)
    text:SetCursorPosition(0)
    text:ClearFocus()
    scroll:SetVerticalScroll(0)
    pageLabel:SetText("Diagnostics")
  end, 100)
  button("Mark", width - 108, -104, function()
    addon.Mark(label:GetText())
    label:ClearFocus()
    updateStatus()
  end)
  button("<", 20, -height + 40, function() page = math.max(1, (page or 2) - 1); window:Refresh() end)
  button(">", 112, -height + 40, function() page = (page or 0) + 1; window:Refresh() end)

  if type(StaticPopupDialogs) == "table" and type(StaticPopup_Show) == "function" then
    StaticPopupDialogs.ARTISANLOGBOOK_CLEAR_TRACE = {
      text = "Delete all captured trace events? Export them first. This cannot be undone.",
      button1 = "Clear",
      button2 = "Cancel",
      OnAccept = function()
        local ok, reason = addon.recorder:Clear()
        if not ok then addon.Notify(reason) end
        window:Refresh(true)
      end,
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
      preferredIndex = 3,
    }
    button("Clear Trace", width - 154, -height + 40, function()
      if addon.recorder.recording then
        addon.Notify("Stop recording before clearing.")
      else
        StaticPopup_Show("ARTISANLOGBOOK_CLEAR_TRACE")
      end
    end, 134)
  else
    addon.Notify("Clear Trace unavailable: confirmation popup API is missing.")
  end

  local elapsed = 0
  window:SetScript("OnUpdate", function(_, delta)
    elapsed = elapsed + delta
    if elapsed >= 0.5 then
      elapsed = 0
      updateStatus()
    end
  end)
  window:SetScript("OnShow", function() window:Refresh() end)
  window:Hide()
end
