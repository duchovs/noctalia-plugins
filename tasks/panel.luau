--!nonstrict
-- The task panel: all lists at once or one at a time, colour-coded per list.
--
-- Writes happen here rather than in the service, so a checkbox flips the moment
-- it is clicked: the local model changes, the panel re-renders, the cache is
-- updated, and only then does the PUT go out. A failed write rolls the task
-- back and says why. The service reconciles with the server afterwards.

local caldav = require("./lib/caldav.luau")
local ical = require("./lib/ical.luau")
local store = require("./lib/store.luau")

local ACCENTS = { "primary", "secondary", "tertiary" } -- lists the server gave no colour

local cache = { lists = {}, tasks = {}, errors = {}, updatedAt = 0 }
local prefs = store.loadPrefs()
local accounts = {}
local accountProblems = {}

local view = "tasks" -- "tasks" | "detail" | "accounts"
local detailUid = nil
local hoveredKey = nil
local pendingDelete = nil
local showCompleted = false
local busy = {} -- uid -> true while a write is in flight
local notice = "" -- transient message under the header
local editorRev = 0 -- reseeds the detail inputs after an external change
local syncing = false
local syncError = ""

-- Published by the service, which owns the browser login: { phase, login, message }.
local loginState = { phase = "idle", login = "", message = "" }

local render
local cornerScale = 1.0

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- ── Colour helpers ───────────────────────────────────────────────────────────

local function listColor(list, index: number): string
  if list == nil then
    return "primary"
  end
  if list.color ~= nil and list.color ~= "" then
    return list.color
  end
  return ACCENTS[((index - 1) % #ACCENTS) + 1]
end

-- Picks readable text for whatever a list is coloured with. A palette role has
-- a matching `on_` role the theme already guarantees contrast for; a raw hex
-- from the server does not, so pick black or white by perceived brightness.
local function contrastOn(color: string): string
  local r, g, b = color:match("^#(%x%x)(%x%x)(%x%x)")
  if r == nil then
    return "on_" .. color
  end
  local luminance = (0.299 * tonumber(r, 16) + 0.587 * tonumber(g, 16) + 0.114 * tonumber(b, 16)) / 255
  return luminance > 0.6 and "#000000" or "#ffffff"
end

-- A translucent variant of a colour. The two forms take it differently: the
-- host resolves a `role/0.45` suffix live against the palette but rejects that
-- suffix on a hex value, where the alpha is the fourth byte instead. Servers
-- send both `#rrggbb` and `#rrggbbaa`, so an existing alpha byte is replaced
-- rather than appended to.
local function withAlpha(color: string, hexAlpha: string, roleAlpha: string): string
  local rgb = color:match("^(#%x%x%x%x%x%x)")
  if rgb ~= nil then
    return rgb .. hexAlpha
  end
  return color .. "/" .. roleAlpha
end

-- ── Model ────────────────────────────────────────────────────────────────────

local function listsById()
  local byId = {}
  for index, list in ipairs(cache.lists) do
    byId[list.id] = { list = list, index = index }
  end
  return byId
end

local function findList(listId: string)
  for _, list in ipairs(cache.lists) do
    if list.id == listId then
      return list
    end
  end
  return nil
end

local function findAccount(accountId: string)
  for _, account in ipairs(accounts) do
    if account.id == accountId then
      return account
    end
  end
  return nil
end

local function findTask(uid: string)
  for _, task in ipairs(cache.tasks) do
    if task.uid == uid then
      return task
    end
  end
  return nil
end

local function isHidden(listId: string): boolean
  for _, hidden in ipairs(prefs.hiddenLists) do
    if hidden == listId then
      return true
    end
  end
  return false
end

-- The tasks the current filter admits, sorted for display.
local function visibleTasks()
  local selected = prefs.selectedList
  local tasks = {}
  for _, task in ipairs(cache.tasks) do
    local matchesList = selected == "" and not isHidden(task.listId) or task.listId == selected
    local matchesState = showCompleted or not (task.completed or task.cancelled)
    if matchesList and matchesState then
      table.insert(tasks, task)
    end
  end
  return store.sortTasks(tasks, prefs.sortBy)
end

-- Where a new task goes: the selected list, else the remembered quick-add list,
-- else the first writable one.
local function defaultList()
  if prefs.selectedList ~= "" then
    local list = findList(prefs.selectedList)
    if list ~= nil and not list.readOnly then
      return list
    end
  end
  if prefs.quickAddList ~= "" then
    local list = findList(prefs.quickAddList)
    if list ~= nil and not list.readOnly then
      return list
    end
  end
  for _, list in ipairs(cache.lists) do
    if not list.readOnly and not isHidden(list.id) then
      return list
    end
  end
  return nil
end

local function reloadCache()
  cache = store.loadCache()
  if detailUid ~= nil and findTask(detailUid) == nil then
    view = "tasks" -- the open task vanished from the server
    detailUid = nil
  end
end

local function persistCache()
  store.saveCache(cache)
end

local function requestSync()
  noctalia.state.set(store.SYNC_REQUEST, noctalia.nowMs())
end

local function setNotice(message: string)
  notice = message
  render()
end

-- ── Writes ───────────────────────────────────────────────────────────────────

-- Applies `mutate` to a task's parsed VTODO and pushes the result. The local
-- model is updated first so the panel reacts immediately; `rollback` restores
-- it when the server refuses.
local function writeTask(task, mutate, rollback)
  local account = findAccount((task.listId:match("^([^|]+)|") or ""))
  if account == nil then
    setNotice(tr("error.no_account"))
    rollback()
    return
  end
  local calendar = ical.parse(task.ics)
  if calendar == nil then
    setNotice(tr("error.bad_task"))
    rollback()
    return
  end
  local vtodo = ical.findComponent(calendar, "VTODO")
  if vtodo == nil then
    setNotice(tr("error.bad_task"))
    rollback()
    return
  end

  mutate(vtodo)
  local ics = ical.serialize(calendar)
  local previousIcs = task.ics
  task.ics = ics
  busy[task.uid] = true
  persistCache()
  render()

  caldav.putTask(account, task.href, ics, task.etag, function(etag, err)
    busy[task.uid] = nil
    if err ~= nil then
      task.ics = previousIcs
      rollback()
      persistCache()
      setNotice(err == "conflict" and tr("error.conflict") or store.errorText(err))
      requestSync()
      return
    end
    if etag ~= nil then
      task.etag = etag
    end
    persistCache()
    render()
    requestSync()
  end)
end

local function toggleComplete(task)
  if busy[task.uid] then
    return
  end
  local wasCompleted = task.completed
  local previousStatus = task.status
  local previousCompletedAt = task.completedAt
  local now = os.time()

  -- Optimistic: the row redraws before the request is even dispatched.
  task.completed = not wasCompleted
  task.status = task.completed and "COMPLETED" or "NEEDS-ACTION"
  task.completedAt = task.completed and { epoch = now, dateOnly = false, floating = false } or nil

  writeTask(task, function(vtodo)
    ical.markComplete(vtodo, not wasCompleted, now)
  end, function()
    task.completed = wasCompleted
    task.status = previousStatus
    task.completedAt = previousCompletedAt
    render()
  end)
end

local function createTask(summary: string, list, dueEpoch: number?)
  summary = noctalia.string.trim(summary)
  if summary == "" then
    return
  end
  if list == nil then
    setNotice(tr("error.no_writable_list"))
    return
  end
  local account = findAccount(list.accountId)
  if account == nil then
    setNotice(tr("error.no_account"))
    return
  end

  local now = os.time()
  local uid = caldav.newUid()
  local calendar = ical.newTodo(uid, summary, now, dueEpoch)
  local ics = ical.serialize(calendar)
  local href = caldav.taskHref(list, uid)

  -- Shown as soon as it is typed; the server confirms it a moment later.
  local task = {
    uid = uid,
    href = href,
    etag = "",
    listId = list.id,
    summary = summary,
    description = "",
    status = "NEEDS-ACTION",
    completed = false,
    cancelled = false,
    due = dueEpoch ~= nil and { epoch = dueEpoch, dateOnly = true, floating = false } or nil,
    priority = 0,
    important = false,
    recurring = false,
    ics = ics,
  }
  table.insert(cache.tasks, task)
  busy[uid] = true
  persistCache()
  render()

  caldav.putTask(account, href, ics, nil, function(etag, err)
    busy[uid] = nil
    if err ~= nil then
      for index, candidate in ipairs(cache.tasks) do
        if candidate.uid == uid then
          table.remove(cache.tasks, index)
          break
        end
      end
      persistCache()
      setNotice(store.errorText(err))
      return
    end
    task.etag = etag or ""
    persistCache()
    render()
    requestSync()
  end)

  prefs.quickAddList = list.id
  store.savePrefs(prefs)
end

local function deleteTask(task)
  local account = findAccount(task.listId:match("^([^|]+)|") or "")
  if account == nil then
    setNotice(tr("error.no_account"))
    return
  end
  local index = nil
  for candidateIndex, candidate in ipairs(cache.tasks) do
    if candidate.uid == task.uid then
      index = candidateIndex
      break
    end
  end
  if index == nil then
    return
  end
  table.remove(cache.tasks, index)
  pendingDelete = nil
  if detailUid == task.uid then
    view = "tasks"
    detailUid = nil
  end
  persistCache()
  render()

  caldav.deleteTask(account, task.href, task.etag, function(ok, err)
    if not ok then
      table.insert(cache.tasks, index, task) -- put it back where it was
      persistCache()
      setNotice(err == "conflict" and tr("error.conflict") or store.errorText(err))
      render()
      return
    end
    requestSync()
  end)
end

-- ── Building blocks ──────────────────────────────────────────────────────────

local function iconButton(key: string, glyph: string, tooltip: string, onClick, variant: string?, onHover)
  return ui.button({
    key = key,
    glyph = glyph,
    variant = variant or "ghost",
    controlSize = "sm",
    tooltip = tooltip,
    onClick = onClick,
    onHover = onHover,
  })
end

local function sectionHeader(label: string, count: number)
  return ui.row({ key = "section-" .. label, gap = 8, align = "center", paddingV = 4 }, {
    ui.label({
      text = label:upper(),
      fontSize = 10,
      fontWeight = "bold",
      color = "on_surface_variant",
    }),
    ui.label({ text = tostring(count), fontSize = 10, color = "on_surface_variant" }),
    ui.separator({ flexGrow = 1, color = "outline" }),
  })
end

-- The host hovers only the innermost input area under the pointer, so a row's
-- checkbox and buttons forward their hover to the row or it un-highlights there.
local function rowHover(uid: string)
  return function(state)
    onRowHover(state, uid)
  end
end

-- A checkbox that reads as one: an outlined square in the list's colour that
-- fills and gains a tick when checked.
local function checkbox(task, color: string, readOnly: boolean?)
  local checked = task.completed
  local pending = busy[task.uid] == true
  return ui.column({
    key = "check-" .. task.uid .. (checked and "-on" or "-off") .. (readOnly and "-ro" or ""),
    width = 22,
    height = 22,
    minWidth = 22,
    align = "center",
    justify = "center",
    radius = 6 * cornerScale,
    fill = checked and color or "surface_variant",
    border = checked and color or "outline",
    borderWidth = checked and 0 or 2,
    opacity = (pending or readOnly) and 0.5 or 1.0,
    onHover = rowHover(task.uid),
    -- A collection the server grants no write privilege on gets no control at
    -- all, rather than one that fails on click.
    onClick = not readOnly and function()
      toggleComplete(task)
    end or nil,
  }, {
    ui.glyph({
      name = "check",
      size = 13,
      color = contrastOn(color),
      visible = checked,
    }),
  })
end

local function dueChip(task, today: number)
  if task.due == nil or task.due.epoch == nil then
    return nil
  end
  local bucket = store.dueBucket(task, today)
  local label
  if bucket == "today" then
    label = tr("due.today")
  elseif bucket == "tomorrow" then
    label = tr("due.tomorrow")
  else
    -- Within the year the year itself is noise; beyond it, it is the point.
    local sameYear = noctalia.formatTime("%Y", task.due.epoch) == noctalia.formatTime("%Y")
    label = noctalia.formatTime(sameYear and "%b %d" or "%b %d %Y", task.due.epoch)
  end
  local urgent = bucket == "overdue"
  return ui.row({ gap = 4, align = "center" }, {
    ui.glyph({
      name = urgent and "alert-circle" or "calendar",
      size = 11,
      color = urgent and "error" or "on_surface_variant",
    }),
    ui.label({
      text = label,
      fontSize = 11,
      color = urgent and "error" or "on_surface_variant",
    }),
  })
end

local function listDot(color: string, name: string?)
  local children = {
    ui.box({ width = 8, height = 8, radius = 4 * cornerScale, fill = color }),
  }
  if name ~= nil then
    table.insert(children, ui.label({
      text = name,
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
    }))
  end
  return ui.row({ gap = 5, align = "center" }, children)
end

local function taskRow(task, listInfo, today: number, showListName: boolean)
  local list = listInfo ~= nil and listInfo.list or nil
  local color = listColor(list, listInfo ~= nil and listInfo.index or 1)
  local readOnly = list ~= nil and list.readOnly == true
  local hovered = hoveredKey == task.uid
  local confirming = pendingDelete == task.uid

  local meta = {}
  local due = dueChip(task, today)
  if due ~= nil then
    table.insert(meta, due)
  end
  if showListName and listInfo ~= nil then
    table.insert(meta, listDot(color, listInfo.list.name))
  end
  if task.recurring then
    table.insert(meta, ui.glyph({ name = "repeat", size = 11, color = "on_surface_variant" }))
  end

  local title = {
    ui.label({
      text = task.summary ~= "" and task.summary or tr("untitled"),
      maxLines = 2,
      color = task.completed and "on_surface_variant" or "on_surface",
      opacity = task.completed and 0.7 or 1.0,
    }),
  }
  if #meta > 0 then
    table.insert(title, ui.row({ gap = 10, align = "center" }, meta))
  end

  local trailing = {}
  if task.important then
    table.insert(trailing, ui.glyph({ name = "flag", size = 13, color = "error" }))
  end
  if readOnly then
    if hovered then
      table.insert(trailing, ui.glyph({ name = "lock", size = 13, color = "on_surface_variant" }))
    end
  elseif confirming then
    table.insert(trailing, ui.label({ text = tr("confirm_delete"), fontSize = 11, color = "error" }))
    table.insert(trailing, iconButton("del-yes-" .. task.uid, "check", tr("delete"), function()
      deleteTask(task)
    end, "destructive", rowHover(task.uid)))
    table.insert(trailing, iconButton("del-no-" .. task.uid, "close", tr("cancel"), function()
      pendingDelete = nil
      render()
    end, nil, rowHover(task.uid)))
  elseif hovered then
    table.insert(trailing, iconButton("del-" .. task.uid, "trash", tr("delete"), function()
      pendingDelete = task.uid
      render()
    end, nil, rowHover(task.uid)))
  end

  local children = {
    -- A slim spine of the list's colour. It is the one cue that survives the
    -- all-lists view, where rows from different lists sit next to each other.
    ui.box({ width = 3, height = 26, radius = 2 * cornerScale, fill = color }),
    checkbox(task, color, readOnly),
    ui.column({ gap = 3, flexGrow = 1 }, title),
  }
  for _, node in ipairs(trailing) do
    table.insert(children, node)
  end

  -- The row is the click target so the title adds no input area of its own.
  return ui.row({
    key = task.uid,
    gap = 10,
    align = "center",
    padding = 8,
    paddingH = 10,
    radius = 8 * cornerScale,
    fill = hovered and "hover" or "surface_variant",
    onHover = "onRowHover",
    onClick = function()
      detailUid = task.uid
      editorRev += 1
      view = "detail"
      pendingDelete = nil
      render()
    end,
  }, children)
end

-- ── Filter chips ─────────────────────────────────────────────────────────────

-- ui.row does not wrap, so chips are packed into rows by estimated width. The
-- estimate only has to be close: a row that comes out slightly narrow still
-- reads correctly, it just leaves a gap.
local function chipRows(chips, maxWidth: number)
  local rows = {}
  local current = {}
  local used = 0
  for _, chip in ipairs(chips) do
    if used + chip.width > maxWidth and #current > 0 then
      table.insert(rows, current)
      current = {}
      used = 0
    end
    table.insert(current, chip.node)
    used += chip.width + 6
  end
  if #current > 0 then
    table.insert(rows, current)
  end
  local nodes = {}
  for index, row in ipairs(rows) do
    table.insert(nodes, ui.row({ key = "chiprow-" .. index, gap = 6, align = "center" }, row))
  end
  return nodes
end

local function filterChips(today: number)
  local counts = {}
  local total = 0
  for _, task in ipairs(cache.tasks) do
    if not task.completed and not task.cancelled then
      counts[task.listId] = (counts[task.listId] or 0) + 1
      if not isHidden(task.listId) then
        total += 1
      end
    end
  end

  local function chip(id: string, label: string, color: string, count: number)
    local selected = prefs.selectedList == id
    local hovered = hoveredKey == "chip-" .. id
    local ink = selected and contrastOn(color) or "on_surface"

    -- The selected chip is the only one carrying a tick. Fill alone used to
    -- distinguish it, but hover is also a fill, so a chip the pointer merely
    -- rested on read as a second active filter. The tick is a token hover has
    -- no way to imitate, and the unselected chips keep a hairline of their own
    -- colour so the row still reads as a set of lists rather than grey pills.
    local marker
    if selected then
      marker = ui.glyph({ name = "check", size = 12, color = ink })
    else
      marker = ui.box({ width = 8, height = 8, radius = 4 * cornerScale, fill = color })
    end

    local node = ui.row({
      -- Selection is part of the key: the marker swaps between a glyph and a
      -- box, and a retained node would otherwise keep whichever it was built with.
      key = "chip-" .. id .. (selected and "-on" or "-off"),
      gap = 6,
      align = "center",
      paddingH = 10,
      paddingV = 6,
      radius = 14 * cornerScale,
      fill = selected and color or (hovered and "hover" or "surface_variant"),
      border = selected and color or withAlpha(color, "73", "0.45"),
      borderWidth = selected and 0 or 1,
      onHover = "onRowHover",
      onClick = function()
        prefs.selectedList = selected and "" or id
        store.savePrefs(prefs)
        -- The clicked chip is by definition the one under the pointer. Pinning
        -- hover to it drops any stale hover left on the chip that was selected
        -- before, which would otherwise still be painted as if it were active.
        hoveredKey = "chip-" .. id
        render()
      end,
    }, {
      marker,
      ui.label({
        text = label,
        fontSize = 12,
        fontWeight = selected and "semibold" or "normal",
        color = ink,
        maxLines = 1,
      }),
      ui.label({
        text = tostring(count),
        fontSize = 11,
        color = selected and ink or "on_surface_variant",
      }),
    })
    -- ~7px per character at 12px, plus the marker, count, padding and gaps.
    return { node = node, width = 58 + #label * 7 + #tostring(count) * 7 }
  end

  local chips = { chip("", tr("all_lists"), "primary", total) }
  for index, list in ipairs(cache.lists) do
    if not isHidden(list.id) then
      table.insert(chips, chip(list.id, list.name, listColor(list, index), counts[list.id] or 0))
    end
  end
  return chipRows(chips, 420)
end

-- ── Views ────────────────────────────────────────────────────────────────────

local function noticeBar()
  local message = notice ~= "" and notice or (syncError ~= "" and store.errorText(syncError) or "")
  if message == "" then
    return nil
  end
  return ui.row({
    key = "notice",
    gap = 8,
    align = "center",
    padding = 8,
    paddingH = 10,
    radius = 8 * cornerScale,
    fill = "error/0.18",
  }, {
    ui.glyph({ name = "alert-triangle", size = 14, color = "on_surface" }),
    ui.label({ text = message, fontSize = 11, color = "on_surface", flexGrow = 1, maxLines = 3 }),
    iconButton("notice-dismiss", "close", tr("dismiss"), function()
      notice = ""
      syncError = ""
      render()
    end),
  })
end

local function emptyState()
  local hasAccounts = #accounts > 0
  return ui.column({ gap = 10, align = "center", justify = "center", flexGrow = 1, padding = 24 }, {
    ui.glyph({ name = hasAccounts and "checklist" or "cloud-off", size = 40, color = "on_surface_variant" }),
    ui.label({
      text = hasAccounts and tr("empty.clear") or tr("empty.no_accounts"),
      fontSize = 13,
      color = "on_surface_variant",
      textAlign = "center",
    }),
    ui.button({
      text = tr("empty.connect"),
      variant = "primary",
      visible = not hasAccounts,
      onClick = function()
        view = "accounts"
        render()
      end,
    }),
  })
end

local function tasksView(today: number)
  local tasks = visibleTasks()
  if #tasks == 0 then
    return emptyState()
  end

  local byId = listsById()
  local showListName = prefs.selectedList == ""
  local rows = {}

  if prefs.sortBy == "due" then
    -- Sections mirror the sort, so the eye lands on what is late first.
    local buckets = { overdue = {}, today = {}, tomorrow = {}, upcoming = {}, none = {}, done = {} }
    for _, task in ipairs(tasks) do
      if task.completed or task.cancelled then
        table.insert(buckets.done, task)
      else
        table.insert(buckets[store.dueBucket(task, today)], task)
      end
    end
    for _, section in ipairs({
      { key = "overdue", label = tr("section.overdue") },
      { key = "today", label = tr("section.today") },
      { key = "tomorrow", label = tr("section.tomorrow") },
      { key = "upcoming", label = tr("section.upcoming") },
      { key = "none", label = tr("section.no_date") },
      { key = "done", label = tr("section.completed") },
    }) do
      local bucket = buckets[section.key]
      if #bucket > 0 then
        table.insert(rows, sectionHeader(section.label, #bucket))
        for _, task in ipairs(bucket) do
          table.insert(rows, taskRow(task, byId[task.listId], today, showListName))
        end
      end
    end
  else
    for _, task in ipairs(tasks) do
      table.insert(rows, taskRow(task, byId[task.listId], today, showListName))
    end
  end

  return ui.scroll({ flexGrow = 1, gap = 4 }, rows)
end

local function quickAdd()
  local target = defaultList()
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "plus", size = 16, color = "primary" }),
    ui.input({
      -- Uncontrolled: a fresh key is what clears the field after a submit.
      key = "quickadd-" .. editorRev,
      placeholder = target ~= nil
        and tr("quick_add.placeholder", { list = target.name })
        or tr("quick_add.no_list"),
      enabled = target ~= nil,
      flexGrow = 1,
      controlSize = "sm",
      onSubmit = "onQuickAdd",
    }),
  })
end

local function detailView(today: number)
  local task = detailUid ~= nil and findTask(detailUid) or nil
  if task == nil then
    view = "tasks"
    return tasksView(today)
  end
  local info = listsById()[task.listId]
  local color = listColor(info ~= nil and info.list or nil, info ~= nil and info.index or 1)
  -- Everything editable is gated on the same privilege the checkbox is, so a
  -- shared list opens as a readable detail view rather than a broken form.
  local readOnly = info ~= nil and info.list.readOnly == true
  local editable = not readOnly

  local function setDue(epoch: number?)
    local previous = task.due
    task.due = epoch ~= nil and { epoch = epoch, dateOnly = true, floating = false } or nil
    writeTask(task, function(vtodo)
      ical.setDueDate(vtodo, epoch, os.time())
    end, function()
      task.due = previous
      render()
    end)
  end

  local function priorityButton(label: string, value: number)
    return ui.button({
      key = "prio-" .. tostring(value),
      text = label,
      controlSize = "sm",
      enabled = editable,
      variant = task.priority == value and "primary" or "outline",
      onClick = function()
        local previous = task.priority
        task.priority = value
        task.important = value > 0 and value <= 4
        writeTask(task, function(vtodo)
          ical.setPriority(vtodo, value, os.time())
        end, function()
          task.priority = previous
          task.important = previous > 0 and previous <= 4
          render()
        end)
      end,
    })
  end

  local function dueButton(key: string, label: string, epoch: number?)
    return ui.button({
      key = "due-" .. key,
      text = label,
      controlSize = "sm",
      variant = "outline",
      enabled = editable,
      onClick = function()
        setDue(epoch)
      end,
    })
  end

  local heading = {
    checkbox(task, color, readOnly),
    listDot(color, info ~= nil and info.list.name or nil),
    ui.spacer({ flexGrow = 1 }),
  }
  if readOnly then
    table.insert(heading, ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "lock", size = 13, color = "on_surface_variant" }),
      ui.label({ text = tr("account.read_only"), fontSize = 11, color = "on_surface_variant" }),
    }))
  else
    table.insert(heading, iconButton("detail-delete", "trash", tr("delete"), function()
      pendingDelete = task.uid
      render()
    end))
  end

  return ui.scroll({ flexGrow = 1, gap = 14 }, {
    ui.row({ gap = 8, align = "center" }, heading),
    pendingDelete == task.uid and ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("confirm_delete"), fontSize = 12, color = "error", flexGrow = 1 }),
      ui.button({ text = tr("delete"), variant = "destructive", controlSize = "sm", onClick = function()
        deleteTask(task)
      end }),
      ui.button({ text = tr("cancel"), variant = "ghost", controlSize = "sm", onClick = function()
        pendingDelete = nil
        render()
      end }),
    }) or ui.spacer({ height = 0 }),

    ui.column({ gap = 6 }, {
      ui.label({ text = tr("detail.title"), fontSize = 11, color = "on_surface_variant" }),
      ui.input({
        key = "detail-summary-" .. task.uid .. "-" .. editorRev,
        value = task.summary,
        onSubmit = "onDetailSummary",
              enabled = editable,
      }),
    }),

    ui.column({ gap = 6 }, {
      ui.label({ text = tr("detail.due"), fontSize = 11, color = "on_surface_variant" }),
      ui.row({ gap = 6, align = "center" }, {
        dueButton("today", tr("due.today"), today),
        dueButton("tomorrow", tr("due.tomorrow"), today + store.DAY),
        dueButton("week", tr("due.next_week"), today + 7 * store.DAY),
        dueButton("none", tr("due.none"), nil),
      }),
      ui.input({
        key = "detail-due-" .. task.uid .. "-" .. editorRev,
        value = task.due ~= nil and noctalia.formatTime("%Y-%m-%d", task.due.epoch) or "",
        placeholder = "YYYY-MM-DD",
        controlSize = "sm",
        onSubmit = "onDetailDue",
              enabled = editable,
      }),
    }),

    ui.column({ gap = 6 }, {
      ui.label({ text = tr("detail.priority"), fontSize = 11, color = "on_surface_variant" }),
      ui.row({ gap = 6, align = "center" }, {
        priorityButton(tr("priority.none"), 0),
        priorityButton(tr("priority.low"), 9),
        priorityButton(tr("priority.medium"), 5),
        priorityButton(tr("priority.high"), 1),
      }),
    }),

    ui.column({ gap = 6, flexGrow = 1 }, {
      ui.label({ text = tr("detail.notes"), fontSize = 11, color = "on_surface_variant" }),
      ui.input({
        key = "detail-notes-" .. task.uid .. "-" .. editorRev,
        value = task.description,
        multiline = true,
        height = 140,
        placeholder = tr("detail.notes_placeholder"),
        onSubmit = "onDetailNotes",
              enabled = editable,
      }),
      ui.label({ text = tr("detail.notes_hint"), fontSize = 10, color = "on_surface_variant" }),
    }),
  })
end

local function accountRow(kind: string, connected: boolean, detail: string, children)
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({
        name = "cloud",
        size = 18,
        color = connected and "primary" or "on_surface_variant",
      }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = tr("account." .. kind), fontWeight = "semibold" }),
        ui.label({ text = detail, fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
      }),
      ui.glyph({
        name = connected and "circle-check" or "circle-x",
        size = 16,
        color = connected and "primary" or "outline",
      }),
    }),
  }
  for _, child in ipairs(children or {}) do
    table.insert(rows, child)
  end
  return ui.column({
    key = "account-" .. kind,
    gap = 10,
    padding = 12,
    radius = 10 * cornerScale,
    fill = "surface_variant",
  }, rows)
end

local function accountsView()
  local nextcloudOn = noctalia.getConfig("nextcloud_enabled") == true
  local credentials = store.loadCredentials()
  local nextcloudStored = credentials.nextcloud or {}

  local function problem(kind: string): string?
    for _, entry in ipairs(accountProblems) do
      if entry.kind == kind then
        return store.errorText(entry.message)
      end
    end
    return nil
  end

  local nextcloudChildren = {}
  if nextcloudOn then
    local phase = loginState.phase
    if phase == "waiting" then
      local link = loginState.login
      table.insert(nextcloudChildren, ui.column({ gap = 8 }, {
        -- Closing this panel is expected here -- approving happens in the
        -- browser -- and the service keeps polling either way.
        ui.label({ text = tr("account.login_open"), fontSize = 11, color = "on_surface_variant", maxLines = 4 }),
        ui.row({ gap = 6, align = "center" }, {
          ui.button({ text = tr("account.open_browser"), variant = "primary", controlSize = "sm", onClick = function()
            noctalia.runAsync({ "xdg-open", link })
          end }),
          ui.button({ text = tr("account.copy_link"), variant = "outline", controlSize = "sm", onClick = function()
            noctalia.copyToClipboard(link, "text/plain")
            setNotice(tr("account.link_copied"))
          end }),
          ui.button({ text = tr("cancel"), variant = "ghost", controlSize = "sm", onClick = function()
            noctalia.state.set(store.LOGIN_CANCEL, noctalia.nowMs())
          end }),
        }),
      }))
    else
      table.insert(nextcloudChildren, ui.row({ gap = 6, align = "center" }, {
        ui.button({
          text = nextcloudStored.password ~= nil and tr("account.reconnect") or tr("account.connect"),
          variant = "primary",
          controlSize = "sm",
          enabled = phase ~= "starting",
          onClick = "onStartLogin",
        }),
        ui.button({
          text = tr("account.disconnect"),
          variant = "outline",
          controlSize = "sm",
          visible = nextcloudStored.password ~= nil,
          onClick = function()
            store.clearCredentials()
            setNotice(tr("account.disconnected"))
            requestSync()
          end,
        }),
      }))
    end
    local status = ""
    if phase == "starting" then
      status = tr("account.login_starting")
    elseif phase == "done" then
      status = tr("account.connected", { user = loginState.message })
    elseif phase == "error" then
      status = store.errorText(loginState.message)
    end
    if status ~= "" then
      table.insert(nextcloudChildren, ui.label({
        text = status,
        fontSize = 11,
        color = phase == "error" and "error" or "on_surface_variant",
        maxLines = 3,
      }))
    end
  end

  local listToggles = {}
  for index, list in ipairs(cache.lists) do
    local hidden = isHidden(list.id)
    table.insert(listToggles, ui.row({ key = "vis-" .. list.id, gap = 10, align = "center" }, {
      ui.box({ width = 10, height = 10, radius = 5 * cornerScale, fill = listColor(list, index) }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = list.name, maxLines = 1 }),
        ui.label({
          text = list.readOnly and tr("account.read_only") or tr("account." .. (list.accountKind or "nextcloud")),
          fontSize = 10,
          color = "on_surface_variant",
        }),
      }),
      ui.toggle({
        key = "vis-toggle-" .. list.id,
        checked = not hidden,
        onChange = function(value)
          local nowHidden = value ~= "true"
          local next = {}
          for _, id in ipairs(prefs.hiddenLists) do
            if id ~= list.id then
              table.insert(next, id)
            end
          end
          if nowHidden then
            table.insert(next, list.id)
          end
          prefs.hiddenLists = next
          if nowHidden and prefs.selectedList == list.id then
            prefs.selectedList = ""
          end
          store.savePrefs(prefs)
          render()
        end,
      }),
    }))
  end

  return ui.scroll({ flexGrow = 1, gap = 12 }, {
    accountRow(
      "nextcloud",
      findAccount("nextcloud") ~= nil,
      nextcloudOn
        and (problem("nextcloud") or (nextcloudStored.username or noctalia.getConfig("nextcloud_url") or ""))
        or tr("account.disabled"),
      nextcloudChildren
    ),
    #listToggles > 0 and ui.column({ gap = 10, padding = 12, radius = 10 * cornerScale, fill = "surface_variant" }, {
      ui.label({ text = tr("account.visible_lists"), fontWeight = "semibold" }),
      ui.column({ gap = 8 }, listToggles),
    }) or ui.spacer({ height = 0 }),
  })
end

-- ── Header ───────────────────────────────────────────────────────────────────

local function header()
  local children = {}
  if view ~= "tasks" then
    table.insert(children, iconButton("back", "arrow-left", tr("back"), function()
      view = "tasks"
      detailUid = nil
      pendingDelete = nil
      render()
    end))
  else
    table.insert(children, ui.glyph({ name = "checklist", size = 18, color = "primary" }))
  end
  table.insert(children, ui.label({
    text = view == "accounts" and tr("accounts_title") or tr("title"),
    fontSize = 16,
    fontWeight = "bold",
    color = "on_surface",
    flexGrow = 1,
    maxLines = 1,
  }))

  if view == "tasks" then
    table.insert(children, iconButton(
      "sort",
      prefs.sortBy == "name" and "sort-ascending-letters" or (prefs.sortBy == "priority" and "flag" or "calendar"),
      tr("sort." .. prefs.sortBy),
      function()
        prefs.sortBy = prefs.sortBy == "due" and "priority" or (prefs.sortBy == "priority" and "name" or "due")
        store.savePrefs(prefs)
        render()
      end
    ))
    table.insert(children, iconButton(
      "completed",
      showCompleted and "eye" or "eye-off",
      tr(showCompleted and "hide_completed" or "show_completed"),
      function()
        showCompleted = not showCompleted
        prefs.showCompleted = showCompleted
        store.savePrefs(prefs)
        render()
      end
    ))
  end
  table.insert(children, iconButton("sync", syncing and "loader-2" or "refresh", tr("sync_now"), function()
    requestSync()
  end))
  table.insert(children, iconButton("accounts", "settings", tr("accounts_title"), function()
    view = view == "accounts" and "tasks" or "accounts"
    pendingDelete = nil
    render()
  end))
  table.insert(children, iconButton("close", "close", tr("close"), function()
    panel.close()
  end))

  return ui.row({ align = "center", gap = 6 }, children)
end

-- ── Render ───────────────────────────────────────────────────────────────────

render = function()
  local today = store.startOfToday()
  local children = { header() }

  local bar = noticeBar()
  if bar ~= nil then
    table.insert(children, bar)
  end

  if view == "tasks" then
    table.insert(children, quickAdd())
    if #cache.lists > 1 then
      for _, row in ipairs(filterChips(today)) do
        table.insert(children, row)
      end
    end
    table.insert(children, tasksView(today))
    if cache.updatedAt > 0 then
      table.insert(children, ui.label({
        text = tr("last_sync", { time = noctalia.formatTime("%H:%M", cache.updatedAt) }),
        fontSize = 10,
        color = "on_surface_variant",
        textAlign = "end",
      }))
    end
  elseif view == "detail" then
    table.insert(children, detailView(today))
  else
    table.insert(children, accountsView())
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
end

-- ── Callbacks ────────────────────────────────────────────────────────────────

function onRowHover(state, key)
  if state == "true" then
    hoveredKey = key
  elseif hoveredKey == key then
    hoveredKey = nil
  else
    return -- a leave from an area that no longer owns the hover
  end
  render()
end

function onQuickAdd(value)
  createTask(value, defaultList(), nil)
  editorRev += 1
  render()
end

function onDetailSummary(value)
  local task = detailUid ~= nil and findTask(detailUid) or nil
  if task == nil then
    return
  end
  local trimmed = noctalia.string.trim(value)
  if trimmed == "" or trimmed == task.summary then
    return
  end
  local previous = task.summary
  task.summary = trimmed
  writeTask(task, function(vtodo)
    ical.setSummary(vtodo, trimmed, os.time())
  end, function()
    task.summary = previous
    render()
  end)
end

function onDetailNotes(value)
  local task = detailUid ~= nil and findTask(detailUid) or nil
  if task == nil or value == task.description then
    return
  end
  local previous = task.description
  task.description = value
  writeTask(task, function(vtodo)
    ical.setDescription(vtodo, value, os.time())
  end, function()
    task.description = previous
    render()
  end)
end

function onDetailDue(value)
  local task = detailUid ~= nil and findTask(detailUid) or nil
  if task == nil then
    return
  end
  local trimmed = noctalia.string.trim(value)
  local epoch = nil
  if trimmed ~= "" then
    local year, month, day = trimmed:match("^(%d%d%d%d)-(%d%d?)-(%d%d?)$")
    if year == nil then
      setNotice(tr("error.bad_date"))
      return
    end
    epoch = os.time({
      year = tonumber(year),
      month = tonumber(month),
      day = tonumber(day),
      hour = 0, min = 0, sec = 0, isdst = false,
    })
  end
  local previous = task.due
  task.due = epoch ~= nil and { epoch = epoch, dateOnly = true, floating = false } or nil
  writeTask(task, function(vtodo)
    ical.setDueDate(vtodo, epoch, os.time())
  end, function()
    task.due = previous
    render()
  end)
end

-- Hands the flow to the service and shows whatever it publishes. The panel
-- deliberately does not poll: approving happens in the browser, which dismisses
-- this panel, and the poll endpoint yields its credentials only once.
function onStartLogin()
  local url = noctalia.string.trim(noctalia.getConfig("nextcloud_url") or "")
  if url == "" then
    setNotice(tr("error.no_server"))
    return
  end
  loginState = { phase = "starting", login = "", message = "" }
  render()
  noctalia.state.set(store.LOGIN_REQUEST, { url = url, at = noctalia.nowMs() })
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function onOpen(_context)
  cornerScale = tonumber(noctalia.getSetting("shell.corner_radius_scale")) or 1.0
  prefs = store.loadPrefs()
  showCompleted = prefs.showCompleted == true
  reloadCache()
  notice = ""
  pendingDelete = nil
  hoveredKey = nil
  panel.setWantsSecondTicks(true)
  -- A flow started before this panel was dismissed is still running in the
  -- service, so pick up wherever it got to rather than resetting the view.
  local published = noctalia.state.get(store.LOGIN_STATE)
  if type(published) == "table" and type(published.phase) == "string" then
    loginState = published
  end
  store.resolveAccounts(function(resolved, problems)
    accounts = resolved
    accountProblems = problems
    render()
  end)
  requestSync()
  render()
end

-- Nothing to tear down: the browser login belongs to the service precisely so
-- that dismissing this panel does not abandon it.

-- The one thing second ticks are still for: the day rollover, which changes
-- what "overdue" means under a panel left open.
local lastDay = nil

function update()
  local today = store.startOfToday()
  if lastDay ~= today then
    local rollover = lastDay ~= nil
    lastDay = today
    if rollover then
      render()
    end
  end
end

noctalia.state.watch(store.LOGIN_STATE, function(value)
  if type(value) ~= "table" or type(value.phase) ~= "string" then
    return
  end
  local finished = value.phase == "done" and loginState.phase ~= "done"
  loginState = value
  if finished then
    -- The service already saved the credentials and kicked off a sync; this
    -- side just needs the account list to catch up.
    store.resolveAccounts(function(resolved, problems)
      accounts = resolved
      accountProblems = problems
      render()
    end)
  end
  render()
end)

noctalia.state.watch(store.CACHE_REV, function(_value)
  reloadCache()
  render()
end)

noctalia.state.watch(store.STATUS, function(value)
  if type(value) ~= "table" then
    return
  end
  syncing = value.syncing == true
  syncError = type(value.error) == "string" and value.error or ""
  render()
end)
