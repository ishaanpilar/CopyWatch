# CopyWatch — project instructions

Read `AGENTS.md` first, and follow its Read-Before-Editing and Place-Before-Building
rules before touching any file.

## Stack

- Swift 6.0 toolchain, Swift language mode 5, SwiftPM (`Package.swift`), macOS 14+.
- Single executable target `CopyWatch`, SwiftUI app with an `--headless` CLI mode
  (`main.swift` dispatches to `Headless.main` or `CopyWatchApp.main`).
- No external package dependencies.

## Build

- Debug build: `swift build`
- Full signed `.app` bundle: `./build.sh` (wraps `swift build -c release`, then
  packages `dist/CopyWatch.app`; ad-hoc signs unless `DEVELOPER_ID_APP` is set).
- Tests: `swift test` (`Tests/CopyWatchTests`). Also verify changes by building
  and exercising the affected flow (see `--headless copy` / `--headless compare` for scriptable
  verification without the UI).

## Code intelligence

- Query the CodeGraph MCP server before reading files to understand or change
  code — one query returns source + callers + blast radius. Read files only to
  confirm or edit what the graph surfaced. Re-sync after non-trivial changes:
  `codegraph sync .`
- Noisy commands (`swift build`, `git diff/status/log`) are auto-compressed by
  the RTK Claude Code hook (`.claude/hooks/rtk-bash.sh`) — no action needed, it
  rewrites transparently. Never run `swift build` through anything else that
  wraps it.

## Architecture

- See `AGENTS.md` (root DOX contract) and the per-directory `AGENTS.md` files
  under `Sources/CopyWatch/*` for what each subsystem owns and where new work
  belongs. Read the chain for any directory you're about to touch.
