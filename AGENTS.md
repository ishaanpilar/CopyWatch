# DOX framework

- DOX is a hierarchy of AGENTS.md files that act as binding work contracts.
- Agents must follow DOX instructions across any edit in the covered subtree.

## Core Contract

- AGENTS.md files are binding contracts for their subtree.
- Work products, source, instructions, records, assets, and durable docs must stay
  understandable from the nearest applicable AGENTS.md plus every parent AGENTS.md
  above it.

## Read Before Editing

1. Read this root AGENTS.md.
2. Identify every file or folder you expect to touch.
3. Walk from the repository root to each target path.
4. Read every AGENTS.md found along each route.
5. If a parent AGENTS.md lists a child whose scope contains the path, read that child and continue.
6. Use the nearest AGENTS.md as the local contract and parent docs for repo-wide rules.
7. If docs conflict, the closer doc controls local details, but no child may weaken DOX.

Do not rely on memory. Re-read the applicable DOX chain in the current session before editing.

## Place Before Building

Every new feature, module, tool, endpoint, or asset must land in its
architecturally-correct home **before** any code is written. Convenience of the
file you happen to have open is never a reason to place work elsewhere. Before
building:

1. Name the kind of thing you're adding, and which architectural layer owns that
   kind. The directory split is load-bearing, not cosmetic — respect it.
2. Walk the Child DOX Index (below) and the nested indexes to find the scope that
   owns that kind. The nearest owning AGENTS.md is the target directory.
3. Verify the placement against this repo's Global Constraints and the local
   AGENTS.md contract before writing code.
4. Reuse the existing seam before adding a new one — extend the owning module,
   service, or package rather than duplicating its capability in a closer folder.
   If no scope fits, the right move is a new scope with its own AGENTS.md, not an
   orphan file wedged into an unrelated tree.
5. If placement is genuinely ambiguous, state the candidate homes and the
   trade-off before writing code — do not default to the current directory.

A feature in the wrong layer is a defect even if it works. Correct the placement
first, then build.

## Update After Editing

Every meaningful change requires a DOX pass before the task is done.
Update the closest owning AGENTS.md when a change affects:
- purpose, scope, ownership, or responsibilities
- durable structure, contracts, workflows, or operating rules
- required inputs, outputs, permissions, constraints, side effects, or artifacts
- user preferences about behavior, communication, process, organization, or quality
- AGENTS.md creation, deletion, move, rename, or index contents

Update parent docs when parent-level structure, ownership, workflow, or child index changes.
Update child docs when parent changes alter local rules.
Remove stale or contradictory text immediately.

## Style

- Keep docs concise, current, and operational.
- Document stable contracts, not diary entries.
- Put broad rules in parent docs and concrete details in child docs.
- Prefer direct bullets with explicit names.
- Do not duplicate rules across many files unless each scope needs a local version.
- Delete stale notes instead of explaining history.

---

# CopyWatch — Project Root

A free macOS app (SwiftUI + SwiftPM) that copies files to a destination, verifies
every file byte-for-byte against the source, and keeps a permanent, resumable
record of every backup — organized around user-defined Projects and camera-card
imports, with a scriptable `--headless` CLI mode alongside the GUI.

## Stack & Conventions

- Language / runtime: Swift 6.0 toolchain, Swift language mode 5, SwiftPM only
  (no external dependencies).
- Framework(s): SwiftUI (views + app lifecycle), AppKit interop where needed
  (`AppDelegate`), Foundation for filesystem/hashing work.
- Build: `swift build` (debug) or `./build.sh` (release `.app` bundle in `dist/`,
  ad-hoc signed by default). Tests: `swift test` (`Tests/CopyWatchTests`). Also
  verify by building and driving the actual flow (`--headless copy` /
  `--headless compare` for scriptable checks without the GUI).
- Code intelligence: query the CodeGraph symbol graph before reading files;
  noisy shell output is auto-compressed by the RTK Claude Code hook.
- One executable target (`CopyWatch`); everything lives under `Sources/CopyWatch`,
  split by *kind of work*, not by feature — see the Child DOX Index.

## Global Constraints (Non-Negotiable)

1. Never make destructive filesystem operations silent or irreversible from the
   user's point of view — "clear originals" always moves to Trash, never a
   permanent delete (`TrashFinder`), and verification always reads back from the
   destination disk, never from cache.
2. Checksums (SHA-256 / xxHash64) are the source of truth for "did this file
   copy correctly," not size/mtime alone — do not weaken a comparison to a
   cheaper heuristic without an explicit user-facing toggle.
3. Long-running work (copy, verify, benchmark) must remain resumable — do not
   introduce a code path that loses progress state on interruption (app quit,
   drive disconnect, sleep).
4. GUI (`Views`) must not embed engine logic (hashing, copy planning, device
   detection) — it calls into `Engine`/`System` and renders their state.

## Child DOX Index

Every top-level subsystem that owns a distinct kind of work should have its own
AGENTS.md and a row here. This table is the routing map for **Place Before
Building** — an unlisted directory is a placement smell.

| Scope | Path | Covers |
|---|---|---|
| App     | `Sources/CopyWatch/App/AGENTS.md`     | App lifecycle, entry point (`main.swift`), global `AppState`, headless CLI dispatch, formatting utilities |
| Engine  | `Sources/CopyWatch/Engine/AGENTS.md`  | Copy/verify/hash engine: copying, checksumming, reconciliation, MHL export, benchmarking, certificates |
| Models  | `Sources/CopyWatch/Models/AGENTS.md`  | Plain data model types shared across Engine/Store/Views |
| Store   | `Sources/CopyWatch/Store/AGENTS.md`   | Persistence of jobs/projects to disk |
| System  | `Sources/CopyWatch/System/AGENTS.md`  | macOS system integration: device/volume detection, Finder metadata, update checks |
| Views   | `Sources/CopyWatch/Views/AGENTS.md`   | SwiftUI presentation layer |

`Resources/` (Info.plist, entitlements, icons) and `dist/`/`.build/` (build
output) are build artifacts/static metadata, not a code subsystem — no AGENTS.md
needed there.
