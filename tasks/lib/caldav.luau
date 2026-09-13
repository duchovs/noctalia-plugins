--!nonstrict
-- CalDAV client for task lists, shared by the service, panel, and launcher.
--
-- Nothing here is Nextcloud-specific beyond where discovery starts: the rest is
-- plain RFC 4791 against VTODO collections, so another CalDAV server needs only
-- its own root URL and credentials.
--
-- Every call is asynchronous: noctalia.http() returns immediately and delivers
-- to a callback, so the request chains here are written as continuations.
--
-- One constraint shapes the design: noctalia.http() surfaces only
-- { ok, status, body } -- never response headers. The ETag a server returns
-- from a PUT is therefore invisible, so a write is followed by a re-read of
-- that resource's etag rather than trusting the response.

local xml = require("./xml.luau")
local ical = require("./ical.luau")

local M = {}

local DAV = "DAV:"
local CALDAV = "urn:ietf:params:xml:ns:caldav"
local CALSRV = "http://calendarserver.org/ns/"
-- Apple defined the calendar-color property, but every major CalDAV server
-- (Nextcloud included) publishes list colours under this namespace.
local APPLE_ICAL = "http://apple.com/ns/ical/"

-- ── URLs ─────────────────────────────────────────────────────────────────────

local function splitUrl(url: string)
  local scheme, host, path = url:match("^(https?://)([^/]+)(.*)$")
  return scheme, host, (path ~= nil and path ~= "" and path or "/")
end

-- Resolves an href from a DAV response against the URL it was fetched from.
-- Servers mix the three forms freely: some hand back absolute URLs on a
-- different host once discovery leaves the entry point, while Nextcloud stays
-- root-relative throughout.
function M.resolveUrl(base: string, href: string): string
  href = (href:gsub("^%s+", ""):gsub("%s+$", ""))
  if href == "" then
    return base
  end
  if href:match("^https?://") then
    return href
  end
  local scheme, host, path = splitUrl(base)
  if scheme == nil then
    return href
  end
  if href:sub(1, 1) == "/" then
    return scheme .. host .. href
  end
  local directory = path:match("^(.*/)") or "/"
  return scheme .. host .. directory .. href
end

-- ── Requests ─────────────────────────────────────────────────────────────────

local function accountHeaders(extra)
  local headers = { "User-Agent: noctalia-tasks" }
  for _, header in ipairs(extra or {}) do
    table.insert(headers, header)
  end
  return headers
end

-- `onDone(ok, status, body)`. `ok` is transport success; a 401 is ok = true.
function M.request(account, method: string, url: string, body: string?, extraHeaders, onDone)
  local accepted = noctalia.http({
    url = url,
    method = method,
    body = body,
    headers = accountHeaders(extraHeaders),
    basic_username = account.username,
    basic_password = account.password,
    follow_redirects = true,
  }, function(response)
    onDone(response.ok, response.status, response.body or "")
  end)
  if not accepted then
    -- Rejected before dispatch: offline mode, or a malformed request.
    onDone(false, 0, "")
  end
end

local function propfind(account, url: string, depth: string, body: string, onDone)
  M.request(account, "PROPFIND", url, body, {
    "Depth: " .. depth,
    "Content-Type: application/xml; charset=utf-8",
  }, onDone)
end

local function report(account, url: string, depth: string, body: string, onDone)
  M.request(account, "REPORT", url, body, {
    "Depth: " .. depth,
    "Content-Type: application/xml; charset=utf-8",
  }, onDone)
end

-- A DAV response element only counts when its propstat says 2xx; servers
-- report unsupported properties as 404 inside an otherwise successful 207.
local function propstatOk(propstat): boolean
  local status = xml.text(xml.child(propstat, DAV, "status"))
  return status == "" or status:find(" 2%d%d ") ~= nil
end

local function propsOf(responseNode)
  local props = {}
  for _, propstat in ipairs(xml.children(responseNode, DAV, "propstat")) do
    if propstatOk(propstat) then
      local prop = xml.child(propstat, DAV, "prop")
      if prop ~= nil then
        for _, child in ipairs(prop.children) do
          props[child.ns .. "|" .. child.name] = child
        end
      end
    end
  end
  return props
end

local function responsesOf(root)
  if root.name ~= "multistatus" then
    return nil, "expected a DAV multistatus, got <" .. root.name .. ">"
  end
  return xml.children(root, DAV, "response")
end

local function multistatus(body: string)
  local root, err = xml.parse(body)
  if root == nil then
    return nil, err
  end
  return responsesOf(root)
end

-- ── Sliced work ──────────────────────────────────────────────────────────────
--
-- The host gives each plugin callback 25 ms of CPU and meters it on every loop
-- iteration, which makes parsing far costlier than it looks: one list of a few
-- dozen tasks takes over 30 ms on a low-power laptop when done in one go. The
-- service installs a scheduler that runs a deferred function on a later update
-- tick with a fresh budget, and collection-sized responses are worked through
-- in slices of it. Without a scheduler -- the panel and launcher, which only
-- ever parse a single resource -- the work runs inline.

local SLICE_MS = 5
local defer = nil

function M.setScheduler(scheduler)
  defer = scheduler
end

-- Calls `work(shouldYield)` until it returns true, then `onDone()`. The first
-- slice runs immediately; each later one is handed to the scheduler.
local function sliced(work, onDone)
  if defer == nil then
    work(nil)
    return onDone()
  end
  local function run()
    local sliceEnd = noctalia.nowMs() + SLICE_MS
    local finished = work(function()
      return noctalia.nowMs() >= sliceEnd
    end)
    if finished then
      return onDone()
    end
    defer(run)
  end
  run()
end

-- multistatus() for a response that can be large: `onDone(responses, err)`.
local function multistatusSliced(body: string, onDone)
  local parser = xml.parser(body)
  local root, err = nil, nil
  sliced(function(shouldYield)
    local done, result = parser.step(shouldYield)
    if done == false then
      return false
    end
    if done then
      root = result
    else
      err = result
    end
    return true
  end, function()
    if root == nil then
      return onDone(nil, err)
    end
    onDone(responsesOf(root))
  end)
end

-- ── Discovery ────────────────────────────────────────────────────────────────

local PRINCIPAL_BODY = [[<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>]]

local HOME_BODY = [[<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><c:calendar-home-set/></d:prop>
</d:propfind>]]

local COLLECTIONS_BODY = [[<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"
            xmlns:cs="http://calendarserver.org/ns/"
            xmlns:ical="http://apple.com/ns/ical/">
  <d:prop>
    <d:resourcetype/>
    <d:displayname/>
    <d:current-user-privilege-set/>
    <cs:getctag/>
    <ical:calendar-color/>
    <c:supported-calendar-component-set/>
  </d:prop>
</d:propfind>]]

local function firstHref(responses, ns: string, name: string, base: string)
  for _, response in ipairs(responses) do
    local props = propsOf(response)
    local node = props[ns .. "|" .. name]
    if node ~= nil then
      local href = xml.text(xml.child(node, DAV, "href"))
      if href ~= "" then
        return M.resolveUrl(base, href)
      end
    end
  end
  return nil
end

-- `onDone(lists, err)` where each list is
-- { id, accountId, href, name, color, ctag, readOnly }.
function M.discoverLists(account, onDone)
  local root = account.root

  propfind(account, root, "0", PRINCIPAL_BODY, function(ok, status, body)
    if not ok then
      return onDone(nil, "could not reach " .. root)
    end
    if status == 401 then
      return onDone(nil, "authentication rejected")
    end
    if status ~= 207 then
      return onDone(nil, "principal lookup returned HTTP " .. tostring(status))
    end
    local responses, err = multistatus(body)
    if responses == nil then
      return onDone(nil, err)
    end
    local principal = firstHref(responses, DAV, "current-user-principal", root)
    if principal == nil then
      return onDone(nil, "server did not report a current-user-principal")
    end

    propfind(account, principal, "0", HOME_BODY, function(homeOk, homeStatus, homeBody)
      if not homeOk or homeStatus ~= 207 then
        return onDone(nil, "calendar-home lookup returned HTTP " .. tostring(homeStatus))
      end
      local homeResponses, homeErr = multistatus(homeBody)
      if homeResponses == nil then
        return onDone(nil, homeErr)
      end
      local home = firstHref(homeResponses, CALDAV, "calendar-home-set", principal)
      if home == nil then
        return onDone(nil, "server did not report a calendar-home-set")
      end

      propfind(account, home, "1", COLLECTIONS_BODY, function(listOk, listStatus, listBody)
        if not listOk or listStatus ~= 207 then
          return onDone(nil, "collection listing returned HTTP " .. tostring(listStatus))
        end
        multistatusSliced(listBody, function(listResponses, listErr)
          if listResponses == nil then
            return onDone(nil, listErr)
          end

          local lists = {}
          for _, response in ipairs(listResponses) do
            local props = propsOf(response)
            local components = props[CALDAV .. "|supported-calendar-component-set"]
            local holdsTodos = false
            if components ~= nil then
              for _, comp in ipairs(xml.children(components, CALDAV, "comp")) do
                if (comp.attrs.name or ""):upper() == "VTODO" then
                  holdsTodos = true
                end
              end
            end

            -- Advertising VTODO is not enough to make something a task list.
            -- A Depth:1 listing of the calendar home also returns the home
            -- itself, CalDAV's scheduling collections, the trash bin, and any
            -- subscribed ICS feed -- several of which claim VTODO support while
            -- answering 403 or 404 to an actual query. RFC 4791 says a calendar
            -- collection is the one carrying `<C:calendar/>` in its resourcetype,
            -- so that -- not the component set -- is what decides.
            local resourceType = props[DAV .. "|resourcetype"]
            local isCalendar = resourceType ~= nil
              and xml.child(resourceType, CALDAV, "calendar") ~= nil

            if holdsTodos and isCalendar then
              local href = M.resolveUrl(home, xml.text(xml.child(response, DAV, "href")))
              local displayName = xml.text(props[DAV .. "|displayname"])
              local color = xml.text(props[APPLE_ICAL .. "|calendar-color"])
              local privileges = props[DAV .. "|current-user-privilege-set"]
              local writable = true
              if privileges ~= nil then
                writable = false
                for _, privilege in ipairs(xml.children(privileges, DAV, "privilege")) do
                  if xml.child(privilege, DAV, "write") ~= nil
                    or xml.child(privilege, DAV, "write-content") ~= nil
                    or xml.child(privilege, DAV, "all") ~= nil then
                    writable = true
                  end
                end
              end
              table.insert(lists, {
                id = account.id .. "|" .. href,
                accountId = account.id,
                accountKind = account.kind,
                href = href,
                name = displayName ~= "" and displayName or (href:match("([^/]+)/?$") or href),
                -- Servers write #rrggbb and #rrggbbaa; both are valid UiColor values.
                color = color:match("^#%x+$") and color or nil,
                ctag = xml.text(props[CALSRV .. "|getctag"]),
                readOnly = not writable,
              })
            end
          end
          table.sort(lists, function(a, b)
            return a.name:lower() < b.name:lower()
          end)
          onDone(lists, nil)
        end)
      end)
    end)
  end)
end

-- ── Reading tasks ────────────────────────────────────────────────────────────

local TODOS_BODY = [[<?xml version="1.0" encoding="utf-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><d:getetag/><c:calendar-data/></d:prop>
  <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VTODO"/></c:comp-filter></c:filter>
</c:calendar-query>]]

local CTAG_BODY = [[<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">
  <d:prop><cs:getctag/></d:prop>
</d:propfind>]]

-- `onDone(ctag, err)`. A collection whose ctag is unchanged needs no refetch,
-- which keeps a five-minute poll cheap on lists that rarely move.
function M.fetchCtag(account, list, onDone)
  propfind(account, list.href, "0", CTAG_BODY, function(ok, status, body)
    if not ok or status ~= 207 then
      return onDone(nil, "ctag check returned HTTP " .. tostring(status))
    end
    local responses, err = multistatus(body)
    if responses == nil then
      return onDone(nil, err)
    end
    for _, response in ipairs(responses) do
      local ctag = xml.text(propsOf(response)[CALSRV .. "|getctag"])
      if ctag ~= "" then
        return onDone(ctag, nil)
      end
    end
    onDone("", nil) -- server does not implement ctags; always refetch
  end)
end

-- `onDone(tasks, err)`; each task is an ical.readTodo record plus href/etag/listId.
function M.fetchTasks(account, list, onDone)
  report(account, list.href, "1", TODOS_BODY, function(ok, status, body)
    if not ok then
      return onDone(nil, "could not reach " .. list.href)
    end
    if status ~= 207 then
      return onDone(nil, "task query returned HTTP " .. tostring(status))
    end
    multistatusSliced(body, function(responses, err)
      if responses == nil then
        return onDone(nil, err)
      end

      local tasks = {}
      local index = 0
      sliced(function(shouldYield)
        while index < #responses do
          index += 1
          local response = responses[index]
          local props = propsOf(response)
          local data = props[CALDAV .. "|calendar-data"]
          local ics = xml.text(data)
          if data ~= nil and ics ~= "" then
            local calendar = ical.parse(ics)
            local task = calendar ~= nil and ical.readTodo(calendar) or nil
            if task ~= nil and task.uid ~= "" then
              task.href = M.resolveUrl(list.href, xml.text(xml.child(response, DAV, "href")))
              task.etag = xml.text(props[DAV .. "|getetag"])
              task.listId = list.id
              -- The source ICS travels with the task so an edit can rewrite it
              -- without a refetch, and so nothing the plugin does not model is lost.
              task.ics = ics
              table.insert(tasks, task)
            end
          end
          if shouldYield ~= nil and shouldYield() then
            return index >= #responses
          end
        end
        return true
      end, function()
        onDone(tasks, nil)
      end)
    end)
  end)
end

-- Re-reads one resource's etag. Needed after every write, because the ETag
-- response header from a PUT is not reachable through noctalia.http().
function M.fetchEtag(account, href: string, onDone)
  local body = [[<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>]]
  propfind(account, href, "0", body, function(ok, status, responseBody)
    if not ok or status ~= 207 then
      return onDone(nil)
    end
    local responses = multistatus(responseBody)
    if responses == nil then
      return onDone(nil)
    end
    for _, response in ipairs(responses) do
      local etag = xml.text(propsOf(response)[DAV .. "|getetag"])
      if etag ~= "" then
        return onDone(etag)
      end
    end
    onDone(nil)
  end)
end

-- ── Writing tasks ────────────────────────────────────────────────────────────

-- `onDone(etag, err)`. `etag` is the resource's new etag, re-read after the
-- write; nil with no error means the write succeeded but the etag could not be
-- confirmed, which the next poll repairs.
--
-- `etag` in: the etag the edit was based on, sent as If-Match so a concurrent
-- change on another device loses the race instead of being overwritten. Pass
-- nil for a new task, which sends If-None-Match: * so a UID collision fails
-- rather than clobbering an existing resource.
function M.putTask(account, href: string, ics: string, etag: string?, onDone)
  local headers = { "Content-Type: text/calendar; charset=utf-8" }
  if etag ~= nil and etag ~= "" then
    table.insert(headers, "If-Match: " .. etag)
  else
    table.insert(headers, "If-None-Match: *")
  end
  M.request(account, "PUT", href, ics, headers, function(ok, status, body)
    if not ok then
      return onDone(nil, "could not reach the server")
    end
    if status == 412 then
      return onDone(nil, "conflict")
    end
    if status < 200 or status >= 300 then
      return onDone(nil, "write returned HTTP " .. tostring(status))
    end
    M.fetchEtag(account, href, function(newEtag)
      onDone(newEtag, nil)
    end)
  end)
end

-- `onDone(ok, err)`. A 404 counts as success: the task is gone either way.
function M.deleteTask(account, href: string, etag: string?, onDone)
  local headers = {}
  if etag ~= nil and etag ~= "" then
    table.insert(headers, "If-Match: " .. etag)
  end
  M.request(account, "DELETE", href, nil, headers, function(ok, status, _body)
    if not ok then
      return onDone(false, "could not reach the server")
    end
    if status == 404 or (status >= 200 and status < 300) then
      return onDone(true, nil)
    end
    if status == 412 then
      return onDone(false, "conflict")
    end
    onDone(false, "delete returned HTTP " .. tostring(status))
  end)
end

-- Task resource names are the UID, which is what CalDAV clients conventionally
-- do and what makes a UID collision detectable via If-None-Match.
function M.taskHref(list, uid: string): string
  local base = list.href
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  return base .. noctalia.string.urlEncode(uid) .. ".ics"
end

function M.newUid(): string
  -- Enough entropy to never collide in practice, and readable in a server's UI.
  local random = string.format("%08x%08x", math.random(0, 0xFFFFFFF), math.random(0, 0xFFFFFFF))
  return string.format("noctalia-%d-%s", os.time(), random)
end

-- ── Nextcloud Login Flow v2 ──────────────────────────────────────────────────
--
-- Nextcloud is the one backend with a real SSO path: the user authenticates in
-- their browser (server-side SSO and 2FA included) and the server hands back a
-- device-scoped app password that can be revoked on its own, so no password is
-- ever typed into the shell config.

function M.nextcloudBase(url: string): string
  local trimmed = noctalia.string.trim(url):gsub("/+$", "")
  if not trimmed:match("^https?://") then
    trimmed = "https://" .. trimmed
  end
  return trimmed
end

function M.nextcloudRoot(url: string): string
  return M.nextcloudBase(url) .. "/remote.php/dav/"
end

-- `onDone(flow, err)` with flow = { login, endpoint, token }.
function M.startLoginFlow(serverUrl: string, onDone)
  local accepted = noctalia.http({
    url = M.nextcloudBase(serverUrl) .. "/index.php/login/v2",
    method = "POST",
    headers = { "User-Agent: noctalia-tasks" },
    follow_redirects = true,
  }, function(response)
    if not response.ok or response.status ~= 200 then
      return onDone(nil, "login flow returned HTTP " .. tostring(response.status))
    end
    local payload = noctalia.json.decode(response.body or "")
    if type(payload) ~= "table" or payload.login == nil or type(payload.poll) ~= "table" then
      return onDone(nil, "unexpected login flow response")
    end
    onDone({
      login = payload.login,
      endpoint = payload.poll.endpoint,
      token = payload.poll.token,
    }, nil)
  end)
  if not accepted then
    onDone(nil, "request rejected")
  end
end

-- One poll attempt. `onDone(credentials, pending, err)`: 404 means the user has
-- not finished in the browser yet, and the caller should poll again.
function M.pollLoginFlow(flow, onDone)
  local accepted = noctalia.http({
    url = flow.endpoint,
    method = "POST",
    body = "token=" .. noctalia.string.urlEncode(flow.token),
    headers = {
      "Content-Type: application/x-www-form-urlencoded",
      "User-Agent: noctalia-tasks",
    },
    follow_redirects = true,
  }, function(response)
    if not response.ok then
      return onDone(nil, false, "could not reach the server")
    end
    if response.status == 404 then
      return onDone(nil, true, nil)
    end
    if response.status ~= 200 then
      return onDone(nil, false, "login poll returned HTTP " .. tostring(response.status))
    end
    local payload = noctalia.json.decode(response.body or "")
    if type(payload) ~= "table" or payload.appPassword == nil then
      return onDone(nil, false, "unexpected login poll response")
    end
    onDone({
      server = payload.server,
      username = payload.loginName,
      password = payload.appPassword,
    }, false, nil)
  end)
  if not accepted then
    onDone(nil, false, "request rejected")
  end
end

return M
