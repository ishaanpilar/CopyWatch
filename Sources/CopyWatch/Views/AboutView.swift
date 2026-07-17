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
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .padding(.top, 24)

                VStack(spacing: 4) {
                    Text("CopyWatch")
                        .font(.largeTitle.bold())
                    Text("Version \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                updateRow

                Divider().frame(maxWidth: 420)

                VStack(spacing: 10) {
                    Text("A note from Ishaan Pilar")
                        .font(.headline)
                    Text("""
                    I built CopyWatch after watching how much guesswork goes into copying and backing up files — did everything actually transfer? What happens if the drive disconnects halfway through? Which file was I on when it crashed? I ran into these questions myself often enough that I decided to build something that answers them for good, and I wanted to share it with anyone else who deals with the same thing.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    Text("— Ishaan Pilar")
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                }

                Divider().frame(maxWidth: 420)

                Button {
                    NSWorkspace.shared.open(feedbackURL)
                } label: {
                    Label("Request a Feature or Send Feedback", systemImage: "lightbulb")
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 20) {
                    Link(destination: URL(string: "https://github.com/ishaanpilar/CopyWatch")!) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://github.com/ishaanpilar/CopyWatch/releases/latest")!) {
                        Label("Latest Release", systemImage: "arrow.down.circle")
                    }
                    Link(destination: URL(string: "https://github.com/ishaanpilar/CopyWatch/issues")!) {
                        Label("Report an Issue", systemImage: "exclamationmark.bubble")
                    }
                }
                .padding(.top, 2)

                Divider().frame(maxWidth: 420)

                diagnosticsSection

                Text("© 2026 Ishaan Pilar")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("About")
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

    @ViewBuilder private var diagnosticsSection: some View {
        VStack(spacing: 8) {
            Text("Diagnostics")
                .font(.headline)
            Toggle(isOn: $diagnosticsEnabled) {
                Text("Record transfer performance logs")
            }
            .toggleStyle(.switch)
            .frame(maxWidth: 420)
            Text("When on, each copy writes a detailed timing log (throughput, read/write bottlenecks, verify time, UI lag). Useful for diagnosing slow or stuttering transfers. Leave off for normal use.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([TransferLog.directory])
            } label: {
                Label("Reveal Logs in Finder", systemImage: "folder")
            }
            .controlSize(.small)
        }
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
                Text("Checking for updates…").font(.callout).foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("You're up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .updateAvailable(let newVersion, let url):
            VStack(spacing: 6) {
                Label("Version \(newVersion) is available", systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.callout.bold())
                Link("Download from GitHub", destination: url)
            }
        case .failed(let message):
            VStack(spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Button("Try Again") {
                    Task {
                        updateStatus = .checking
                        updateStatus = await UpdateChecker.check()
                    }
                }
            }
        }
    }
}
