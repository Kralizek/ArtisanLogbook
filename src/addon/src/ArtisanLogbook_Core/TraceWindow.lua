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
  scroll:SetPoint("BOTTOMRIGHT", -42, 98)
  local text = CreateFrame("EditBox", nil, scroll)
  text:SetMultiLine(true)
  text:SetAutoFocus(false)
  text:SetFontObject(ChatFontNormal)
  text:SetWidth(width - 70)
  text:SetMaxLetters(0)
  text:SetScript("OnEscapePressed", text.ClearFocus)
  text:SetScript("OnTextChanged", function()
    text:SetHeight(math.max(scroll:GetHeight(), text:GetStringHeight()))
    scroll:UpdateScrollChildRect()
  end)
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
    status:SetText(string.format("%s | %d / %d events | %.0f KiB estimated\n%s",
      recorder.recording and "Recording" or "Paused", #recorder.database.records,
      addon.Trace.maxRecords, recorder.database.bytes / 1024,
      recorder.database.stoppedReason or "Capture contract: unverified"))
  end

  function window:Refresh(resetPage)
    if resetPage then page = nil end
    local pageCount = math.max(1, math.ceil(#addon.recorder.database.records / pageSize))
    if page then
      page = math.min(page, pageCount)
      text:SetText(addon.recorder:Export((page - 1) * pageSize + 1, pageSize))
      pageLabel:SetText(string.format("Export page %d / %d", page, pageCount))
    else
      text:SetText(addon.recorder:Export(1, #addon.recorder.database.records))
      pageLabel:SetText(string.format("Complete export: %d events", #addon.recorder.database.records))
    end
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
  button("Diagnostics", 296, -72, function()
    local lines = { addon.Trace.Serialize(addon.adapter.capabilities) }
    local diagnostics = ArtisanLogbookManagement.RecipeOutputDiagnostics()
    if diagnostics then
      lines[#lines + 1] = string.format("Known recipe/output relationships: %d",
        diagnostics.relationshipCount)
      lines[#lines + 1] = string.format("Unknown retained crafts: %d",
        diagnostics.unknownCount)
      lines[#lines + 1] = string.format("Uniquely repairable now: %d",
        diagnostics.repairableCount)
      lines[#lines + 1] = string.format("Ambiguous: %d | Without sufficient evidence: %d",
        diagnostics.ambiguousCount,
        diagnostics.insufficientCount + diagnostics.missingOutputCount)
      if diagnostics.recovery then
        lines[#lines + 1] = string.format("Last discovery: %d candidates, %d confirmed, %d unavailable, %d unconfirmed",
          diagnostics.recovery.candidateCount, diagnostics.recovery.verifiedCount,
          diagnostics.recovery.unavailableCount, diagnostics.recovery.unconfirmedCount)
      end
      lines[#lines + 1] = string.format("Retail relationships learned this session: %d",
        diagnostics.verifiedRelationshipCount)
      if diagnostics.recoveryDiagnostic then lines[#lines + 1] = diagnostics.recoveryDiagnostic end
      if diagnostics.knowledgeDiagnostic then
        lines[#lines + 1] = diagnostics.knowledgeDiagnostic
      end
      if diagnostics.maintenanceDiagnostic then
        lines[#lines + 1] = diagnostics.maintenanceDiagnostic
      end
    end
    text:SetText(table.concat(lines, "\n\n"))
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

  local function analysisText(analysis)
    local message = string.format("Unknown recipe repair\n\n%d unattributed crafts found.\n\n%d uniquely repairable\n%d ambiguous\n%d missing output identity\n%d outputs without a known recipe mapping",
      analysis.unattributedCount, analysis.repairableCount, analysis.ambiguousCount,
      analysis.missingOutputCount, analysis.insufficientEvidenceCount)
    local recovery = analysis.recovery
    if recovery then
      message = message .. string.format("\n\n%d candidate recipes\n%d authoritatively confirmed\n%d metadata unavailable\n%d not confirmed by available metadata",
        recovery.candidateCount, recovery.verifiedCount, recovery.unavailableCount, recovery.unconfirmedCount)
    end
    return message
  end

  StaticPopupDialogs.ARTISANLOGBOOK_REPAIR_UNKNOWN_RECIPES = {
    text = "Repair unknown recipes?",
    button1 = "Repair",
    button2 = "Cancel",
    OnAccept = function()
      local result, reason = ArtisanLogbookManagement.RepairUnknownRecipes()
      if not result then
        addon.Notify("Unknown recipe repair failed: " .. tostring(reason))
        return
      end
      local analysis = result.analysis
      local insufficient = analysis.insufficientEvidenceCount + analysis.missingOutputCount
      local message = string.format("Repaired %d crafts and reconciled affected aggregates. %d ambiguous and %d without sufficient evidence remain.",
        result.repairedCount, analysis.ambiguousCount, insufficient)
      addon.Notify(message)
      text:SetText("Unknown recipe repair\n\n" .. message)
      text:SetCursorPosition(0)
      text:ClearFocus()
      scroll:SetVerticalScroll(0)
      pageLabel:SetText("Repair result")
      updateStatus()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
  button("Repair unknown recipes", 214, -height + 40, function()
    local analysis, reason = ArtisanLogbookManagement.AnalyzeUnknownRecipeRepair()
    if not analysis then
      addon.Notify("Unknown recipe repair analysis failed: " .. tostring(reason))
      return
    end
    text:SetText(analysisText(analysis))
    text:SetCursorPosition(0)
    text:ClearFocus()
    scroll:SetVerticalScroll(0)
    pageLabel:SetText("Repair analysis")
    updateStatus()
    if analysis.repairableCount == 0 then
      addon.Notify(string.format("No crafts can be repaired. %d ambiguous, %d without sufficient evidence.",
        analysis.ambiguousCount, analysis.missingOutputCount + analysis.insufficientEvidenceCount))
      return
    end
    StaticPopupDialogs.ARTISANLOGBOOK_REPAIR_UNKNOWN_RECIPES.text = string.format(
      "Repair unknown recipes?\n\n%d unattributed crafts were found.\n%d can be uniquely attributed from authoritative recipe/output knowledge.\n\nAmbiguous or unsupported crafts will not be changed.",
      analysis.unattributedCount, analysis.repairableCount)
    StaticPopupDialogs.ARTISANLOGBOOK_REPAIR_UNKNOWN_RECIPES.button1 =
      string.format("Repair %d crafts", analysis.repairableCount)
    StaticPopup_Show("ARTISANLOGBOOK_REPAIR_UNKNOWN_RECIPES")
  end, 210)

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

  StaticPopupDialogs.ARTISANLOGBOOK_PURGE_LOGBOOK_DB = {
    text = "Permanently delete all recorded Artisan Logbook crafts, requests, dimensions and historical aggregates? This cannot be undone.",
    button1 = "Purge Logbook DB",
    button2 = "Cancel",
    OnAccept = function()
      local ok, reason = addon.PurgeLogbookDB()
      addon.Notify(ok and "Logbook DB purged." or reason)
      window:Refresh(true)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
  button("Purge Logbook DB", width - 328, -height + 40, function()
    StaticPopup_Show("ARTISANLOGBOOK_PURGE_LOGBOOK_DB")
  end, 166)

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
