--!nonstrict
-- Background sync: the only entry that talks to the CalDAV servers on a timer.
--
-- It resolves the configured accounts, discovers their VTODO collections, pulls
-- the tasks that changed, and writes the result to the shared cache. The panel,
-- bar widget, and launcher read that cache; none of them poll.
--
-- Writes are a different path: the panel performs them itself so a checkbox
-- responds immediately, then bumps `sync_request` so this service reconciles
-- with the server shortly after.

local caldav = require("./lib/caldav.luau")
local store = require("./lib/store.luau")

local IDLE_TICK_MS = 60 * 1000
local LOGIN_TICK_MS = 1000 -- while a browser login is pending
local JOB_TICK_MS = 16 -- while a sync is in flight; the host's minimum
local JOB_TICK_BUDGET_MS = 10 -- of the 25 ms of CPU the host allows each update()
local LOGIN_POLL_SECONDS = 2
local LOGIN_LIFETIME_SECONDS = 20 * 60 -- the server's own token lifetime

-- A sync is a chain of async callbacks. If the host kills one -- an exceeded CPU
-- budget, a script error -- the chain stops without ever reaching its
-- completion, and a naive `syncing` flag would then reject every later sync for
-- the lifetime of the shell. The generation counter lets a stuck run be
-- abandoned, and makes a late callback from it harmless.
local SYNC_TIMEOUT_SECONDS = 90

local syncing = false
local syncGeneration = 0
local syncStartedAt = 0
local pendingSync = false -- a request that arrived mid-sync
local lastSyncAt = 0
local lastError = ""
local intervalMinutes = 5
local nextSyncAt = 0
local login = nil -- { flow, deadline } while a browser login is pending
local loginPollAt = 0
local jobs = {} -- deferred slices of sync work, oldest first

local function publishStatus()
  noctalia.state.set(store.STATUS, {
    syncing = syncing,
    error = lastError,
    lastSyncAt = lastSyncAt,
  })
end

-- Cached tasks are plain data: the parsed component tree they came with is
-- dropped, and the source ICS kept in its place.
local function strippedTask(task)
  return {
    uid = task.uid,
    href = task.href,
    etag = task.etag,
    listId = task.listId,
    summary = task.summary,
    description = task.description,
    status = task.status,
    completed = task.completed,
    cancelled = task.cancelled,
    due = task.due,
    start = task.start,
    completedAt = task.completedAt,
    priority = task.priority,
    important = task.important,
    parentUid = task.parentUid,
    recurring = task.recurring,
    ics = task.ics,
  }
end

-- Walks the account list, then each account's collections, one request at a
-- time. Serial rather than parallel: a handful of collections is quick either
-- way, and it keeps a flaky server from producing a burst of failures.
local function runSync(onFinished)
  local previous = store.loadCache()
  local previousLists = {}
  for _, list in ipairs(previous.lists) do
    previousLists[list.id] = list
  end
  local previousTasks = {}
  for _, task in ipairs(previous.tasks) do
    local bucket = previousTasks[task.listId]
    if bucket == nil then
      bucket = {}
      previousTasks[task.listId] = bucket
    end
    table.insert(bucket, task)
  end

  local collected = { lists = {}, tasks = {}, errors = {} }

  local function finish()
    collected.updatedAt = os.time()
    store.saveCache(collected)
    lastSyncAt = collected.updatedAt
    lastError = collected.errors[1] ~= nil and collected.errors[1].message or ""
    onFinished()
  end

  store.resolveAccounts(function(accounts, problems)
    for _, problem in ipairs(problems) do
      table.insert(collected.errors, { account = problem.kind, message = problem.message })
    end
    if #accounts == 0 then
      return finish()
    end

    local accountIndex = 0
    local nextAccount

    local function syncLists(account, lists)
      local listIndex = 0
      local function nextList()
        listIndex += 1
        local list = lists[listIndex]
        if list == nil then
          return nextAccount()
        end
        table.insert(collected.lists, list)

        -- An unchanged ctag means nothing in the collection moved, so the
        -- cached tasks stand and the collection costs one request instead of
        -- a full fetch of every VTODO in it.
        local cached = previousLists[list.id]
        if cached ~= nil and cached.ctag ~= "" and cached.ctag == list.ctag and previousTasks[list.id] ~= nil then
          for _, task in ipairs(previousTasks[list.id]) do
            table.insert(collected.tasks, task)
          end
          return nextList()
        end

        caldav.fetchTasks(account, list, function(tasks, err)
          if tasks == nil then
            table.insert(collected.errors, { account = account.id, list = list.name, message = err })
            -- Keep whatever was last known for this list rather than blanking
            -- it: a transient failure should not empty the panel.
            for _, task in ipairs(previousTasks[list.id] or {}) do
              table.insert(collected.tasks, task)
            end
          else
            for _, task in ipairs(tasks) do
              table.insert(collected.tasks, strippedTask(task))
            end
          end
          nextList()
        end)
      end
      nextList()
    end

    nextAccount = function()
      accountIndex += 1
      local account = accounts[accountIndex]
      if account == nil then
        return finish()
      end
      caldav.discoverLists(account, function(lists, err)
        if lists == nil then
          table.insert(collected.errors, { account = account.id, message = err })
          -- Discovery failed: keep this account's last known lists and tasks so
          -- the panel degrades to stale-but-useful instead of empty.
          for _, list in ipairs(previous.lists) do
            if list.accountId == account.id then
              table.insert(collected.lists, list)
              for _, task in ipairs(previousTasks[list.id] or {}) do
                table.insert(collected.tasks, task)
              end
            end
          end
          return nextAccount()
        end
        syncLists(account, lists)
      end)
    end

    nextAccount()
  end)
end

local function sync()
  if syncing then
    pendingSync = true
    return
  end
  syncing = true
  syncGeneration += 1
  syncStartedAt = os.time()
  lastError = ""
  publishStatus()

  local generation = syncGeneration
  local startedMs = noctalia.nowMs()
  runSync(function()
    if generation ~= syncGeneration then
      return -- this run was already given up on; a newer one owns the state
    end
    syncing = false
    nextSyncAt = os.time() + intervalMinutes * 60
    publishStatus()
    noctalia.log(string.format("tasks: sync finished in %d ms", noctalia.nowMs() - startedMs))
    if pendingSync then
      -- Same reasoning as scheduleSync: this completion runs inside the last
      -- HTTP callback of the run, so hand the follow-up to the next tick.
      pendingSync = false
      nextSyncAt = 0
    end
  end)
end

-- Asks for a sync on the next tick rather than starting one here. Callers are
-- mostly inside an async callback or a state watch, which run under the host's
-- per-callback CPU budget; a sync begun there would inherit whatever is left of
-- it instead of starting with a full one.
local function scheduleSync()
  if syncing then
    pendingSync = true
  else
    nextSyncAt = 0
  end
end

-- Called from the tick. Abandons a run whose callback chain died so the next
-- scheduled sync can proceed, instead of every future sync being swallowed.
local function checkSyncWatchdog()
  if not syncing or os.time() - syncStartedAt < SYNC_TIMEOUT_SECONDS then
    return
  end
  noctalia.log("tasks: sync did not complete within "
    .. SYNC_TIMEOUT_SECONDS .. "s; abandoning it and rescheduling")
  syncGeneration += 1 -- orphans the stuck run's callbacks
  syncing = false
  pendingSync = false
  lastError = "sync_stalled"
  nextSyncAt = os.time() + 30
  publishStatus()
end

local function readInterval()
  local minutes = tonumber(noctalia.getConfig("sync_interval_minutes")) or 5
  intervalMinutes = math.max(1, math.floor(minutes))
end

-- ── Nextcloud browser login ──────────────────────────────────────────────────
--
-- The whole flow lives here because approving it means leaving the panel, and
-- the poll endpoint answers only once: whoever is polling at that instant gets
-- the credentials, and nobody gets them afterwards. The service outlives the
-- panel, so it is the only entry that can still be listening.

local function publishLogin(phase: string, message: string?, url: string?)
  noctalia.state.set(store.LOGIN_STATE, {
    phase = phase, -- "idle" | "starting" | "waiting" | "done" | "error"
    message = message or "",
    login = url or "",
    at = noctalia.nowMs(),
  })
end

-- Fast ticks cost nothing while a sync or login is in flight and keep the idle
-- case at one wakeup a minute.
local function applyInterval()
  local interval = IDLE_TICK_MS
  if syncing or #jobs > 0 then
    interval = JOB_TICK_MS
  elseif login ~= nil then
    interval = LOGIN_TICK_MS
  end
  noctalia.setUpdateInterval(interval)
end

-- Sliced sync work from lib/caldav.luau runs here, a few slices per update tick,
-- so each gets a fresh CPU budget instead of sharing one HTTP callback's.
local function defer(fn)
  table.insert(jobs, fn)
  applyInterval()
end

local function runJobs()
  if #jobs == 0 then
    return
  end
  local tickEnd = noctalia.nowMs() + JOB_TICK_BUDGET_MS
  repeat
    local job = table.remove(jobs, 1)
    job()
  until #jobs == 0 or noctalia.nowMs() >= tickEnd
end

caldav.setScheduler(defer)

local function startLogin(url: string)
  if login ~= nil then
    return -- a flow is already running; the panel shows its link
  end
  publishLogin("starting")
  caldav.startLoginFlow(url, function(flow, err)
    if flow == nil then
      publishLogin("error", err)
      return
    end
    login = { flow = flow, deadline = os.time() + LOGIN_LIFETIME_SECONDS }
    loginPollAt = 0
    applyInterval()
    publishLogin("waiting", nil, flow.login)
    noctalia.runAsync({ "xdg-open", flow.login })
  end)
end

local function endLogin(phase: string, message: string?)
  login = nil
  applyInterval()
  publishLogin(phase, message)
end

local function pollLogin()
  local now = os.time()
  if now > login.deadline then
    return endLogin("error", "login_expired")
  end
  if now < loginPollAt then
    return
  end
  loginPollAt = now + LOGIN_POLL_SECONDS

  local current = login
  caldav.pollLoginFlow(current.flow, function(credentials, pending, err)
    if login ~= current then
      return -- cancelled or superseded while the poll was in flight
    end
    if pending then
      return
    end
    if credentials == nil then
      return endLogin("error", err)
    end
    local stored = store.loadCredentials()
    stored.nextcloud = credentials
    if not store.saveCredentials(stored) then
      return endLogin("error", "save_failed")
    end
    endLogin("done", credentials.username)
    scheduleSync()
  end)
end

-- Scheduling is by wall clock rather than a tick count, because the tick rate
-- changes while a sync or login is in flight.
readInterval()
publishLogin("idle")
publishStatus()
sync()
applyInterval()

function update()
  runJobs()
  if login ~= nil then
    pollLogin()
  end
  checkSyncWatchdog()
  if not syncing and os.time() >= nextSyncAt then
    sync()
  end
  applyInterval()
end

function onConfigChanged()
  readInterval()
  scheduleSync()
end

function onEnable()
  readInterval()
  scheduleSync()
end

function onIpc(event, payload)
  if event == "sync" or event == "refresh" then
    scheduleSync()
  elseif event == "login" then
    -- Also reachable from the terminal, which is the only way to retry the
    -- browser login without the panel open.
    local url = noctalia.string.trim(payload or "")
    if url == "" then
      url = noctalia.string.trim(noctalia.getConfig("nextcloud_url") or "")
    end
    if url == "" then
      publishLogin("error", "no_server")
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.no_server"))
      return
    end
    startLogin(url)
  elseif event == "logout" then
    store.clearCredentials()
    scheduleSync()
  end
end

noctalia.state.watch(store.SYNC_REQUEST, function(_value)
  scheduleSync()
end)

noctalia.state.watch(store.LOGIN_REQUEST, function(value)
  if type(value) == "table" and type(value.url) == "string" and value.url ~= "" then
    startLogin(value.url)
  end
end)

noctalia.state.watch(store.LOGIN_CANCEL, function(_value)
  if login ~= nil then
    endLogin("idle")
  end
end)
