import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case job(UUID)
    case compare
    case destinations
    case device(String)
    case volume(String)
    case about
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: SidebarSelection?
    @State private var showNewJob = false
    @State private var newJobSources: [String] = []
    @State private var newJobDest = ""
    @State private var isDropTargeted = false
    @State private var lastNewestJobID: UUID?

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
            case .device(let id):
                DeviceView(deviceID: id) { jobID in
                    selection = .job(jobID)
                }
            case .volume(let path):
                VolumeView(
                    volumePath: path,
                    onNewJob: { source, dest in
                        newJobSources = source.map { [$0] } ?? []
                        newJobDest = dest ?? ""
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
                    newJobDest = ""
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
                initialDest: newJobDest,
                onCreate: { sources, destParent, verify in
                    appState.createJob(sourcePaths: sources, destParentPath: destParent, verify: verify)
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
            guard !showNewJob else { return false }
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
                    Label("Drop to start a copy job", systemImage: "square.and.arrow.down.on.square")
                        .font(.title2.bold())
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .allowsHitTesting(false)
            }
        }
        .onChange(of: appState.pendingSourcePaths) { _, paths in
            guard let paths, !paths.isEmpty else { return }
            newJobSources = paths
            newJobDest = ""
            showNewJob = true
            appState.pendingSourcePaths = nil
        }
        .onAppear {
            // Seed so launch (with existing history) doesn't look like a new
            // drop and auto-navigate away from "No job selected".
            lastNewestJobID = appState.jobs.first?.id
        }
        .onChange(of: appState.jobs.first?.id) { _, newestID in
            // A drop with a default destination creates and starts a job
            // without going through the sheet — jump straight to it.
            guard !showNewJob, let newestID, newestID != lastNewestJobID else { return }
            lastNewestJobID = newestID
            selection = .job(newestID)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No job selected",
            systemImage: "externaldrive.badge.timemachine",
            description: Text("Create a copy job with the + button, pick one from the sidebar, or drag files or a folder anywhere onto this window.")
        )
    }
}
