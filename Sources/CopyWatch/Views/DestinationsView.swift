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
                    Text("Drag a file or folder anywhere onto CopyWatch and it copies straight to your default destination below — no prompts. Drop onto a specific destination to send it there instead.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            AddDestinationSheet()
        }
    }
}

private struct DestinationRow: View {
    @Environment(AppState.self) private var appState
    let preset: DestinationPreset
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(preset.isDefault ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(preset.name).font(.callout.bold())
                    if preset.isDefault {
                        Text("DEFAULT")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(preset.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !preset.isDefault {
                Button("Make Default") { appState.setDefaultDestination(preset.id) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
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
    }
}

private struct AddDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var name = ""
    @State private var path = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Destination").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("e.g. Archive SSD", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Folder")
                    TextField("Where copies land", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button("Choose") { choose() }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let finalName = name.isEmpty ? (path as NSString).lastPathComponent : name
                    appState.addDestinationPreset(name: finalName, path: path)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(path.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose or create a folder to use as a destination."
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if name.isEmpty { name = url.lastPathComponent }
        }
    }
}
