import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case job(UUID)
    case compare
    case destinations
    case benchmark
    case device(String)
    case volume(String)
    case about
}

/// Identifiable wrapper so a dropped-source list can drive a `.sheet(item:)`.
private struct DroppedSources: Identifiable {
    let paths: [String]
    var id: String { paths.joined(separator: "\u{0}") }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: SidebarSelection?
    @State private var showNewJob = false
    @State private var newJobSources: [String] = []
    @State private var newJobDests: [String] = []
    @State private var isDropTargeted = false
    @State private var lastNewestJobID: UUID?
    @State private var dropSources: [String]?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            switch selection {
            case .job(let id):
                if let job = appState.jobs.first(where: { $0.id == id }) {
                    JobDetailView(job: job)
                } else {
                    emptyState
                }
            case .compare:
                CompareView()
            case .destinations:
                DestinationsView()
            case .benchmark:
                BenchmarkView()
            case .device(let id):
                DeviceView(deviceID: id) { jobID in
                    selection = .job(jobID)
                }
            case .volume(let path):
                VolumeView(
                    volumePath: path,
                    onNewJob: { sources, dest in
                        newJobSources = sources
                        newJobDests = dest.map { [$0] } ?? []
                        showNewJob = true
                    },
                    onSelectJob: { selection = .job($0) })
            case .about:
                AboutView()
            case nil:
                emptyState
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newJobSources = []
                    newJobDests = []
                    showNewJob = true
                } label: {
                    Label("New Copy Job", systemImage: "plus")
                }
                .help("Create a new tracked copy job")
            }
        }
        .sheet(isPresented: $showNewJob) {
            NewJobSheet(
                initialSources: newJobSources,
                initialDests: newJobDests,
                onCreate: { sources, destParents, verify in
                    appState.createJob(sourcePaths: sources, destParentPaths: destParents, verify: verify)
                    if let first = appState.jobs.first {
                        selection = .job(first.id)
                    }
                },
                onPickDevice: { deviceID in
                    showNewJob = false
                    selection = .device(deviceID)
                }
            )
        }
        .navigationTitle("CopyWatch")
        .dropDestination(for: URL.self) { items, _ in
            guard !showNewJob, dropSources == nil else { return false }
            appState.handleIncomingSources(items.map(\.path))
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                ZStack {
                    Color.accentColor.opacity(0.12)
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, lineWidth: 3, antialiased: true)
                        .padding(8)
                    Label("Drop to choose a destination", systemImage: "square.and.arrow.down.on.square")
                        .font(.title2.bold())
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .allowsHitTesting(false)
            }
        }
        .sheet(item: Binding(
            get: { dropSources.map { DroppedSources(paths: $0) } },
            set: { dropSources = $0?.paths }
        )) { dropped in
            DropDestinationSheet(sources: dropped.paths)
        }
        .onChange(of: appState.pendingDrop) { _, paths in
            presentDrop(paths)
        }
        .onAppear {
            // Seed so launch (with existing history) doesn't look like a new
            // drop and auto-navigate away from "No job selected".
            lastNewestJobID = appState.jobs.first?.id
            // When the Finder service (or a Dock drop) cold-launches the app,
            // `pendingDrop` is set before this view starts observing, so
            // `.onChange` never fires — catch that initial value here.
            presentDrop(appState.pendingDrop)
        }
        .onChange(of: appState.jobs.first?.id) { _, newestID in
            // A drop with a default destination creates and starts a job
            // without going through the sheet — jump straight to it.
            guard !showNewJob, let newestID, newestID != lastNewestJobID else { return }
            lastNewestJobID = newestID
            selection = .job(newestID)
        }
    }

    private func presentDrop(_ paths: [String]?) {
        guard let paths, !paths.isEmpty else { return }
        dropSources = paths
        appState.pendingDrop = nil
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No job selected",
            systemImage: "externaldrive.badge.timemachine",
            description: Text("Create a copy job with the + button, pick one from the sidebar, or drag files or a folder anywhere onto this window.")
        )
    }
}
