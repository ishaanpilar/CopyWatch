import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct JobDetailView: View {
    @Environment(AppState.self) private var appState
    let job: CopyJob
    @State private var fileFilter: FileStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            dashboard
            Divider()
            fileTable
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.name).font(.title2.bold())
                StatusBadge(status: job.status)
                Spacer()
                controls
            }
            PathLine(label: "From", path: job.sourcePath, volume: job.sourceVolume.name)
            PathLine(label: "To", path: job.destPath, volume: job.destVolume.name)

            if let message = job.statusMessage {
                Label(message, systemImage: infoIcon)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bannerColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding()
    }

    private var infoIcon: String {
        switch job.status {
        case .waitingForVolume: "externaldrive.badge.questionmark"
        case .interrupted: "arrow.uturn.forward.circle"
        case .completedWithErrors: "exclamationmark.triangle"
        default: "info.circle"
        }
    }

    private var bannerColor: Color {
        switch job.status {
        case .waitingForVolume, .completedWithErrors: .orange
        default: .blue
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            switch job.status {
            case .ready, .interrupted, .waitingForVolume:
                Button {
                    appState.start(job.id)
                } label: {
                    Label(job.status == .ready ? "Start" : "Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            case .paused:
                Button {
                    appState.start(job.id)
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            case .running:
                Button {
                    appState.pause(job.id)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
            default:
                EmptyView()
            }

            if job.status.isActive && job.status != .scanning {
                Button(role: .destructive) {
                    appState.cancel(job.id)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            }

            Menu {
                if !job.isDeviceJob {
                    Button("Reveal Source in Finder") { reveal(job.sourcePath) }
                }
                Button("Reveal Destination in Finder") { reveal(job.destPath) }
                Button("Export Manifest as CSV…") { exportCSV() }
                if !job.status.isActive {
                    Divider()
                    Button("Delete Job Record", role: .destructive) {
                        appState.delete(job.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: Comparison dashboard

    private var dashboard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                StatCard(
                    title: "Source",
                    files: job.totalFiles,
                    bytes: job.totalBytes,
                    subtitle: job.status == .scanning ? "Scanning…" : "in manifest")
                Image(systemName: deltaZero ? "checkmark.circle.fill" : "arrow.right")
                    .font(.title2)
                    .foregroundStyle(deltaZero ? .green : .secondary)
                StatCard(
                    title: "Destination",
                    files: job.doneFiles,
                    bytes: job.doneBytes,
                    subtitle: destSubtitle)
                deltaCard
            }

            if job.status == .running || job.status == .paused {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: job.fractionDone)
                    HStack {
                        Text("\(Int(job.fractionDone * 100))%")
                        if job.status == .running {
                            Text(Format.speed(job.bytesPerSecond))
                            if let eta = job.etaSeconds { Text(Format.eta(eta)) }
                        }
                        Spacer()
                        if let current = job.currentFile {
                            Text(current).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var deltaZero: Bool {
        job.doneFiles == job.totalFiles && job.doneBytes == job.totalBytes && job.totalFiles > 0
    }

    private var destSubtitle: String {
        var parts: [String] = []
        if job.verifiedFiles > 0 { parts.append("\(job.verifiedFiles) verified") }
        if job.skippedFiles > 0 { parts.append("\(job.skippedFiles) already there") }
        return parts.isEmpty ? "written & confirmed" : parts.joined(separator: " · ")
    }

    @ViewBuilder private var deltaCard: some View {
        let remainingFiles = job.totalFiles - job.doneFiles
        let remainingBytes = job.totalBytes - job.doneBytes
        VStack(alignment: .leading, spacing: 4) {
            Text(deltaZero ? "Match" : "Remaining")
                .font(.caption)
                .foregroundStyle(.secondary)
            if deltaZero {
                Label("Everything is good", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else {
                Text("\(remainingFiles) files")
                    .font(.headline)
                    .foregroundStyle(job.failedFiles > 0 ? .red : .primary)
                Text(Format.bytes(max(remainingBytes, 0)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if job.failedFiles > 0 {
                Text("\(job.failedFiles) failed")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(minWidth: 140, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: File table

    private var filteredFiles: [FileRecord] {
        let files = fileFilter.map { f in job.files.filter { $0.status == f } } ?? job.files
        return Array(files.prefix(5000))
    }

    private var fileTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Show", selection: $fileFilter) {
                    Text("All (\(job.files.count))").tag(FileStatus?.none)
                    Text("Pending").tag(FileStatus?.some(.pending))
                    Text("Copied").tag(FileStatus?.some(.copied))
                    Text("Verified").tag(FileStatus?.some(.verified))
                    Text("Skipped").tag(FileStatus?.some(.skipped))
                    Text("Failed (\(job.failedFiles))").tag(FileStatus?.some(.failed))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Table(filteredFiles) {
                TableColumn("File") { f in
                    Text(f.relativePath).truncationMode(.middle)
                }
                TableColumn("Size") { f in
                    Text(Format.bytes(f.size)).monospacedDigit()
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn("Status") { f in
                    FileStatusView(record: f)
                }
                .width(min: 90, ideal: 130, max: 240)
                TableColumn("SHA-256") { f in
                    Text(f.checksum.map { String($0.prefix(16)) + "…" } ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 150, max: 200)
            }
        }
    }

    // MARK: Actions

    private func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = job.name.replacingOccurrences(of: "/", with: "-") + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Format.csv(for: job).data(using: .utf8)?.write(to: url)
    }
}

// MARK: Small components

struct StatusBadge: View {
    let status: JobStatus

    var body: some View {
        Text(status.label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .running, .scanning: .blue
        case .completed: .green
        case .completedWithErrors, .paused, .interrupted, .waitingForVolume: .orange
        case .cancelled: .secondary
        case .ready: .secondary
        }
    }
}

struct PathLine: View {
    let label: String
    let path: String
    let volume: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Image(systemName: "externaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(volume).font(.caption.bold())
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct StatCard: View {
    let title: String
    let files: Int
    let bytes: Int64
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(files) files")
                .font(.headline)
                .monospacedDigit()
            Text(Format.bytes(bytes))
                .font(.subheadline)
                .monospacedDigit()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 150, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct FileStatusView: View {
    let record: FileRecord

    var body: some View {
        HStack(spacing: 4) {
            switch record.status {
            case .pending:
                Text("Pending").foregroundStyle(.secondary)
            case .copying:
                if record.size > 0 {
                    ProgressView(value: Double(record.bytesCopied), total: Double(record.size))
                        .controlSize(.small)
                } else {
                    Text("Copying…")
                }
            case .copied:
                Label("Copied", systemImage: "checkmark").foregroundStyle(.blue)
            case .verified:
                Label("Verified", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .skipped:
                Label("Already there", systemImage: "equal.circle").foregroundStyle(.secondary)
            case .failed:
                Label(record.error ?? "Failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(record.error ?? "Failed")
            }
        }
        .font(.caption)
    }
}
