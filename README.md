# EventKit HTTP MCP

A macOS menu bar app that exposes your calendars (every account in Calendar.app: Exchange/Microsoft 365, iCloud, Google, CalDAV, local) as an **MCP server over Streamable HTTP**, reachable **only from this Mac**.

- **MCP tools**: list/search/create/update/delete events, free-slot search, recurring events, join links. Inspired by the [`ical`](https://github.com/BRO3886/ical) Go CLI.
- **Calendar sync & blocking**: a port of the block/copy sync from `outlook-cli` (`CalendarSyncService` + `SyncScheduler`), built on EventKit so it works across all accounts on the Mac.
- **Menu bar widget**: shows a countdown to the next meeting when it is less than 10 minutes away, in red when it is less than 4 minutes away. It also lists today's and tomorrow's meetings (click to join Teams/Zoom/Meet) and has **Sync Calendars Now**.

## Why Swift

| | Swift | Go (like `ical`) | .NET |
|---|---|---|---|
| EventKit | Native | cgo + Objective‑C bridge | .NET for macOS bindings (Xcode workload) |
| Menu bar UI with colored countdown | AppKit `NSStatusItem` + SwiftUI settings | Third-party systray libs via cgo | Needs `net*-macos` + AppKit bindings |
| Calendar permission (TCC) | `.app` bundle with usage description | Needs an app bundle anyway | Same |
| HTTP server | `Network.framework`, no dependencies | stdlib | Kestrel |
| Toolchain on this Mac | Installed (Xcode 27 / Swift 6.4) | Not installed | Installed |

Everything here needs to live in a signed `.app` bundle that talks to EventKit and AppKit. Swift does that with no bridging layer and no third-party dependencies.

## Build & run

Requires macOS 14+ and Xcode. SwiftUI macros need the full Xcode toolchain; the script sets `DEVELOPER_DIR` for you.

```sh
scripts/build-app.sh             # builds build/EventKit MCP.app
scripts/build-app.sh --install   # also copies it to ~/Applications and (re)starts it
```

On first launch macOS asks for calendar access. If you deny it, the menu bar icon shows a warning badge; use **Grant Calendar Access…** in the menu (it opens System Settings → Privacy & Security → Calendars).

The app is ad-hoc signed by default, so macOS may ask for calendar access again after a rebuild. Set `CODESIGN_IDENTITY="Apple Development: …"` to sign with a stable identity.

Enable **Settings → General → Launch at login** to start it automatically.

## Connect an MCP client

Endpoint: `http://127.0.0.1:8765/mcp` (the port is configurable in Settings).

Claude Code (the menu has **Copy Claude Code Command**):

```sh
claude mcp add --transport http --scope user eventkit http://127.0.0.1:8765/mcp
```

Other clients (`.mcp.json` / Claude Desktop style):

```json
{ "mcpServers": { "eventkit": { "type": "http", "url": "http://127.0.0.1:8765/mcp" } } }
```

Prefer `127.0.0.1` over `localhost`. The server listens on both `127.0.0.1` and `::1`, but `127.0.0.1` avoids DNS lookups.

## Tools

| Tool | What it does |
|---|---|
| `get_current_time` | Local date/time, weekday, time zone |
| `list_calendars` | Calendars with id, account, type, color, writable |
| `list_events` | Events in a range (default today); filter by calendars/text; optional notes |
| `search_events` | Text search in title/location/notes (default −30 … +180 days) |
| `upcoming_events` | Ongoing + upcoming meetings with `minutesUntilStart` and `joinUrl` |
| `get_event` | Full details: notes, attendees + responses, organizer, recurrence, alerts |
| `find_free_slots` | Free slots of N minutes within working hours |
| `create_event` | Timed/all-day, location, notes, URL, availability, alerts, recurrence |
| `update_event` | Change any field; `span: this \| future` for recurring events |
| `delete_event` | Delete an occurrence or this-and-future |
| `get_sync_status` | Sync rules, schedule, last/next run, recent log |
| `run_sync` | Run all rules, one rule, or a one-off source→target sync |
| `save_sync_rule` / `delete_sync_rule` | Manage sync rules |
| `purge_synced_events` | Remove sync-created events from a calendar (supports `dry_run`) |

Dates accept ISO 8601, `YYYY-MM-DD HH:mm`, `YYYY-MM-DD` and `today`/`tomorrow`/`yesterday`/`now`. Values without an offset are local time. Event ids for recurring events include the occurrence (`<eventIdentifier>|<epoch>`), so update/delete acts on the right occurrence.

EventKit cannot add attendees or send RSVPs, so those `ical` features are not included.

## Calendar sync (blocking)

Rules are set up in **Settings → Sync** (or via MCP). Each rule copies busy time from a *source* calendar into a *target* calendar:

- **Block** (default): anonymous events titled `Busy` (configurable title and location). Out of Office stays `Out of Office`.
- **Copy**: copies title and notes, marked Free.
- **Only outside working hours**: optional, default 07:00–18:00.

As in `outlook-cli`:

- Events with availability Busy or Out of Office are synced. Free, tentative, declined and canceled events are skipped. On calendars without free/busy support, timed events count as busy.
- Created events carry `[eventkit-sync:<mode>:<hash>]` in their notes and are **never re-synced**, so two-way rules (A→B and B→A) don't cascade. Events tagged by outlook-cli (`[outlook-sync:…]`) are skipped too.
- Each run deletes blocks whose source disappeared or moved, refreshes stale titles/locations, and skips slots where the target already has a real event at the same time.
- Rules run automatically every hour at minutes **12, 27, 42 and 57**, for today + 90 days (configurable), and on **Sync Calendars Now**. **Purge** removes a rule's events.

## Local-only access

- Listens on loopback only (`127.0.0.1` and `::1`). Other machines cannot connect.
- Drops any connection whose remote address is not loopback.
- Requires a `Host` header of `localhost`/`127.0.0.1`/`[::1]`, which blocks DNS-rebinding attacks.
- Rejects requests with a non-local `Origin` and requires `Content-Type: application/json`, so web pages in your browser cannot call it.
- Stateless Streamable HTTP: `POST /mcp` returns JSON; `GET /mcp` returns 405 (no server push). `GET /health` is a simple liveness check.

## Files

- Config: `~/Library/Application Support/EventKitMCP/config.json` (port, sync rules, countdown settings)
- `Sources/EventKitMCPCore`: EventKit store, sync engine, MCP server, HTTP server (unit-tested)
- `Sources/EventKitMCP`: menu bar app (AppKit status item + SwiftUI settings)

## Development

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test     # sync engine, HTTP/MCP handling, dates, countdown, free slots
swift build
```
