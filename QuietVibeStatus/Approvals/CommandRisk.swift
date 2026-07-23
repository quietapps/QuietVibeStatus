import Foundation

/// How much attention a pending tool call deserves before you wave it through.
enum RiskLevel: Int, Comparable {
    case caution
    case danger

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One reason a tool call is worth a second look.
struct RiskFinding: Equatable, Identifiable {
    let level: RiskLevel
    /// Plain description of what the command would do, not the pattern that matched it.
    let reason: String

    var id: String { "\(level.rawValue)-\(reason)" }
}

/// Flags the shapes of tool call that are worth reading twice.
///
/// Approval cards are read in a hurry, and a destructive command looks much like a harmless one at a
/// glance — `rm -rf build` and `rm -rf ~/` differ by three characters. This exists to make the
/// difference visible before the click, not to block anything: every finding is advisory, and an
/// unflagged command is not thereby endorsed. Deliberately conservative — a strip that cries wolf on
/// every `git status` teaches you to ignore the strip.
enum CommandRisk {
    static func assess(tool: String, input: JSONValue, cwd: String?) -> [RiskFinding] {
        switch tool {
        case "Bash":
            guard let command = input["command"].stringValue else { return [] }
            return assessCommand(command, cwd: cwd)
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            guard let path = input["file_path"].stringValue else { return [] }
            return assessPath(path, cwd: cwd, writing: true)
        case "Read":
            guard let path = input["file_path"].stringValue else { return [] }
            return assessPath(path, cwd: cwd, writing: false)
        default:
            return []
        }
    }

    /// The single finding a compact UI should lead with.
    static func headline(tool: String, input: JSONValue, cwd: String?) -> RiskFinding? {
        assess(tool: tool, input: input, cwd: cwd)
            .max { lhs, rhs in lhs.level < rhs.level }
    }

    // MARK: - Bash

    private static func assessCommand(_ command: String, cwd: String?) -> [RiskFinding] {
        var findings: [RiskFinding] = []
        let lower = command.lowercased()

        func flag(_ level: RiskLevel, _ reason: String) {
            guard !findings.contains(where: { $0.reason == reason }) else { return }
            findings.append(RiskFinding(level: level, reason: reason))
        }

        // Recursive force-delete. The target decides how bad it is: inside the project it is
        // routine, outside it is the command people write postmortems about.
        if lower.contains("rm ") || lower.hasPrefix("rm ") {
            let recursive = matchesFlag(lower, letters: ["r", "f"])
            for target in deletionTargets(in: command) {
                if isRootLike(target) {
                    flag(.danger, "Deletes a root or home directory")
                } else if recursive, isOutside(target, cwd: cwd) {
                    flag(.danger, "Recursively deletes a path outside the project")
                } else if recursive {
                    flag(.caution, "Recursively deletes files")
                }
            }
            if findings.isEmpty, recursive {
                flag(.caution, "Recursively deletes files")
            }
        }

        // Downloading code and executing it in one step: nothing is reviewed before it runs.
        if (lower.contains("curl ") || lower.contains("wget ")),
           lower.contains("|"),
           ["| sh", "|sh", "| bash", "|bash", "| zsh", "|zsh", "| python", "|python"]
           .contains(where: { lower.contains($0) }) {
            flag(.danger, "Pipes downloaded content straight into a shell")
        }

        if lower.hasPrefix("sudo ") || lower.contains(" sudo ") || lower.contains("&& sudo ") {
            flag(.danger, "Runs as root")
        }

        if lower.contains("mkfs") || lower.contains("diskutil erase")
            || (lower.contains("dd ") && lower.contains("of=/dev/")) {
            flag(.danger, "Writes directly to a disk device")
        }

        if lower.contains(":(){") || lower.contains(":(){:|:&};:") {
            flag(.danger, "Fork bomb")
        }

        if lower.contains("chmod 777") || lower.contains("chmod -r 777") {
            flag(.caution, "Makes files world-writable")
        }

        // History rewrites and discards — recoverable in principle, gone in practice.
        if lower.contains("git push") && (lower.contains("--force") || matchesGitForceFlag(lower)) {
            flag(.danger, "Force-pushes, overwriting remote history")
        }
        if lower.contains("git reset --hard") {
            flag(.caution, "Discards uncommitted changes")
        }
        if lower.contains("git clean") && matchesFlag(lower, letters: ["f"]) {
            flag(.caution, "Deletes untracked files")
        }
        if lower.contains("git checkout .") || lower.contains("git restore .") {
            flag(.caution, "Discards uncommitted changes")
        }

        // Anything that reads secrets is worth seeing, whatever it plans to do with them.
        for marker in ["/.ssh/", "id_rsa", "id_ed25519", ".aws/credentials", ".netrc",
                       "security find-generic-password", "keychain"] {
            if lower.contains(marker) {
                flag(.danger, "Touches credentials or private keys")
            }
        }
        if lower.contains(".env") {
            flag(.caution, "Reads or writes an environment file")
        }
        if containsLiveSecret(command) {
            flag(.danger, "Contains what looks like a live API key")
        }

        // Publishing is outward-facing and hard to walk back.
        if lower.contains("npm publish") || lower.contains("pod trunk push")
            || lower.contains("gem push") || lower.contains("cargo publish")
            || lower.contains("gh release create") {
            flag(.caution, "Publishes a release publicly")
        }

        if lower.contains("shutdown") || lower.contains("reboot") || lower.contains("halt ") {
            flag(.danger, "Shuts down or restarts the machine")
        }

        return findings
    }

    /// Whether a short flag letter appears in any flag cluster (`-rf`, `-r -f`, `--force`).
    private static func matchesFlag(_ command: String, letters: [String]) -> Bool {
        let clusters = command
            .split(separator: " ")
            .filter { $0.hasPrefix("-") && !$0.hasPrefix("--") }
            .joined()
        let long = command.contains("--recursive") || command.contains("--force")
        return letters.allSatisfy { clusters.contains($0) } || long
    }

    private static func matchesGitForceFlag(_ command: String) -> Bool {
        command.split(separator: " ").contains { $0 == "-f" || $0 == "+HEAD" || $0.hasPrefix("+") }
    }

    /// Paths a delete command would act on — every bare argument after the flags.
    private static func deletionTargets(in command: String) -> [String] {
        guard let range = command.range(of: "rm ") else { return [] }
        return command[range.upperBound...]
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.hasPrefix("-") && !$0.hasPrefix("&") && !$0.hasPrefix("|") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    }

    private static func isRootLike(_ path: String) -> Bool {
        let stripped = path.hasSuffix("/") ? String(path.dropLast()) : path
        return ["/", "~", "$HOME", "/*", "~/*", "/Users", "/System", "/Library", "/Applications"]
            .contains(stripped)
    }

    // MARK: - Paths

    private static func assessPath(_ path: String, cwd: String?, writing: Bool) -> [RiskFinding] {
        var findings: [RiskFinding] = []
        let expanded = (path as NSString).expandingTildeInPath
        let lower = expanded.lowercased()

        if lower.contains("/.ssh/") || lower.contains("/.aws/") || lower.hasSuffix("id_rsa")
            || lower.hasSuffix(".pem") || lower.contains("/.netrc") {
            findings.append(RiskFinding(level: .danger, reason: "Touches credentials or private keys"))
        } else if lower.hasSuffix(".env") || lower.contains("/.env.") {
            findings.append(RiskFinding(level: .caution, reason: "Reads or writes an environment file"))
        }

        if writing {
            if lower.hasPrefix("/etc/") || lower.hasPrefix("/system/") || lower.hasPrefix("/library/")
                || lower.contains("/launchagents/") || lower.contains("/launchdaemons/") {
                findings.append(RiskFinding(level: .danger, reason: "Writes to a system location"))
            } else if isOutside(expanded, cwd: cwd) {
                findings.append(RiskFinding(level: .caution, reason: "Writes outside the project"))
            }
        }

        return findings
    }

    /// Whether a path escapes the session's working directory.
    ///
    /// Relative paths are inside by definition, and an unknown `cwd` means we can't tell — silence
    /// beats a warning we can't stand behind.
    private static func isOutside(_ path: String, cwd: String?) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return expanded.hasPrefix("..") }
        return !expanded.hasPrefix(cwd)
    }

    /// Recognisable live-credential shapes, not the mere word "key".
    private static func containsLiveSecret(_ command: String) -> Bool {
        let prefixes = ["sk-ant-", "sk-proj-", "ghp_", "gho_", "github_pat_", "AKIA", "xoxb-", "xoxp-"]
        return prefixes.contains { command.contains($0) }
    }
}
