import SwiftUI
import UniformTypeIdentifiers

/// The Home tab: everything that matters, one calm scroll.
/// Drop zone → active copies → projects → destinations → tools → history.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    let onSelect: (SidebarSelection) -> Void
    let onNewJob: () -> Void
    /// Open the New Copy Job sheet with these sources prefilled (used when a
    /// card is imported but no projects exist yet).
    let onNewJobWithSources: ([String]) -> Void
    let onNewProject: () -> Void

    private let projectColumns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 12)]

    /// Camera/drone/audio cards mounted right now (project drives excluded).
    private var connectedCards: [CardDetector.DetectedCard] {
        let projectVolumes = Set(appState.projects.flatMap { p in
            p.roots.compactMap(\.volume.uuid)
        })
        return appState.volumes
            .filter { $0.isEjectable && !$0.isInternal }
            .filter { !projectVolumes.contains($0.uuid ?? "") }
            .compactMap { CardDetector.detect(volumePath: $0.path, volumeName: $0.name) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero

                if !connectedCards.isEmpty || !appState.devices.isEmpty {
                    cardsSection
                }

                if !appState.activeJobs.isEmpty {
                    activeSection
                }

                if !appState.projects.isEmpty {
                    projectsSection
                }

                if !appState.destinationPresets.isEmpty {
                    destinationsSection
                }

                toolsSection

                if !appState.historyJobs.isEmpty {
                    historySection
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .navigationTitle("Home")
    }

    // MARK: Hero — ready to copy

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Ready to copy")
                .font(.title2.bold())
            Text("Drag files or folders anywhere in this window")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                onNewJob()
            } label: {
                Label("Choose What to Copy", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Color.accentColor.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        }
    }

    // MARK: Connected cards & devices

    private var cardsSection: some View {
        sectionBox("Connected Now", icon: "sdcard") {
            VStack(spacing: 6) {
                ForEach(connectedCards) { card in
                    HStack(spacing: 10) {
                        Image(systemName: card.kind.icon)
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.kind.label).font(.callout.weight(.medium))
                            Text("“\(card.volumeName)”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Browse") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: card.volumePath))
                        }
                        .help("Look through the card's files in Finder")
                        Button("Import…") {
                            if appState.projects.isEmpty {
                                onNewJobWithSources([card.volumePath])
                            } else {
                                appState.pendingCardImport = card
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Copy this card into a project")
                    }
                    .padding(10)
                    .background(Color(.quaternaryLabelColor).opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 8))
                }

                ForEach(appState.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: "iphone")
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).font(.callout.weight(.medium))
                            Text(device.isLocked
                                 ? "Locked — unlock and tap “Trust”"
                                 : "iPhone or camera")
                                .font(.caption)
                                .foregroundStyle(device.isLocked ? .orange : .secondary)
                        }
                        Spacer()
                        Button("Browse & Back Up") {
                            onSelect(.device(device.id))
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Browse the device's media and choose what to back up")
                    }
                    .padding(10)
                    .background(Color(.quaternaryLabelColor).opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: Active copies

    private var activeSection: some View {
        sectionBox("Copying Now", icon: "arrow.triangle.2.circlepath") {
            VStack(spacing: 6) {
                ForEach(appState.activeJobs) { job in
                    Button {
                        onSelect(.job(job.id))
                    } label: {
                        JobRow(job: job)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.quaternaryLabelColor).opacity(0.35),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Projects

    private var projectsSection: some View {
        sectionBox("Projects", icon: "folder", trailing: {
            HStack(spacing: 12) {
                Button("New Project", action: onNewProject)
                    .font(.caption)
                Button {
                    onSelect(.projects)
                } label: {
                    HStack(spacing: 3) {
                        Text("All Projects")
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }) {
            LazyVGrid(columns: projectColumns, spacing: 12) {
                ForEach(appState.projects.prefix(4)) { project in
                    ProjectCard(project: project) { onSelect(.project(project.id)) }
                }
            }
        }
    }

    // MARK: Destinations — droppable chips

    private var destinationsSection: some View {
        sectionBox("Destinations", icon: "externaldrive",
                   subtitle: "Drop files on a destination to copy straight there",
                   trailing: {
            Button {
                onSelect(.destinations)
            } label: {
                HStack(spacing: 3) {
                    Text("Manage")
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 10)],
                      spacing: 10) {
                ForEach(appState.destinationPresets) { preset in
                    DestinationChip(preset: preset)
                }
            }
        }
    }

    // MARK: Tools

    private var toolsSection: some View {
        sectionBox("Tools", icon: "wrench.and.screwdriver") {
            HStack(spacing: 10) {
                toolButton("Compare Folders", icon: "arrow.left.arrow.right") {
                    onSelect(.compare)
                }
                toolButton("Benchmark Drive", icon: "gauge.with.dots.needle.67percent") {
                    onSelect(.benchmark)
                }
                Spacer()
            }
        }
    }

    private func toolButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .controlSize(.large)
    }

    // MARK: History

    private var historySection: some View {
        sectionBox("Recent Copies", icon: "clock.arrow.circlepath") {
            VStack(spacing: 6) {
                ForEach(appState.historyJobs.prefix(5)) { job in
                    Button {
                        onSelect(.job(job.id))
                    } label: {
                        JobRow(job: job)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.quaternaryLabelColor).opacity(0.35),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Section scaffolding

    private func sectionBox(
        _ title: String, icon: String, subtitle: String? = nil,
        @ViewBuilder trailing: () -> some View = { EmptyView() },
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                trailing()
            }
            content()
        }
    }
}

/// A saved destination as a compact droppable chip: drop files → copy there.
private struct DestinationChip: View {
    @Environment(AppState.self) private var appState
    let preset: DestinationPreset
    @State private var isTargeted = false

    private var connected: Bool {
        preset.allPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: preset.isMulti ? "square.stack.3d.up.fill" : "externaldrive.fill")
                .foregroundStyle(connected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(preset.isMulti
                     ? "\(preset.allPaths.count) drives"
                     : (preset.path as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
                .help(connected ? "Connected" : "Not connected")
        }
        .padding(10)
        .background(
            isTargeted ? Color.accentColor.opacity(0.18)
                       : Color(.quaternaryLabelColor).opacity(0.35),
            in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { items, _ in
            guard !items.isEmpty else { return false }
            appState.handleIncomingSources(items.map(\.path), destination: preset)
            return true
        } isTargeted: { isTargeted = $0 }
        .help("Drop files here to copy them to \(preset.name)")
    }
}
