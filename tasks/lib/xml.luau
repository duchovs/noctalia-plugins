--!nonstrict
-- Minimal namespace-aware XML parser, sized for WebDAV multistatus documents.
--
-- CalDAV servers pick their own prefixes for the same namespaces -- one says
-- `<D:response>` where another says `<d:response>`, and a default `xmlns` is
-- legal too -- so nodes are matched on resolved namespace URI + local name,
-- never on the literal prefix.
--
-- A node is { ns = uri, name = localName, attrs = {}, children = {}, text = "" }.
-- `text` holds the node's own concatenated character data, entity-decoded.

local M = {}

local ENTITIES = {
  lt = "<",
  gt = ">",
  amp = "&",
  quot = '"',
  apos = "'",
}

-- Encodes a codepoint as UTF-8; numeric character references arrive as
-- codepoints and the rest of the pipeline is byte-oriented UTF-8.
local function encodeCodepoint(code: number): string
  if utf8 ~= nil and utf8.char ~= nil then
    local ok, encoded = pcall(utf8.char, code)
    if ok then
      return encoded
    end
  end
  return ""
end

function M.unescape(text: string): string
  if not text:find("&", 1, true) then
    return text -- the common case: no entities, no allocation
  end
  return (text:gsub("&(#?[%w]+);", function(body)
    if body:sub(1, 2) == "#x" or body:sub(1, 2) == "#X" then
      return encodeCodepoint(tonumber(body:sub(3), 16) or 0)
    elseif body:sub(1, 1) == "#" then
      return encodeCodepoint(tonumber(body:sub(2)) or 0)
    end
    return ENTITIES[body] or ("&" .. body .. ";")
  end))
end

function M.escape(text: string): string
  return (text:gsub("[&<>\"']", {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
    ['"'] = "&quot;",
    ["'"] = "&apos;",
  }))
end

local EMPTY_ATTRS = {}

-- Most DAV elements carry no attributes, and running the pattern over an empty
-- segment for every one of them is measurable inside the host's per-callback
-- CPU budget. The shared empty table is safe because attribute tables are only
-- ever read.
local function parseAttributes(raw: string)
  if raw:find("=", 1, true) == nil then
    return EMPTY_ATTRS
  end
  local attrs = {}
  for name, _, value in raw:gmatch("([%w_:%-%.]+)%s*=%s*([\"'])(.-)%2") do
    attrs[name] = M.unescape(value)
  end
  return attrs
end

local function splitName(qualified: string): (string?, string)
  local prefix, localName = qualified:match("^([^:]+):(.+)$")
  if prefix ~= nil then
    return prefix, localName
  end
  return nil, qualified
end

-- Namespace bindings are scoped to the element that declares them, so each
-- element pushes a frame that inherits from its parent and is popped on close.
local function scopeFor(parentScope, attrs)
  local scope = nil
  for name, value in pairs(attrs) do
    if name == "xmlns" then
      scope = scope or setmetatable({}, { __index = parentScope })
      scope[""] = value
    else
      local prefix = name:match("^xmlns:(.+)$")
      if prefix ~= nil then
        scope = scope or setmetatable({}, { __index = parentScope })
        scope[prefix] = value
      end
    end
  end
  return scope or parentScope
end

-- Markup items consumed between calls to `shouldYield`, which is a host call.
local YIELD_CHECK_ITEMS = 32

-- A resumable parser. `step(shouldYield)` returns (true, root) once the document
-- is parsed, (nil, err) on malformed input, or false when `shouldYield()` asked
-- it to stop -- calling `step` again resumes where it left off. The host meters
-- every loop iteration against a 25 ms per-callback CPU budget, and a whole
-- collection's WebDAV response does not fit inside one on a slow machine.
--
-- Anything the parser does not need -- processing instructions, comments,
-- doctypes -- is skipped rather than modelled.
function M.parser(source: string)
  local failed = nil
  if type(source) ~= "string" or source == "" then
    failed = "empty document"
  end

  local root = nil
  local stack = {}
  local rootScope = setmetatable({}, { __index = function() return nil end })
  local scopes = { rootScope }
  local pos = 1
  local length = failed == nil and #source or 0

  local function appendText(chunk: string)
    local node = stack[#stack]
    if node ~= nil and chunk ~= "" then
      node.text = node.text .. chunk
    end
  end

  -- Consumes the text before the next markup item and the item itself.
  -- Returns an error message, or nil.
  local function advance(): string?
    local open = source:find("<", pos, true)
    if open == nil then
      appendText(M.unescape(source:sub(pos)))
      pos = length + 1
      return nil
    end
    if open > pos then
      appendText(M.unescape(source:sub(pos, open - 1)))
    end

    local marker = source:sub(open + 1, open + 1)
    if marker == "?" then
      local finish = source:find("?>", open + 2, true)
      if finish == nil then
        return "unterminated processing instruction"
      end
      pos = finish + 2
    elseif marker == "!" then
      if source:sub(open + 2, open + 8) == "[CDATA[" then
        local finish = source:find("]]>", open + 9, true)
        if finish == nil then
          return "unterminated CDATA section"
        end
        appendText(source:sub(open + 9, finish - 1)) -- CDATA is literal, not escaped
        pos = finish + 3
      elseif source:sub(open + 2, open + 3) == "--" then
        local finish = source:find("-->", open + 4, true)
        if finish == nil then
          return "unterminated comment"
        end
        pos = finish + 3
      else
        local finish = source:find(">", open + 2, true)
        if finish == nil then
          return "unterminated declaration"
        end
        pos = finish + 1
      end
    elseif marker == "/" then
      local finish = source:find(">", open + 2, true)
      if finish == nil then
        return "unterminated closing tag"
      end
      if #stack == 0 then
        return "closing tag without a matching open tag"
      end
      -- A mismatch means the document is not what it claims to be; unwinding
      -- to the named element instead would quietly reshape the tree the
      -- caller then reads properties out of.
      local closing = source:sub(open + 2, finish - 1):match("^([%w_:%-%.]+)")
      local _, closingLocal = splitName(closing or "")
      if closingLocal ~= stack[#stack].name then
        return "closing </" .. tostring(closing) .. "> does not match <" .. stack[#stack].name .. ">"
      end
      table.remove(stack)
      table.remove(scopes)
      pos = finish + 1
    else
      local finish = source:find(">", open + 1, true)
      if finish == nil then
        return "unterminated tag"
      end
      local body = source:sub(open + 1, finish - 1)
      local selfClosing = body:sub(-1) == "/"
      if selfClosing then
        body = body:sub(1, -2)
      end
      local qualified = body:match("^([%w_:%-%.]+)")
      if qualified == nil then
        return "malformed tag"
      end
      local attrs = parseAttributes(body:sub(#qualified + 1))
      local scope = scopeFor(scopes[#scopes], attrs)
      local prefix, localName = splitName(qualified)
      local node = {
        ns = scope[prefix or ""] or "",
        name = localName,
        attrs = attrs,
        children = {},
        text = "",
      }
      local parent = stack[#stack]
      if parent ~= nil then
        table.insert(parent.children, node)
      elseif root == nil then
        root = node
      else
        return "multiple root elements"
      end
      if not selfClosing then
        table.insert(stack, node)
        table.insert(scopes, scope)
      end
      pos = finish + 1
    end
    return nil
  end

  local function step(shouldYield)
    if failed ~= nil then
      return nil, failed
    end
    local items = 0
    while pos <= length do
      failed = advance()
      if failed ~= nil then
        return nil, failed
      end
      items += 1
      if shouldYield ~= nil and items % YIELD_CHECK_ITEMS == 0 and pos <= length and shouldYield() then
        return false
      end
    end
    if #stack > 0 then
      failed = "unclosed element <" .. stack[#stack].name .. ">"
      return nil, failed
    end
    if root == nil then
      failed = "no root element"
      return nil, failed
    end
    return true, root
  end

  return { step = step }
end

-- Parses a whole document in one call. Returns the root node, or (nil, err).
function M.parse(source: string)
  local done, result = M.parser(source).step(nil)
  if done then
    return result
  end
  return nil, result
end

-- Direct children matching a namespace + local name. `ns` of nil matches any.
function M.children(node, ns: string?, name: string)
  local found = {}
  if node == nil then
    return found
  end
  for _, child in ipairs(node.children) do
    if child.name == name and (ns == nil or child.ns == ns) then
      table.insert(found, child)
    end
  end
  return found
end

function M.child(node, ns: string?, name: string)
  if node == nil then
    return nil
  end
  for _, child in ipairs(node.children) do
    if child.name == name and (ns == nil or child.ns == ns) then
      return child
    end
  end
  return nil
end

-- Depth-first search for every descendant with this namespace + local name.
function M.find(node, ns: string?, name: string)
  local found = {}
  local function walk(current)
    for _, child in ipairs(current.children) do
      if child.name == name and (ns == nil or child.ns == ns) then
        table.insert(found, child)
      end
      walk(child)
    end
  end
  if node ~= nil then
    walk(node)
  end
  return found
end

function M.findFirst(node, ns: string?, name: string)
  return M.find(node, ns, name)[1]
end

-- Trims without `gsub("%s+$", "")`, which is quadratic in the length of a
-- trailing whitespace run: the matcher retries `%s+` from every position in the
-- run and rescans it to the end each time. A 16 KiB run costs the better part
-- of a second, which is far outside the host's per-callback CPU budget. Scanning
-- inward from both ends is linear.
local function trim(value: string): string
  local first = value:find("%S")
  if first == nil then
    return ""
  end
  local last = #value
  while last > first do
    local byte = value:byte(last)
    if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
      break
    end
    last -= 1
  end
  return value:sub(first, last)
end

M.trim = trim

-- The node's own text, trimmed. Nested markup contributes nothing, which is
-- what DAV leaf properties (href, displayname, getetag) want.
function M.text(node): string
  if node == nil then
    return ""
  end
  return trim(node.text)
end

return M
