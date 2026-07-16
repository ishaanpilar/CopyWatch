import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: SidebarSelection?
    @State private var ejectError: String?

    var body: some View {
        List(selection: $selection) {
            if !appState.activeJobs.isEmpty {
                Section("Active") {
                    ForEach(appState.activeJobs) { job in
                        JobRow(job: job).tag(SidebarSelection.job(job.id))
                    }
                }
            }

            Section("Tools") {
                Label("Compare Folders", systemImage: "arrow.left.arrow.right.square")
                    .tag(SidebarSelection.compare)
            }

            Section("Devices") {
                ForEach(appState.devices) { device in
                    HStack {
                        Label(device.name, systemImage: "iphone")
                        Spacer()
                        if device.isLocked {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.orange)
                                .help("Unlock the device and tap “Trust”")
                        }
                    }
                    .tag(SidebarSelection.device(device.id))
                }
                if appState.devices.isEmpty {
                    Text("No iPhone or camera connected")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .selectionDisabled()
                }
            }

            if !appState.historyJobs.isEmpty {
                Section("History") {
                    ForEach(appState.historyJobs) { job in
                        JobRow(job: job).tag(SidebarSelection.job(job.id))
                    }
                }
            }

            Section("Drives") {
                // External drives first, then internal disks — everything mounted is shown.
                ForEach(appState.volumes.sorted {
                    ($0.isInternal ? 1 : 0, $0.name) < ($1.isInternal ? 1 : 0, $1.name)
                }) { volume in
                    HStack {
                        Label(volume.name, systemImage:
                                volume.isInternal ? "internaldrive" : "externaldrive")
                        Spacer()
                        if volume.isEjectable {
                            Button {
                                ejectError = appState.eject(volume)
                            } label: {
                                Image(systemName: "eject")
                            }
                            .buttonStyle(.borderless)
                            .help(appState.jobsUsing(volumePath: volume.path).isEmpty
                                  ? "Eject \(volume.name)"
                                  : "In use by a running job")
                        }
                    }
                    .tag(SidebarSelection.volume(volume.path))
                }
                if appState.volumes.isEmpty {
                    Text("No drives")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }

            // Same row style as everything above — just last, so it reads as
            // a quiet final stop rather than a featured tool.
            Section {
                Label("About CopyWatch", systemImage: "info.circle")
                    .tag(SidebarSelection.about)
            }
        }
        .listStyle(.sidebar)
        .alert("Could not eject", isPresented: .init(
            get: { ejectError != nil },
            set: { if !$0 { ejectError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ejectError ?? "")
        }
    }
}

struct JobRow: View {
    let job: CopyJob

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.name).lineLimit(1)
                Spacer()
                statusIcon
            }
            if job.status == .running || job.status == .paused {
                ProgressView(value: job.fractionDone)
                    .controlSize(.small)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch job.status {
        case .running:
            return "\(Int(job.fractionDone * 100))% · \(Format.speed(job.bytesPerSecond))"
        case .completed:
            return "\(job.totalFiles) files · \(Format.bytes(job.totalBytes))"
        default:
            return job.status.label
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.status {
        case .running, .scanning:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .completedWithErrors, .waitingForVolume:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .interrupted, .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        case .ready:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }
}
