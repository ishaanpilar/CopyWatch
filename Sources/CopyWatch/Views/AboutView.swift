import SwiftUI
import AppKit

/// In-app About screen (also reachable via CopyWatch menu → About CopyWatch).
struct AboutView: View {
    @State private var updateStatus: UpdateStatus = .idle
    @AppStorage("diagnosticsEnabled") private var diagnosticsEnabled = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                identity
                creatorNote
                card {
                    linkRow("questionmark.bubble", "Send Feedback",
                            "Request a feature or share an idea", feedbackURL)
                    Divider()
                    linkRow("exclamationmark.bubble", "Report an Issue",
                            "Something broken or unexpected",
                            URL(string: "https://github.com/ishaanpilar/CopyWatch/issues")!)
                    Divider()
                    linkRow("chevron.left.forwardslash.chevron.right", "View on GitHub",
                            "Source code and releases",
                            URL(string: "https://github.com/ishaanpilar/CopyWatch")!)
                }
                diagnosticsCard
                Text("© 2026 Ishaan Pilar")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("About")
    }

    // MARK: Identity

    private var identity: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 28)
            VStack(spacing: 3) {
                Text("CopyWatch")
                    .font(.title.bold())
                Text("Version \(version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Copies you can prove — by Ishaan Pilar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            updateRow
        }
    }

    private var creatorNote: some View {
        Text("“Built after watching my friend track 20TB of copies by hand, in a spreadsheet.”")
            .font(.callout)
            .italic()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    // MARK: Cards

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func linkRow(_ icon: String, _ title: String, _ subtitle: String, _ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var diagnosticsCard: some View {
        card {
            Toggle(isOn: $diagnosticsEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Performance logs").font(.callout.weight(.medium))
                    Text("Records per-copy timing details for diagnosing slow transfers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if diagnosticsEnabled {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([TransferLog.directory])
                } label: {
                    Label("Reveal Logs in Finder", systemImage: "folder")
                }
                .controlSize(.small)
            }
        }
    }

    /// Opens a prefilled GitHub issue for a feature request or feedback.
    private var feedbackURL: URL {
        let title = "Feature request / feedback: "
        let body = """
        What would you like CopyWatch to do, or what feedback do you have?


        —
        Version: \(version)
        """
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        }
        let string = "https://github.com/ishaanpilar/CopyWatch/issues/new"
            + "?labels=enhancement&title=\(enc(title))&body=\(enc(body))"
        return URL(string: string)
            ?? URL(string: "https://github.com/ishaanpilar/CopyWatch/issues/new")!
    }

    @ViewBuilder private var updateRow: some View {
        switch updateStatus {
        case .idle:
            Button {
                Task {
                    updateStatus = .checking
                    updateStatus = await UpdateChecker.check()
                }
            } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.callout).foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .updateAvailable(let newVersion, let url):
            HStack(spacing: 10) {
                Label("Version \(newVersion) available", systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.callout.bold())
                Link("Download", destination: url)
            }
        case .failed(let message):
            HStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Button("Retry") {
                    Task {
                        updateStatus = .checking
                        updateStatus = await UpdateChecker.check()
                    }
                }
            }
        }
    }
}
