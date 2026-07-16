import Foundation
import SwiftUI
import AppKit
import Observation
import ImageCaptureCore

struct CameraDeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let isLocked: Bool
}

@MainActor
@Observable
final class AppState {
    var jobs: [CopyJob] = []
    var comparisons: [ComparisonRecord] = []
    var volumes: [MountedVolume] = []
    var devices: [CameraDeviceInfo] = []
    var destinationPresets: [DestinationPreset] = []

    let store: JobStore
    @ObservationIgnored private var engines: [UUID: any JobRunning] = [:]
    @ObservationIgnored private var scanTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let sleepBlocker = SleepBlocker()
    @ObservationIgnored private(set) var volumeWatcher: VolumeWatcher!
    @ObservationIgnored private(set) var deviceWatcher: DeviceWatcher!

    init(store: JobStore = JobStore()) {
        self.store = store
        jobs = store.loadJobs().sorted { $0.createdAt > $1.createdAt }
        comparisons = store.loadComparisons().sorted { $0.date > $1.date }
        destinationPresets = store.loadDestinations()

        // Anything that claimed to be moving when the app died was interrupted.
        for i in jobs.indices {
            switch jobs[i].status {
            case .running, .paused:
                jobs[i].status = .interrupted
                jobs[i].statusMessage = "The app quit while this job was running. Resume to continue."
                store.save(jobs[i], force: true)
            case .scanning, .ready:
                jobs[i].status = .cancelled
                store.save(jobs[i], force: true)
            default: break
            }
        }

        volumeWatcher = VolumeWatcher()
        volumes = volumeWatcher.volumes
        volumeWatcher.volumesChanged = { [weak self] in
            guard let self else { return }
            self.volumes = self.volumeWatcher.volumes
        }
        volumeWatcher.onMount = { [weak self] vol in self?.volumeReturned(vol) }
        volumeWatcher.onUnmount = { [weak self] path in self?.volumeLost(path) }

        deviceWatcher = DeviceWatcher()
        deviceWatcher.changed = { [weak self] in self?.refreshDevices() }
        deviceWatcher.onDeviceConnected = { [weak self] camera in self?.deviceReturned(camera) }
        refreshDevices()
    }

    var activeJobs: [CopyJob] { jobs.filter { $0.status.isActive } }
    var historyJobs: [CopyJob] { jobs.filter { !$0.status.isActive } }
    var anyJobRunning: Bool { jobs.contains { $0.status == .running || $0.status == .scanning } }

    // MARK: Job lifecycle

    /// Create a job from one or more selected sources — a single folder (the
    /// common case), or a mix of individual files and folders picked together
    /// (Scanner.scanSelection finds their common ancestor and preserves enough
    /// structure to avoid collisions). Pass more than one `destParentPaths` to
    /// back up the same source to several drives in one pass.
    func createJob(sourcePaths: [String], destParentPaths: [String], verify: Bool) {
        guard !sourcePaths.isEmpty, let primaryParent = destParentPaths.first else { return }
        let isSingleFolder = sourcePaths.count == 1
            && (try? URL(fileURLWithPath: sourcePaths[0]).resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
        let extraParents = Array(destParentPaths.dropFirst())

        // Placeholder root/dest until the scan resolves the real common ancestor;
        // refined below once scanSelection returns.
        let provisionalName = isSingleFolder
            ? CopyJob.defaultName(
                source: sourcePaths[0],
                dest: (primaryParent as NSString).appendingPathComponent(
                    (sourcePaths[0] as NSString).lastPathComponent))
            : "\(sourcePaths.count) items → \((primaryParent as NSString).lastPathComponent)"

        var job = CopyJob(
            id: UUID(),
            name: provisionalName,
            sourceVolume: .forPath(sourcePaths[0]),
            destVolume: .forPath(primaryParent),
            sourcePath: sourcePaths[0],
            destPath: primaryParent
        )
        job.verifyAfterCopy = verify
        job.status = .scanning
        jobs.insert(job, at: 0)
        store.save(job, force: true)

        let jobID = job.id
        scanTasks[jobID] = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (root, records) = try Scanner.scanSelection(paths: sourcePaths)
                // A single folder keeps its name at each destination; loose files
                // (or a mixed selection) land directly in the chosen folder, the
                // way Finder drops them — no artificial wrapper folder.
                func destPath(in parent: String) -> String {
                    isSingleFolder
                        ? (parent as NSString).appendingPathComponent((root as NSString).lastPathComponent)
                        : parent
                }
                let primaryDest = destPath(in: primaryParent)
                let extras = extraParents.map {
                    JobDestination(volume: .forPath($0), path: destPath(in: $0))
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.mutateJob(jobID) { j in
                        j.sourcePath = root
                        j.destPath = primaryDest
                        j.extraDestinations = extras
                        j.sourceVolume = .forPath(root)
                        let destLabel = extras.isEmpty
                            ? (primaryParent as NSString).lastPathComponent
                            : "\(destParentPaths.count) drives"
                        j.name = isSingleFolder && extras.isEmpty
                            ? CopyJob.defaultName(source: root, dest: primaryDest)
                            : "\(isSingleFolder ? (root as NSString).lastPathComponent : "\(sourcePaths.count) items") → \(destLabel)"
                        j.files = records
                        j.totalFiles = records.count
                        j.totalBytes = records.reduce(0) { $0 + $1.size }
                        j.status = .ready
                    }
                    self.scanTasks[jobID] = nil
                    self.start(jobID)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.mutateJob(jobID) { j in
                        j.status = .cancelled
                        j.statusMessage = "Scan failed: \(error.localizedDescription)"
                    }
                    self?.scanTasks[jobID] = nil
                }
            }
        }
    }

    func start(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        guard job.status == .ready || job.status == .paused
                || job.status == .interrupted || job.status == .waitingForVolume else { return }

        let engine: any JobRunning
        if let deviceID = job.sourceDeviceID {
            guard let camera = deviceWatcher.camera(withID: deviceID) else {
                mutateJob(jobID) { j in
                    j.status = .waitingForVolume
                    j.statusMessage = "Connect “\(job.sourceVolume.name)” (and unlock it) to continue."
                }
                return
            }
            engine = CameraJobEngine(job: job, device: camera) { [weak self] snapshot in
                self?.apply(snapshot)
            }
        } else {
            engine = JobEngine(job: job) { [weak self] snapshot in
                Task { @MainActor [weak self] in self?.apply(snapshot) }
            }
        }
        engines[jobID] = engine
        engine.start()
        sleepBlocker.setActive(true)
    }

    /// Create a backup job for an iPhone/camera. Pass `manifest` to back up a
    /// specific selection of the device's files; nil backs up the whole media
    /// catalog (read on first run).
    func createDeviceJob(
        deviceID: String, deviceName: String, destParentPath: String,
        verify: Bool, manifest: [FileRecord]? = nil
    ) {
        let folderName = deviceName.replacingOccurrences(of: "/", with: "-")
        let destPath = (destParentPath as NSString).appendingPathComponent(folderName)
        var job = CopyJob(
            id: UUID(),
            name: "\(deviceName) → \((destParentPath as NSString).lastPathComponent)",
            sourceVolume: VolumeRef(uuid: nil, name: deviceName, lastMountPath: ""),
            destVolume: .forPath(destParentPath),
            sourcePath: "Device media (Camera Roll / DCIM)",
            destPath: destPath
        )
        job.sourceDeviceID = deviceID
        job.verifyAfterCopy = verify
        if let manifest {
            job.files = manifest
            job.totalFiles = manifest.count
            job.totalBytes = manifest.reduce(0) { $0 + $1.size }
            job.sourcePath = "Selected device media (\(manifest.count) files)"
        }
        job.status = .ready
        jobs.insert(job, at: 0)
        store.save(job, force: true)
        start(job.id)
    }

    func pause(_ jobID: UUID) { engines[jobID]?.pause() }

    func cancel(_ jobID: UUID) {
        if let engine = engines[jobID] {
            engine.cancel()
        } else if let scan = scanTasks[jobID] {
            scan.cancel()
            scanTasks[jobID] = nil
            mutateJob(jobID) { $0.status = .cancelled }
        } else {
            mutateJob(jobID) { j in
                j.status = .cancelled
                j.completedAt = Date()
            }
        }
    }

    func delete(_ jobID: UUID) {
        cancel(jobID)
        engines[jobID] = nil
        if let job = jobs.first(where: { $0.id == jobID }) {
            store.delete(job)
        }
        try? FileManager.default.removeItem(at: Certificate.url(for: jobID))
        jobs.removeAll { $0.id == jobID }
    }

    // MARK: Integrity certificates

    private func generateCertificate(for job: CopyJob) {
        Task.detached(priority: .utility) { Certificate.generate(for: job) }
    }

    func hasCertificate(_ jobID: UUID) -> Bool { Certificate.exists(for: jobID) }

    /// Open the certificate in the browser (generating it on demand if needed).
    func openCertificate(for job: CopyJob) {
        let url = Certificate.exists(for: job.id)
            ? Certificate.url(for: job.id)
            : Certificate.generate(for: job)
        NSWorkspace.shared.open(url)
    }

    /// Export a copy of the certificate to a user-chosen location.
    func exportCertificate(for job: CopyJob, to destination: URL) {
        let src = Certificate.exists(for: job.id)
            ? Certificate.url(for: job.id)
            : Certificate.generate(for: job)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: src, to: destination)
    }

    private func apply(_ snapshot: CopyJob) {
        guard let index = jobs.firstIndex(where: { $0.id == snapshot.id }) else { return }
        let oldStatus = jobs[index].status
        jobs[index] = snapshot
        store.save(snapshot, force: oldStatus != snapshot.status)

        if oldStatus != snapshot.status {
            switch snapshot.status {
            case .completed:
                engines[snapshot.id] = nil
                generateCertificate(for: snapshot)
                Notifier.notify(
                    title: "Backup verified ✓",
                    body: "\(snapshot.name): \(snapshot.totalFiles) files, \(Format.bytes(snapshot.totalBytes))")
            case .completedWithErrors:
                engines[snapshot.id] = nil
                generateCertificate(for: snapshot)
                Notifier.notify(
                    title: "Backup finished with errors",
                    body: "\(snapshot.name): \(snapshot.failedFiles) file(s) failed.")
            case .cancelled:
                engines[snapshot.id] = nil
            case .waitingForVolume:
                Notifier.notify(
                    title: "Copy paused — drive disconnected",
                    body: "\(snapshot.name) will be resumable when the drive returns.")
            default: break
            }
        }
        sleepBlocker.setActive(anyJobRunning)
    }

    private func mutateJob(_ jobID: UUID, _ change: (inout CopyJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        change(&jobs[index])
        store.save(jobs[index], force: true)
    }

    /// Persist current engine snapshots (called when the app terminates).
    func flush() {
        for (_, engine) in engines { store.save(engine.job, force: true) }
    }

    // MARK: Volumes

    private func volumeReturned(_ volume: MountedVolume) {
        guard let uuid = volume.uuid else { return }
        for job in jobs where job.status == .waitingForVolume {
            if job.sourceVolume.uuid == uuid || job.destVolume.uuid == uuid {
                mutateJob(job.id) { j in
                    j.status = .interrupted
                    j.statusMessage = "Drive “\(volume.name)” is back — ready to resume."
                }
                Notifier.notify(
                    title: "Drive reconnected",
                    body: "“\(volume.name)” is back. “\(job.name)” is ready to resume.")
            }
        }
    }

    private func volumeLost(_ path: String) {
        for job in jobs where job.status == .running {
            if job.sourcePath.hasPrefix(path + "/") || job.destPath.hasPrefix(path + "/")
                || job.sourcePath == path || job.destPath == path {
                engines[job.id]?.suspendForMissingVolume()
            }
        }
    }

    // MARK: Re-verify a finished job against the drives as they are NOW

    var recheckRunning: Set<UUID> = []
    /// Trash matches found by the last recheck: jobID -> relativePath -> Trash URL.
    var trashCandidates: [UUID: [String: URL]] = [:]
    /// Files verified at the destination but missing from the source — can be
    /// copied back to the source ("Restore to Source"). jobID -> relative paths.
    var sourceMissingPaths: [UUID: [String]] = [:]
    var restoreRunning: Set<UUID> = []

    /// Re-check every manifest file against BOTH sides as they are right now:
    ///  - Destination missing/changed → reset to pending so Repair re-copies
    ///    them from the source (or restores from the Trash if that's where a
    ///    deleted destination file ended up).
    ///  - Source missing but destination intact → offered for "Restore to
    ///    Source" (copy the verified destination copy back). This is also how a
    ///    job whose source was cleared via "Free Up Source" reports that the
    ///    originals are gone, instead of falsely showing "everything is good".
    func recheck(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }),
              !job.status.isActive || job.status == .interrupted,
              !recheckRunning.contains(jobID) else { return }
        guard let dst = job.destVolume.resolve(job.destPath) else {
            mutateJob(jobID) {
                $0.statusMessage = "Cannot verify: destination drive “\($0.destVolume.name)” is not connected."
            }
            return
        }
        recheckRunning.insert(jobID)
        trashCandidates[jobID] = nil
        sourceMissingPaths[jobID] = nil
        let sourceRoot = job.isDeviceJob ? nil : job.sourceVolume.resolve(job.sourcePath)
        Task.detached(priority: .userInitiated) { [weak self, job] in
            var job = job
            let destRoot = URL(fileURLWithPath: dst)
            let fm = FileManager.default
            var missing = 0, changed = 0, unrestorable = 0
            var foundInTrash: [String: URL] = [:]
            var srcMissing: [String] = []

            for i in job.files.indices where job.files[i].isDone {
                let state = Reconciler.classify(job.files[i], destRoot: destRoot)
                // Only meaningful when the source drive is actually connected.
                let sourceGone = sourceRoot.map {
                    !fm.fileExists(atPath: ($0 as NSString)
                        .appendingPathComponent(job.files[i].relativePath))
                } ?? false

                if state == .match {
                    // Destination fine — does the original still exist at source?
                    if sourceGone { srcMissing.append(job.files[i].relativePath) }
                    continue
                }

                if state == .missing { missing += 1 } else { changed += 1 }
                var trashMatch: URL?
                if state == .missing {
                    trashMatch = TrashFinder.find(
                        fileName: (job.files[i].relativePath as NSString).lastPathComponent,
                        size: job.files[i].size, near: dst)
                    if let trashMatch {
                        foundInTrash[job.files[i].relativePath] = trashMatch
                    }
                }

                if sourceGone && trashMatch == nil {
                    job.files[i].status = .failed
                    job.files[i].error = "Gone from both the destination and the source — cannot recover."
                    unrestorable += 1
                } else if trashMatch == nil {
                    job.files[i].status = .pending
                    job.files[i].error = nil
                    job.files[i].checksum = nil
                }
                job.files[i].bytesCopied = 0
            }
            job.recomputeCounters()

            let restoredFromTrash = foundInTrash.count
            let destProblems = missing + changed
            let repairable = destProblems - unrestorable - restoredFromTrash
            let stamp = Date().formatted(date: .omitted, time: .shortened)

            // The destination-side detail goes in the status banner; the
            // source-side detail is carried entirely by its own action banner
            // (with the Restore to Source button), so it is not duplicated here.
            var parts: [String] = []
            if destProblems > 0 {
                parts.append("\(missing) missing, \(changed) changed at the destination.")
                if repairable > 0 { parts.append("Repair re-copies \(repairable) from the source.") }
                if restoredFromTrash > 0 { parts.append("\(restoredFromTrash) found in the Trash — restore below.") }
                if unrestorable > 0 { parts.append("\(unrestorable) gone from both sides — cannot recover.") }
            }

            // Status: interrupted if the destination itself needs work; otherwise
            // completed (source-only issues are surfaced via banner + button, not
            // by making the backup itself look broken).
            if destProblems == 0 {
                if job.status == .interrupted && job.pendingFiles == 0 && job.failedFiles == 0 {
                    job.status = .completed
                }
                job.statusMessage = srcMissing.isEmpty
                    ? "Re-verified \(stamp) — source and destination both match the manifest."
                    : nil
            } else {
                job.status = repairable == 0 && restoredFromTrash == 0 && unrestorable == destProblems
                    ? .completedWithErrors : .interrupted
                job.statusMessage = parts.joined(separator: " ")
            }

            let finalJob = job
            let finalTrash = foundInTrash
            let finalSrcMissing = srcMissing
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.recheckRunning.remove(jobID)
                self.trashCandidates[jobID] = finalTrash.isEmpty ? nil : finalTrash
                self.sourceMissingPaths[jobID] = finalSrcMissing.isEmpty ? nil : finalSrcMissing
                if let idx = self.jobs.firstIndex(where: { $0.id == jobID }) {
                    self.jobs[idx] = finalJob
                    self.store.save(finalJob, force: true)
                }
            }
        }
    }

    /// Copy verified destination files back to their original source location —
    /// undoes an over-eager "Free Up Source", or restores an accidentally
    /// deleted original. Re-checksums each restored file.
    func restoreToSource(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }),
              let paths = sourceMissingPaths[jobID], !paths.isEmpty,
              let dst = job.destVolume.resolve(job.destPath),
              !restoreRunning.contains(jobID) else { return }
        // The source root may be an empty (freed-up) folder that still exists,
        // or need recreating; resolve the volume, fall back to the recorded path.
        let srcRoot = job.sourceVolume.resolve(job.sourcePath) ?? job.sourcePath
        restoreRunning.insert(jobID)
        Task.detached(priority: .userInitiated) { [weak self, job] in
            var job = job
            let destRoot = URL(fileURLWithPath: dst)
            let sourceRoot = URL(fileURLWithPath: srcRoot)
            let fm = FileManager.default
            var restored = 0, failed = 0
            var failMsg: String?

            for relativePath in paths {
                let destURL = destRoot.appendingPathComponent(relativePath)
                let srcURL = sourceRoot.appendingPathComponent(relativePath)
                guard fm.fileExists(atPath: destURL.path) else { failed += 1; continue }
                do {
                    try fm.createDirectory(
                        at: srcURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: srcURL.path) { try fm.removeItem(at: srcURL) }
                    try fm.copyItem(at: destURL, to: srcURL)
                    restored += 1
                } catch {
                    failed += 1
                    failMsg = error.localizedDescription
                }
            }
            // A full restore means the source is repopulated — the earlier
            // "Free Up Source" no longer applies.
            if failed == 0 {
                job.sourceTrashedAt = nil
                job.sourceTrashedCount = nil
            }
            job.statusMessage = failed == 0
                ? "Restored \(restored) file(s) to “\(job.sourceVolume.name)”. Source and destination match again."
                : "Restored \(restored) file(s); \(failed) could not be restored\(failMsg.map { " (\($0))" } ?? "")."

            let finalJob = job
            let allRestored = failed == 0
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.restoreRunning.remove(jobID)
                if allRestored { self.sourceMissingPaths[jobID] = nil }
                if let idx = self.jobs.firstIndex(where: { $0.id == jobID }) {
                    self.jobs[idx] = finalJob
                    self.store.save(finalJob, force: true)
                }
            }
        }
    }

    /// Move Trash-found files back to their destination location. Each is
    /// re-checksummed after landing so a corrupted or wrong-name Trash match
    /// never silently passes as verified.
    func restoreFromTrash(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }),
              let candidates = trashCandidates[jobID], !candidates.isEmpty,
              let dst = job.destVolume.resolve(job.destPath),
              !restoreRunning.contains(jobID) else { return }
        restoreRunning.insert(jobID)
        Task.detached(priority: .userInitiated) { [weak self, job] in
            var job = job
            let destRoot = URL(fileURLWithPath: dst)
            let fm = FileManager.default
            var restored = 0, failed = 0

            for (relativePath, trashURL) in candidates {
                guard let idx = job.files.firstIndex(where: { $0.relativePath == relativePath }) else { continue }
                let destURL = destRoot.appendingPathComponent(relativePath)
                do {
                    try fm.createDirectory(
                        at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
                    try fm.copyItem(at: trashURL, to: destURL)
                    let checksum = try FileHasher.sha256(of: destURL)
                    job.files[idx].checksum = checksum
                    job.files[idx].status = .verified
                    job.files[idx].bytesCopied = job.files[idx].size
                    job.files[idx].error = nil
                    restored += 1
                    try? fm.removeItem(at: trashURL)
                } catch {
                    job.files[idx].status = .failed
                    job.files[idx].error = "Restore from Trash failed: \(error.localizedDescription)"
                    failed += 1
                }
            }
            job.recomputeCounters()
            if job.pendingFiles == 0 && job.failedFiles == 0 {
                job.status = .completed
                job.statusMessage = "Restored \(restored) file(s) from the Trash. Destination matches the manifest again."
            } else {
                job.status = job.failedFiles > 0 ? .interrupted : job.status
                job.statusMessage = failed > 0
                    ? "Restored \(restored) file(s); \(failed) could not be restored."
                    : "Restored \(restored) file(s) from the Trash."
            }

            let finalJob = job
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.restoreRunning.remove(jobID)
                self.trashCandidates[jobID] = nil
                if let idx = self.jobs.firstIndex(where: { $0.id == jobID }) {
                    self.jobs[idx] = finalJob
                    self.store.save(finalJob, force: true)
                }
            }
        }
    }

    // MARK: Source cleanup (move copied originals to Trash)

    var cleanupRunning: Set<UUID> = []

    /// Move a completed job's source files to the Trash (never a permanent
    /// delete). Each file gets a final safety check — its destination copy must
    /// still exist with the recorded size — before its original is trashed.
    func trashSourceFiles(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }),
              job.status == .completed, !job.isDeviceJob,
              job.sourceTrashedAt == nil, !cleanupRunning.contains(jobID) else { return }
        guard let src = job.sourceVolume.resolve(job.sourcePath),
              let dst = job.destVolume.resolve(job.destPath) else {
            mutateJob(jobID) {
                $0.statusMessage = "Cannot clean up: connect both the source and destination drives first."
            }
            return
        }
        cleanupRunning.insert(jobID)
        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            var trashed = 0
            var skipped = 0
            for record in job.files where record.isDone {
                let source = URL(fileURLWithPath: src).appendingPathComponent(record.relativePath)
                let dest = URL(fileURLWithPath: dst).appendingPathComponent(record.relativePath)
                guard let attrs = try? fm.attributesOfItem(atPath: dest.path),
                      (attrs[.size] as? NSNumber)?.int64Value == record.size,
                      fm.fileExists(atPath: source.path) else {
                    skipped += 1
                    continue
                }
                do {
                    try fm.trashItem(at: source, resultingItemURL: nil)
                    trashed += 1
                } catch {
                    skipped += 1
                }
            }
            let trashedCount = trashed
            let summary = skipped == 0
                ? "\(trashed) source files moved to the Trash. Empty the Trash to reclaim the space."
                : "\(trashed) source files moved to the Trash; \(skipped) left in place (missing or unverifiable at the destination)."
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cleanupRunning.remove(jobID)
                self.mutateJob(jobID) { j in
                    j.sourceTrashedAt = Date()
                    j.sourceTrashedCount = trashedCount
                    j.statusMessage = summary
                }
                Notifier.notify(title: "Source cleanup finished", body: summary)
            }
        }
    }

    // MARK: Devices (iPhone / camera)

    private func refreshDevices() {
        devices = deviceWatcher.cameras.map { camera in
            CameraDeviceInfo(
                id: deviceWatcher.deviceID(for: camera),
                name: camera.name ?? "Camera",
                isLocked: camera.isAccessRestrictedAppleDevice)
        }
    }

    private func deviceReturned(_ camera: ICCameraDevice) {
        let id = deviceWatcher.deviceID(for: camera)
        let name = camera.name ?? "Device"
        for job in jobs where job.status == .waitingForVolume && job.sourceDeviceID == id {
            mutateJob(job.id) { j in
                j.status = .interrupted
                j.statusMessage = "“\(name)” is back — ready to resume."
            }
            Notifier.notify(
                title: "Device reconnected",
                body: "“\(name)” is back. “\(job.name)” is ready to resume.")
        }
    }

    func jobsUsing(volumePath: String) -> [CopyJob] {
        jobs.filter { job in
            guard job.status == .running || job.status == .scanning else { return false }
            return job.sourcePath.hasPrefix(volumePath) || job.destPath.hasPrefix(volumePath)
        }
    }

    func eject(_ volume: MountedVolume) -> String? {
        guard jobsUsing(volumePath: volume.path).isEmpty else {
            return "A job is still using “\(volume.name)”. Pause it first."
        }
        do {
            try volumeWatcher.eject(volume)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Compare

    var compareRunning = false
    var compareStatus: String = ""

    func runCompare(pathA: String, pathB: String, deep: Bool) {
        guard !compareRunning else { return }
        compareRunning = true
        compareStatus = "Starting…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let report = try Reconciler.compare(
                    a: URL(fileURLWithPath: pathA),
                    b: URL(fileURLWithPath: pathB),
                    deep: deep
                ) { status in
                    Task { @MainActor [weak self] in self?.compareStatus = status }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.comparisons.insert(report, at: 0)
                    self.store.save(report)
                    self.compareRunning = false
                    self.compareStatus = ""
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.compareRunning = false
                    self?.compareStatus = "Compare failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func deleteComparison(_ id: UUID) {
        if let record = comparisons.first(where: { $0.id == id }) {
            store.delete(record)
        }
        comparisons.removeAll { $0.id == id }
    }

    // MARK: Destination presets

    func addDestinationPreset(name: String, paths: [String]) {
        guard let primary = paths.first else { return }
        let preset = DestinationPreset(
            id: UUID(), name: name, path: primary,
            extraPaths: Array(paths.dropFirst()), isDefault: destinationPresets.isEmpty)
        destinationPresets.append(preset)
        store.saveDestinations(destinationPresets)
    }

    func updateDestinationPreset(_ id: UUID, name: String, paths: [String]) {
        guard let idx = destinationPresets.firstIndex(where: { $0.id == id }),
              let primary = paths.first else { return }
        destinationPresets[idx].name = name
        destinationPresets[idx].path = primary
        destinationPresets[idx].extraPaths = Array(paths.dropFirst())
        store.saveDestinations(destinationPresets)
    }

    func removeDestinationPreset(_ id: UUID) {
        let wasDefault = destinationPresets.first { $0.id == id }?.isDefault ?? false
        destinationPresets.removeAll { $0.id == id }
        if wasDefault, !destinationPresets.isEmpty {
            destinationPresets[0].isDefault = true
        }
        store.saveDestinations(destinationPresets)
    }

    func setDefaultDestination(_ id: UUID) {
        for i in destinationPresets.indices {
            destinationPresets[i].isDefault = (destinationPresets[i].id == id)
        }
        store.saveDestinations(destinationPresets)
    }

    // MARK: Drag-and-drop / Finder service entry point

    /// Sources dropped onto the app (or sent from the Finder service) that are
    /// waiting for the user to choose a destination in the drop prompt.
    var pendingDrop: [String]?

    /// One entry point for the in-app drop zone and the Finder "Copy with
    /// CopyWatch" service. It never copies straight to a default — it always
    /// raises the drop prompt so the user confirms where each drop goes.
    func handleIncomingSources(_ paths: [String]) {
        let valid = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !valid.isEmpty else { return }
        pendingDrop = valid
    }

    /// Drop directly onto a specific destination preset (in the Destinations
    /// list) — an explicit choice, so it copies straight there without a prompt.
    func handleIncomingSources(_ paths: [String], destination preset: DestinationPreset) {
        let valid = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !valid.isEmpty else { return }
        startCopy(valid, toFolders: preset.allPaths, label: preset.name)
    }

    /// Begin a copy of `paths` into one or more folders — used by the drop
    /// prompt for a chosen preset (possibly multi-destination) or a browsed folder.
    func startCopy(_ paths: [String], toFolders folders: [String], label: String? = nil) {
        guard !folders.isEmpty else { return }
        createJob(sourcePaths: paths, destParentPaths: folders, verify: true)
        let dest = label ?? (folders.count > 1
            ? "\(folders.count) drives"
            : (folders[0] as NSString).lastPathComponent)
        Notifier.notify(
            title: "Copy started",
            body: "\(paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) items") → \(dest)")
    }
}
