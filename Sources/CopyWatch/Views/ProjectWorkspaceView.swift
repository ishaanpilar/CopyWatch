import SwiftUI
import AppKit

/// Inside one production: its media, its drives, and its full history.
struct ProjectWorkspaceView: View {
    @Environment(AppState.self) private var appState
    let projectID: UUID
    let onSelectJob: (UUID) -> Void

    @State private var showImport = false
    @State private var importSources: [String] = []
    @State private var confirmDelete = false

    var body: some View {
        if let project = appState.project(projectID) {
            content(project)
        } else {
            ContentUnavailableView("Project not found", systemImage: "folder.badge.questionmark")
        }
    }

    private func content(_ project: Project) -> some View {
        let health = appState.health(of: project)
        let stats = appState.stats(of: project)
        let pjobs = appState.jobs(in: projectID).filter { $0.status != .cancelled }

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(project, health: health, stats: stats)

                if pjobs.isEmpty {
                    emptyMedia
                } else {
                    section("Source Media", icon: "sdcard") {
                        VStack(spacing: 6) {
                            ForEach(pjobs) { job in
                                SourceMediaRow(job: job) { onSelectJob(job.id) }
                            }
                        }
                    }
                }

                section("Destinations", icon: "externaldrive") {
                    VStack(spacing: 6) {
                        ForEach(appState.destinationStatus(of: project), id: \.root.path) { d in
                            destinationRow(d)
                        }
                    }
                }

                if !project.events.isEmpty {
                    section("Timeline", icon: "clock") {
                        timeline(project)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(project.name)
        .sheet(isPresented: $showImport) {
            ProjectImportSheet(
                card: nil,
                fixedProjectID: projectID,
                sourcePaths: importSources)
        }
        .confirmationDialog("Delete “\(project.name)”?", isPresented: $confirmDelete) {
            Button("Delete Project", role: .destructive) { appState.deleteProject(projectID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the project record only. Files on your drives and copy history are kept.")
        }
    }

    // MARK: Header

    private func header(_ project: Project, health: ProjectHealth,
                        stats: (bytes: Int64, imports: Int, lastActivity: Date)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.title.bold())
                    HStack(spacing: 8) {
                        HealthBadge(health: health)
                        if let why = health.detail {
                            Text(why).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Spacer()
                Button {
                    chooseImportSources()
                } label: {
                    Label("Import Media", systemImage: "square.and.arrow.down")
                }
                .help("Copy a card or folder into this project")
                Button {
                    appState.verifyProject(projectID)
                } label: {
                    Label("Verify Project", systemImage: "checkmark.seal")
                }
                .disabled(stats.imports == 0)
                .help("Re-check every import against the drives as they are now")
                Menu {
                    ForEach(project.roots, id: \.path) { root in
                        Button("Reveal on \(root.volume.name)") {
                            if let p = root.volume.resolve(root.path) {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p)
                            }
                        }
                        .disabled(root.volume.resolve(root.path) == nil)
                    }
                    Divider()
                    Button("Delete Project…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: 22) {
                headerStat(Format.bytes(stats.bytes), "Backed up")
                headerStat("\(stats.imports)", stats.imports == 1 ? "Import" : "Imports")
                headerStat("\(project.roots.count)", project.roots.count == 1 ? "Drive" : "Drives")
                if let verified = project.lastVerifiedAt {
                    headerStat(verified.formatted(date: .abbreviated, time: .omitted), "Last verified")
                }
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func headerStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Sections

    private func section(_ title: String, icon: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var emptyMedia: some View {
        VStack(spacing: 10) {
            Image(systemName: "sdcard")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No media imported yet")
                .font(.headline)
            Text("Insert a camera card — CopyWatch will offer to file it here.\nOr click Import Media to choose folders by hand.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(Color(.quaternaryLabelColor).opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func destinationRow(
        _ d: (root: JobDestination, connected: Bool, verified: Int, total: Int)
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: d.connected ? "externaldrive.fill" : "externaldrive")
                .foregroundStyle(d.connected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.root.volume.name).font(.callout.weight(.medium))
                Text(d.root.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if d.total > 0 {
                Label(d.verified == d.total ? "Verified" : "\(d.verified) of \(d.total) verified",
                      systemImage: d.verified == d.total ? "checkmark.seal.fill" : "checkmark.seal")
                    .font(.caption.bold())
                    .foregroundStyle(d.verified == d.total ? .green : .orange)
            }
            Text(d.connected ? "Connected" : "Offline")
                .font(.caption)
                .foregroundStyle(d.connected ? .green : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    (d.connected ? Color.green : Color.secondary).opacity(0.12),
                    in: Capsule())
        }
        .padding(10)
        .background(Color(.quaternaryLabelColor).opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Timeline

    private func timeline(_ project: Project) -> some View {
        let grouped = Dictionary(grouping: project.events.reversed()) {
            Calendar.current.startOfDay(for: $0.date)
        }
        let days = grouped.keys.sorted(by: >)

        return VStack(alignment: .leading, spacing: 12) {
            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading, spacing: 6) {
                    Text(dayLabel(day))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(grouped[day] ?? []) { event in
                        HStack(spacing: 10) {
                            Image(systemName: event.kind.icon)
                                .font(.caption)
                                .foregroundStyle(event.kind.tint)
                                .frame(width: 18)
                            Text(event.detail)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(event.date.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let jobID = event.jobID,
                               appState.jobs.contains(where: { $0.id == jobID }) {
                                onSelectJob(jobID)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.quaternaryLabelColor).opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .long, time: .omitted)
    }

    // MARK: Import picker

    private func chooseImportSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose a card, folder, or files to copy into this project."
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            importSources = panel.urls.map(\.path)
            showImport = true
        }
    }
}

/// One imported card/folder: status at a glance, full card record on expand.
struct SourceMediaRow: View {
    @Environment(AppState.self) private var appState
    let job: CopyJob
    let onOpen: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.sourceLabel ?? job.name)
                            .font(.callout.weight(.medium))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if job.status == .running || job.status == .paused {
                        ProgressView(value: job.fractionDone)
                            .frame(width: 90)
                            .controlSize(.small)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                cardRecord
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(Color(.quaternaryLabelColor).opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Open Copy Details") { onOpen() }
            if let folder = job.projectFolder, !folder.isEmpty,
               FileManager.default.fileExists(atPath: job.destPath) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: job.destPath)
                }
            }
        }
    }

    /// The permanent card record: everything about this physical card's fate.
    private var cardRecord: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 4)
            recordLine("Imported", job.createdAt.formatted(date: .abbreviated, time: .shortened))
            recordLine("Files", "\(job.totalFiles)")
            recordLine("Size", Format.bytes(job.totalBytes))
            if let folder = job.projectFolder, !folder.isEmpty {
                recordLine("Folder", folder)
            }
            recordLine("Verified", job.verifyAfterCopy && job.failedFiles == 0
                       && job.status == .completed ? "Yes — every file checksummed" : "No")
            recordLine("Card freed", job.sourceTrashedAt.map {
                "Yes — \($0.formatted(date: .abbreviated, time: .omitted))"
            } ?? "No — originals still on the card")
            HStack {
                Spacer()
                Button("Full Details") { onOpen() }
                    .controlSize(.small)
            }
        }
    }

    private func recordLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value).font(.caption)
            Spacer()
        }
    }

    private var subtitle: String {
        switch job.status {
        case .running: "\(Int(job.fractionDone * 100))% · \(Format.speed(job.bytesPerSecond))"
        case .scanning: "Scanning…"
        case .completed: "\(job.totalFiles) files · \(Format.bytes(job.totalBytes)) · \(job.createdAt.formatted(date: .abbreviated, time: .omitted))"
        default: job.status.label
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.status {
        case .completed where job.verifyAfterCopy && job.failedFiles == 0:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .running, .scanning, .ready, .queued:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .completedWithErrors, .interrupted, .waitingForVolume, .paused:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }
}
