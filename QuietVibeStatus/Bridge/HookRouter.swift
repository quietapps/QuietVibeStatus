import Foundation

/// Turns a bridge envelope into UI state and a hook response.
protocol AgentAdapter {
    var kind: AgentKind { get }
    /// Returns the JSON the agent should see on the hook's stdout.
    func handle(_ envelope: HookEnvelope) async -> String
}

/// Fans hook envelopes out to the adapter for the agent that sent them.
actor HookRouter {
    static let shared = HookRouter()

    private lazy var adapters: [AgentKind: AgentAdapter] = {
        let all: [AgentAdapter] = [
            ClaudeAdapter(),
            CodexAdapter(),
            GeminiAdapter(),
            CursorAdapter(),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })
    }()

    private init() {}

    func handle(_ envelope: HookEnvelope) async -> String {
        guard let adapter = adapters[envelope.agent] else {
            Log.bridge.error("no adapter for source \(envelope.source)")
            return "{}"
        }
        return await adapter.handle(envelope)
    }
}

/// Helpers for building the JSON an agent expects back.
enum HookResponse {
    static let empty = "{}"

    static func encode(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: []),
            let string = String(data: data, encoding: .utf8)
        else { return empty }
        return string
    }
}
