import Foundation

/// What the bridge script sends us: the agent's raw hook payload plus the terminal environment it
/// was running in.
struct HookEnvelope: Decodable {
    var v: Int
    var source: String
    var env: EnvBlock
    /// Left as loose JSON because each agent's hook schema differs; adapters pick out what they need.
    var payload: JSONValue

    struct EnvBlock: Decodable {
        var term_program: String?
        var term_session_id: String?
        var iterm_session_id: String?
        var window_id: String?
        var tmux: String?
        var tmux_pane: String?
        var ghostty: String?
        var pid: String?
        var cwd: String?

        var identity: TerminalIdentity {
            TerminalIdentity(
                termProgram: term_program.nilIfEmpty,
                termSessionID: term_session_id.nilIfEmpty,
                itermSessionID: iterm_session_id.nilIfEmpty,
                windowID: window_id.nilIfEmpty,
                tmux: tmux.nilIfEmpty,
                tmuxPane: tmux_pane.nilIfEmpty,
                ghostty: !(ghostty ?? "").isEmpty,
                pid: pid.flatMap { Int($0) }
            )
        }
    }

    var agent: AgentKind {
        AgentKind(rawValue: source) ?? .claude
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

/// A minimal dynamic JSON value, so adapters can read vendor-specific fields without a Codable
/// model per agent per event.
@dynamicMemberLookup
enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    subscript(dynamicMember key: String) -> JSONValue {
        self[key]
    }

    subscript(key: String) -> JSONValue {
        guard case let .object(dict) = self else { return .null }
        return dict[key] ?? .null
    }

    subscript(index: Int) -> JSONValue {
        guard case let .array(items) = self, items.indices.contains(index) else { return .null }
        return items[index]
    }

    var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .number(value): return value == value.rounded() ? String(Int(value)) : String(value)
        case let .bool(value): return String(value)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case let .number(value): return Int(value)
        case let .string(value): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .number(value): return value
        case let .string(value): return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case let .bool(value): return value
        case let .string(value): return value == "true"
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(items) = self else { return nil }
        return items
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(dict) = self else { return nil }
        return dict
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Back to a Foundation object, for re-serializing tool input we hand back to the agent.
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .number(value): return value
        case let .string(value): return value
        case let .array(items): return items.map(\.foundationValue)
        case let .object(dict): return dict.mapValues(\.foundationValue)
        }
    }
}
