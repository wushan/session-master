# Changelog

All notable changes to SessionMaster. Format based on [Keep a Changelog](https://keepachangelog.com).

## [0.2.3] — 2026-06-25

### Added
- **Recall across virtual desktops (Spaces)**: when a session's terminal is on another desktop,
  SessionMaster fans that app's windows out with **App Exposé** — click the one you want and macOS
  switches to its desktop natively. (Modern macOS locks down every private Space/window-move SPI,
  so this is the only reliable, no-SIP path.) Visible windows are still raised + focused directly,
  even when buried behind other windows.
- **Routine / automation badges**: Claude routine sessions show a teal **routine** badge and Codex
  automation runs an **auto** badge (clock glyph), so machine-started sessions are obvious.
- **Sub-agent count** chip on a parent session, and a **three concentric-rings** menu-bar icon.
- The dashboard gets a **Dock icon while it's open**, so you can minimize it like a normal window;
  it drops back to menu-bar-only when closed.

### Changed
- **Sub-agents / Codex companions collapse by default** and, when expanded, render as a single dim,
  non-interactive line nested to the right of the parent (they can't be recalled or acted on).
- Dashboard tabs moved to a **sidebar**; the session list defaults to **Recent** sort.
- Menu-bar popover: footer reordered (⚡ launch-at-login + ⚙️ settings on the left, **Dashboard** on
  the right), row actions moved to a **hover overlay** so titles/paths use the full width, and the
  popover **closes itself** when you open the dashboard.
- Removed the **pin-to-floating-window** feature — the now-dockable dashboard window replaces it.
- The "actively working" indicator is a **static halo ring** instead of a pulsing dot.

### Fixed
- Menu-bar popover **flicker/slide** on open (caused by a repeatForever pulse animation).
- The **About** page now shows the real app icon instead of an SF Symbol.

## [0.2.2] — 2026-06-25

### Added
- App icon — three concentric neon-green rings on deep purple.
- `scripts/notarize.sh` — Developer ID signing + notarization for clean Gatekeeper on direct
  distribution. (The Mac App Store isn't viable: the sandbox forbids this app's arbitrary file
  access, subprocesses, and Accessibility-based window control.)

## [0.2.1] — 2026-06-25

### Added
- **Timeline list**: last-activity time on a left axis; the status dot **pulses** while a
  session is actively working.
- **Rename sessions** to a custom title (click the ✏️ to edit; clear + return resets).
- **Quick-filter box** in the menu-bar popover (by title / project / branch / model / cwd /
  last prompt).
- **Configurable menu-bar icon** (Config), a **gear** in the popover and floating panel, and a
  **loading state** on first launch instead of a blank list.

### Changed
- The popover now lists every session sorted needs-you-first; sessions idle **>48h fade to
  grayscale** (still recallable) so live ones stand out.
- Removed the easy-to-misclick Quit/power icon from the popover (Quit now lives in Config).

## [0.2.0] — 2026-06-24

### Added
- **Claude Desktop sessions** are now surfaced (not just live ones) — your saved Desktop
  conversations, grouped per project, showing the recent ones with a "Show N more" expander.
- **Click a row to recall** it (the whole row, not just a button).
- **Sound + Notification Center alerts** when a session finishes its turn (your turn) or hits a
  permission prompt. Toggleable in Config.
- **Rich per-row status**: git branch state (merged / ↑unpushed / ↓behind / local), uncommitted
  change count, a **clickable PR badge** (open / draft / merged via `gh`, number from the
  transcript), context-window %, and the session's last prompt as a subtitle.
- **Codex Desktop recall via deep link** — `codex://threads/<id>` jumps straight to the
  conversation.
- **Dashboard**: Project / Recent sort toggle; **Config** tab (editor, sound/notifications,
  launch-at-login) and **About** tab (version + one-click *Update via Homebrew*).
- **Configurable editor** for "open worktree" — VS Code / Cursor / Zed / Sublime / Xcode / a
  custom command.
- **Pin to a floating window** that stays on top and doesn't dismiss on click-outside.
- `scripts/release.sh` one-command release (dmg + tag + GitHub Release + Homebrew cask bump);
  `VERSION` file as the single source of truth.

### Changed
- The menu-bar popover now lists **every** session (sorted needs-you-first, then most recent)
  so you can resume any conversation, not only live ones.
- Codex **automation runs** are shown only while recently active (deduped), instead of hidden
  outright — so you can follow up on a just-finished automation; stale runs drop off.
- `idle` for a saved Desktop session reads as idle (not "your turn"); the recall button was
  removed (the row click recalls); the Dashboard button is larger.

### Fixed
- Multi-display recall mis-attributed a window at a screen boundary; the wrong-model
  (`<synthetic>`) and `shell`/`unknown` status edge cases; per-poll file re-reads (now
  `mtime`-cached across all collectors).

## [0.1.0] — 2026-06-24

### Added
- Initial release: a menu-bar console aggregating Claude Code (CLI + Desktop) and Codex
  (CLI + Desktop + VS Code) sessions in real time, grouped by project / worktree / branch with
  model, effort, and status.
- One-click **Recall** of the owning terminal window (Accessibility), **Open in VS Code**,
  **Reveal in Finder**; parent → child hierarchy; Routines & Automations panel.
- Homebrew cask, `.dmg`, and from-source install; stable self-signed signing so the
  Accessibility grant persists.
