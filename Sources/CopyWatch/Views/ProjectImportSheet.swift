import SwiftUI

/// Smart Import: raised automatically when a camera/drone/audio card mounts,
/// or manually from a project's Import Media button. One click files the media
/// into the right project folder on every project drive, verified.
struct ProjectImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    /// Set when a mounted card triggered this (drives icon, label, source).
    let card: CardDetector.DetectedCard?
    /// Set when opened from inside a project (locks the project picker).
    var fixedProjectID: UUID?
    /// Manual mode: the files/folders picked in the open panel.
    var sourcePaths: [String] = []

    @State private var projectID: UUID?
    @State private var folder = ""
    @State private var label = ""
    @State private var verify = true
    @State private var algorithm: ChecksumAlgorithm = .sha256

    private var project: Project? {
        appState.projects.first { $0.id == (fixedProjectID ?? projectID) }
    }

    private var effectiveSources: [String] {
        card.map { [$0.volumePath] } ?? sourcePaths
    }

    private var anyRootConnected: Bool {
        project?.roots.contains { $0.volume.resolve($0.path) != nil } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: card?.kind.icon ?? "square.and.arrow.down")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.map { "\($0.kind.label) detected" } ?? "Import into project")
                        .font(.headline)
                    Text(card.map { "“\($0.volumeName)”" } ?? sourceSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if fixedProjectID == nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Project").frame(width: 52, alignment: .trailing)
                    Picker("Project", selection: $projectID) {
                        ForEach(appState.projects) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Folder").frame(width: 52, alignment: .trailing)
                TextField("Folder inside the project", text: $folder)
                    .textFieldStyle(.roundedBorder)
                if let project, !project.folderNames.isEmpty {
                    Menu {
                        ForEach(project.folderNames, id: \.self) { f in
                            Button(f) { folder = f }
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Pick one of the project's folders")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Label").frame(width: 52, alignment: .trailing)
                TextField("Sony FX3 Card 2", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .help("How this card appears in the project's history")
            }

            HStack {
                Toggle("Verify after copying", isOn: $verify)
                    .help("Re-reads every copy from the drive and checksums it against the card")
                Spacer()
                Picker("Checksum", selection: $algorithm) {
                    ForEach(ChecksumAlgorithm.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(algorithm.blurb)
            }

            if project != nil && !anyRootConnected {
                Label("None of this project's drives are connected — plug one in to import.",
                      systemImage: "externaldrive.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(card != nil ? "Not This Time" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import & \(verify ? "Verify" : "Copy")") {
                    if let project {
                        appState.importIntoProject(
                            project.id, sourcePaths: effectiveSources,
                            folder: folder,
                            label: label.isEmpty ? defaultLabel : label,
                            verify: verify, algorithm: algorithm)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(project == nil || effectiveSources.isEmpty || !anyRootConnected)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { seedSuggestions() }
        .onChange(of: projectID) { _, _ in seedFolderSuggestion() }
    }

    private var sourceSummary: String {
        sourcePaths.count == 1
            ? (sourcePaths[0] as NSString).lastPathComponent
            : "\(sourcePaths.count) items"
    }

    private var defaultLabel: String {
        if !folder.isEmpty { return (folder as NSString).lastPathComponent }
        return card?.volumeName ?? sourceSummary
    }

    /// Prefill project, folder, and label from the card's detected identity.
    private func seedSuggestions() {
        if fixedProjectID == nil {
            projectID = CardDetector.suggestProject(
                from: appState.projects, jobs: appState.jobs)?.id
        }
        seedFolderSuggestion()
    }

    private func seedFolderSuggestion() {
        guard let project else { return }
        if let card {
            folder = CardDetector.suggestFolder(
                for: card.kind, in: project, jobs: appState.jobs)
            let leaf = (folder as NSString).lastPathComponent
            let brand: String? = switch card.kind {
            case .camera(let b): b
            case .drone(let b): b
            case .gopro: "GoPro"
            case .audioRecorder: nil
            case .avchdCamcorder: nil
            }
            label = [brand, leaf.isEmpty ? card.volumeName : leaf]
                .compactMap { $0 }.joined(separator: " ")
        } else if folder.isEmpty {
            folder = project.folderNames.first ?? ""
        }
    }
}
