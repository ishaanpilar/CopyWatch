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

    func createJob(sourcePath: String, destParentPath: String, verify: Bool) {
        let destPath = (destParentPath as NSString)
            .appendingPathComponent((sourcePath as NSString).lastPathComponent)
        var job = CopyJob(
            id: UUID(),
            name: CopyJob.defaultName(source: sourcePath, dest: destPath),
            sourceVolume: .forPath(sourcePath),
            destVolume: .forPath(destParentPath),
            sourcePath: sourcePath,
            destPath: destPath
        )
        job.verifyAfterCopy = verify
        job.status = .scanning
        jobs.insert(job, at: 0)
        store.save(job, force: true)

        let jobID = job.id
        scanTasks[jobID] = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let records = try Scanner.scan(root: URL(fileURLWithPath: sourcePath)) { count, bytes in
                    Task { @MainActor [weak self] in
                        self?.mutateJob(jobID) { j in
                            j.totalFiles = count
                            j.totalBytes = bytes
                        }
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.mutateJob(jobID) { j in
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

    /// Create a backup job for an iPhone/camera. The manifest is read from the
    /// device's media catalog on first run.
    func createDeviceJob(deviceID: String, deviceName: String, destParentPath: String, verify: Bool) {
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
