# Contributing to SessionMaster

Thanks for your interest! SessionMaster is a small, focused macOS menu-bar app.

## Getting started

```bash
scripts/make-dev-cert.sh    # one-time signing identity (stable Accessibility grant)
scripts/bundle-app.sh       # debug build → build/SessionMaster.app
open build/SessionMaster.app
```

The engine lives in the `SessionCore` library and can be exercised headlessly:

```bash
swift run recall-probe list | all | tree | jobs
```

## Project shape

- `Sources/SessionCore` — collectors (read on-disk session state), the unified model, and
  actions (Accessibility recall, VS Code, git worktree). No UI, no global state beyond
  `mtime`-keyed `FileCache`s.
- `Sources/SessionMaster` — the SwiftUI menu-bar app and dashboard.
- `Sources/recall-probe` — a CLI that drives `SessionCore` for manual testing.

## Guidelines

- **Keep `SessionCore` UI-free and testable.** Prefer adding a `recall-probe` subcommand to
  verify a collector over eyeballing the GUI.
- **Collectors must be cheap.** They run every ~2s — cache by file `mtime` (see `FileCache`)
  rather than re-reading whole files each poll.
- **Don't depend on process names.** Correlate via the process parent chain (the Claude CLI
  renames its own process).
- **Match the surrounding style** (small, single-purpose files; clear comments explaining
  *why*, especially around the macOS Accessibility / coordinate / TCC quirks).
- The on-disk formats of Claude Code / Codex are undocumented and change between builds; when
  you add a field, note the build you observed it on and fail soft if it's missing.

## Reporting issues

Please include your macOS version, the Claude Code / Codex versions, and (if relevant) a
redacted `swift run recall-probe all` / `tree` output.
