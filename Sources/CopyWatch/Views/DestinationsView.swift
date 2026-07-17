import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Manage saved "copy to here" locations. Any of them can be marked default
/// (drag-and-drop anywhere in the app then copies straight there, no
/// prompt) or used directly by dragging a source onto its row.
struct DestinationsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAdd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Destinations").font(.title2.bold())
                    Text("Saved copy targets — drop files on one to copy there directly.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if appState.destinationPresets.isEmpty {
                    ContentUnavailableView {
                        Label("No destinations yet", systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text("Add one so drag-and-drop knows where to copy to.")
                    } actions: {
                        Button("Add Destination") { showAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    VStack(spacing: 8) {
                        ForEach(appState.destinationPresets) { preset in
                            DestinationRow(preset: preset)
                        }
                    }
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Destination", systemImage: "plus")
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Destinations")
        .sheet(isPresented: $showAdd) {
            DestinationEditorSheet()
        }
    }
}

private struct DestinationRow: View {
    @Environment(AppState.self) private var appState
    let preset: DestinationPreset
    @State private var isTargeted = false
    @State private var editing = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: preset.isMulti ? "square.stack.3d.up.fill" : "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(preset.isDefault ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(preset.name).font(.callout.bold())
                    if preset.isMulti {
                        Text("\(preset.allPaths.count) DRIVES")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if preset.isDefault {
                        Text("DEFAULT")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                ForEach(preset.allPaths, id: \.self) { p in
                    Text(p)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if !preset.isDefault {
                Button("Make Default") { appState.setDefaultDestination(preset.id) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Button {
                editing = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                appState.removeDestinationPreset(preset.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(
            isTargeted ? Color.accentColor.opacity(0.25) : Color(.quaternaryLabelColor).opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2))
        .dropDestination(for: URL.self) { items, _ in
            appState.handleIncomingSources(items.map(\.path), destination: preset)
            return true
        } isTargeted: { isTargeted = $0 }
        .sheet(isPresented: $editing) {
            DestinationEditorSheet(preset: preset)
        }
    }
}

/// Create or edit a destination preset. A preset can hold several folders —
/// dropping onto it (or choosing it) then copies one source to all of them,
/// each independently verified.
private struct DestinationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let preset: DestinationPreset?   // nil = create new

    @State private var name: String
    @State private var paths: [String]

    init(preset: DestinationPreset? = nil) {
        self.preset = preset
        _name = State(initialValue: preset?.name ?? "")
        _paths = State(initialValue: preset?.allPaths ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(preset == nil ? "Add Destination" : "Edit Destination").font(.headline)

            HStack(spacing: 8) {
                Text("Name").frame(width: 46, alignment: .trailing)
                TextField("e.g. Archive SSD, or “Both Backups”", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Folders").font(.callout)
                    if paths.count > 1 {
                        Text("copies to all \(paths.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        addFolder()
                    } label: {
                        Label("Add folder", systemImage: "plus")
                    }
                    .font(.caption)
                }
                if paths.isEmpty {
                    Button { addFolder() } label: {
                        Label("Choose a folder", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive").foregroundStyle(.secondary)
                            Text(path).font(.callout.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                paths.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(.quaternaryLabelColor).opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(preset == nil ? "Add" : "Save") {
                    let finalName = name.isEmpty
                        ? (paths[0] as NSString).lastPathComponent
                        : name
                    if let preset {
                        appState.updateDestinationPreset(preset.id, name: finalName, paths: paths)
                    } else {
                        appState.addDestinationPreset(name: finalName, paths: paths)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(paths.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose or create a destination folder."
        if panel.runModal() == .OK, let url = panel.url, !paths.contains(url.path) {
            paths.append(url.path)
            if name.isEmpty { name = url.lastPathComponent }
        }
    }
}
