import Foundation

/// Branch and worktree for a session's working directory.
///
/// Shelling out to `git` is cheap but not free, and several sessions usually share one repository,
/// so results are cached per directory with a short lifetime — long enough that a burst of hook
/// events costs one lookup, short enough to notice a branch switch.
enum GitInfo {
    struct Info {
        var branch: String?
        /// Set only when the directory is a linked worktree rather than the main checkout.
        var worktree: String?
    }

    private struct Entry {
        let info: Info
        let resolvedAt: Date
    }

    private static let lock = NSLock()
    private static var cache: [String: Entry] = [:]
    private static let ttl: TimeInterval = 30

    /// Cached lookup. Returns nil when the directory isn't a git repository.
    static func resolve(for directory: String) -> Info? {
        lock.lock()
        if let entry = cache[directory], Date().timeIntervalSince(entry.resolvedAt) < ttl {
            lock.unlock()
            return entry.info
        }
        lock.unlock()

        let info = read(directory)

        lock.lock()
        cache[directory] = Entry(info: info ?? Info(), resolvedAt: Date())
        lock.unlock()

        return info
    }

    private static func read(_ directory: String) -> Info? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }

        guard let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], in: directory),
              !branch.isEmpty
        else { return nil }

        // A detached HEAD reports "HEAD"; show the short SHA instead, which is at least actionable.
        let name: String
        if branch == "HEAD" {
            name = git(["rev-parse", "--short", "HEAD"], in: directory).map { "@\($0)" } ?? "detached"
        } else {
            name = branch
        }

        // In a linked worktree the per-worktree git dir differs from the shared common dir.
        var worktree: String?
        let gitDir = git(["rev-parse", "--absolute-git-dir"], in: directory)
        let commonDir = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)
        if let gitDir, let commonDir, gitDir != commonDir {
            worktree = (directory as NSString).lastPathComponent
        }

        return Info(branch: name, worktree: worktree)
    }

    private static func git(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
