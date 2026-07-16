import SwiftUI
import AppKit

/// Screen for a mounted drive: capacity, quick copy actions, and the jobs that
/// touch it.
struct VolumeView: View {
    @Environment(AppState.self) private var appState
    let volumePath: String
    /// (prefill sources, prefill destination) → opens the New Job sheet.
    let onNewJob: ([String], String?) -> Void
    let onSelectJob: (UUID) -> Void

    @State private var ejectError: String?

    private var volume: MountedVolume? {
        appState.volumes.first { $0.path == volumePath }
    }

    private var relatedJobs: [CopyJob] {
        appState.jobs.filter {
            $0.sourcePath.hasPrefix(volumePath) || $0.destPath.hasPrefix(volumePath)
        }
    }

    var body: some View {
        if let volume {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(volume)
                    actions(volume)
                    if !relatedJobs.isEmpty {
                        jobList
                    }
                }
                .padding()
            }
            .navigationTitle(volume.name)
            .alert("Could not eject", isPresented: .init(
                get: { ejectError != nil }, set: { if !$0 { ejectError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(ejectError ?? "")
            }
        } else {
            ContentUnavailableView(
                "Drive disconnected",
                systemImage: "externaldrive.badge.xmark",
                description: Text("Reconnect the drive to work with it."))
        }
    }

    private func header(_ volume: MountedVolume) -> some View {
        let values = try? URL(fileURLWithPath: volume.path).resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0

        return HStack(spacing: 14) {
            Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive.fill")
                .font(.system(size: 36))
                .foregroundStyle(volume.isInternal ? Color.secondary : .blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name).font(.title2.bold())
                Text(volume.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if total > 0 {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(total - free), total: Double(total))
                            .frame(width: 160)
                        Text("\(Format.bytes(free)) free of \(Format.bytes(total))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
        }
    }

    private func actions(_ volume: MountedVolume) -> some View {
        HStack(spacing: 10) {
            Button {
                pickSources(on: volume) { onNewJob($0, nil) }
            } label: {
                Label("Copy From This Drive", systemImage: "square.and.arrow.up.on.square")
            }
            .buttonStyle(.borderedProminent)
            .help("Pick folders or files on “\(volume.name)” to copy somewhere else")

            Button {
                pickDestination(on: volume) { onNewJob([], $0) }
            } label: {
                Label("Back Up Onto This Drive", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Pick where on “\(volume.name)” a copy should land")

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: volume.path)
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }

            if volume.isEjectable {
                Button {
                    ejectError = appState.eject(volume)
                } label: {
                    Label("Eject", systemImage: "eject")
                }
                .disabled(!appState.jobsUsing(volumePath: volume.path).isEmpty)
            }
            Spacer()
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Jobs using this drive").font(.headline)
            ForEach(relatedJobs) { job in
                Button {
                    onSelectJob(job.id)
                } label: {
                    HStack {
                        StatusBadge(status: job.status)
                        Text(job.name).lineLimit(1)
                        Spacer()
                        Text("\(job.doneFiles)/\(job.totalFiles) files · \(Format.bytes(job.totalBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Pick what to copy — folders or individual files, multiple allowed.
    private func pickSources(on volume: MountedVolume, then use: ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Copy From"
        panel.message = "Choose folders or files on “\(volume.name)” to copy."
        panel.directoryURL = URL(fileURLWithPath: volume.path)
        if panel.runModal() == .OK {
            use(panel.urls.map(\.path))
        }
    }

    /// Pick where a copy lands — a folder, with a New Folder button available.
    private func pickDestination(on volume: MountedVolume, then use: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose or create a folder on “\(volume.name)” to copy into."
        panel.directoryURL = URL(fileURLWithPath: volume.path)
        if panel.runModal() == .OK, let url = panel.url {
            use(url.path)
        }
    }
}
