local _, addon = ...
local Inspector = {}
addon.Inspector = Inspector

-- Text is streamed, never evaluated. Escapes also prevent WoW markup from hiding data.
local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function escape(text)
  return (text:gsub('[%z\1-\31\127-\255\\\"|]', function(character)
    return escapes[character] or string.format("\\%03d", string.byte(character))
  end))
end
Inspector.Escape = escape

function Inspector.Readable(value)
  if type(issecretvalue) == "function" then
    local ok, secret = pcall(issecretvalue, value)
    if not ok or secret then return false, "<secret or inaccessible value>" end
  end
  if type(value) == "table" and type(canaccesstable) == "function" then
    local ok, accessible = pcall(canaccesstable, value)
    if not ok or not accessible then return false, "<inaccessible table>" end
  end
  return true
end

function Inspector.SafeText(value)
  local readable, reason = Inspector.Readable(value)
  if not readable then return reason end
  local kind = type(value)
  if kind == "string" then return escape(value:sub(1, 240)) .. (#value > 240 and "..." or "") end
  if kind == "number" then
    if value ~= value then return "nan" end
    if value == math.huge then return "inf" end
    if value == -math.huge then return "-inf" end
    return string.format("%.17g", value)
  end
  if kind == "nil" or kind == "boolean" then return tostring(value) end
  return "<" .. kind .. ">"
end

function Inspector.Format(value)
  local renderer = { pages = {}, done = false, limited = false, pageBytes = 12000 }
  local buffer, bytes, emitted, nodes = {}, 0, 0, 0
  local function flush(pause)
    if bytes > 0 then
      renderer.pages[#renderer.pages + 1] = table.concat(buffer)
      buffer, bytes = {}, 0
      if pause then coroutine.yield() end
    end
  end
  local function emit(text)
    local start = 1
    while start <= #text do
      if bytes == renderer.pageBytes then flush(true) end
      local length = math.min(renderer.pageBytes - bytes, #text - start + 1)
      buffer[#buffer + 1] = text:sub(start, start + length - 1)
      bytes, emitted, start = bytes + length, emitted + length, start + length
    end
  end
  local ranks = { number = 1, string = 2, boolean = 3 }
  local function before(left, right)
    local a, b = type(left), type(right)
    if a ~= b then return ranks[a] < ranks[b] end
    if a == "boolean" then return left == false and right == true end
    return left < right
  end
  local active = {}
  local visit
  visit = function(child, depth)
    nodes = nodes + 1
    if nodes % 100 == 0 then coroutine.yield() end
    if nodes > 50000 or emitted > 1500000 then
      renderer.limited = true
      emit("<total inspection budget reached; narrow the selected response>")
      return
    end
    local readable, reason = Inspector.Readable(child)
    if not readable then emit(reason); return end
    local kind = type(child)
    if kind == "string" then
      emit('"')
      for start = 1, #child, 512 do
        emit(escape(child:sub(start, start + 511)))
        coroutine.yield()
        if emitted > 1500000 then
          renderer.limited = true
          emit('" <string exceeds total inspection budget>')
          return
        end
      end
      emit('"')
    elseif kind ~= "table" then
      emit(Inspector.SafeText(child))
    elseif active[child] then
      emit("<cycle>")
    elseif depth >= 12 then
      renderer.limited = true
      emit("<depth limit 12; select a smaller response>")
    else
      local keys, skipped, overflow, key, scanned = {}, false, false, nil, 0
      repeat
        -- next/rawget avoid executing user-supplied table metamethods.
        key = next(child, key)
        if key ~= nil then
          scanned = scanned + 1
          if Inspector.Readable(key) and ranks[type(key)] then
            keys[#keys + 1] = key
          else
            skipped = true
          end
          if scanned > 5000 then overflow = true; break end
          if scanned % 100 == 0 then coroutine.yield() end
        end
      until key == nil
      if overflow then
        renderer.limited = true
        emit("<table exceeds safe key budget 5000; narrow the selected response>")
        return
      end
      table.sort(keys, before)
      active[child] = true
      emit("{")
      for _, entry in ipairs(keys) do
        emit("\n" .. string.rep("  ", depth + 1) .. "[")
        visit(entry, depth + 1)
        emit("] = ")
        visit(rawget(child, entry), depth + 1)
        emit(",")
        if nodes > 50000 or emitted > 1500000 then break end
      end
      if skipped then
        renderer.limited = true
        emit("\n" .. string.rep("  ", depth + 1) .. "<secret or non-scalar keys not traversed>")
      end
      active[child] = nil
      emit(#keys > 0 and ("\n" .. string.rep("  ", depth) .. "}") or "}")
    end
  end
  renderer.thread = coroutine.create(function()
    visit(value, 0)
    flush(false)
  end)
  function renderer:Step()
    if self.done then return end
    local ok = coroutine.resume(self.thread)
    if not ok then
      self.error = "Inspection failed safely; response was not modified."
      self.pages[#self.pages + 1] = self.error
      self.done, self.limited = true, true
    elseif coroutine.status(self.thread) == "dead" then
      self.done = true
    end
  end
  return renderer
end
