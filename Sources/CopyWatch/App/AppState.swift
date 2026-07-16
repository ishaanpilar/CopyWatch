import Foundation
import SwiftUI
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
    /// structure to avoid collisions).
    func createJob(sourcePaths: [String], destParentPath: String, verify: Bool) {
        guard !sourcePaths.isEmpty else { return }
        let isSingleFolder = sourcePaths.count == 1
            && (try? URL(fileURLWithPath: sourcePaths[0]).resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true

        // Placeholder root/dest until the scan resolves the real common ancestor;
        // refined below once scanSelection returns.
        let provisionalName = isSingleFolder
            ? CopyJob.defaultName(
                source: sourcePaths[0],
                dest: (destParentPath as NSString).appendingPathComponent(
                    (sourcePaths[0] as NSString).lastPathComponent))
            : "\(sourcePaths.count) items → \((destParentPath as NSString).lastPathComponent)"

        var job = CopyJob(
            id: UUID(),
            name: provisionalName,
            sourceVolume: .forPath(sourcePaths[0]),
            destVolume: .forPath(destParentPath),
            sourcePath: sourcePaths[0],
            destPath: destParentPath
        )
        job.verifyAfterCopy = verify
        job.status = .scanning
        jobs.insert(job, at: 0)
        store.save(job, force: true)

        let jobID = job.id
        scanTasks[jobID] = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (root, records) = try Scanner.scanSelection(paths: sourcePaths)
                let destPath = (destParentPath as NSString).appendingPathComponent(
                    isSingleFolder ? (root as NSString).lastPathComponent : "Selected Files")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.mutateJob(jobID) { j in
                        j.sourcePath = root
                        j.destPath = destPath
                        j.sourceVolume = .forPath(root)
                        j.name = isSingleFolder
                            ? CopyJob.defaultName(source: root, dest: destPath)
                            : "\(sourcePaths.count) items → \((destParentPath as NSString).lastPathComponent)"
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
        jobs.removeAll { $0.id == jobID }
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
                Notifier.notify(
                    title: "Backup verified ✓",
                    body: "\(snapshot.name): \(snapshot.totalFiles) files, \(Format.bytes(snapshot.totalBytes))")
            case .completedWithErrors:
                engines[snapshot.id] = nil
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
    var restoreRunning: Set<UUID> = []

    /// Re-check every manifest file against the destination's current state.
    /// Files that vanished or changed since the copy are flagged and reset to
    /// pending, and the job becomes resumable — Resume then re-copies exactly
    /// those files (the repair). Files also gone from the source are marked
    /// failed UNLESS a matching copy is found sitting in the Trash, in which
    /// case they're offered a direct restore instead of a recopy.
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
        let sourceRoot = job.isDeviceJob ? nil : job.sourceVolume.resolve(job.sourcePath)
        Task.detached(priority: .userInitiated) { [weak self, job] in
            var job = job
            let destRoot = URL(fileURLWithPath: dst)
            let fm = FileManager.default
            var missing = 0, changed = 0, unrestorable = 0
            var foundInTrash: [String: URL] = [:]

            for i in job.files.indices where job.files[i].isDone {
                let state = Reconciler.classify(job.files[i], destRoot: destRoot)
                guard state != .match else { continue }
                if state == .missing { missing += 1 } else { changed += 1 }
                let sourceGone = sourceRoot.map {
                    !fm.fileExists(atPath: ($0 as NSString)
                        .appendingPathComponent(job.files[i].relativePath))
                } ?? false

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
                    job.files[i].error = "Missing at destination, and the source original is gone — nothing to restore from."
                    unrestorable += 1
                } else if trashMatch == nil {
                    job.files[i].status = .pending
                    job.files[i].error = nil
                    job.files[i].checksum = nil
                }
                // Files with a Trash match keep their prior status — they're
                // surfaced via trashCandidates and restored in place, not recopied.
                job.files[i].bytesCopied = 0
            }
            job.recomputeCounters()

            let restoredFromTrash = foundInTrash.count
            let problems = missing + changed - restoredFromTrash
            if problems == 0 && restoredFromTrash == 0 {
                if job.status == .interrupted && job.pendingFiles == 0 && job.failedFiles == 0 {
                    job.status = .completed
                }
                job.statusMessage = "Re-verified \(Date().formatted(date: .omitted, time: .shortened)) — destination matches the manifest."
            } else {
                job.status = problems > 0 && problems == unrestorable && restoredFromTrash == 0
                    ? .completedWithErrors : .interrupted
                var parts: [String] = []
                if missing + changed - restoredFromTrash > 0 || unrestorable > 0 {
                    parts.append("\(missing) missing, \(changed) changed at the destination.")
                }
                let repairable = problems - unrestorable
                if repairable > 0 {
                    parts.append("Press Repair to re-copy \(repairable) file(s).")
                }
                if restoredFromTrash > 0 {
                    parts.append("\(restoredFromTrash) found in the Trash — restore below.")
                }
                if unrestorable > 0 {
                    parts.append("\(unrestorable) also gone from the source.")
                }
                job.statusMessage = parts.joined(separator: " ")
            }

            let finalJob = job
            let finalTrashCandidates = foundInTrash
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.recheckRunning.remove(jobID)
                self.trashCandidates[jobID] = finalTrashCandidates.isEmpty ? nil : finalTrashCandidates
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
}
