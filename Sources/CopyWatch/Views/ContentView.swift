import SwiftUI

enum SidebarSelection: Hashable {
    case job(UUID)
    case compare
    case device(String)
    case volume(String)
    case about
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: SidebarSelection?
    @State private var showNewJob = false
    @State private var newJobSource = ""
    @State private var newJobDest = ""

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
            case .device(let id):
                DeviceView(deviceID: id) { jobID in
                    selection = .job(jobID)
                }
            case .volume(let path):
                VolumeView(
                    volumePath: path,
                    onNewJob: { source, dest in
                        newJobSource = source ?? ""
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
                    newJobSource = ""
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
                initialSource: newJobSource,
                initialDest: newJobDest,
                onCreate: { source, destParent, verify in
                    appState.createJob(sourcePath: source, destParentPath: destParent, verify: verify)
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
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No job selected",
            systemImage: "externaldrive.badge.timemachine",
            description: Text("Create a copy job with the + button, or pick one from the sidebar.")
        )
    }
}
