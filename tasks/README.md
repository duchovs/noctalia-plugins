# Tasks

Your Nextcloud Tasks lists in a Noctalia side panel, kept in sync over CalDAV.
Every list keeps the colour it has on the server, the panel filters to one list
or shows them all together, and a bar widget carries the count of what is due.

Tasks created here show up in the Nextcloud Tasks app — and in Apple Reminders
or any other CalDAV client pointed at the same server — with changes made there
appearing here on the next sync.

## Plugin

| Field | Value |
| --- | --- |
| ID | `duchovs/tasks` |
| Entries | Bar widget: `tasks`; panel: `panel`; service: `sync`; launcher provider: `finder` |
| Launcher Prefix | `/td` |

## Requirements

A Nextcloud server with the **Tasks** app enabled — that is what makes its
calendars advertise VTODO support.

You only supply the server address. Everything else is handled by Nextcloud's
Login Flow v2: you approve the connection in your browser (server SSO and
two-factor included) and the server issues a device-scoped app password that you
can revoke on its own from *Settings → Security*.

## Usage

Open the panel from the bar widget, or with:

```sh
noctalia msg panel-toggle duchovs/tasks:panel
```

**Connecting.** Turn Nextcloud on in *Settings → Plugins → Tasks* and enter the
server address, then open the panel's account view (the gear in its header) and
press **Connect**. Finish signing in in the browser window that opens — the panel
dismissing when you click into the browser is expected and harmless, because the
`sync` service owns the login and keeps polling for up to 20 minutes whether the
panel is open or not. Reopen the panel to see the result.

**The task list.** The chips under the search field filter the view: `All` shows
every list at once, and a single chip narrows to that list. Each chip carries the
list's colour and its open count; the same colour runs down the left edge of
every task row and fills its checkbox, so a mixed view stays readable. The header
buttons cycle the sort order (due date → priority → name), show or hide completed
tasks, force a sync, and open the account view.

**Working with tasks.** Click a checkbox to complete a task — the row updates
immediately and the write goes out behind it. Type in the field at the top to add
a task to the filtered list. Click a task's title to open it, where you can
rename it, set or clear a due date, change its priority, and edit its notes.
Hover a row for its delete button; deletes ask once before going through.

**Launcher.** Type `/td` for the agenda, soonest due first. Keep typing to filter
by name; activating a task ticks it off. The first result is always
`Add "…"` with whatever you typed, which files a new task in the list you last
added to.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `nextcloud_enabled` | `bool` | `false` | Sync Nextcloud Tasks. |
| `nextcloud_url` | `string` | — | Server address, e.g. `https://cloud.example.com`. |
| `nextcloud_password_command` | `string` | — | Advanced. Command printing an app password, used instead of the one obtained by connecting in the browser. |
| `sync_interval_minutes` | `int` | `5` | Minutes between background syncs, 1–240. |
| `glyph` | `glyph` | `checklist` | Bar widget icon. |
| `count_mode` | `select` | `due` | Which number the bar widget shows: due today and overdue, overdue only, all open tasks, or none. |

Which lists appear, the selected filter, the sort order, and whether completed
tasks are shown are all set from the panel itself and stored with the plugin's
data, not in the shell config.

## IPC

```sh
# Sync now, without waiting for the interval.
noctalia msg plugin duchovs/tasks:sync all sync

# Start the Nextcloud browser login (uses the configured address unless one is
# given). Same flow the panel's Connect button triggers.
noctalia msg plugin duchovs/tasks:sync all login
noctalia msg plugin duchovs/tasks:sync all login https://cloud.example.com

# Forget the stored Nextcloud app password.
noctalia msg plugin duchovs/tasks:sync all logout
```

The bar widget's right click syncs.

## Notes

- **Network.** The `sync` service is the only entry that polls. It re-checks each
  collection's `ctag` and refetches only the ones that changed, so an idle
  five-minute sync costs one request per list. Writes are issued by the panel and
  the launcher so the interface reacts immediately.
- **Data.** The task cache, view preferences, and the Nextcloud app password live
  in the plugin's data directory
  (`~/.local/state/noctalia/plugins/data/duchovs/tasks/` by default, following
  `NOCTALIA_STATE_HOME`/`XDG_STATE_HOME`). The credentials file is written with
  `0600` permissions. Nothing is written to the plugin's own directory.
- **Conflicts.** Writes carry the ETag the edit was based on as `If-Match`, so a
  task changed on another device in the meantime is not overwritten — the change
  is rolled back locally and a sync pulls the newer version in.
- **Preserved fields.** Editing a task rewrites only the properties this plugin
  manages. Alarms, recurrence rules, subtask relationships, attachments, and
  anything else the original carries are re-serialised untouched.
- **Timezones.** Due dates written here are all-day `DATE` values. A due date
  read from a task authored in another timezone is displayed as local time,
  since the plugin runtime has no timezone database; that affects display and
  sorting only, never what is written back.
- **Read-only lists** — a collection the server grants no write privilege on
  renders without its checkbox, delete button, or editable fields, rather than
  offering controls whose writes would be refused.
- **What counts as a task list.** Only collections whose `resourcetype` carries
  `<C:calendar/>` *and* whose component set includes `VTODO`. Advertising VTODO
  is not sufficient on its own: a `Depth: 1` listing of the calendar home also
  returns the home itself, the scheduling collections, and the trash bin, some
  of which claim VTODO support while answering 403 or 404 to an actual query.
  Subscribed calendars (`<cs:subscribed/>`, such as an ICS feed pulled from a
  URL) are excluded for the same reason — they are read-only event feeds, not
  task lists.
- **CPU budget.** Noctalia gives every plugin callback 25 ms of CPU and meters
  it on each loop iteration, which makes parsing much costlier than it looks: a
  list of a few dozen tasks exceeded the budget on a low-power laptop when
  parsed in one go, killing the sync before it could save anything. The `sync`
  service therefore works through collection responses in ~5 ms slices, one
  per update tick, ticking every 16 ms while a sync is in flight and once a
  minute otherwise.
