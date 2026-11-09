# Engine

## Purpose

The core copy/verify engine: everything that actually reads, writes, hashes,
and reconciles files, plus the artifacts a finished job produces (certificates,
MHL manifests, benchmarks).

## Scope & Boundaries

- Owns: `CopyEngine.swift` (job execution/orchestration), `Scanner.swift`
  (building a file manifest from a source root), `Checksum.swift` +
  `FileHasher.swift` (SHA-256 / xxHash64), `Reconciler.swift` (resuming
  interrupted copies, detecting partial/Finder-mangled destinations),
  `Certificate.swift` (integrity certificate generation), `MHL.swift` (Media
  Hash List export), `Benchmark.swift` + `SpeedAnalyzer.swift` (drive
  read/write speed measurement), `CopyError.swift` (the error taxonomy Views
  render as plain-language messages).
- Does NOT own: SwiftUI presentation (belongs to `Views`), persisting job state
  to disk (belongs to `Store`), device/volume enumeration (belongs to `System`,
  though Engine consumes `VolumeRef` from `Models`).
- New work of kind "how a copy/verify/hash/benchmark actually happens" goes
  here. A new checksum algorithm goes in `Checksum.swift`; a new failure mode
  goes in `CopyError.swift`, not a raw `Error` thrown ad hoc.

## Conventions

- Verification always reads back from the destination disk, never trusts the
  write-buffer/cache (Global Constraint — do not "optimize" this away).
- Long-running operations must report progress in a way `Store` can persist as
  a resumable snapshot — don't add a copy path that can't be interrupted and
  resumed.
- Progress snapshots must stay independent of the file count: `emit` strips the
  manifest, finished rows leave in batches via `onFilesChanged`, and
  `emit(force: true)` is for job status changes only.
- Parallel small-file workers only touch the disk; job state is merged on the
  engine's own thread. A batch's single `F_FULLFSYNC` must precede its verify
  reads, and a started batch is always verified.
- Checksums, not size/mtime, are the correctness signal; any cheaper shortcut
  needs an explicit user-facing toggle, not a silent default change.

## Child DOX Index

(leaf — no child AGENTS.md)
