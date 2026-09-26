local _, addon = ...

local Trace = {}
addon.Trace = Trace

Trace.schemaVersion = 1
Trace.exportVersion = 1
Trace.maxRecords = 2000
Trace.maxBytes = 2 * 1024 * 1024
Trace.maxPayloadBytes = 16384

function Trace.Serialize(value, isSecret)
  local visited, warnings = {}, {}
  local remainingNodes, remainingBytes = 512, Trace.maxPayloadBytes

  local function omitted(reason)
    warnings[reason] = true
    return '{["traceOmitted"]=' .. string.format("%q", reason) .. '}'
  end

  local function encode(current, depth)
    if isSecret and isSecret(current) then
      return omitted("secret")
    end
    remainingNodes = remainingNodes - 1
    if remainingNodes < 0 then
      return omitted("node-limit")
    end
    local kind = type(current)
    if kind == "nil" or kind == "boolean" then
      return tostring(current)
    elseif kind == "number" then
      if current ~= current or current == math.huge or current == -math.huge then
        return omitted("non-finite-number")
      end
      return string.format("%.17g", current)
    elseif kind == "string" then
      if #current > 2048 then
        return omitted("string-limit")
      end
      local encoded = string.format("%q", current)
      remainingBytes = remainingBytes - #encoded
      if remainingBytes < 0 then
        return omitted("byte-limit")
      end
      return encoded
    elseif kind ~= "table" then
      return omitted(kind)
    end
    if visited[current] then
      return omitted("cycle")
    end
    if depth >= 8 then
      return omitted("depth-limit")
    end
    visited[current] = true
    local entries = {}
    for key, child in next, current do
      remainingNodes = remainingNodes - 1
      if remainingNodes < 2 or remainingBytes < 0 then
        entries[#entries + 1] = '["traceRemainder"]=' .. omitted("table-limit")
        break
      end
      if (isSecret and isSecret(key)) or
          (type(key) ~= "string" and type(key) ~= "number" and type(key) ~= "boolean") then
        warnings["unsupported-key"] = true
      else
        entries[#entries + 1] = "[" .. encode(key, depth + 1) .. "]=" .. encode(child, depth + 1)
      end
    end
    visited[current] = nil
    table.sort(entries)
    return "{" .. table.concat(entries, ",") .. "}"
  end

  local ok, encoded = pcall(encode, value, 0)
  if not ok then
    encoded = omitted("inaccessible-value")
  elseif #encoded > Trace.maxPayloadBytes then
    encoded = omitted("payload-limit")
  end
  local reasons = {}
  for reason in pairs(warnings) do
    reasons[#reasons + 1] = reason
  end
  table.sort(reasons)
  return encoded, table.concat(reasons, ",")
end

function Trace.New(database, clock, isSecret)
  if database == nil then
    database = {
      traceSchemaVersion = Trace.schemaVersion,
      exportContractVersion = Trace.exportVersion,
      nextSequence = 1,
      records = {},
      bytes = 0,
    }
  end
  if type(database) ~= "table" or database.traceSchemaVersion ~= Trace.schemaVersion or
      database.exportContractVersion ~= Trace.exportVersion or type(database.records) ~= "table" or
      type(database.nextSequence) ~= "number" or type(database.bytes) ~= "number" then
    return nil, "Unsupported or invalid trace database; existing data was left untouched."
  end

  local recorder = { database = database, recording = false }

  function recorder:Capture(event, ...)
    if not self.recording then
      return false
    end
    local arguments = { n = select("#", ...), ... }
    local payload, warnings = Trace.Serialize(arguments, isSecret)
    local record = {
      sequence = database.nextSequence,
      timestamp = clock.wall(),
      elapsed = clock.elapsed(),
      event = event,
      payload = payload,
    }
    if warnings ~= "" then
      record.warnings = warnings
    end
    local byteCount = #payload + #event + #warnings + 512
    if #database.records >= Trace.maxRecords or database.bytes + byteCount > Trace.maxBytes then
      self.recording = false
      database.stoppedReason = "capacity"
      return false, "Trace capacity reached; export and clear before recording more."
    end
    database.records[#database.records + 1] = record
    database.bytes = database.bytes + byteCount
    database.nextSequence = database.nextSequence + 1
    return true
  end

  function recorder:Start(metadata)
    if self.recording then
      return false, "Already recording."
    end
    self.recording = true
    local captured, reason = self:Capture("TRACE_START", metadata)
    if captured then database.stoppedReason = nil end
    return captured, reason
  end

  function recorder:Stop()
    self:Capture("TRACE_STOP")
    self.recording = false
  end

  function recorder:Clear()
    if self.recording then
      return false, "Stop recording before clearing."
    end
    database.records = {}
    database.bytes = 0
    database.stoppedReason = nil
    return true
  end

  function recorder:Export(first, count)
    local lines = {
      "return {",
      "traceSchemaVersion=" .. Trace.schemaVersion .. ",",
      "exportContractVersion=" .. Trace.exportVersion .. ",",
      "totalRecords=" .. #database.records .. ",",
      "records={",
    }
    for index = first, math.min(first + count - 1, #database.records) do
      local record = database.records[index]
      lines[#lines + 1] = string.format(
        "{sequence=%d,timestamp=%.17g,elapsed=%.17g,event=%q,arguments=%s,warnings=%s},",
        record.sequence, record.timestamp, record.elapsed, record.event, record.payload,
        record.warnings and string.format("%q", record.warnings) or "nil")
    end
    lines[#lines + 1] = "}}"
    return table.concat(lines, "\n")
  end

  return recorder
end