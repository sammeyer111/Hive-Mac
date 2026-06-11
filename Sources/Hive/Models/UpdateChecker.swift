import Foundation
import AppKit

/// Checks GitHub Releases for a newer build of the app on launch and, on
/// request, downloads it, swaps it in place, and relaunches. Only active when
/// running from a real .app bundle (dev binaries skip it entirely).
@MainActor
final class UpdateChecker: ObservableObject {
    static let repo = "sammeyer111/Hive-Mac"

    enum Status: Equatable {
        case idle
        case available(version: String)
        case downloading
        case installing
        case failed(String)
    }

    @Published var status: Status = .idle

    private var assetURL: URL?

    /// The version baked into the bundle by make-app.sh; nil for dev binaries.
    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// True only when running from an installed .app the user can replace.
    private var isUpdatableInstall: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    func checkOnLaunch() {
        guard isUpdatableInstall, let current = Self.currentVersion else {
            netlog("update: skipped (not an installed app bundle)")
            return
        }
        Task {
            await check(currentVersion: current)
        }
    }

    private func check(currentVersion: String) async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            netlog("update: no release info (offline, or no releases yet)")
            return
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(latest, than: currentVersion) else {
            netlog("update: up to date (\(currentVersion) vs latest \(latest))")
            return
        }
        // Find the zip asset.
        guard let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let urlString = zip["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString) else {
            netlog("update: release \(latest) has no zip asset")
            return
        }
        netlog("update: \(latest) available (running \(currentVersion))")
        assetURL = downloadURL
        status = .available(version: latest)
    }

    /// Semantic-ish comparison: split on dots, compare numerically.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Install

    func install() {
        guard let assetURL, case .available = status else { return }
        status = .downloading
        Task {
            do {
                try await performInstall(from: assetURL)
            } catch {
                netlog("update: install failed — \(error.localizedDescription)")
                status = .failed(error.localizedDescription)
            }
        }
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func performInstall(from url: URL) async throws {
        let (zipURL, _) = try await URLSession.shared.download(from: url)
        status = .installing

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("hive-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // ditto preserves the bundle exactly (permissions, structure).
        try run("/usr/bin/ditto", "-x", "-k", zipURL.path, work.path)
        guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError("Downloaded archive didn't contain an app")
        }
        // Belt and braces: clear quarantine so Gatekeeper can't block the swap.
        try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", newApp.path)

        let installed = Bundle.main.bundleURL
        let backup = fm.temporaryDirectory.appendingPathComponent("hive-old-\(UUID().uuidString).app")
        try fm.moveItem(at: installed, to: backup)
        do {
            try fm.moveItem(at: newApp, to: installed)
        } catch {
            // Roll back so the user still has a working app.
            try? fm.moveItem(at: backup, to: installed)
            throw UpdateError("Couldn't replace the app: \(error.localizedDescription)")
        }
        netlog("update: installed new version at \(installed.path), relaunching")

        // Relaunch the new copy and quit this one.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunch.arguments = ["-n", installed.path]
        try relaunch.run()
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSApplication.shared.terminate(nil)
    }

    private func run(_ tool: String, _ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus))")
        }
    }
}
