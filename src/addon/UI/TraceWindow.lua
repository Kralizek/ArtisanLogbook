local _, addon = ...

function addon.CreateTraceWindow()
  local width = math.min(760, UIParent:GetWidth() - 40)
  local height = math.min(560, UIParent:GetHeight() - 40)
  local window = CreateFrame("Frame", "ArtisanLogbookTraceWindow", UIParent, "BasicFrameTemplateWithInset")
  addon.window = window
  window:SetSize(width, height)
  window:SetPoint("CENTER")
  window:SetClampedToScreen(true)
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  window.TitleText:SetText("Artisan Logbook - Capture Tracer")
  tinsert(UISpecialFrames, "ArtisanLogbookTraceWindow")

  local status = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("TOPLEFT", 20, -38)
  status:SetSize(width - 40, 30)
  status:SetJustifyH("LEFT")

  local function button(text, offset, vertical, callback, buttonWidth)
    local control = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    control:SetSize(buttonWidth or 86, 24)
    control:SetPoint("TOPLEFT", offset, vertical)
    control:SetText(text)
    control:SetScript("OnClick", callback)
    return control
  end

  local label = CreateFrame("EditBox", nil, window, "InputBoxTemplate")
  label:SetSize(width - 150, 24)
  label:SetPoint("TOPLEFT", 26, -104)
  label:SetAutoFocus(false)
  label:SetMaxLetters(240)
  label:SetScript("OnEscapePressed", label.ClearFocus)

  local scroll = CreateFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 20, -142)
  scroll:SetPoint("BOTTOMRIGHT", -42, 54)
  local text = CreateFrame("EditBox", nil, scroll)
  text:SetMultiLine(true)
  text:SetAutoFocus(false)
  text:SetFontObject(ChatFontNormal)
  text:SetWidth(width - 70)
  text:SetMaxLetters(0)
  text:SetScript("OnEscapePressed", text.ClearFocus)
  text:SetScript("OnTextChanged", function() scroll:UpdateScrollChildRect() end)
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

  local page, pageSize = 1, 10
  local pageLabel = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  pageLabel:SetPoint("BOTTOMLEFT", 214, 24)
  pageLabel:SetSize(width - 340, 24)
  pageLabel:SetJustifyH("LEFT")

  local function updateStatus()
    local recorder = addon.recorder
    status:SetText(string.format("%s | %d / %d events | %.0f / %.0f KiB\n%s",
      recorder.recording and "Recording" or "Paused", #recorder.database.records,
      addon.Trace.maxRecords, recorder.database.bytes / 1024, addon.Trace.maxBytes / 1024,
      recorder.database.stoppedReason or "Capture contract: unverified"))
  end

  function window:Refresh(resetPage)
    if resetPage then page = 1 end
    local pageCount = math.max(1, math.ceil(#addon.recorder.database.records / pageSize))
    page = math.min(page, pageCount)
    text:SetText(addon.recorder:Export((page - 1) * pageSize + 1, pageSize))
    text:SetCursorPosition(0)
    text:ClearFocus()
    scroll:SetVerticalScroll(0)
    pageLabel:SetText(string.format("Export page %d / %d", page, pageCount))
    updateStatus()
  end

  button("Start", 20, -72, function()
    addon.Start()
    if label:GetText() ~= "" then addon.Mark(label:GetText()) end
    window:Refresh()
  end)
  button("Stop", 112, -72, function() addon.Stop(); window:Refresh() end)
  button("Export", 204, -72, function() window:Refresh(true) end)
  button("Diagnostics", 296, -72, function()
    text:SetText(addon.Trace.Serialize(addon.adapter.capabilities))
    text:SetCursorPosition(0)
    text:ClearFocus()
    scroll:SetVerticalScroll(0)
    pageLabel:SetText("Capabilities")
  end, 100)
  button("Mark", width - 108, -104, function()
    addon.Mark(label:GetText())
    label:ClearFocus()
    updateStatus()
  end)
  button("<", 20, -height + 40, function() page = math.max(1, page - 1); window:Refresh() end)
  button(">", 112, -height + 40, function() page = page + 1; window:Refresh() end)

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
  button("Clear", width - 108, -height + 40, function()
    if addon.recorder.recording then
      addon.Notify("Stop recording before clearing.")
    else
      StaticPopup_Show("ARTISANLOGBOOK_CLEAR_TRACE")
    end
  end)

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

  local launcher = CreateFrame("Button", "ArtisanLogbookTraceButton", UIParent)
  launcher:SetSize(28, 28)
  launcher:SetPoint("TOPRIGHT", Minimap, "BOTTOMRIGHT", 0, -6)
  launcher:SetNormalTexture("Interface\\Icons\\INV_Misc_Book_09")
  launcher:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  launcher:SetScript("OnClick", function()
    if window:IsShown() then window:Hide() else window:Show() end
  end)
  launcher:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Artisan Logbook - Capture Tracer")
    GameTooltip:Show()
  end)
  launcher:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
