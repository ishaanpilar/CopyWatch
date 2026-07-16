import Foundation
import ImageCaptureCore

/// Common interface for job runners (filesystem copies and device downloads).
@MainActor
protocol JobRunning: AnyObject {
    var job: CopyJob { get }
    func start()
    func pause()
    func cancel()
    func suspendForMissingVolume()
}

extension JobEngine: JobRunning {}

/// Runs a backup job whose source is an iPhone/camera (PTP media catalog).
/// Files are downloaded via ImageCaptureCore, checksummed on landing, and the
/// job resumes at file granularity (PTP has no partial-file reads).
@MainActor
final class CameraJobEngine: NSObject, JobRunning {
    private(set) var job: CopyJob
    private let device: ICCameraDevice
    private let onUpdate: (CopyJob) -> Void

    private var runTask: Task<Void, Never>?
    private enum StopIntent { case pause, cancel, waitForVolume }
    private var stopIntent: StopIntent?
    private var deviceGone = false

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var downloadContinuation: CheckedContinuation<String, Error>?

    private var lastEmit = Date.distantPast
    private var speedSamples: [(time: Date, bytes: Int64)] = []

    init(job: CopyJob, device: ICCameraDevice, onUpdate: @escaping (CopyJob) -> Void) {
        self.job = job
        self.device = device
        self.onUpdate = onUpdate
        super.init()
    }

    // MARK: Control

    func start() {
        guard runTask == nil else { return }
        stopIntent = nil
        runTask = Task { [self] in
            await run()
            runTask = nil
        }
    }

    func pause() { stop(.pause) }
    func cancel() { stop(.cancel) }
    func suspendForMissingVolume() { stop(.waitForVolume) }

    private func stop(_ intent: StopIntent) {
        stopIntent = intent
        device.cancelDownload()
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
        if runTask == nil {
            switch intent {
            case .pause: job.status = .paused
            case .cancel:
                job.status = .cancelled
                job.completedAt = Date()
            case .waitForVolume: job.status = .waitingForVolume
            }
            stopIntent = nil
            emit(force: true)
        }
    }

    // MARK: Main loop

    private func run() async {
        guard let destParent = job.destVolume.resolve(
            (job.destPath as NSString).deletingLastPathComponent) else {
            return finishWaiting("Destination drive “\(job.destVolume.name)” is not connected.")
        }
        job.destPath = (destParent as NSString)
            .appendingPathComponent((job.destPath as NSString).lastPathComponent)
        let destRoot = URL(fileURLWithPath: job.destPath)
        do {
            try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        } catch {
            return finishWaiting("Cannot create destination: \(error.localizedDescription)")
        }

        job.status = .running
        job.statusMessage = "Reading the device's media catalog… (unlock the device if asked)"
        emit(force: true)

        do {
            try await openSessionAndWaitForCatalog()
        } catch {
            return finishWaiting(deviceGone
                ? "The device was disconnected. Reconnect it to resume."
                : "Could not read the device: \(error.localizedDescription). Unlock it, tap “Trust”, and resume.")
        }

        // First run: build the manifest from the catalog. Later runs keep the
        // stored manifest so history and resume stay consistent.
        if job.files.isEmpty {
            job.files = buildManifest()
            job.totalFiles = job.files.count
            job.totalBytes = job.files.reduce(0) { $0 + $1.size }
        }
        for i in job.files.indices where job.files[i].status == .copying {
            job.files[i].status = .pending
        }
        job.statusMessage = nil
        Reconciler.reconcile(job: &job, destRoot: destRoot)
        recomputeCounters()
        speedSamples.removeAll()
        emit(force: true)

        let byPath = Dictionary(
            device.mediaFiles?.compactMap { item -> (String, ICCameraFile)? in
                guard let file = item as? ICCameraFile else { return nil }
                return (Self.relativePath(for: file), file)
            } ?? [],
            uniquingKeysWith: { first, _ in first })

        for i in job.files.indices where !job.files[i].isDone && job.files[i].status != .failed {
            if stopIntent != nil { return finishStopped() }
            guard let cameraFile = byPath[job.files[i].relativePath] else {
                job.files[i].status = .failed
                job.files[i].error = "No longer on the device."
                job.failedFiles += 1
                continue
            }
            do {
                try await downloadOneFile(at: i, cameraFile: cameraFile, destRoot: destRoot)
            } catch is CancellationError {
                return finishStopped()
            } catch {
                if deviceGone {
                    job.files[i].status = .pending
                    return finishWaiting("The device was disconnected mid-backup. Reconnect it to resume.")
                }
                if !FileManager.default.fileExists(atPath: destRoot.path) {
                    job.files[i].status = .pending
                    return finishWaiting("The destination drive disconnected. Reconnect it to resume.")
                }
                job.files[i].status = .failed
                job.files[i].error = error.localizedDescription
                job.failedFiles += 1
                emit(force: true)
            }
        }

        closeSession()
        job.currentFile = nil
        job.bytesPerSecond = 0
        job.completedAt = Date()
        job.status = job.failedFiles > 0 ? .completedWithErrors : .completed
        job.statusMessage = job.failedFiles > 0
            ? "\(job.failedFiles) file(s) failed — see the file list."
            : nil
        emit(force: true)
    }

    // MARK: Session / catalog

    private func openSessionAndWaitForCatalog() async throws {
        device.delegate = self
        if device.hasOpenSession, device.mediaFiles != nil {
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuation = cont
            device.requestOpenSession()
            // Don't wait forever on a locked phone.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                self?.failReady(NSError(
                    domain: "CopyWatch", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the device"]))
            }
        }
    }

    private func closeSession() {
        let device = self.device
        Task { try? await device.requestCloseSession() }
    }

    private func readyOK() {
        readyContinuation?.resume()
        readyContinuation = nil
    }

    private func failReady(_ error: Error) {
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
    }

    private func buildManifest() -> [FileRecord] {
        Self.makeRecords(from: device)
    }

    /// Flatten a device's media catalog into manifest records
    /// (shared with the pre-job catalog browser).
    static func makeRecords(from device: ICCameraDevice) -> [FileRecord] {
        var records: [FileRecord] = []
        var seen = Set<String>()
        for item in device.mediaFiles ?? [] {
            guard let file = item as? ICCameraFile else { continue }
            var path = relativePath(for: file)
            var n = 1
            while seen.contains(path) {
                n += 1
                path = relativePath(for: file) + " (\(n))"
            }
            seen.insert(path)
            records.append(FileRecord(
                relativePath: path,
                size: Int64(file.fileSize),
                modificationDate: file.modificationDate ?? file.creationDate ?? .distantPast))
        }
        records.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return records
    }

    static func relativePath(for file: ICCameraFile) -> String {
        var parts = [file.name ?? "unnamed"]
        var folder = file.parentFolder
        while let f = folder, let name = f.name, !name.isEmpty {
            parts.insert(name, at: 0)
            folder = f.parentFolder
        }
        return parts.joined(separator: "/")
    }

    // MARK: Download

    private func downloadOneFile(
        at index: Int, cameraFile: ICCameraFile, destRoot: URL
    ) async throws {
        let record = job.files[index]
        job.files[index].status = .copying
        job.currentFile = record.relativePath
        emit(force: true)

        let destURL = destRoot.appendingPathComponent(record.relativePath)
        let dir = destURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let started = Date()
        let savedName: String = try await withCheckedThrowingContinuation { cont in
            downloadContinuation = cont
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: dir,
                .saveAsFilename: destURL.lastPathComponent,
                .overwrite: true,
            ]
            device.requestDownloadFile(
                cameraFile,
                options: options,
                downloadDelegate: self,
                didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                contextInfo: nil)
        }

        let landedURL = dir.appendingPathComponent(savedName)
        // Keep the manifest's name even if the device renamed on save.
        if savedName != destURL.lastPathComponent {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: landedURL, to: destURL)
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: record.modificationDate], ofItemAtPath: destURL.path)

        let landedSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size]
                          as? NSNumber)?.int64Value ?? record.size
        job.doneBytes += landedSize - job.files[index].bytesCopied
        job.files[index].bytesCopied = landedSize
        job.files[index].status = .copied
        job.doneFiles += 1
        recordSpeed(delta: landedSize, since: started)

        if job.verifyAfterCopy {
            job.currentFile = "Checksumming: \(record.relativePath)"
            emit(force: true)
            let checksum = try await Task.detached(priority: .userInitiated) {
                try FileHasher.sha256(of: destURL)
            }.value
            job.files[index].checksum = checksum
            job.files[index].status = .verified
            job.verifiedFiles += 1
        }
        emit(force: true)
    }

    @objc nonisolated func didDownloadFile(
        _ file: ICCameraFile, error: Error?,
        options: [String: Any], contextInfo: UnsafeMutableRawPointer?
    ) {
        let saved = options[ICDownloadOption.savedFilename.rawValue] as? String
            ?? file.name ?? "unnamed"
        Task { @MainActor in
            let cont = self.downloadContinuation
            self.downloadContinuation = nil
            if let error {
                cont?.resume(throwing: error)
            } else {
                cont?.resume(returning: saved)
            }
        }
    }

    // MARK: Bookkeeping (mirrors JobEngine)

    private func recomputeCounters() {
        var doneFiles = 0, skipped = 0, verified = 0, failed = 0
        var doneBytes: Int64 = 0
        for f in job.files {
            switch f.status {
            case .copied, .verified, .skipped:
                doneFiles += 1
                doneBytes += f.size
                if f.status == .skipped { skipped += 1 }
                if f.status == .verified { verified += 1 }
            case .failed: failed += 1
            case .pending, .copying: doneBytes += f.bytesCopied
            }
        }
        job.doneFiles = doneFiles
        job.doneBytes = doneBytes
        job.skippedFiles = skipped
        job.verifiedFiles = verified
        job.failedFiles = failed
    }

    private func recordSpeed(delta: Int64, since: Date) {
        let now = Date()
        speedSamples.append((now, delta))
        speedSamples.removeAll { now.timeIntervalSince($0.time) > 10 }
        let window = max(now.timeIntervalSince(speedSamples.first?.time ?? since), 0.5)
        job.bytesPerSecond = Double(speedSamples.reduce(0) { $0 + $1.bytes }) / window
    }

    private func emit(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) > 0.5 else { return }
        lastEmit = now
        onUpdate(job)
    }

    private func finishStopped() {
        job.currentFile = nil
        job.bytesPerSecond = 0
        switch stopIntent {
        case .cancel:
            job.status = .cancelled
            job.completedAt = Date()
            closeSession()
        case .waitForVolume:
            job.status = .waitingForVolume
        case .pause, .none:
            job.status = .paused
        }
        stopIntent = nil
        emit(force: true)
    }

    private func finishWaiting(_ message: String) {
        job.currentFile = nil
        job.bytesPerSecond = 0
        job.status = .waitingForVolume
        job.statusMessage = message
        emit(force: true)
    }
}

// MARK: ImageCaptureCore delegates

extension CameraJobEngine: ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in self.readyOK() }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            Task { @MainActor in self.failReady(error) }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in
            self.deviceGone = true
            self.failReady(CancellationError())
            self.downloadContinuation?.resume(throwing: NSError(
                domain: "CopyWatch", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Device disconnected"]))
            self.downloadContinuation = nil
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(
        _ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(
        _ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
