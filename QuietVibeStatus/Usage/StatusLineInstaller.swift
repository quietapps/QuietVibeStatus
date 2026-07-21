import Foundation

/// Installs the status line bridge that lets us read Claude Code's rate limits.
///
/// This modifies a setting the user may already be using, so it is strictly reversible: the
/// original command is saved before we take over, and `remove()` puts it back verbatim.
@MainActor
final class StatusLineInstaller: ObservableObject {
    static let shared = StatusLineInstaller()

    @Published private(set) var isInstalled = false

    static var cacheDirectory: URL {
        let url = BridgeServer.supportDirectory.appendingPathComponent("cache")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var cacheURL: URL {
        cacheDirectory.appendingPathComponent("usage.json")
    }

    static var originalCommandURL: URL {
        cacheDirectory.appendingPathComponent("original-statusline-command")
    }

    static var scriptPath: String {
        BridgeInstaller.binDirectory.appendingPathComponent("quiet-vibe-statusline").path
    }

    private var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    private init() {
        refresh()
    }

    func refresh() {
        guard let root = readSettings(),
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String
        else {
            isInstalled = false
            return
        }
        isInstalled = command.contains("quiet-vibe-statusline")
    }

    func install() {
        do {
            try deployScript()

            var root = readSettings() ?? [:]
            let existing = (root["statusLine"] as? [String: Any])?["command"] as? String

            if let existing, !existing.contains("quiet-vibe-statusline") {
                // Remember what to chain to — and what to restore on removal.
                try? existing.write(to: Self.originalCommandURL, atomically: true, encoding: .utf8)
            }

            root["statusLine"] = [
                "type": "command",
                "command": Self.scriptPath,
            ]
            try writeSettings(root)
            isInstalled = true
            Log.usage.info("status line bridge installed")
        } catch {
            Log.usage.error("status line install failed: \(error.localizedDescription)")
        }
    }

    func remove() {
        guard var root = readSettings() else { return }

        let original = try? String(contentsOf: Self.originalCommandURL, encoding: .utf8)
        if let original, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root["statusLine"] = [
                "type": "command",
                "command": original.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        } else {
            root.removeValue(forKey: "statusLine")
        }

        try? writeSettings(root)
        try? FileManager.default.removeItem(at: Self.originalCommandURL)
        isInstalled = false
        Log.usage.info("status line bridge removed")
    }

    // MARK: - Helpers

    private func deployScript() throws {
        try FileManager.default.createDirectory(
            at: BridgeInstaller.binDirectory,
            withIntermediateDirectories: true
        )
        guard
            let source = Bundle.main.url(
                forResource: "quiet-vibe-statusline",
                withExtension: nil,
                subdirectory: "bridge"
            )
        else {
            throw NSError(
                domain: "app.quiet.qvs",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "status line script missing from bundle"]
            )
        }

        let destination = URL(fileURLWithPath: Self.scriptPath)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
    }

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return nil }
        let cleaned = JSONCStripper.strip(data)
        return (try? JSONSerialization.jsonObject(with: cleaned)) as? [String: Any]
    }

    private func writeSettings(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL.resolvingSymlinksInPath(), options: .atomic)
    }
}
