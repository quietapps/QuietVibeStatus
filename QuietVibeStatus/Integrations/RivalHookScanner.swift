import Foundation

/// A hook belonging to another agent monitor, found in a config we also write to.
struct RivalHook: Identifiable, Equatable {
    /// Config file it lives in, e.g. `~/.claude/settings.json`.
    var configPath: String
    var displayName: String
    /// Event names it is registered for, sorted.
    var events: [String]
    /// The substring that identifies every one of its entries.
    var marker: String

    var id: String { configPath + "|" + marker }

    var summary: String {
        let file = (configPath as NSString).abbreviatingWithTildeInPath
        return "\(displayName) — \(events.count) hook\(events.count == 1 ? "" : "s") in \(file)"
    }
}

/// Finds hooks from *other* agent monitors sitting alongside ours.
///
/// Two monitors watching the same CLI both get every event, so the user sees duplicate cards, hears
/// every sound twice, and — worst — two apps race to answer the same permission request. This also
/// catches the common case of an uninstalled rival whose hooks were never cleaned up: the entry
/// stays, and each event still pays to spawn a helper that does nothing.
enum RivalHookScanner {
    /// Known monitors, matched on the substring their hook command always contains.
    ///
    /// Pattern matching is deliberately narrow. A user's own hook that merely mentions an agent
    /// must never be offered up for deletion, so we only claim entries we can name.
    private static let known: [(marker: String, name: String)] = [
        ("vibe-island", "Vibe Island"),
        ("notchnook", "NotchNook"),
        ("dynamic-island", "Dynamic Island"),
        ("boring.notch", "The Boring Notch"),
        ("ai-island", "AI Island"),
    ]

    /// Every rival hook across the configs the given integrations own.
    static func scan(_ integrations: [Integration]) -> [RivalHook] {
        integrations.flatMap { scan($0) }
    }

    static func scan(_ integration: Integration) -> [RivalHook] {
        let url = integration.configURL
        guard
            let data = try? Data(contentsOf: url),
            !data.isEmpty,
            let root = try? JSONSerialization.jsonObject(with: JSONCStripper.strip(data)) as? [String: Any],
            let hooks = nested(root, path: integration.hooksKeyPath) as? [String: Any]
        else { return [] }

        var eventsByMarker: [String: Set<String>] = [:]

        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for command in entries.flatMap(commands) {
                for rival in known where command.contains(rival.marker) {
                    eventsByMarker[rival.marker, default: []].insert(event)
                }
            }
        }

        return known.compactMap { rival in
            guard let events = eventsByMarker[rival.marker], !events.isEmpty else { return nil }
            return RivalHook(
                configPath: url.path,
                displayName: rival.name,
                events: events.sorted(),
                marker: rival.marker
            )
        }
    }

    /// Every command string in a hook entry, in either the nested or flat shape.
    static func commands(in entry: [String: Any]) -> [String] {
        var found: [String] = []
        if let command = entry["command"] as? String { found.append(command) }
        if let inner = entry["hooks"] as? [[String: Any]] {
            found.append(contentsOf: inner.compactMap { $0["command"] as? String })
        }
        return found
    }

    private static func nested(_ root: [String: Any], path: [String]) -> Any? {
        guard !path.isEmpty else { return root }
        var current: Any? = root
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }
}
