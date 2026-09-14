--!nonstrict
-- The console.
--
-- A thin client: the sidecar owns the session and the transcript, this file owns
-- only what is on screen. On open it takes a snapshot and then follows deltas, so
-- reopening mid-turn shows the run already in progress rather than an empty box.
--
-- Rendering is coalesced onto the frame tick. Text deltas land about twelve times
-- a second while a reply streams, and re-rendering per delta would rebuild the
-- tree far more often than the compositor draws it; marking dirty and rendering
-- in onFrameTick collapses each burst into one pass, and the tick is switched off
-- entirely when nothing is streaming.

local shared = require("./shared.luau")

-- ── Local state ─────────────────────────────────────────────────────────────

local items = {}          -- dense array, transcript order
local byIndex = {}        -- item id -> position in `items`
local status = { phase = "off" }
local caps = {}
local stream = nil

local draft = ""
local inputKey = 1        -- bumped to force a fresh (and re-focused) input
local expanded = {}       -- item id -> true, for tool output / thinking
local palette = false
local paletteFilter = ""
local sessions = {}
local sessionsPending = false
local dirty = true
local ticking = false
local notice = ""

-- Rendering every item of a long scrollback rebuilds hundreds of nodes per pass.
-- The sidecar keeps the real history; this is the window onto its tail.
local VISIBLE_LIMIT = 200

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function setTicking(want: boolean)
  if want ~= ticking then
    ticking = want
    panel.setNeedsFrameTick(want)
  end
end

-- Marking the tree dirty has to ask for a frame as well. The tick is switched
-- off whenever the picture settles, so without this a keystroke or a click
-- between turns would set the flag and then never be drawn.
local function markDirty()
  dirty = true
  setTicking(true)
end

local function busy(): boolean
  return status.phase == "busy" or status.phase == "starting"
end

local function resetTranscript()
  items = {}
  byIndex = {}
  markDirty()
end

local function applyItem(item)
  if type(item) ~= "table" or item.i == nil then
    return
  end
  local position = byIndex[item.i]
  if position == nil then
    items[#items + 1] = item
    byIndex[item.i] = #items
  else
    local existing = items[position]
    for key, value in pairs(item) do
      existing[key] = value
    end
  end
  markDirty()
end

local function trimmedCount(): number
  local extra = #items - VISIBLE_LIMIT
  return extra > 0 and extra or 0
end

-- ── Bridge wiring ───────────────────────────────────────────────────────────

local function handleEvent(event)
  local kind = event.e
  if kind == "hello" then
    local snapshot = event.snapshot
    if type(snapshot) ~= "table" then
      return
    end
    resetTranscript()
    if type(snapshot.items) == "table" then
      for _, item in ipairs(snapshot.items) do
        applyItem(item)
      end
    end
    if type(snapshot.status) == "table" then
      status = snapshot.status
    end
    if type(snapshot.caps) == "table" then
      caps = snapshot.caps
    end
  elseif kind == "item" then
    applyItem(event.item)
  elseif kind == "patch" then
    applyItem(event.item)
  elseif kind == "status" then
    if type(event.status) == "table" then
      status = event.status
    end
  elseif kind == "caps" then
    if type(event.caps) == "table" then
      caps = event.caps
    end
  elseif kind == "reset" then
    resetTranscript()
  end
  markDirty()
end

-- Retries are paced in milliseconds, not frames: the sidecar needs a second or
-- two to boot, and a frame-counted budget would be spent before it ever listens.
local connectWaitMs = 0
local connectElapsedMs = 0
local launched = false
local CONNECT_RETRY_MS = 400
local CONNECT_GIVE_UP_MS = 20000

local function connect()
  if stream ~= nil then
    return
  end
  stream = shared.events(handleEvent, function()
    stream = nil
    launched = false
    status = { phase = "off" }
    markDirty()
  end)
  if stream == nil then
    -- No bridge yet. Start one; it writes its endpoint on boot and a later tick
    -- picks it up.
    if not launched then
      if not noctalia.commandExists("python3") then
        notice = noctalia.tr("error.no_python")
        return
      end
      if not noctalia.commandExists(tostring(noctalia.getConfig("binary") or "claude")) then
        notice = noctalia.tr("error.no_claude")
        return
      end
      launched = true
      shared.launch()
      notice = noctalia.tr("status.starting")
    elseif connectElapsedMs >= CONNECT_GIVE_UP_MS then
      notice = noctalia.tr("error.no_bridge")
      setTicking(false)
      return
    end
    setTicking(true)
  else
    connectElapsedMs = 0
    notice = ""
  end
end

-- ── Sending ─────────────────────────────────────────────────────────────────

local function submit(text: string)
  text = noctalia.string.trim(text)
  if text == "" then
    return
  end

  -- Panel-local commands: things the console owns, that the CLI has no way to
  -- do from inside a turn. Everything else — /model, /compact, /context, every
  -- skill — is forwarded verbatim and answered by Claude Code itself, which is
  -- why this list stays this short.
  local command, argument = text:match("^/(%S+)%s*(.*)$")
  if command == "clear" then
    shared.post("/clear", {})
    draft = ""
    inputKey += 1
    markDirty()
    return
  elseif command == "new" then
    shared.post("/session", { action = "new" })
    draft = ""
    inputKey += 1
    markDirty()
    return
  elseif command == "stop" then
    shared.post("/control", { subtype = "interrupt" })
    draft = ""
    inputKey += 1
    markDirty()
    return
  elseif command == "resume" then
    -- The CLI's own /resume opens a terminal picker that has nowhere to draw
    -- here, so the console answers this one itself.
    picker = "session"
    loadSessions()
    draft = ""
    inputKey += 1
    markDirty()
    return
  elseif command == "cwd" and argument ~= "" then
    local target = noctalia.expandPath(noctalia.string.trim(argument))
    shared.post("/session", { action = "cwd", cwd = target })
    shared.rememberWorkingDir(target)
    draft = ""
    inputKey += 1
    markDirty()
    return
  end

  shared.post("/send", { text = text })
  draft = ""
  inputKey += 1
  palette = false
  setTicking(true)
  markDirty()
end

-- ── Rendering: transcript rows ──────────────────────────────────────────────

local function userRow(item)
  return ui.row({
    key = "u" .. tostring(item.i),
    justify = "end",
    paddingV = 2,
  }, {
    ui.column({
      fill = "primary/0.14",
      radius = 10,
      padding = 8,
    }, {
      ui.label({ text = tostring(item.text or ""), color = "on_surface", maxWidth = 400 }),
    }),
  })
end

local function assistantRow(item)
  return ui.column({ key = "a" .. tostring(item.i), paddingV = 2 }, {
    ui.markdown({ text = tostring(item.text or "") }),
  })
end

local function thinkingRow(item)
  local open = expanded[item.i] == true
  local text = tostring(item.text or "")
  local preview = text
  if not open then
    preview = text:gsub("%s+", " ")
    if #preview > 90 then
      preview = preview:sub(1, 90) .. "…"
    end
  end
  return ui.column({
    key = "t" .. tostring(item.i),
    paddingV = 2,
    gap = 2,
    onClick = function()
      expanded[item.i] = not open
      markDirty()
    end,
  }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = open and "chevron-down" or "chevron-right", size = 12, color = "on_surface_variant" }),
      ui.glyph({ name = "bulb", size = 12, color = "on_surface_variant" }),
      ui.label({
        text = open and noctalia.tr("transcript.thinking") or preview,
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 1,
        flexGrow = 1,
      }),
    }),
    ui.label({
      visible = open,
      text = text,
      fontSize = 11,
      color = "on_surface_variant",
    }),
  })
end

local function toolRow(item)
  local open = expanded[item.i] == true
  local name = tostring(item.name or "tool")
  local risk = tostring(item.risk or "read")
  local state = tostring(item.state or "running")
  local accent = shared.riskColor(risk)

  local stateGlyph = "loader"
  local stateColor = "on_surface_variant"
  if state == "ok" then
    stateGlyph = "check"
    stateColor = "primary"
  elseif state == "error" then
    stateGlyph = "x"
    stateColor = "error"
  end

  local output = tostring(item.output or "")
  local hasOutput = output ~= ""

  return ui.column({
    key = "l" .. tostring(item.i),
    paddingV = 2,
    gap = 3,
    padding = 6,
    fill = "on_surface/0.04",
    radius = 8,
    border = accent .. "/0.35",
    borderWidth = 1,
    onClick = hasOutput and function()
      expanded[item.i] = not open
      markDirty()
    end or nil,
  }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = shared.riskGlyph(name, risk), size = 13, color = accent }),
      ui.label({ text = name, fontSize = 11, fontWeight = "semibold", color = accent }),
      ui.label({
        text = tostring(item.summary or ""),
        fontSize = 11,
        fontFamily = "monospace",
        color = "on_surface_variant",
        maxLines = 1,
        flexGrow = 1,
      }),
      ui.glyph({ name = stateGlyph, size = 12, color = stateColor }),
    }),
    ui.label({
      visible = open and hasOutput,
      text = output,
      fontSize = 10,
      fontFamily = "monospace",
      color = "on_surface_variant",
    }),
    ui.label({
      visible = open and item.truncated == true,
      text = noctalia.tr("transcript.truncated"),
      fontSize = 10,
      color = "on_surface_variant",
      opacity = 0.7,
    }),
  })
end

local function permissionRow(item)
  local state = tostring(item.state or "pending")
  local pending = state == "pending"
  local name = tostring(item.name or "tool")

  local verdict = ""
  if state == "allowed" then
    verdict = noctalia.tr("permission.allowed")
  elseif state == "denied" then
    verdict = noctalia.tr("permission.denied")
  elseif state == "cancelled" then
    verdict = noctalia.tr("permission.cancelled")
  end

  return ui.column({
    key = "p" .. tostring(item.i),
    paddingV = 4,
    padding = 8,
    gap = 6,
    fill = pending and "error/0.10" or "on_surface/0.04",
    radius = 8,
    border = pending and "error" or "on_surface/0.2",
    borderWidth = 1,
  }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "shield-question", size = 14, color = pending and "error" or "on_surface_variant" }),
      ui.label({
        text = noctalia.tr("permission.title", { tool = name }),
        fontSize = 12,
        fontWeight = "semibold",
        color = pending and "error" or "on_surface_variant",
        flexGrow = 1,
      }),
    }),
    ui.label({
      text = tostring(item.summary or ""),
      fontSize = 11,
      fontFamily = "monospace",
      color = "on_surface",
      maxLines = 4,
    }),
    ui.row({ visible = pending, gap = 6 }, {
      ui.button({
        text = noctalia.tr("permission.allow"),
        variant = "primary",
        controlSize = "sm",
        onClick = function()
          shared.post("/permission", { rid = item.rid, allow = true })
        end,
      }),
      ui.button({
        text = noctalia.tr("permission.deny"),
        variant = "destructive",
        controlSize = "sm",
        onClick = function()
          shared.post("/permission", { rid = item.rid, allow = false })
        end,
      }),
      ui.spacer({ flexGrow = 1 }),
    }),
    ui.label({
      visible = not pending,
      text = verdict,
      fontSize = 11,
      color = "on_surface_variant",
    }),
  })
end

local function resultRow(item)
  local parts = {}
  local cost = shared.cost(item.cost)
  if cost ~= "" then
    parts[#parts + 1] = cost
  end
  local elapsed = shared.duration(item.ms)
  if elapsed ~= "" then
    parts[#parts + 1] = elapsed
  end
  parts[#parts + 1] = noctalia.tr("transcript.tokens", {
    out = shared.tokens(item.output),
    cached = shared.tokens(item.cache_read),
  })

  return ui.row({ key = "r" .. tostring(item.i), gap = 8, paddingV = 2, align = "center" }, {
    ui.separator({ flexGrow = 1, thickness = 1, color = "on_surface/0.12" }),
    ui.label({
      text = table.concat(parts, "  ·  "),
      fontSize = 10,
      fontFamily = "monospace",
      color = item.error and "error" or "on_surface_variant",
      opacity = 0.85,
    }),
  })
end

local function renderItem(item)
  local kind = item.kind
  if kind == "user" then return userRow(item) end
  if kind == "assistant" then return assistantRow(item) end
  if kind == "thinking" then return thinkingRow(item) end
  if kind == "tool" then return toolRow(item) end
  if kind == "permission" then return permissionRow(item) end
  if kind == "result" then return resultRow(item) end
  return ui.label({
    key = "n" .. tostring(item.i),
    text = tostring(item.text or ""),
    fontSize = 11,
    color = "on_surface_variant",
  })
end

-- ── Rendering: chrome ───────────────────────────────────────────────────────

local PHASE_GLYPH = {
  off = "plug-off",
  starting = "loader",
  idle = "circle-check",
  busy = "player-play",
  awaiting = "shield-question",
  error = "alert-circle",
}

local PHASE_COLOR = {
  off = "on_surface_variant",
  starting = "on_surface_variant",
  idle = "primary",
  busy = "primary",
  awaiting = "error",
  error = "error",
}

local function modelLabel(): string
  local model = tostring(status.model or "")
  local models = type(caps.models) == "table" and caps.models or {}
  if model == "" then
    -- No model on the status until the first session-init frame, but the session
    -- is already on the CLI's default; name that rather than saying nothing.
    for _, entry in ipairs(models) do
      if type(entry) == "table" and tostring(entry.value) == "default" then
        model = tostring(entry.resolvedModel or "")
        break
      end
    end
    if model == "" then
      return noctalia.tr("header.model_default")
    end
  end
  -- The picker's display names are friendlier than the wire ids.
  for _, entry in ipairs(models) do
    if type(entry) == "table" and entry.resolvedModel == model
      and tostring(entry.value) ~= "default" then
      return tostring(entry.displayName or model)
    end
  end
  return (model:gsub("^claude%-", ""))
end

-- Pickers render inline rather than as a native context menu: openContextMenu is
-- only legal from an onRightClick, and a left-click chip is the affordance people
-- expect here. It also keeps them consistent with the slash palette.
local picker = ""  -- "" | "model" | "mode"

local function loadSessions()
  if sessionsPending then
    return
  end
  sessionsPending = true
  shared.get("/sessions", function(data)
    sessionsPending = false
    if type(data) == "table" and type(data.sessions) == "table" then
      sessions = data.sessions
    end
    markDirty()
  end)
end

local function togglePicker(which: string)
  picker = (picker == which) and "" or which
  -- Re-read on every open: a session that was live a moment ago has a newer
  -- title and timestamp than the last look.
  if picker == "session" then
    loadSessions()
  end
  markDirty()
end

-- Auto first because it is the console's default; "default" is the CLI's name
-- for ask-before-anything-risky, which is what it is labelled.
local MODES = { "auto", "default", "plan", "acceptEdits", "dontAsk", "bypassPermissions" }

local function pickerRows()
  local rows = {}
  if picker == "model" then
    local models = type(caps.models) == "table" and caps.models or {}
    for _, entry in ipairs(models) do
      -- The session always offers a "default" alias that resolves to the same
      -- model as one of the named entries; showing both is a duplicate row whose
      -- label says less than the real one.
      if type(entry) == "table" and entry.value ~= nil and tostring(entry.value) ~= "default" then
        local value = tostring(entry.value)
        rows[#rows + 1] = ui.row({
          key = "m" .. value,
          gap = 6,
          padding = 4,
          radius = 6,
          align = "center",
          onClick = function()
            shared.post("/control", { subtype = "set_model", model = value })
            picker = ""
            markDirty()
          end,
        }, {
          ui.label({
            text = tostring(entry.displayName or value),
            fontSize = 11,
            fontWeight = "medium",
            color = entry.resolvedModel == status.model and "primary" or "on_surface",
          }),
          ui.label({
            text = tostring(entry.description or ""),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 1,
            flexGrow = 1,
          }),
        })
      end
    end
  elseif picker == "session" then
    if #sessions == 0 then
      rows[#rows + 1] = ui.label({
        key = "nosessions",
        text = noctalia.tr(sessionsPending and "sessions.loading" or "sessions.none"),
        fontSize = 11,
        color = "on_surface_variant",
      })
    end
    for index, entry in ipairs(sessions) do
      if index > 12 then
        break
      end
      local id = tostring(entry.id or "")
      local current = id == tostring(status.session_id or "")
      rows[#rows + 1] = ui.row({
        key = "s" .. id,
        gap = 6,
        padding = 4,
        radius = 6,
        align = "center",
        onClick = function()
          if not current then
            shared.post("/session", { action = "resume", id = id })
          end
          picker = ""
          markDirty()
        end,
      }, {
        ui.glyph({
          name = current and "player-play" or "history",
          size = 12,
          color = current and "primary" or "on_surface_variant",
        }),
        ui.label({
          text = tostring(entry.title or id),
          fontSize = 11,
          color = current and "primary" or "on_surface",
          maxLines = 1,
          flexGrow = 1,
        }),
        ui.label({
          text = shared.ago(tonumber(entry.mtime)),
          fontSize = 10,
          fontFamily = "monospace",
          color = "on_surface_variant",
          opacity = 0.8,
        }),
      })
    end
  elseif picker == "mode" then
    for _, mode in ipairs(MODES) do
      rows[#rows + 1] = ui.row({
        key = "pm" .. mode,
        gap = 6,
        padding = 4,
        radius = 6,
        align = "center",
        onClick = function()
          shared.post("/control", { subtype = "set_permission_mode", mode = mode })
          picker = ""
          markDirty()
        end,
      }, {
        ui.label({
          text = shared.modeLabel(mode),
          fontSize = 11,
          fontWeight = "medium",
          color = mode == status.mode and "primary"
            or (mode == "bypassPermissions" and "error" or "on_surface"),
        }),
        ui.label({
          text = shared.modeHint(mode),
          fontSize = 10,
          color = "on_surface_variant",
          maxLines = 1,
          flexGrow = 1,
        }),
      })
    end
  end
  return rows
end

local function header()
  local phase = tostring(status.phase or "off")
  local usage = noctalia.state.get("usage")
  local usageText = ""
  local usageColor = "on_surface_variant"
  if type(usage) == "table" and usage.ok then
    usageText = shared.percent(usage.session_percent)
    usageColor = shared.severityColor(tostring(usage.severity or "normal"))
  end

  local mode = tostring(status.mode or "default")
  local effort = tostring(status.effort or "")

  return ui.column({ gap = 4 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({
        name = PHASE_GLYPH[phase] or "sparkles",
        size = 15,
        color = PHASE_COLOR[phase] or "on_surface_variant",
      }),
      ui.label({
        text = noctalia.tr("status." .. phase),
        fontSize = 12,
        fontWeight = "semibold",
        color = PHASE_COLOR[phase] or "on_surface",
      }),
      ui.spacer({ flexGrow = 1 }),

      ui.button({
        text = shared.modeLabel(mode),
        controlSize = "sm",
        variant = mode == "bypassPermissions" and "destructive"
          or (mode == "plan" and "secondary" or "ghost"),
        tooltip = noctalia.tr("header.mode_tooltip"),
        onClick = function() togglePicker("mode") end,
      }),
      ui.button({
        text = modelLabel(),
        controlSize = "sm",
        variant = "ghost",
        tooltip = noctalia.tr("header.model_tooltip"),
        onClick = function() togglePicker("model") end,
      }),
      ui.label({
        visible = effort ~= "",
        text = effort,
        fontSize = 10,
        fontFamily = "monospace",
        color = "on_surface_variant",
        opacity = 0.85,
      }),
      ui.label({
        visible = usageText ~= "",
        text = usageText,
        fontSize = 11,
        fontWeight = "medium",
        color = usageColor,
      }),
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "folder", size = 11, color = "on_surface_variant" }),
      ui.label({
        text = tostring(status.cwd or ""),
        fontSize = 10,
        color = "on_surface_variant",
        maxLines = 1,
        flexGrow = 1,
      }),
      ui.label({
        visible = status.session_id ~= nil and status.session_id ~= "",
        text = tostring(status.session_id or ""):sub(1, 8),
        fontSize = 10,
        fontFamily = "monospace",
        color = "on_surface_variant",
        opacity = 0.7,
      }),
      ui.button({
        glyph = "history",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("header.sessions_tooltip"),
        onClick = function() togglePicker("session") end,
      }),
    }),
  })
end

local function paletteRows()
  local rows = {}
  local commands = type(caps.commands) == "table" and caps.commands or {}
  local filter = paletteFilter:lower()
  local shown = 0
  for _, entry in ipairs(commands) do
    if shown >= 8 then
      break
    end
    local name = type(entry) == "table" and tostring(entry.name or "") or ""
    if name ~= "" and (filter == "" or name:lower():sub(1, #filter) == filter) then
      shown += 1
      local description = tostring(entry.description or "")
      if #description > 70 then
        description = description:sub(1, 70) .. "…"
      end
      rows[#rows + 1] = ui.row({
        key = "cmd" .. name,
        gap = 6,
        padding = 4,
        radius = 6,
        align = "center",
        onClick = function()
          draft = "/" .. name .. " "
          inputKey += 1
          palette = false
          markDirty()
        end,
      }, {
        ui.label({ text = "/" .. name, fontSize = 11, fontFamily = "monospace", color = "primary" }),
        ui.label({
          text = description,
          fontSize = 10,
          color = "on_surface_variant",
          maxLines = 1,
          flexGrow = 1,
        }),
      })
    end
  end
  return rows
end

local function composer()
  local running = busy()
  return ui.column({ gap = 6 }, {
    ui.column({
      visible = palette,
      gap = 2,
      padding = 6,
      fill = "on_surface/0.05",
      radius = 8,
    }, paletteRows()),

    ui.row({ gap = 6, align = "end" }, {
      ui.input({
        key = "composer" .. tostring(inputKey),
        value = draft,
        placeholder = noctalia.tr("composer.placeholder"),
        multiline = true,
        submitOnEnter = true,
        focus = true,
        flexGrow = 1,
        height = 66,
        onChange = function(value)
          draft = value
          local wasOpen = palette
          -- The palette is a prefix affordance: it opens on a leading slash and
          -- closes as soon as the line stops being one.
          if value:sub(1, 1) == "/" and not value:find("%s") then
            palette = true
            paletteFilter = value:sub(2)
          else
            palette = false
          end
          if palette ~= wasOpen or palette then
            markDirty()
          end
        end,
        onSubmit = function(value)
          submit(value)
        end,
      }),
      ui.button({
        glyph = running and "player-stop" or "send",
        variant = running and "destructive" or "primary",
        controlSize = "md",
        tooltip = running and noctalia.tr("composer.stop") or noctalia.tr("composer.send"),
        onClick = function()
          if running then
            shared.post("/control", { subtype = "interrupt" })
          else
            submit(draft)
          end
        end,
      }),
    }),
  })
end

local function render()
  local rows = {}

  if notice ~= "" then
    rows[#rows + 1] = ui.row({ key = "notice", padding = 8, fill = "error/0.10", radius = 8 }, {
      ui.label({ text = notice, fontSize = 11, color = "error" }),
    })
  end

  local skipped = trimmedCount()
  if skipped > 0 then
    rows[#rows + 1] = ui.label({
      key = "trimmed",
      text = noctalia.tr("transcript.earlier", { count = skipped }),
      fontSize = 10,
      color = "on_surface_variant",
      textAlign = "center",
      opacity = 0.7,
    })
  end

  if #items == 0 and notice == "" then
    rows[#rows + 1] = ui.column({ key = "empty", gap = 6, padding = 16, align = "center" }, {
      ui.glyph({ name = "sparkles", size = 26, color = "on_surface_variant" }),
      ui.label({
        text = noctalia.tr("empty.title"),
        fontSize = 12,
        color = "on_surface_variant",
        textAlign = "center",
      }),
      ui.label({
        text = noctalia.tr("empty.hint"),
        fontSize = 10,
        color = "on_surface_variant",
        textAlign = "center",
        opacity = 0.8,
      }),
    })
  end

  for position = math.max(1, #items - VISIBLE_LIMIT + 1), #items do
    rows[#rows + 1] = renderItem(items[position])
  end

  panel.render(ui.column({ flexGrow = 1, align = "stretch", padding = 10, gap = 8 }, {
    header(),
    ui.column({
      visible = picker ~= "",
      gap = 2,
      padding = 6,
      fill = "on_surface/0.05",
      radius = 8,
    }, pickerRows()),
    ui.separator({ thickness = 1, color = "on_surface/0.12" }),
    ui.scroll({
      flexGrow = 1,
      gap = 4,
      stickToBottom = true,
      paddingV = 2,
    }, rows),
    composer(),
  }))
end

-- ── Entry points ────────────────────────────────────────────────────────────

function onOpen(context: string?)
  noctalia.state.set("panel_open", true)
  connectElapsedMs = 0
  connectWaitMs = 0
  launched = false
  notice = ""
  connect()
  shared.post("/session", { action = "start" })
  dirty = true
  render()
  -- Always tick briefly after opening: the first connect may still be waiting on
  -- a sidecar that is booting.
  setTicking(true)
end

function onClose()
  noctalia.state.set("panel_open", false)
  if stream ~= nil then
    stream.stop()
    stream = nil
  end
  setTicking(false)
end

function onFrameTick(deltaMs: number)
  if stream == nil then
    connectElapsedMs += deltaMs
    connectWaitMs += deltaMs
    if connectWaitMs >= CONNECT_RETRY_MS then
      connectWaitMs = 0
      connect()
    end
  end
  if dirty then
    dirty = false
    render()
  end
  -- Stop burning frames once the picture is settled and a stream is attached.
  if stream ~= nil and not busy() and not dirty then
    setTicking(false)
  end
end

function onKey(chord: string, pressed: boolean)
  if not pressed then
    return
  end
  if chord == "ctrl+c" then
    shared.post("/control", { subtype = "interrupt" })
  elseif chord == "ctrl+l" then
    shared.post("/clear", {})
  elseif chord == "ctrl+k" then
    picker = ""
    palette = not palette
    paletteFilter = ""
    markDirty()
    setTicking(true)
  end
end
