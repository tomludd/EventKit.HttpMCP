# Notes for coding agents

EventKit MCP is a macOS menu bar app (Swift, SwiftPM) that serves the user's calendars as a local MCP
server and runs calendar sync rules. See README.md for features; this file is what you need to work on it.

## Build and test

- Needs the full Xcode toolchain (SwiftUI macros): `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `swift test` runs the core tests (sync engine, config, HTTP/MCP). Run it before every commit.
- `scripts/build-app.sh --install` builds, copies to `~/Applications/EventKit MCP.app` and restarts the app.
  This is how the maintainer's own Mac runs the app (not Homebrew).

## The running app

- Health: `curl http://127.0.0.1:8765/health` (shows the running version).
- MCP: `POST http://127.0.0.1:8765/mcp` with JSON-RPC `tools/call` and `Content-Type: application/json`.
- Every rebuild is ad-hoc signed, so macOS drops calendar access. Afterwards every rule fails with
  "Calendar not found" and tools say "no calendar access" until the **user** grants access again (menu bar item →
  Grant Calendar Access…). You cannot click this; ask the user, then continue. Restarting without rebuilding keeps access.
- Config: `~/Library/Application Support/EventKitMCP/config.json`. The app reads it only at launch and overwrites it
  on changes, so quit the app before editing it by hand, and back it up first (`config.backup-<date>.json`).
- MCP clients only see calendars enabled in Settings → MCP, and only sync rules (and log lines) whose source and
  target are both enabled. To inspect other calendars, enable them temporarily (quit, edit `mcpCalendars`, start),
  then restore the user's selection and say so.

## Sync rules: things that bite

- Events created by a rule carry `[eventkit-sync:<mode>:<key>]` in their notes; the key is a hash of the calendar ids
  (or the rule's pinned `markerKey`). Events whose marker belongs to no current rule are orphans: no rule updates or
  deletes them, and block rules treat them as real events occupying the slot. Find them by comparing markers in
  `list_events` (`include_synced`, `include_notes`) with `get_sync_status` rule markers.
- `[outlook-sync:…]` events come from outlook-cli on Windows. Never delete them.
- Calendars are stored as `{id, title, account}`; ids that disappear are relinked by title and account
  (`AppConfig.reconcileCalendars`). Nothing is changed while no calendars are visible (e.g. without access).
- Deleting events in the user's calendars needs the user's go-ahead; list what you would delete first.

## Commits

- Commit only when asked. Branch from `main`, then fast-forward `main` when the user wants it merged.
- Subject in imperative sentence case, no prefix; body explains why. End with the `Co-Authored-By` line.

## Release checklist

Do every step; a release is not done until the GitHub Release has the zip and the formula points at the tag.

1. `swift test` passes on `main`, and the change is committed and pushed.
2. Bump `CFBundleShortVersionString` in `Resources/Info.plist`; commit "Bump version to X.Y.Z"; push.
3. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z` (lightweight tags, like earlier releases).
4. `scripts/package-release.sh` → `build/EventKit-MCP-X.Y.Z.zip` (universal, ad-hoc signed, not notarized).
5. Publish the GitHub Release with release notes and the zip:
   `gh release create vX.Y.Z build/EventKit-MCP-X.Y.Z.zip --verify-tag --title "EventKit MCP X.Y.Z" --notes-file <notes> --latest`.
   Notes: what changed for the user, then the Install section (download + `xattr` / Open Anyway, and Homebrew),
   as in the v1.1.1 release.
6. Homebrew: download `https://github.com/tomludd/EventKit.HttpMCP/archive/refs/tags/vX.Y.Z.tar.gz`, put its
   `shasum -a 256` and the new url in `Formula/eventkit-mcp.rb`, `ruby -c` it, commit
   "Point the Homebrew formula at the vX.Y.Z release", push.
7. Verify: the release is Latest and its zip downloads with the same sha256; the tarball has the new version.
8. Offer to reinstall locally (`scripts/build-app.sh --install`), warning that calendar access must be granted again.
