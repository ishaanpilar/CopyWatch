# CopyWatch

A native macOS app for filmmakers and videographers who back up footage between drives and need to **know** — not hope — that every file made it.

CopyWatch is the copy engine (like Hedge or ShotPut Pro), which is what makes verification and resume possible: macOS offers no API to observe or resume Finder's own copies.

## What it does

- **Tracked copy jobs** — pick a source (camera card, SSD folder) and a destination; CopyWatch scans a full manifest, then copies every file with a streaming SHA-256 checksum.
- **Verification** — after each file is copied it is read back from the destination and its checksum compared. Silent corruption gets caught, not discovered months later.
- **Stop today, resume tomorrow** — quit the app, yank the drive, lose power: the job state is persisted every second. Reconnect the SSD (it's tracked by volume UUID, so the mount point can change) and resume from the exact byte where it stopped — a 90 GB clip interrupted at 80 GB does not restart from zero.
- **Rescue dead Finder copies** — point a job at a destination holding the greyed-out leftovers of a failed Finder copy. Complete files are recognized and skipped; a truncated file is prefix-verified against the source and continued, not recopied.
- **Compare Folders** — the check you'd do by hand (file counts, total sizes) plus exactly which files are missing, different, or extra. Deep mode checksums both sides.
- **History** — every job keeps its full manifest (paths, sizes, checksums, outcomes), exportable as CSV.
- **Drive-aware** — pauses automatically when a drive disconnects, tells you when it's back, ejects drives from the app (guarded while jobs run), keeps the Mac awake during copies, and notifies you when a backup finishes. The sidebar lists every mounted volume — internal disks, SSDs, hard disks, pen drives, SD cards.
- **iPhone & camera backup** — iPhones don't mount as drives (they speak the PTP camera protocol), so CopyWatch browses them via ImageCaptureCore. Connect an iPhone (unlock it and tap "Trust"), pick it under **Devices**, choose a destination, and its Camera Roll/DCIM media is downloaded with a full manifest, per-file checksums, and file-level resume. Note: macOS only exposes a device's media catalog (photos/videos), not its whole filesystem — the same limit Image Capture has.

## Build & run

```sh
./build.sh          # → dist/CopyWatch.app
open dist/CopyWatch.app
```

Requires macOS 14+ and Xcode command-line tools. No dependencies.

### Headless mode (testing / scripting)

```sh
CopyWatch --headless copy <source> <destParent> [--no-verify]
CopyWatch --headless compare <a> <b> [--deep]
```

Headless jobs are saved to the same history the app shows.

## Layout

- `Sources/CopyWatch/Engine/` — scanner, checksummer, reconciler, and the copy engine (chunked copy, mid-file resume, verify).
- `Sources/CopyWatch/Models/` + `Store/` — job/manifest models, JSON persistence in `~/Library/Application Support/CopyWatch/`.
- `Sources/CopyWatch/System/` — volume mount/unmount watching, eject, sleep blocking, notifications.
- `Sources/CopyWatch/Views/` — SwiftUI: sidebar, job detail with comparison dashboard, compare tool, new-job sheet.

## Roadmap

- Passive Finder-activity logger (best-effort history of copies made outside CopyWatch).
- xxHash64 + MHL manifest export for postproduction-standard interchange.
- Multiple simultaneous destinations per source (card → two backups in one pass).
