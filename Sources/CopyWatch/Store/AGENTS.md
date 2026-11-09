# Store

## Purpose

Persistence of application data to disk — currently job/project state so a
copy can be resumed and history survives an app restart.

## Scope & Boundaries

- Owns: `JobStore.swift` (saving/loading `CopyJob` headers as JSON, one-time
  migration of old job files) and `ManifestStore.swift` (each job's file
  manifest in SQLite, one database per job under `manifests/`).
- Does NOT own: deciding *when* to save (that's `Engine` calling `store.save`
  with a snapshot) or what the persisted shape looks like beyond serialization
  (the shape is defined in `Models`).
- New work of kind "persist X to disk / load X back" goes here. A new
  persisted entity gets its own store file (e.g. a hypothetical
  `ProjectStore.swift`) rather than growing `JobStore` into a catch-all.

## Conventions

- A save must be safe to call mid-copy (partial progress) — never assume the
  snapshot represents a finished job.
- Do not perform hashing, copying, or device queries here — take fully-formed
  `Models` values in, write them out (and the reverse for load).
- Job JSON never contains the manifest. Anything needing `job.files` loads it
  with `JobStore.hydrated`, and treats nil as "unreadable", never as empty.

## Child DOX Index

(leaf — no child AGENTS.md)
