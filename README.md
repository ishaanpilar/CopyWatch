<p align="center">
  <img src=".github/social-preview.png" alt="CopyWatch — Verified, resumable backups for people who can't afford to lose a single file." width="100%">
</p>

# CopyWatch

**A free Mac app that copies your files and actually tells you whether it worked.**

If you've ever dragged a folder full of photos or video onto a hard drive and just *hoped* it all made it — CopyWatch is for you. It copies your files, double-checks every single one against the original, and keeps a permanent record so you never have to wonder again.

## Why this exists

Copying files in Finder is a black box. It shows you a progress bar, and then it's done — or it isn't, and you find out weeks later that half your wedding footage never made it to the backup drive. If the drive disconnects halfway through, or your Mac goes to sleep, or you accidentally quit the copy, Finder just... stops, and you're left guessing what actually transferred.

CopyWatch was built to remove the guesswork:

- It **checks every file it copies**, byte for byte, so a "successful" copy is actually verified — not just assumed.
- If something goes wrong partway through, it **remembers exactly where it stopped** and picks up from there — even if that's tomorrow, on a different Mac, after the drive got moved somewhere else.
- It keeps a **permanent history** of every backup you've ever run, so you can always look back and confirm what got copied, when, and whether it's still intact.

## What it can do

- **Copy folders or individual files** to any drive, with a live progress view.
- **Verify** every file after copying, so silent corruption gets caught immediately instead of months later.
- **Resume interrupted copies** — stop today, plug the drive back in tomorrow, and it continues exactly where it left off (even mid-way through a single huge video file).
- **Rescue a copy Finder already messed up** — point CopyWatch at a destination that has a half-finished Finder copy sitting in it, and it'll figure out what's already there and finish the job properly.
- **Compare two folders** to see, at a glance, whether they truly match — same files, same sizes, nothing missing or corrupted.
- **Back up an iPhone or camera** — browse its photos and videos like a gallery and pick exactly what to copy.
- **Double-check itself, anytime** — hit "Recheck" on any past backup to confirm the destination still matches, even if it's been weeks. If a file went missing (even if it just got dragged to the Trash), CopyWatch will tell you and offer to fix it.
- **Free up space safely** — once a backup is fully verified, CopyWatch can move the original files to the Trash for you (never a permanent delete) so you can reuse the card or drive.

## Install it

**Easiest way — Homebrew:**

```sh
brew tap ishaanpilar/tap
brew install --cask copywatch
```

**Or download directly:** grab the latest `.dmg` from the [Releases page](https://github.com/ishaanpilar/CopyWatch/releases/latest), open it, and drag CopyWatch into your Applications folder.

> **First launch note:** CopyWatch isn't (yet) signed with an Apple Developer certificate, so macOS will warn you the first time you open it. Right-click the app and choose **Open**, then confirm — you'll only need to do this once.

## Using it

1. Open CopyWatch and click **+ New Copy Job**.
2. Choose where you're copying **from** (a folder, or select individual files) and where you're copying **to**.
3. Click **Start Copy**. CopyWatch scans everything first so it knows exactly how much work there is, then copies and verifies each file.
4. When it's done, you'll see a green **"Everything is good"** — every file made it and matches the original.

If a drive disconnects, or you quit the app, or your Mac restarts — just open CopyWatch again and hit **Resume**. Nothing is lost, and nothing gets copied twice.

Backing up an iPhone or camera works the same way: connect it, find it under **Devices** in the sidebar, and pick what you want backed up.

## Frequently asked questions

**Do I need to know anything technical to use this?**
No. Everything above is the whole app — pick a source, pick a destination, click Start. The one exception is if you want to build it yourself from source, which is covered further down for the curious.

**Is this safe to use for something important, like footage I can't reshoot?**
That's exactly the situation it's built for. Every copy is verified against the original before CopyWatch calls it done, and nothing is ever deleted from your source files unless you explicitly ask it to (and even then, files go to the Trash, not straight to permanent deletion).

**What's the difference between this and just dragging files in Finder?**
Finder doesn't check its own work, doesn't tell you what specifically failed if something goes wrong, and can't resume an interrupted copy — you'd have to start over and hope you can tell what's already there. CopyWatch does all three.

**Does it cost anything?**
No — it's free and open source.

**Does it work with SD cards, external SSDs, USB drives?**
Yes, any drive that shows up on your Mac. iPhones and cameras are supported too, through a separate flow since they don't work like normal drives.

---

## For developers

The rest of this section is for people who want to build CopyWatch from source or contribute to it — not needed to just use the app.

### Build & run

```sh
./build.sh          # → dist/CopyWatch.app
open dist/CopyWatch.app
```

Requires macOS 14+ and Xcode command-line tools. No external dependencies — it's a plain SwiftPM executable target, no `.xcodeproj`.

### Headless mode (testing / scripting)

```sh
CopyWatch --headless copy <source> <destParent> [--no-verify]
CopyWatch --headless compare <a> <b> [--deep]
```

Headless jobs are saved to the same history the app shows.

### Code layout

- `Sources/CopyWatch/Engine/` — scanner, checksummer, reconciler, and the copy engine (chunked copy, mid-file resume, verify).
- `Sources/CopyWatch/Models/` + `Store/` — job/manifest models, JSON persistence in `~/Library/Application Support/CopyWatch/`.
- `Sources/CopyWatch/System/` — volume mount/unmount watching, eject, sleep blocking, notifications, Trash search.
- `Sources/CopyWatch/Views/` — SwiftUI: sidebar, job detail with comparison dashboard, compare tool, new-job sheet, device gallery.

### Roadmap

- Passive Finder-activity logger (best-effort history of copies made outside CopyWatch).
- xxHash64 + MHL manifest export for postproduction-standard interchange.
- Multiple simultaneous destinations per source (card → two backups in one pass).
- Code signing & notarization, to remove the Gatekeeper warning on first launch.

### Contributing

Issues and pull requests are welcome — see the [issue tracker](https://github.com/ishaanpilar/CopyWatch/issues).

---

<p align="center"><sub>Created by Ishaan Pilar</sub></p>
