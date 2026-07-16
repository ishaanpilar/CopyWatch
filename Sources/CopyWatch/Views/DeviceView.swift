import SwiftUI
import AppKit

/// Backup screen for a connected iPhone/camera: pick a destination and start a
/// tracked, checksummed download of the device's media (Camera Roll / DCIM).
struct DeviceView: View {
    @Environment(AppState.self) private var appState
    let deviceID: String
    let onJobCreated: (UUID) -> Void

    @State private var destParentPath = ""
    @State private var verify = true

    private var device: CameraDeviceInfo? {
        appState.devices.first { $0.id == deviceID }
    }

    private var deviceJobs: [CopyJob] {
        appState.jobs.filter { $0.sourceDeviceID == deviceID }
    }

    var body: some View {
        if let device {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone")
                            .font(.system(size: 40))
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(device.name).font(.title2.bold())
                            Text("Photos & videos (Camera Roll / DCIM)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if device.isLocked {
                        Label(
                            "The device is locked. Unlock it and tap “Trust” so its media can be read.",
                            systemImage: "lock.fill")
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    }

                    GroupBox("Back up this device") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Copy into")
                                TextField("Backup folder…", text: $destParentPath)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.callout.monospaced())
                                Button("Choose…") { pickDest() }
                            }
                            Toggle(isOn: $verify) {
                                Text("Checksum every file after download (SHA-256, kept in history)")
                            }
                            Button {
                                appState.createDeviceJob(
                                    deviceID: device.id,
                                    deviceName: device.name,
                                    destParentPath: destParentPath,
                                    verify: verify)
                                if let job = appState.jobs.first(where: {
                                    $0.sourceDeviceID == device.id && $0.status.isActive
                                }) {
                                    onJobCreated(job.id)
                                }
                            } label: {
                                Label("Start Backup", systemImage: "square.and.arrow.down.on.square")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(destParentPath.isEmpty)

                            Text("The device's media catalog is scanned into a manifest first, so interrupted backups resume — already-downloaded files are recognized and skipped.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }

                    if !deviceJobs.isEmpty {
                        GroupBox("Previous backups of this device") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(deviceJobs) { job in
                                    Button {
                                        onJobCreated(job.id)
                                    } label: {
                                        HStack {
                                            StatusBadge(status: job.status)
                                            Text(job.name)
                                            Spacer()
                                            Text("\(job.doneFiles)/\(job.totalFiles) files")
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(6)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(device.name)
        } else {
            ContentUnavailableView(
                "Device disconnected",
                systemImage: "iphone.slash",
                description: Text("Reconnect the device to back it up. Interrupted backups stay in the sidebar and resume when it returns."))
        }
    }

    private func pickDest() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            destParentPath = url.path
        }
    }
}
