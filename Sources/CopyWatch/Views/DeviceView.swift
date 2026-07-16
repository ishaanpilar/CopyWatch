import SwiftUI
import AppKit

/// Backup screen for a connected iPhone/camera. Browses the device's media
/// catalog (folders & files) so specific items can be selected, then creates a
/// tracked, checksummed backup job for exactly that selection.
struct DeviceView: View {
    @Environment(AppState.self) private var appState
    let deviceID: String
    let onJobCreated: (UUID) -> Void

    @State private var loader: DeviceCatalog?
    @State private var catalog = CatalogSnapshot()
    @State private var selected: Set<String> = []   // file relative paths
    @State private var destParentPath = ""
    @State private var verify = true

    private var device: CameraDeviceInfo? {
        appState.devices.first { $0.id == deviceID }
    }

    private var deviceJobs: [CopyJob] {
        appState.jobs.filter { $0.sourceDeviceID == deviceID }
    }

    private var runningJob: CopyJob? {
        deviceJobs.first { $0.status == .running }
    }

    private var selectedBytes: Int64 {
        catalog.folders.reduce(0) { sum, folder in
            sum + folder.files.filter { selected.contains($0.relativePath) }
                .reduce(0) { $0 + $1.size }
        }
    }

    var body: some View {
        if let device {
            VStack(alignment: .leading, spacing: 0) {
                header(device)
                Divider()
                catalogArea(device)
                Divider()
                footer(device)
            }
            .navigationTitle(device.name)
            .task(id: deviceID) { startLoading() }
        } else {
            ContentUnavailableView(
                "Device disconnected",
                systemImage: "iphone.slash",
                description: Text("Reconnect the device to browse and back up its media. Interrupted backups stay in the sidebar and resume when it returns."))
        }
    }

    // MARK: Header

    private func header(_ device: CameraDeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.system(size: 34))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text(device.name).font(.title2.bold())
                    Text("Photos & videos (Camera Roll / DCIM) — iPhones don't mount as disks, so media is read through the camera protocol, like Image Capture.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if device.isLocked {
                Label("The device is locked. Unlock it and tap “Trust” so its media can be read.",
                      systemImage: "lock.fill")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
            if !deviceJobs.isEmpty {
                HStack(spacing: 10) {
                    Text("Backups of this device:").font(.caption).foregroundStyle(.secondary)
                    ForEach(deviceJobs.prefix(4)) { job in
                        Button {
                            onJobCreated(job.id)
                        } label: {
                            HStack(spacing: 4) {
                                StatusBadge(status: job.status)
                                Text("\(job.doneFiles)/\(job.totalFiles)")
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
    }

    // MARK: Catalog

    @ViewBuilder
    private func catalogArea(_ device: CameraDeviceInfo) -> some View {
        if let runningJob {
            ContentUnavailableView {
                Label("Backup in progress", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text("“\(runningJob.name)” is using this device. Browse its media again when the backup finishes.")
            } actions: {
                Button("Show Backup") { onJobCreated(runningJob.id) }
            }
        } else {
            switch catalog.state {
            case .idle, .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading the device's media catalog…\nIf nothing happens, unlock the device and tap “Trust”.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't read the device", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { startLoading(force: true) }
                }
            case .ready:
                folderList
            }
        }
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(catalog.totalFiles) files · \(Format.bytes(catalog.totalBytes)) on the device — pick what to back up:")
                    .font(.callout)
                Spacer()
                Button("Select All") { selectAll() }
                    .disabled(selected.count == catalog.totalFiles)
                Button("Select None") { selected.removeAll() }
                    .disabled(selected.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            List {
                ForEach(catalog.folders) { folder in
                    DisclosureGroup {
                        ForEach(folder.files) { file in
                            HStack {
                                checkbox(isOn: selected.contains(file.relativePath)) {
                                    toggleFile(file.relativePath)
                                }
                                Text((file.relativePath as NSString).lastPathComponent)
                                Spacer()
                                Text(Format.bytes(file.size))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.callout)
                        }
                    } label: {
                        HStack {
                            checkbox(state: folderState(folder)) { toggleFolder(folder) }
                            Label(folder.path, systemImage: "folder")
                            Spacer()
                            Text("\(folder.files.count) files · \(Format.bytes(folder.totalBytes))")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private enum CheckState { case all, some, none }

    private func folderState(_ folder: CatalogFolder) -> CheckState {
        let count = folder.files.count { selected.contains($0.relativePath) }
        if count == 0 { return .none }
        return count == folder.files.count ? .all : .some
    }

    private func checkbox(isOn: Bool, action: @escaping () -> Void) -> some View {
        checkbox(state: isOn ? .all : .none, action: action)
    }

    private func checkbox(state: CheckState, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: state == .all ? "checkmark.square.fill"
                  : state == .some ? "minus.square.fill" : "square")
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func toggleFile(_ path: String) {
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
    }

    private func toggleFolder(_ folder: CatalogFolder) {
        let paths = folder.files.map(\.relativePath)
        if folderState(folder) == .all {
            selected.subtract(paths)
        } else {
            selected.formUnion(paths)
        }
    }

    private func selectAll() {
        selected = Set(catalog.folders.flatMap { $0.files.map(\.relativePath) })
    }

    // MARK: Footer — destination & start

    private func footer(_ device: CameraDeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Copy into")
                TextField("Backup folder…", text: $destParentPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button("Choose…") { pickDest() }
            }
            HStack {
                Toggle("Checksum every file (SHA-256)", isOn: $verify)
                Spacer()
                Button {
                    startBackup(device)
                } label: {
                    Label(
                        selected.isEmpty
                            ? "Back Up"
                            : "Back Up \(selected.count) files (\(Format.bytes(selectedBytes)))",
                        systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderedProminent)
                .disabled(destParentPath.isEmpty || selected.isEmpty
                          || catalog.state != .ready || runningJob != nil)
            }
        }
        .padding()
    }

    private func startBackup(_ device: CameraDeviceInfo) {
        let manifest = catalog.folders
            .flatMap { $0.files }
            .filter { selected.contains($0.relativePath) }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        appState.createDeviceJob(
            deviceID: device.id,
            deviceName: device.name,
            destParentPath: destParentPath,
            verify: verify,
            manifest: manifest)
        if let job = appState.jobs.first(where: {
            $0.sourceDeviceID == device.id && $0.status.isActive
        }) {
            onJobCreated(job.id)
        }
    }

    private func startLoading(force: Bool = false) {
        guard runningJob == nil else { return }
        guard force || loader == nil || loader?.device !== appState.deviceWatcher.camera(withID: deviceID) else {
            return
        }
        guard let camera = appState.deviceWatcher.camera(withID: deviceID) else { return }
        let newLoader = DeviceCatalog(device: camera)
        newLoader.onChange = { snapshot in
            catalog = snapshot
            if snapshot.state == .ready, selected.isEmpty {
                selectAll()
            }
        }
        loader = newLoader
        newLoader.load()
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
