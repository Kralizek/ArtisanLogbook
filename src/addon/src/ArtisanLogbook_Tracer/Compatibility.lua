local addonName, addon = ...

function addon.ReadOptional(api, name, ...)
  if type(api) ~= "table" or type(api[name]) ~= "function" then return nil end
  local ok, value = pcall(api[name], ...)
  if ok then return value end
  addon.Notify(name .. " failed: " .. tostring(value))
end

function addon.GetMetadata(field)
  if type(C_AddOns) == "table" and type(C_AddOns.GetAddOnMetadata) == "function" then
    return addon.ReadOptional(C_AddOns, "GetAddOnMetadata", addonName, field)
  end
  return addon.ReadOptional(_G, "GetAddOnMetadata", addonName, field)
end

function addon.DetectClientFlavor(api)
  -- Camelot is selected by Forever's ProjectConstants TOC, not the API family.
  for _, project in ipairs({
    { "WOW_PROJECT_CAMELOT", "forever" },
    { "WOW_PROJECT_MAINLINE", "retail" },
    { "WOW_PROJECT_CLASSIC", "classic" },
    { "WOW_PROJECT_MISTS_CLASSIC", "mists-classic" },
  }) do
    if api[project[1]] ~= nil and api.WOW_PROJECT_ID == api[project[1]] then
      return project[2], "project-constant"
    end
  end
  local packaged = addon.GetMetadata("X-ArtisanLogbook-Flavor")
  if packaged == "forever" or packaged == "retail" then return packaged, "package" end
  return "other", "unknown"
end

function addon.GetCoreDiagnostics()
  if type(ArtisanLogbookAPI) ~= "table" or type(ArtisanLogbookAPI.GetDiagnostics) ~= "function" then
    return { available = false, reason = "Core diagnostics are unavailable." }
  end
  local ok, snapshot, reason = pcall(ArtisanLogbookAPI.GetDiagnostics)
  if not ok then return { available = false, reason = "Core diagnostics failed: " .. tostring(snapshot) } end
  if not snapshot then return { available = false, reason = reason or "Core diagnostics are unavailable." } end
  return { available = true, snapshot = snapshot }
end

function addon.RegisterCoreObserver()
  if type(ArtisanLogbookAPI) ~= "table" or type(ArtisanLogbookAPI.SetDiagnosticObserver) ~= "function" then
    return false, "Core diagnostic observer API is unavailable."
  end
  local ok, registered, reason = pcall(ArtisanLogbookAPI.SetDiagnosticObserver, function(event, context)
    addon.Emit("CORE_CAPTURE_DECISION", event, context)
  end)
  if not ok then return false, "Core diagnostic observer failed: " .. tostring(registered) end
  return registered == true, reason
end

function addon.CreateCompatibleFrame(kind, name, parent, template)
  if template then
    local ok, frame = pcall(CreateFrame, kind, name, parent, template)
    if ok then return frame end
    addon.Notify("UI template " .. template .. " unavailable: " .. tostring(frame))
  end
  return CreateFrame(kind, name, parent)
end
