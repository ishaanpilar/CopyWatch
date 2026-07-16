import Foundation
import AppKit

struct MountedVolume: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let uuid: String?
    let isInternal: Bool
    let isEjectable: Bool
}

/// Watches volume mounts/unmounts and keeps a list of connected drives.
@MainActor
final class VolumeWatcher {
    var onMount: ((MountedVolume) -> Void)?
    var onUnmount: ((String) -> Void)?  // path that disappeared
    private(set) var volumes: [MountedVolume] = []
    var volumesChanged: (() -> Void)?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                   let vol = self.volumes.first(where: { $0.path == url.path }) {
                    self.onMount?(vol)
                }
            }
        }
        center.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    self.onUnmount?(url.path)
                }
            }
        }
        refresh()
    }

    func refresh() {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey, .volumeNameKey, .volumeIsInternalKey,
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.volumeIsBrowsable == true else { return nil }
            return MountedVolume(
                path: url.path,
                name: v.volumeName ?? url.lastPathComponent,
                uuid: v.volumeUUIDString,
                isInternal: v.volumeIsInternal ?? false,
                isEjectable: (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false)
            )
        }
        volumesChanged?()
    }

    func eject(_ volume: MountedVolume) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume.path))
    }
}
