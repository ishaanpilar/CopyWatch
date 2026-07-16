import Foundation

/// Identity of a disk volume, so a job can find its drives again after a remount.
struct VolumeRef: Codable, Hashable {
    var uuid: String?
    var name: String
    /// Mount point when the ref was captured, e.g. "/Volumes/SSD-A" or "/".
    var lastMountPath: String

    static func forPath(_ path: String) -> VolumeRef {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey, .volumeURLKey]
        let values = try? url.resourceValues(forKeys: keys)
        let mount = values?.volume?.path ?? "/"
        return VolumeRef(
            uuid: values?.volumeUUIDString,
            name: values?.volumeName ?? mount,
            lastMountPath: mount
        )
    }

    /// Mount point where this volume currently lives, or nil if not mounted.
    func currentMountPath() -> String? {
        guard let uuid else {
            return FileManager.default.fileExists(atPath: lastMountPath) ? lastMountPath : nil
        }
        let keys: [URLResourceKey] = [.volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []) ?? []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeUUIDString == uuid { return url.path }
        }
        return nil
    }

    /// Re-resolve an absolute path recorded on this volume, following the volume
    /// to its current mount point if it moved. Returns nil if the volume is gone.
    func resolve(_ recordedPath: String) -> String? {
        if FileManager.default.fileExists(atPath: recordedPath) { return recordedPath }
        guard let mount = currentMountPath() else { return nil }
        guard recordedPath.hasPrefix(lastMountPath) else { return nil }
        let relative = String(recordedPath.dropFirst(lastMountPath.count))
        let candidate = (mount as NSString).appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }
}
