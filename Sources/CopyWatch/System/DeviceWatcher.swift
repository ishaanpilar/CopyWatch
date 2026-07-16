import Foundation
import ImageCaptureCore

/// Watches for iPhones, cameras, and other PTP media devices via ImageCaptureCore.
/// These never mount as volumes — they expose a media catalog (DCIM) instead.
@MainActor
final class DeviceWatcher: NSObject, ICDeviceBrowserDelegate {
    private let browser = ICDeviceBrowser()
    private(set) var cameras: [ICCameraDevice] = []
    var changed: (() -> Void)?
    var onDeviceConnected: ((ICCameraDevice) -> Void)?

    override init() {
        super.init()
        browser.delegate = self
        if let mask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue) {
            browser.browsedDeviceTypeMask = mask
        }
        browser.start()
    }

    func camera(withID id: String) -> ICCameraDevice? {
        cameras.first { deviceID(for: $0) == id }
    }

    func deviceID(for device: ICDevice) -> String {
        device.persistentIDString ?? device.serialNumberString ?? device.name ?? "unknown-device"
    }

    // MARK: ICDeviceBrowserDelegate

    nonisolated func deviceBrowser(
        _ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool
    ) {
        Task { @MainActor in
            guard let camera = device as? ICCameraDevice else { return }
            if !cameras.contains(where: { $0 === camera }) {
                cameras.append(camera)
            }
            changed?()
            onDeviceConnected?(camera)
        }
    }

    nonisolated func deviceBrowser(
        _ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool
    ) {
        Task { @MainActor in
            cameras.removeAll { $0 === device }
            changed?()
        }
    }
}
