import Foundation

enum UpdateStatus: Equatable {
    case idle, checking
    case upToDate
    case updateAvailable(version: String, url: URL)
    case failed(String)
}

/// Checks GitHub Releases for a newer CopyWatch than the running build.
/// Read-only, user-initiated only — no background polling.
@MainActor
final class UpdateChecker {
    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }

    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func check() async -> UpdateStatus {
        guard let url = URL(string: "https://api.github.com/repos/ishaanpilar/CopyWatch/releases/latest") else {
            return .failed("Invalid update URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed("Couldn't reach GitHub to check for updates.")
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let current = currentVersion()
            guard let releaseURL = URL(string: release.html_url) else {
                return .failed("Malformed release URL.")
            }
            if compare(latest, isNewerThan: current) {
                return .updateAvailable(version: latest, url: releaseURL)
            }
            return .upToDate
        } catch {
            return .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    /// Simple dotted-version comparison ("1.10.0" > "1.9.2"), padding short components with 0.
    private static func compare(_ a: String, isNewerThan b: String) -> Bool {
        let av = a.split(separator: ".").compactMap { Int($0) }
        let bv = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
