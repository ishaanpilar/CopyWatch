import Foundation
import ImageCaptureCore

/// One folder of a device's media catalog, e.g. "DCIM/100APPLE".
struct CatalogFolder: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let files: [FileRecord]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

enum CatalogLoadState: Equatable {
    case idle, loading, ready
    case failed(String)
}

/// Snapshot handed to SwiftUI.
struct CatalogSnapshot {
    var state: CatalogLoadState = .idle
    var folders: [CatalogFolder] = []
    var totalFiles: Int { folders.reduce(0) { $0 + $1.files.count } }
    var totalBytes: Int64 { folders.reduce(0) { $0 + $1.totalBytes } }
}

/// Opens a session on an iPhone/camera and reads its media catalog so the user
/// can pick specific folders/files BEFORE creating a backup job.
@MainActor
final class DeviceCatalog: NSObject {
    let device: ICCameraDevice
    var onChange: ((CatalogSnapshot) -> Void)?
    /// Delivers a thumbnail for a manifest path as the device provides it.
    var onThumbnail: ((String, CGImage) -> Void)?
    private(set) var snapshot = CatalogSnapshot()
    private var timeoutTask: Task<Void, Never>?
    private var filesByPath: [String: ICCameraFile] = [:]
    private var pathsByItem: [ObjectIdentifier: String] = [:]
    private var thumbnailRequested = Set<String>()

    init(device: ICCameraDevice) {
        self.device = device
        super.init()
    }

    func load() {
        snapshot.state = .loading
        publish()
        device.delegate = self
        if device.hasOpenSession, device.mediaFiles?.isEmpty == false {
            build()
            return
        }
        device.requestOpenSession()
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, self.snapshot.state == .loading else { return }
            self.fail("Timed out reading the device. Unlock it, tap “Trust”, and try again.")
        }
    }

    /// Ask the device for a small preview image of one file (no-op if already
    /// requested). Result arrives via `onThumbnail`.
    func requestThumbnail(for path: String) {
        guard let file = filesByPath[path], !thumbnailRequested.contains(path) else { return }
        thumbnailRequested.insert(path)
        if let existing = file.thumbnail {
            onThumbnail?(path, existing)
        } else {
            file.requestThumbnail()
        }
    }

    private func build() {
        timeoutTask?.cancel()
        let pairs = CameraJobEngine.makeRecordPairs(from: device)
        filesByPath = Dictionary(uniqueKeysWithValues: pairs.map { ($0.record.relativePath, $0.file) })
        pathsByItem = Dictionary(uniqueKeysWithValues: pairs.map { (ObjectIdentifier($0.file), $0.record.relativePath) })
        let records = pairs.map(\.record)
        let grouped = Dictionary(grouping: records) { record -> String in
            let dir = (record.relativePath as NSString).deletingLastPathComponent
            return dir.isEmpty ? "Media" : dir
        }
        snapshot.folders = grouped
            .map { CatalogFolder(path: $0.key, files: $0.value) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        snapshot.state = .ready
        publish()
    }

    private func fail(_ message: String) {
        timeoutTask?.cancel()
        snapshot.state = .failed(message)
        publish()
    }

    private func publish() {
        onChange?(snapshot)
    }
}

extension DeviceCatalog: ICCameraDeviceDelegate {
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in self.build() }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            Task { @MainActor in self.fail(error.localizedDescription) }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in self.fail("The device was disconnected.") }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in
            self.fail("The device is locked. Unlock it and tap “Trust”, then try again.")
        }
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in self.load() }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(
        _ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem, error: Error?) {
        guard let thumbnail else { return }
        let key = ObjectIdentifier(item)
        Task { @MainActor in
            if let path = self.pathsByItem[key] {
                self.onThumbnail?(path, thumbnail)
            }
        }
    }
    nonisolated func cameraDevice(
        _ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}
