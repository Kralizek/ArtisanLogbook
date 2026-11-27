local _, addon = ...

local Trace = {}
addon.Trace = Trace

Trace.schemaVersion = 3
Trace.exportVersion = 2
Trace.largeTraceBytes = 12 * 1024 * 1024
Trace.maxExportRecords = 10
Trace.maxPayloadBytes = 16384
-- WoW loads SavedVariables as one Lua 5.1 function, which is limited to 262,143 unique
-- constants. Saving each record as a table adds several unique constants per record, so a
-- trace of roughly 130,000 records failed to load and was silently replaced. Records are
-- therefore saved in packed strings, each a single constant, and unpacked again on load.
Trace.recordsPerChunk = 1000

local function isValidRecord(record)
  return type(record) == "table" and type(record.sequence) == "number" and
    type(record.timestamp) == "number" and type(record.elapsed) == "number" and
    type(record.event) == "string" and type(record.payload) == "string" and
    (record.warnings == nil or type(record.warnings) == "string")
end

-- Each record is a header of numbers, then its strings at the header's byte lengths:
-- "sequence,timestamp,elapsed,#event,#payload,#warnings;" .. event .. payload .. warnings
-- A warnings length of -1 means the record has no warnings.
function Trace.PackRecords(records, first, last)
  local parts = {}
  for index = first, last do
    local record = records[index]
    if not isValidRecord(record) then return nil, "Invalid trace record at index " .. index .. "." end
    local warnings = record.warnings or ""
    parts[#parts + 1] = string.format("%.17g,%.17g,%.17g,%d,%d,%d;", record.sequence,
      record.timestamp, record.elapsed, #record.event, #record.payload,
      record.warnings and #warnings or -1)
    parts[#parts + 1] = record.event
    parts[#parts + 1] = record.payload
    parts[#parts + 1] = warnings
  end
  return table.concat(parts)
end

function Trace.UnpackRecords(chunk, into)
  if type(chunk) ~= "string" then return false end
  local position, length = 1, #chunk
  while position <= length do
    local headerEnd = string.find(chunk, ";", position, true)
    if not headerEnd then return false end
    local sequence, timestamp, elapsed, eventLength, payloadLength, warningsLength =
      string.match(string.sub(chunk, position, headerEnd - 1), "^([^,]+),([^,]+),([^,]+),(%d+),(%d+),(%-?%d+)$")
    sequence, timestamp, elapsed = tonumber(sequence), tonumber(timestamp), tonumber(elapsed)
    eventLength, payloadLength, warningsLength = tonumber(eventLength), tonumber(payloadLength), tonumber(warningsLength)
    if not sequence or not timestamp or not elapsed or not eventLength or not payloadLength or
        not warningsLength or warningsLength < -1 then
      return false
    end
    local eventStart = headerEnd + 1
    local payloadStart = eventStart + eventLength
    local warningsStart = payloadStart + payloadLength
    local nextPosition = warningsStart + math.max(warningsLength, 0)
    if nextPosition - 1 > length then return false end
    into[#into + 1] = {
      sequence = sequence,
      timestamp = timestamp,
      elapsed = elapsed,
      event = string.sub(chunk, eventStart, payloadStart - 1),
      payload = string.sub(chunk, payloadStart, warningsStart - 1),
      warnings = warningsLength >= 0 and string.sub(chunk, warningsStart, nextPosition - 1) or nil,
    }
    position = nextPosition
  end
  return true
end

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

function Trace.New(database, clock, isSecret, metadata)
  local function isNonnegativeFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value >= 0
  end
  if database == nil then
    database = {
      traceSchemaVersion = Trace.schemaVersion,
      traceExportVersion = Trace.exportVersion,
      nextSequence = 1,
      records = {},
      bytes = 0,
      recordingEnabled = false,
      recordingMode = "normal",
    }
  elseif type(database) == "table" and database.traceSchemaVersion == 1 and
      database.exportContractVersion == 1 and type(database.records) == "table" and
      type(database.nextSequence) == "number" and type(database.bytes) == "number" then
    local migrated = {}
    for key, value in pairs(database) do migrated[key] = value end
    migrated.traceSchemaVersion = Trace.schemaVersion
    migrated.traceExportVersion = Trace.exportVersion
    migrated.exportContractVersion = nil
    database = migrated
  end
  -- Schema 3 only changes how records are saved, so a schema-2 database loads unchanged.
  if type(database) ~= "table" or
      (database.traceSchemaVersion ~= Trace.schemaVersion and database.traceSchemaVersion ~= 2) or
      database.traceExportVersion ~= Trace.exportVersion or type(database.records) ~= "table" or
      (database.recordChunks ~= nil and (database.traceSchemaVersion ~= Trace.schemaVersion or
        type(database.recordChunks) ~= "table")) or
      type(database.nextSequence) ~= "number" or database.nextSequence < 1 or
      database.nextSequence % 1 ~= 0 or not isNonnegativeFinite(database.bytes) or
      database.bytes % 1 ~= 0 then
    return nil, "Unsupported or invalid trace database; existing data was left untouched."
  end
  if (database.recordingEnabled ~= nil and type(database.recordingEnabled) ~= "boolean") or
      (database.recordingMode ~= nil and database.recordingMode ~= "normal" and
        database.recordingMode ~= "verbose") or
      (database.logicalSessionID ~= nil and (not isNonnegativeFinite(database.logicalSessionID) or
        database.logicalSessionID < 1 or database.logicalSessionID % 1 ~= 0)) then
    return nil, "Invalid trace recording settings; existing data was left untouched."
  end
  if database.recordChunks then
    -- Packed records precede any records captured after packing. Decode everything before
    -- changing the database, so an unreadable chunk leaves the saved data as it was.
    local records = {}
    for index = 1, #database.recordChunks do
      if not Trace.UnpackRecords(database.recordChunks[index], records) then
        return nil, "Unreadable saved trace records; existing data was left untouched."
      end
    end
    for index = 1, #database.records do
      if not isValidRecord(database.records[index]) then
        return nil, "Unreadable saved trace records; existing data was left untouched."
      end
      records[#records + 1] = database.records[index]
    end
    database.records = records
    database.recordChunks = nil
  end
  database.traceSchemaVersion = Trace.schemaVersion
  if database.recordingEnabled == nil then database.recordingEnabled = false end
  if database.recordingMode == nil then database.recordingMode = "normal" end

  local recorder = { database = database, recording = false, verbose = database.recordingMode == "verbose" }

  function recorder:Fail(reason)
    self.recording = false
    database.recordingEnabled = false
    database.stoppedReason = "capture-error"
    database.captureError = tostring(reason)
    return false, "Capture stopped; automatic resumption disabled. Earlier evidence is preserved: " ..
      database.captureError
  end

  local function capture(event, ...)
    local arguments = { n = select("#", ...), ... }
    local payload, warnings = Trace.Serialize(arguments, isSecret)
    local record = {
      sequence = database.nextSequence,
      timestamp = clock.wall(),
      elapsed = clock.elapsed(),
      event = event,
      payload = payload,
    }
    assert(type(event) == "string" and isNonnegativeFinite(record.timestamp) and
      isNonnegativeFinite(record.elapsed), "Invalid capture event or clock value.")
    if warnings ~= "" then
      record.warnings = warnings
    end
    local byteCount = #payload + #event + #warnings + 512
    database.records[#database.records + 1] = record
    database.bytes = database.bytes + byteCount
    database.nextSequence = database.nextSequence + 1
    return true
  end

  function recorder:Capture(event, ...)
    if not self.recording then return false, database.stoppedReason end
    local ok, captured = pcall(capture, event, ...)
    if not ok then return self:Fail(captured) end
    return captured
  end

  local function begin(self, context, resumed)
    if self.recording then
      return false, "Already recording."
    end
    if not resumed or not database.logicalSessionID then
      database.logicalSessionID = database.nextSequence
    end
    self.segmentID = database.nextSequence
    local boundary = {}
    for key, value in pairs(context or {}) do boundary[key] = value end
    boundary.logicalSessionID = database.logicalSessionID
    boundary.segmentID = self.segmentID
    boundary.startReason = resumed and "automatic-resume" or "manual"
    boundary.mode = database.recordingMode
    boundary.verbose = self.verbose
    self.recording = true
    database.recordingEnabled = true
    database.stoppedReason = nil
    database.captureError = nil
    return self:Capture("TRACE_START", boundary)
  end

  function recorder:Start(context)
    if self.recording then return false, "Already recording." end
    if context and context.verbose ~= nil then
      database.recordingMode = context.verbose == true and "verbose" or "normal"
    end
    self.verbose = database.recordingMode == "verbose"
    return begin(self, context, false)
  end

  function recorder:Stop()
    local captured, reason = true, nil
    if self.recording then captured, reason = self:Capture("TRACE_STOP") end
    self.recording = false
    database.recordingEnabled = false
    return captured, reason
  end

  function recorder:Clear()
    if self.recording then
      return false, "Stop recording before clearing."
    end
    database.records = {}
    database.recordChunks = nil
    database.bytes = 0
    database.stoppedReason = nil
    database.captureError = nil
    database.logicalSessionID = nil
    return true
  end

  -- Call immediately before WoW writes SavedVariables (PLAYER_LOGOUT, which also precedes a
  -- reload). Records captured afterwards stay as tables and are loaded after the chunks.
  function recorder:PrepareSave()
    local records = database.records
    local chunks = {}
    for index = 1, #(database.recordChunks or {}) do chunks[index] = database.recordChunks[index] end
    for first = 1, #records, Trace.recordsPerChunk do
      local chunk, reason = Trace.PackRecords(records, first, math.min(first + Trace.recordsPerChunk - 1, #records))
      if not chunk then return false, reason end
      chunks[#chunks + 1] = chunk
    end
    database.recordChunks = chunks
    database.records = {}
    return true
  end

  function recorder:Export(first, count)
    first = first or 1
    count = count or Trace.maxExportRecords
    if type(first) ~= "number" or first ~= first or first < 1 or first % 1 ~= 0 or
        type(count) ~= "number" or count ~= count or count < 0 or count % 1 ~= 0 then
      return nil, "Invalid trace export page."
    end
    count = math.min(count, Trace.maxExportRecords)
    local lines = {
      "return {",
      "traceSchemaVersion=" .. Trace.schemaVersion .. ",",
      "traceExportVersion=" .. Trace.exportVersion .. ",",
      "totalRecords=" .. #database.records .. ",",
      "records={",
    }
    for index = first, math.min(first + count - 1, #database.records) do
      local record = database.records[index]
      if not isValidRecord(record) then
        return nil, "Invalid trace record at index " .. index .. "."
      end
      lines[#lines + 1] = string.format(
        "{sequence=%d,timestamp=%.17g,elapsed=%.17g,event=%q,arguments=%s,warnings=%s},",
        record.sequence, record.timestamp, record.elapsed, record.event, record.payload,
        record.warnings and string.format("%q", record.warnings) or "nil")
    end
    lines[#lines + 1] = "}}"
    return table.concat(lines, "\n")
  end

  if database.recordingEnabled then
    local ok, reason = begin(recorder, metadata, true)
    if not ok then return recorder, reason end
  end
  return recorder
end
