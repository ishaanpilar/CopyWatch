import SwiftUI

/// The home screen: every production at a glance. Click a card to open its
/// workspace; the grid answers "is everything safe?" without a single click.
struct ProjectsDashboardView: View {
    @Environment(AppState.self) private var appState
    let onOpen: (UUID) -> Void
    let onNewProject: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16)]

    var body: some View {
        ScrollView {
            if appState.projects.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Projects").font(.largeTitle.bold())
                        Spacer()
                        Button {
                            onNewProject()
                        } label: {
                            Label("New Project", systemImage: "plus")
                        }
                        .controlSize(.large)
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(appState.projects) { project in
                            ProjectCard(project: project) { onOpen(project.id) }
                        }
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("Projects")
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 90)
            Text("Organize backups by project")
                .font(.title2.bold())
            Text("A project keeps every card, drive, and verification\nfor one piece of work together — with its full history.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                onNewProject()
            } label: {
                Label("Create Your First Project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 20) {
                ForEach([ProjectTemplate.media, .photography, .audio, .research]) { t in
                    VStack(spacing: 4) {
                        Image(systemName: t.icon).font(.title3)
                        Text(t.rawValue).font(.caption)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One project on the dashboard: name, health, size, activity, drives.
struct ProjectCard: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let onOpen: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        let health = appState.health(of: project)
        let stats = appState.stats(of: project)
        let dests = appState.destinationStatus(of: project)

        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(lastActivityLine(stats.lastActivity))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HealthBadge(health: health)
                }

                if let why = health.detail {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                HStack(spacing: 14) {
                    statPair(Format.bytes(stats.bytes), "backed up")
                    statPair("\(stats.imports)", stats.imports == 1 ? "import" : "imports")
                    Spacer()
                }
                .padding(.top, 2)

                HStack(spacing: 6) {
                    ForEach(dests, id: \.root.path) { d in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(d.connected ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 6, height: 6)
                            Text(d.root.volume.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(.quaternaryLabelColor).opacity(0.4), in: Capsule())
                        .help(d.connected ? "Connected" : "Not connected")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.quaternaryLabelColor).opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let path = project.roots.first.flatMap({ $0.volume.resolve($0.path) }) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
            }
            Divider()
            Button("Delete Project…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog(
            "Delete “\(project.name)”?", isPresented: $confirmDelete
        ) {
            Button("Delete Project", role: .destructive) {
                appState.deleteProject(project.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the project record only. Files on your drives and copy history are kept.")
        }
    }

    private func statPair(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.callout.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func lastActivityLine(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Updated today" }
        if Calendar.current.isDateInYesterday(date) { return "Updated yesterday" }
        return "Updated " + date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The pill that answers "is this safe?" — used on cards and in the workspace.
struct HealthBadge: View {
    let health: ProjectHealth

    var body: some View {
        Label(health.label, systemImage: health.icon)
            .font(.caption.bold())
            .foregroundStyle(health.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(health.tint.opacity(0.14), in: Capsule())
    }
}
