import Foundation

/// How a CLI expects each hook entry to be shaped inside its config.
///
/// Claude Code, Codex and Gemini nest the command inside a `hooks` array; Cursor lists commands
/// flat under the event name. Writing the wrong shape isn't an error — the CLI simply ignores the
/// entry, which looks exactly like the integration silently not working.
enum HookEntryStyle {
    /// `[{ "hooks": [{ "type": "command", "command": ..., "timeout": ... }] }]`
    case nested
    /// `[{ "command": ... }]`
    case flat
}

/// One CLI we can wire hooks into.
struct Integration: Identifiable {
    let id: String
    let agent: AgentKind
    let displayName: String
    /// Config file we write hooks into.
    let configPath: String
    /// Where the hooks live inside that file: `[]` means the file *is* the hooks object.
    let hooksKeyPath: [String]
    /// Event names to register, and the timeout each should get.
    let events: [(name: String, timeout: Int)]
    /// A path whose existence means this CLI is installed.
    let detectPaths: [String]
    /// Shape of each hook entry in this CLI's config.
    var entryStyle: HookEntryStyle = .nested

    var configURL: URL {
        URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
    }

    var isInstalled: Bool {
        detectPaths.contains { path in
            FileManager.default.fileExists(
                atPath: (path as NSString).expandingTildeInPath
            )
        }
    }
}

/// Installs, removes, and self-heals the hook entries that let agents talk to the app.
///
/// The guiding rule is *merge, never clobber*: these config files hold the user's own hooks and
/// often other tools' hooks too. We only ever add or remove entries whose command is ours.
@MainActor
final class IntegrationManager: ObservableObject {
    static let shared = IntegrationManager()

    /// Every command we write contains this, so we can find our own entries again.
    static let marker = "quiet-vibe-bridge"

    @Published private(set) var activeAgents: Set<AgentKind> = []

    private let prefs = Preferences.shared

    private init() {}

    // MARK: - Catalog

    let integrations: [Integration] = [
        Integration(
            id: "claude",
            agent: .claude,
            displayName: "Claude Code",
            configPath: "~/.claude/settings.json",
            hooksKeyPath: ["hooks"],
            events: [
                ("SessionStart", 5),
                ("UserPromptSubmit", 5),
                ("PreToolUse", 5),
                // Long timeout: this hook is the one the user is deciding on.
                ("PermissionRequest", 86400),
                ("PostToolUse", 5),
                ("PostToolUseFailure", 5),
                ("Notification", 5),
                ("Stop", 5),
                ("StopFailure", 5),
                ("SubagentStart", 5),
                ("SubagentStop", 5),
                ("PreCompact", 5),
                ("PostCompact", 5),
                ("SessionEnd", 5),
            ],
            detectPaths: ["~/.claude"]
        ),
        Integration(
            id: "codex",
            agent: .codex,
            displayName: "Codex",
            configPath: "~/.codex/hooks.json",
            hooksKeyPath: ["hooks"],
            events: [
                ("SessionStart", 5),
                ("UserPromptSubmit", 5),
                ("PreToolUse", 5),
                ("PermissionRequest", 7200),
                ("PostToolUse", 5),
                ("Stop", 5),
                ("SubagentStop", 5),
                ("SessionEnd", 5),
            ],
            detectPaths: ["~/.codex"]
        ),
        Integration(
            id: "gemini",
            agent: .gemini,
            displayName: "Gemini CLI",
            configPath: "~/.gemini/settings.json",
            hooksKeyPath: ["hooks"],
            events: [
                ("SessionStart", 5000),
                ("BeforeAgent", 5000),
                ("BeforeTool", 5000),
                ("AfterTool", 5000),
                ("Notification", 5000),
                ("AfterAgent", 5000),
                ("SessionEnd", 5000),
            ],
            detectPaths: ["~/.gemini"]
        ),
        Integration(
            id: "cursor",
            agent: .cursor,
            displayName: "Cursor Agent",
            configPath: "~/.cursor/hooks.json",
            hooksKeyPath: ["hooks"],
            events: [
                ("beforeSubmitPrompt", 5),
                // Short: these report activity and return immediately. A long timeout here would
                // mean a wedged app could stall a Cursor command for two hours.
                ("beforeShellExecution", 5),
                ("beforeMCPExecution", 5),
                ("beforeReadFile", 5),
                ("afterFileEdit", 5),
                ("afterShellExecution", 5),
                ("afterMCPExecution", 5),
                ("afterAgentResponse", 5),
                ("stop", 5),
                ("subagentStart", 5),
                ("subagentStop", 5),
            ],
            detectPaths: ["~/.cursor"],
            entryStyle: .flat
        ),
    ]

    func integration(for agent: AgentKind) -> Integration? {
        integrations.first { $0.agent == agent }
    }

    // MARK: - Launch

    /// Deploy the bridge script, then re-apply hooks for every agent the user has enabled. Running
    /// this every launch is what repairs configs that another tool overwrote.
    func syncOnLaunch() {
        do {
            try BridgeInstaller.deploy()
        } catch {
            Log.integrations.error("bridge deploy failed: \(error.localizedDescription)")
            return
        }

        for integration in integrations {
            let enabled = prefs.enabledAgents.contains(integration.agent.rawValue)

            if enabled, integration.isInstalled {
                try? install(integration)
            } else if !enabled {
                try? uninstall(integration)
            } else if prefs.autoConfigureNewCLIs, integration.isInstalled {
                // Newly appeared CLI and the user opted into auto-config.
                prefs.enabledAgents.append(integration.agent.rawValue)
                try? install(integration)
            }
        }

        // The status line bridge is the only source of Claude's rate limits, and its script lives in
        // the same folder as the bridge — so it needs the same every-launch repair. Without this it
        // was deployed once, at install, and never again.
        StatusLineInstaller.shared.refresh()

        refreshStatus()
        refreshRivalHooks()
    }

    func refreshStatus() {
        activeAgents = Set(
            integrations
                .filter { isActive($0) }
                .map(\.agent)
        )
    }

    // MARK: - Status

    /// True when our hook entries are actually present in the config right now.
    func isActive(_ integration: Integration) -> Bool {
        guard let root = try? readConfig(integration) else { return false }
        guard let hooks = value(at: integration.hooksKeyPath, in: root) as? [String: Any] else {
            return false
        }
        return hooks.values.contains { entries in
            guard let entries = entries as? [[String: Any]] else { return false }
            return entries.contains(where: isOurs)
        }
    }

    // MARK: - Install / uninstall

    func setEnabled(_ enabled: Bool, for agent: AgentKind) {
        guard let integration = self.integration(for: agent) else { return }

        var enabledAgents = Set(prefs.enabledAgents)
        if enabled {
            enabledAgents.insert(agent.rawValue)
            try? install(integration)
        } else {
            enabledAgents.remove(agent.rawValue)
            try? uninstall(integration)
        }
        prefs.enabledAgents = Array(enabledAgents)
        refreshStatus()
    }

    func install(_ integration: Integration) throws {
        var root = (try? readConfig(integration)) ?? [:]
        var hooks = value(at: integration.hooksKeyPath, in: root) as? [String: Any] ?? [:]

        let command = "'\(BridgeInstaller.bridgePath)' --source \(integration.agent.rawValue)"

        for event in integration.events {
            var entries = hooks[event.name] as? [[String: Any]] ?? []
            // Drop any stale entry of ours before re-adding, so timeouts and paths stay current.
            entries.removeAll(where: isOurs)
            entries.append(hookEntry(command: command, timeout: event.timeout, style: integration.entryStyle))
            hooks[event.name] = entries
        }

        root = setValue(hooks, at: integration.hooksKeyPath, in: root)
        try writeConfig(root, to: integration)
        Log.integrations.info("installed hooks for \(integration.displayName)")
    }

    func uninstall(_ integration: Integration) throws {
        guard var root = try? readConfig(integration) else { return }
        guard var hooks = value(at: integration.hooksKeyPath, in: root) as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll(where: isOurs)
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        root = setValue(hooks, at: integration.hooksKeyPath, in: root)
        try writeConfig(root, to: integration)
        Log.integrations.info("removed hooks for \(integration.displayName)")
    }

    // MARK: - Rival monitors

    /// Hooks from other agent monitors found in the configs we share with them.
    @Published private(set) var rivalHooks: [RivalHook] = []

    func refreshRivalHooks() {
        rivalHooks = RivalHookScanner.scan(integrations.filter(\.isInstalled))
    }

    /// Strip one rival's hooks from the config it was found in.
    ///
    /// Same merge rules as our own entries: only commands carrying that monitor's marker are
    /// touched, the user's other hooks are left exactly as they were, and a backup is kept.
    func removeRivalHooks(_ rival: RivalHook) throws {
        guard let integration = integrations.first(where: { $0.configURL.path == rival.configPath })
        else { return }

        guard var root = try? readConfig(integration),
              var hooks = value(at: integration.hooksKeyPath, in: root) as? [String: Any]
        else { return }

        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                RivalHookScanner.commands(in: entry).contains { $0.contains(rival.marker) }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        root = setValue(hooks, at: integration.hooksKeyPath, in: root)
        try writeConfig(root, to: integration)
        Log.integrations.info("removed \(rival.displayName) hooks from \(integration.displayName)")
        refreshRivalHooks()
    }

    /// Remove every trace of the app from every config — used by Settings → uninstall.
    func uninstallEverything() {
        for integration in integrations {
            try? uninstall(integration)
        }
        StatusLineInstaller.shared.remove()
        try? FileManager.default.removeItem(at: BridgeServer.supportDirectory)
        refreshStatus()
    }

    // MARK: - Hook entries

    private func hookEntry(command: String, timeout: Int, style: HookEntryStyle) -> [String: Any] {
        switch style {
        case .nested:
            return ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
        case .flat:
            return ["command": command]
        }
    }

    /// Recognises our own entry in either shape, so a config written by an older build — or by a
    /// different CLI's conventions — is still cleaned up correctly.
    private func isOurs(_ entry: [String: Any]) -> Bool {
        if let command = entry["command"] as? String, command.contains(Self.marker) {
            return true
        }
        if let inner = entry["hooks"] as? [[String: Any]] {
            return inner.contains { ($0["command"] as? String)?.contains(Self.marker) == true }
        }
        return false
    }

    // MARK: - Config file IO

    private func readConfig(_ integration: Integration) throws -> [String: Any] {
        let url = integration.configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }

        let cleaned = JSONCStripper.strip(data)
        let object = try JSONSerialization.jsonObject(with: cleaned)
        return object as? [String: Any] ?? [:]
    }

    private func writeConfig(_ root: [String: Any], to integration: Integration) throws {
        let url = integration.configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Keep one backup so a bad merge is always recoverable.
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("qvs-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        // Write through symlinks rather than replacing them — dotfile setups symlink these files
        // into a git repo, and replacing the link would break the user's config management.
        let resolved = url.resolvingSymlinksInPath()
        try data.write(to: resolved, options: .atomic)
    }

    // MARK: - Nested key paths

    private func value(at path: [String], in root: [String: Any]) -> Any? {
        guard !path.isEmpty else { return root }
        var current: Any? = root
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }

    private func setValue(_ value: Any, at path: [String], in root: [String: Any]) -> [String: Any] {
        guard let key = path.first else { return value as? [String: Any] ?? root }
        var copy = root
        if path.count == 1 {
            copy[key] = value
        } else {
            let child = copy[key] as? [String: Any] ?? [:]
            copy[key] = setValue(value, at: Array(path.dropFirst()), in: child)
        }
        return copy
    }
}

/// Several agents accept JSON with comments. `JSONSerialization` does not, so strip them first.
///
/// Comments inside string literals must survive, which is why this is a small state machine rather
/// than a regular expression.
enum JSONCStripper {
    static func strip(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)

        var index = 0
        var inString = false
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]

            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 {
                inString = true
                output.append(byte)
                index += 1
                continue
            }

            // `//` to end of line
            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                continue
            }

            // `/* ... */`
            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) {
                    index += 1
                }
                index += 2
                continue
            }

            output.append(byte)
            index += 1
        }

        return Data(output)
    }
}

/// Copies the bridge script out of the app bundle into a stable path the configs can point at.
enum BridgeInstaller {
    static var binDirectory: URL {
        BridgeServer.supportDirectory.appendingPathComponent("bin")
    }

    static var bridgePath: String {
        binDirectory.appendingPathComponent("quiet-vibe-bridge").path
    }

    static func deploy() throws {
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        guard
            let source = Bundle.main.url(
                forResource: "quiet-vibe-bridge",
                withExtension: nil,
                subdirectory: "bridge"
            )
        else {
            throw NSError(
                domain: "app.quiet.qvs",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "bridge script missing from app bundle"]
            )
        }

        let destination = URL(fileURLWithPath: bridgePath)
        // Always overwrite: an app update ships a new script and stale copies cause subtle bugs.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
    }
}
