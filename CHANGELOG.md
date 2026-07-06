# Changelog

All notable changes to SessionMaster. Format based on [Keep a Changelog](https://keepachangelog.com).

## [0.5.1] — 2026-07-06

### Changed
- **The dashboard tabs moved to the bottom** — Sessions / Automations / Settings / About as big
  buttons with a sage highlight, matching the design. Refresh is now a small icon in the Sessions
  controls (the app auto-polls every 2s anyway).

### Fixed
- **Clicking Dashboard now brings the window to the Space you're on.** If the dashboard was already
  open on another desktop, clicking Dashboard used to switch Spaces or appear to do nothing; it now
  follows you to the current Space and comes to the front.

## [0.5.0] — 2026-07-06

A full redesign of the interface into one card system — the same grammar for sessions,
automations, and settings. Designed with a judge-panel of directions and an interactive mock;
implementation reviewed by a multi-agent pass and Codex.

### Changed
- **Sessions are accordion cards.** At rest a card is title-first and near-silent: a state dot,
  the full-width title (it no longer gets crushed by chips), a context ring *only* when usage is
  ≥70%, the source glyph, and age. **Single-click expands** one card at a time into an instrument
  readout — model · effort, branch + git, terminal/app, a clickable PR badge, the last prompt,
  and the actions inline (Recall / Resume / Editor / Finder / rename). **Double-click** Recalls
  (the one-gesture fast path). The old timeline rail is gone; each session is a self-contained card.
- **Brood pips** show what a session spawned without opening it: a red pip per child needing
  approval, a green pip per working child (capped at three with a `+N`), a hollow ring when
  children exist but are all quiet, nothing when there are none — with a full census on hover.
  Expanding the card unfolds them 1:1 into a named CHILDREN list (companion / sub-agent / workflow,
  each with its state and age).
- **A context ring** replaces the "% ctx" text — calm sage-green while healthy, amber ≥70%, red
  ≥85%.
- **The source badge shows the surface** with a glyph: filled terminal (attached), outline
  terminal (closed CLI), macwindow (Desktop app).
- **Automations & Routines** are cards in the same grammar — the left edge means armed (sage) or
  paused (dim), and next-run sits where a session's age does; expand for schedule / model / where.
- **Settings** is regrouped into card sections with a single sage accent on the interactive part
  of each row (toggles, dropdowns, the menu-bar icon picker) — no more default form.
- Empty / no-sessions / no-automations use a shared, friendlier state panel.

### Fixed
- The double-click Recall gesture takes priority over the single-click expand, so a double-click
  jumps to the terminal without also toggling the card.
- The expanded card is cleared when you change the search, filter, sort, or tab, so it can't
  re-open a stale row that scrolls back into view.

## [0.4.2] — 2026-07-06

### Changed
- **The session title gets its own line.** When a row carried several badges (source, PR,
  sub-agent count…) the title was truncated down to a couple of characters ("S…") — the one
  thing you read to tell sessions apart. Title now sits alone on the top line and takes the full
  width; the source badge and state chips moved to a dedicated line beneath it.
- **Bigger search field.** The Filter box (menu-bar popover and dashboard) was cramped with tiny
  text — larger font (13pt) and a taller box.

## [0.4.1] — 2026-07-04

### Fixed
- **Hovering a row no longer reflows it.** 0.4.0 inserted the action buttons into the title line
  on hover, which squeezed the title to a few characters and crushed the chips into vertical
  letter-stacks — and the pre-0.4.0 overlay had covered the chips instead. The actions are now a
  single ellipsis menu (rename / recall / resume / editor / Finder) whose small slot is always
  reserved and only fades in on hover: nothing moves, nothing is covered.
- **Chips can never compress into vertical text** — every capsule badge is now fixed-size; the
  title is the one element that flexes (truncates) when a row runs out of width.

## [0.4.0] — 2026-07-04

A deep-audit release: a multi-agent review swept every subsystem (resume, Desktop↔terminal
duality, parent/child nesting, status mapping, parsing, performance), 42 adversarially-verified
defects were fixed, a second review pass caught and fixed 10 regressions in those fixes, and a
judged panel of UI/UX proposals landed the winners.

### Fixed — correctness
- **Context % told the truth again.** A `<synthetic>` zero-usage record could pin a ~90%-full
  session at "0% ctx" exactly when the warning mattered; 1M sessions under 200k tokens read ~5×
  inflated (the `[1m]` marker lives only in the Desktop store); Bedrock/Vertex model ids were
  excluded entirely. All three paths now measure the real window.
- **Live Codex terminals exist now.** `codex` TUI processes are matched to their rollouts (by
  `resume <id>` argv or working directory) — an open TUI is recallable (never offered a
  double-attaching "resume"), pulls its thread back into the list even after a day idle, and
  closed CLI threads show as "Ended — resume" for 24h (they used to vanish after 3h with no
  path back). Dashboard search now reaches Codex threads over 14 days. New-format Codex
  sub-agents (`parent_thread_id`) render as children again.
- **Phantom sessions are dead.** A stale live-state file whose pid was recycled after a
  crash/reboot no longer resurrects as a frozen "live" row that blocks resuming the real
  session (`procStart` is compared with the actual process start time — in UTC *and* local
  readings, so no timezone can mass-kill real sessions).
- **Takeovers are visible.** `claude --continue` / `-c` / the `-r` picker / `--resume=<id>` are
  detected (previously only `--resume <id>`), resolved to the transcript the process actually
  appends to, and shown live — instead of leaving a stale "saved Desktop" row that could
  double-resume the same conversation. Sessions with a Desktop counterpart carry an
  **app→cli** lineage chip.
- **Companions nest under the right parent.** A live session now beats an ended/saved one that
  shares its branch/PR/worktree key (children used to attach to the "Ended" row); the
  singleton-repo fallback only considers live sessions; a claimed companion's own sub-agents
  are lifted to the parent instead of silently dropped; still-busy parallel companion runs are
  never deduped away; quoted text can no longer fabricate phantom sub-agent children.
- **Status/attention honesty.** argv-resumed sessions no longer show a permanent false "Your
  turn" (status is inferred from transcript activity and marked assumed); `bg`/`daemon`
  sessions never promote to "Your turn"; running Task sub-agents show as working, not idle;
  archived Desktop conversations stay hidden from the ended list and search; ended CLI
  sessions keep the name you gave them (`custom-title`); notifications fire only on genuine
  turn completions — resuming a session yourself is silent.
- **Desktop rows resume safely.** Clicking a saved Desktop conversation resumes it in a
  terminal (targeted at that exact session) instead of blindly fronting Claude.app; if its
  transcript is gone from disk, it falls back to opening the app instead of dead-ending.
  Double-clicking resume can't attach two terminals anymore.
- Sessions in paths with spaces/`~` (iCloud/Obsidian vaults) resolve their transcripts again —
  their timestamps had been frozen at the Desktop store's stale value, greying them out as
  dead while they were active hours ago.
- PR chip's number and click target can no longer disagree; dashboard search matches the last
  prompt (and agrees with the popover); a user-widened window is no longer snapped back to
  430pt on every reopen; stale-fade no longer greys out rows that still need approval.

### Fixed — performance
- Rollout sub-agent scanning is incremental (a 125MB rollout was re-read, unescaped and
  regex-scanned in full on every 2s tick while active). The Codex directory walk is cached
  (15s) and prunes old date dirs. `git rev-parse` failures and first-failure `gh` fetches are
  cached (each used to respawn a subprocess every 2s, forever, per affected session).
  Automation `nextRun` (thousands of Calendar calls per rule) is computed only when the file
  changes or the run passes. Process snapshots retry on spawn bursts instead of blanking every
  terminal for a tick. Missing-folder git probes left the main thread.

### Changed — UI/UX (judge-panel winners)
- **Recent mode renders attention tiers** — *Needs you / Working / Idle* section headers plus a
  collapsed **Saved & ended** shelf, so the actionable rows dominate; search sees through the
  shelf.
- **Needs-you rows carry a leading edge bar** (red/yellow; approval rows add a faint red tint)
  so urgency survives peripheral vision instead of resting on a 9pt dot.
- **The source badge shows the surface**: filled terminal = live terminal attached, outline
  terminal = closed CLI session, macwindow = Desktop app conversation.
- **The blue resume chip appears whenever a click will resume** (saved Desktop rows included)
  and names the target terminal in its hint — the "opens a new terminal" side effect is
  visible before the click.
- **The menu-bar popover triages by default** (needs-you + working, count shown as "n / total")
  with a persisted "Show all" toggle and an honest all-quiet empty state.
- **Repeated routine runs collapse** into one row with an **×N runs** toggle chip.
- **Children are informative**: status word + age per line; the collapsed sub-agent count chip
  tints with the busiest child's color. A **CLI source filter** mutes the Desktop archive.
- Hover actions moved into the title line — the overlay used to cover (and steal clicks from)
  the PR chip. Menu-bar counts and popover height follow the rendered tree, not the flat list.

## [0.3.9] — 2026-07-01

### Fixed
- **A session running a long shell command now shows as working (green), not idle (gray).** Claude
  reports `shell` status while a Bash command runs — e.g. a multi-minute `codex` review subprocess —
  but that was mapped to idle, so a busy session looked dormant. It's now treated as working, and
  flips to "your turn" only when the command finishes and the turn actually ends.

## [0.3.8] — 2026-06-30

### Fixed
- **Context-window % no longer pins at 100% for a 1M-context session.** The window was inferred from
  the model id, but a CLI transcript records `claude-opus-4-8` without the `[1m]` marker (that suffix
  only appears in the Desktop store), so a 1M session was measured against the 200k window and read a
  bogus >100% (clamped to 100%). It now also recognises that exceeding 200k tokens *is* proof of the
  1M window (a 200k session auto-compacts long before that), so e.g. 320k tokens reads 32%, not 100%.
- **Timeline dots and age labels now sit level with the session title.** They were padded to the top
  of the row and floated a few pixels above the title text; they're now centered on the title's first
  line (and the continuous rail still meets each dot).
- **A Codex companion nests under its parent even when the parent runs on the repo's main branch.** A
  Claude session launched from the repo root (on `master`) that drives a `codex exec` run into a
  feature worktree shares no branch or PR with it, so in a repo with many sessions the companion was
  left floating as a separate top-level row. Companions now also match their parent by **worktree
  name**, so the parent → child relationship is clear again.

## [0.3.7] — 2026-06-30

### Fixed
- **Session titles stay readable instead of flipping to a worktree slug.** When a session was running
  in a terminal, the row showed Claude's auto-derived window name (an ugly slug like
  `dazzling-williamson-d051b8-6e`) — which overrode the meaningful title and changed back to the
  readable title whenever the session was only saved, so the same conversation appeared to rename
  itself as it went live ↔ idle. SessionMaster now recognises an auto-derived name (`nameSource:
  "derived"`) and keeps the human/AI title above it, so a conversation titled e.g. "現金網效能" stays
  that way. A name you (or the AI) actually set still takes priority, and a custom rename always wins.

## [0.3.6] — 2026-06-29

### Fixed
- **Resuming a session whose folder was deleted no longer flashes a terminal open and shut.** When a
  session's working directory — a `.claude/worktrees/<name>` git worktree — had been removed after its
  branch merged, Resume ran `cd` into the missing folder, so the terminal opened and instantly closed
  with no explanation (the conversation history was never lost). SessionMaster now detects the missing
  folder first: if the worktree is recoverable (repo present, branch still exists) it offers to
  recreate it and then resume; otherwise it explains why it can't, instead of failing silently.

## [0.3.5] — 2026-06-27

### Added
- **Find and resume older closed sessions by searching.** A Claude CLI session that ended more than
  the recent window ago used to vanish from the list. Now the default window is wider (last day),
  and typing in **Filter** reaches back further (last two weeks) to surface a closed session by its
  title / last prompt / branch / folder — so you can find and resume it without it cluttering the
  default list.

### Fixed
- **Codex companions nest under their parent session again.** A Codex companion ("via Claude Code")
  records its own feature branch, which differs from the parent's worktree branch, so it had been
  floating as a separate top-level session. Companions are now matched to their parent by branch
  **or** shared pull-request number (and a branchless one falls back to the sole session in the repo).

### Fixed
- **The dashboard no longer opens with the Filter search field focused.** AppKit made the search box
  the window's first responder on open, which stole keyboard focus and collapsed the source filter /
  Sort controls; the window now opens ready to browse, with those controls visible.

## [0.3.3] — 2026-06-26

### Fixed
- **Sub-agent transcripts no longer appear as duplicate "ended" sessions.** The ended-session scan
  recursively walked `~/.claude/projects` and treated every transcript as a top-level session,
  including a session's own `subagents/agent-*.jsonl` files — so a project could show several
  phantom *Ended — resume* rows (and resuming one would fail). The scan now skips per-session
  `subagents/`/`workflows/` directories and only accepts UUID-named session transcripts.

## [0.3.2] — 2026-06-26

### Added
- **A Claude session now nests its running Task sub-agents and in-progress dynamic workflows.**
  Sub-agents (Task tool) and Workflow runs are read from the session's own files; only the ones
  *currently running* are shown as compact child lines — a sub-agent while its transcript is still
  being written, a workflow while it has started but not yet completed. Finished sub-agents and
  completed workflows drop off, so the list stays focused on live work. (Previously only Codex
  companions nested; Claude-native sub-agents and workflows were never surfaced.)

## [0.3.1] — 2026-06-26

### Changed
- **The dashboard tabs moved from a sidebar to a compact top tab bar** (icon over label, the
  selected one highlighted) — Sessions, Automations, Config, About — with **Refresh** beside them.
  About flags an available update with a small dot, and the window opens narrower without a sidebar
  column.
- **The source filter collapses to a single pill** ("All") that expands to All / Claude / Codex on
  tap and snaps back after a pick, **Project/Recent fold into one "Sort" menu**, and the **search
  field expands to full width on focus** — all to save room in the narrow window.
- **Larger, more readable text** throughout the Sessions and Automations rows.
- The continuous Recent timeline rail is **trimmed to start at the first dot and end at the last**
  (no overhang above the top dot or tail below the bottom one).

### Fixed
- **A session resumed in a terminal is now detected as live.** Running `claude --resume <id>` on a
  Claude Desktop conversation writes no live-state file, so it used to surface as a stale, grayed,
  days-old idle row sorted to the bottom — even while actively running. SessionMaster now recovers
  the running session from the process's arguments and the transcript's modification time, showing
  it as a live, recallable CLI session at the top.

## [0.3.0] — 2026-06-25

### Added
- **Resume a closed or saved session.** A session whose terminal is gone (shown as *Ended — resume*,
  with a blue **resume** chip) now offers a **Resume** action that reopens it in a fresh terminal
  running the tool's own resume command — `claude --resume <id>` or `codex resume <id>` — in the
  session's folder. Works for ended Claude CLI sessions, saved (non-live) Claude Desktop
  conversations, and Codex CLI threads. Resume launches an **interactive login shell** so your shell
  config (e.g. `.zshrc`) is sourced — without it Claude's resume renderer crashes, which was the
  difference between a manual `claude --resume` (works) and a naively scripted one (crashes).
- **Terminal picker** (*Config → Terminal*): choose which terminal Resume opens in — System default,
  Terminal, iTerm2, or Ghostty.

### Changed
- The dashboard now **opens with the sidebar collapsed** into a narrower (~420pt) session list;
  reveal the tabs anytime with the title-bar sidebar toggle.
- The **Recent timeline is one continuous rail** — the status dots ride a single vertical line down
  the whole list instead of a separate segment boxed around each row.

## [0.2.9] — 2026-06-25

### Added
- Dashboard **always-on-top is now the default** (so the session list stays visible) — toggle it off
  in Config → Dashboard.

### Fixed
- The dashboard **sidebar no longer sticks half-open** when toggled (driven by an explicit column
  visibility binding + balanced split style).
- **Single instance**: launching a second copy now just focuses the running one instead of adding a
  second menu-bar icon.

## [0.2.8] — 2026-06-25

### Fixed
- **`codex exec` runs no longer flood the top level.** Repeated `codex exec` invocations on the same
  worktree are deduplicated to the latest, and runs a Claude session kicked off now nest under it
  (like its companions) instead of stacking up as separate top-level sessions.

## [0.2.7] — 2026-06-25

### Notes
- First release where the self-update UX added in 0.2.6 is visible end-to-end: a 0.2.6 install now
  surfaces the **update pill** in the popover and, on clicking *Update via Homebrew*, upgrades and
  **relaunches automatically** — no manual quit/reopen.

## [0.2.6] — 2026-06-25

### Added
- **Update-available indicator**: a small pill in the menu-bar popover header (and a badge on the
  dashboard's About tab) appears when a newer release is published — click it to jump to About.

### Changed
- **"Update via Homebrew" now relaunches the app automatically** after a successful upgrade, so you
  no longer have to quit and reopen by hand.

## [0.2.5] — 2026-06-25

A three-way code review (a multi-agent pass + Codex + a manual pass) drove a batch of correctness,
robustness, and security fixes.

### Added
- **Keep dashboard always on top** (Config → Dashboard) — floats the dashboard above other apps so
  the session list stays visible behind whatever you're working in.

### Security
- The **custom-editor command no longer runs the session path through a shell**, closing a
  command-injection vector — a directory recorded as `/tmp/$(…)` could otherwise run arbitrary
  commands when you clicked *Open in editor* with a custom command.

### Fixed
- **Recall:** CLI sessions under **tmux / SSH / an unrecognized terminal** are no longer mislabeled
  as Desktop (recall now takes the right path); App Exposé only fires once the terminal is actually
  frontmost; an exact window-title match is preferred over a loose substring.
- **Codex companions** spawned by a Claude session now nest under it even when that session's branch
  is unknown (its transcript can record `HEAD` instead of the branch name).
- **No stalls/deadlocks:** a chatty or hung subprocess can't deadlock or permanently stall the 2s
  poll (stderr drained, watchdog timeout, refresh grace-period); `git`/`gh` state refreshes after a
  fetch / PR-merge; a transient `gh` failure is no longer cached as "no PR" for 5 minutes.
- **No crashes/leaks:** duplicate session ids are de-duplicated (SwiftUI `Identifiable`); the hover
  cursor no longer leaks; the dashboard can't be stranded without a Dock icon; recall and
  editor-open run off the main thread (no UI hitch).
- **Parsing:** RRULE next-run respects `BYHOUR`/`INTERVAL`; TOML arrays keep commas inside quoted
  paths; caches are bounded and can't clobber fresher data; `Xcode` is no longer misdetected as the
  "VS Code" terminal.

## [0.2.4] — 2026-06-25

### Fixed
- **"Update via Homebrew" did nothing.** Three bugs: the cask name had a typo
  (`wushan/tab/...` → `wushan/tap/...`), it never ran `brew update` first (so a stale tap couldn't
  see the new version), and it ran brew synchronously on the main thread with no visible output.
  It now opens a Terminal window running `brew update && brew upgrade --cask wushan/tap/session-master`
  so you can watch progress and see any errors. (Updating *from* a build older than 0.2.4 still
  needs that command run once by hand, since the broken button can't fix itself.)

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
