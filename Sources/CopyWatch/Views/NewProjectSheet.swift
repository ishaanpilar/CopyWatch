import SwiftUI
import AppKit

/// Create a production: name it, pick a folder template, choose the drive(s)
/// it lives on. Templates only create folders — nothing else is imposed.
struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    /// Called with the new project's ID so the caller can navigate to it.
    let onCreate: (UUID) -> Void

    @State private var name = ""
    @State private var template: ProjectTemplate = .media
    @State private var customFolders = "Footage/Card 1\nAudio\nExports"
    @State private var destParents: [String] = []

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !destParents.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Name").frame(width: 50, alignment: .trailing)
                TextField("Summer Campaign, Iceland Trip, Batch 12…", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Folder template").font(.callout)
                    Spacer()
                    Picker("Template", selection: $template) {
                        ForEach(ProjectTemplate.allCases) { t in
                            Label(t.rawValue, systemImage: t.icon).tag(t)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(template.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if template == .custom {
                    TextEditor(text: $customFolders)
                        .font(.callout.monospaced())
                        .frame(height: 96)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(.quaternaryLabelColor).opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 6))
                    Text("One folder per line. Use / for subfolders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    folderPreview
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Project drives").font(.callout)
                    if destParents.count > 1 {
                        Text("every import copies to all \(destParents.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        chooseDest()
                    } label: {
                        Label("Add drive", systemImage: "plus")
                    }
                    .font(.caption)
                }

                if destParents.isEmpty {
                    Button {
                        chooseDest()
                    } label: {
                        Label("Choose where this project lives", systemImage: "externaldrive.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(Array(destParents.enumerated()), id: \.offset) { index, path in
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive")
                                .foregroundStyle(.secondary)
                            Text(projectPathPreview(path))
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                destParents.remove(at: index)
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
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Project") {
                    let folders = customFolders.split(separator: "\n").map(String.init)
                    if let id = appState.createProject(
                        name: name, template: template,
                        customFolders: folders, destParentPaths: destParents) {
                        dismiss()
                        onCreate(id)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    /// The folders the chosen template will create, as an indented tree.
    private var folderPreview: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(template.folders, id: \.self) { folder in
                let depth = folder.components(separatedBy: "/").count - 1
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text((folder as NSString).lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, CGFloat(depth) * 16)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.quaternaryLabelColor).opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func projectPathPreview(_ parent: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty
            ? parent
            : (parent as NSString).appendingPathComponent(clean.replacingOccurrences(of: "/", with: "-"))
    }

    private func chooseDest() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the drive or folder this project lives in — its folder is created inside."
        if panel.runModal() == .OK, let url = panel.url,
           !destParents.contains(url.path) {
            destParents.append(url.path)
        }
    }
}
