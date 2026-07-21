import Foundation
@testable import QuietVibeStatus

/// Builds the envelopes the bridge would have sent, so adapter tests exercise the real decode path
/// rather than hand-constructed `JSONValue` trees. Every fixture here is shaped like a payload an
/// agent actually emits.
enum HookFixtures {
    /// Decode an envelope from the exact JSON line the bridge script writes to the socket.
    static func envelope(
        source: String = "claude",
        pid: String? = "4242",
        cwd: String = "/tmp/project",
        payload: [String: Any]
    ) -> HookEnvelope {
        var env: [String: Any] = ["term_program": "iTerm.app", "cwd": cwd]
        if let pid { env["pid"] = pid }

        let root: [String: Any] = [
            "v": 1,
            "source": source,
            "env": env,
            "payload": payload,
        ]

        let data = try! JSONSerialization.data(withJSONObject: root)
        return try! JSONDecoder().decode(HookEnvelope.self, from: data)
    }

    static func claude(
        event: String,
        sessionID: String = "session-1",
        cwd: String = "/tmp/project",
        pid: String? = "4242",
        extra: [String: Any] = [:]
    ) -> HookEnvelope {
        var payload: [String: Any] = [
            "hook_event_name": event,
            "session_id": sessionID,
            "cwd": cwd,
        ]
        payload.merge(extra) { _, new in new }
        return envelope(source: "claude", pid: pid, cwd: cwd, payload: payload)
    }

    /// Decode a JSON object literal into the loose value adapters read from.
    static func json(_ object: [String: Any]) -> JSONValue {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Parse a hook response string back into a dictionary for assertions.
    static func decode(response: String) -> [String: Any] {
        guard
            let data = response.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return root
    }

    /// The `hookSpecificOutput.decision` block, which is what agents actually act on.
    static func decision(in response: String) -> [String: Any]? {
        let root = decode(response: response)
        let output = root["hookSpecificOutput"] as? [String: Any]
        return output?["decision"] as? [String: Any]
    }
}
