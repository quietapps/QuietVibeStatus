import Foundation

/// The normalized lifecycle every agent gets mapped onto.
enum NormalizedEvent {
    case sessionStart
    case promptSubmitted
    case toolStarting
    case toolFinished
    case permissionRequest
    case notification
    case turnComplete
    case turnFailed
    case subagentStart
    case subagentStop
    case sessionEnd
    case unknown
}

/// Shared implementation for agents whose hook payloads follow the same shape as Claude Code's but
/// use different event names.
///
/// Codex and Gemini both ship Claude-style hooks with their own vocabulary; rather than three
/// near-identical adapters, each supplies an event-name mapping and a few field-name fallbacks.
struct GenericAdapter: AgentAdapter {
    let kind: AgentKind
    /// Vendor event name -> normalized event.
    let eventMap: [String: NormalizedEvent]
    /// Field names to try, in order, when reading the event name out of the payload.
    var eventFields: [String] = ["hook_event_name", "hookEventName", "event", "event_name", "type"]
    var sessionFields: [String] = ["session_id", "sessionId", "conversation_id", "id"]
    var promptFields: [String] = ["prompt_text", "prompt", "user_prompt", "message"]
    var messageFields: [String] = ["last_assistant_message", "message", "response", "text"]
    var toolFields: [String] = ["tool_name", "toolName", "tool"]
    var toolInputFields: [String] = ["tool_input", "toolInput", "input", "args"]
    /// Extra places to look for the working directory. Cursor reports `workspace_roots`.
    var cwdFields: [String] = ["cwd", "workspace_root", "workspaceRoot"]
    /// Whether this agent honors Claude-style `hookSpecificOutput.decision` responses.
    var supportsPermissionDecisions: Bool = true
    /// Cursor answers permission hooks with a flat `{"permission": "allow"|"deny"}` instead of
    /// Claude's nested `hookSpecificOutput.decision`.
    var usesFlatPermissionResponse: Bool = false

    func handle(_ envelope: HookEnvelope) async -> String {
        let payload = envelope.payload
        let rawEvent = firstString(payload, eventFields) ?? ""
        let event = eventMap[rawEvent] ?? .unknown

        // Without a session id from the agent, fall back to the shell's pid so at least each
        // terminal keeps its own card instead of every session collapsing into one.
        let fallbackID = "\(kind.rawValue)-\(envelope.env.pid ?? "0")"
        let sessionID = firstString(payload, sessionFields) ?? fallbackID
        let cwd = resolveCwd(payload, envelope: envelope)
        let identity = envelope.env.identity

        switch event {
        case .sessionStart:
            let created = await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: kind, cwd: cwd) { session in
                    session.terminal = identity
                    session.model = ActivityFormatter.modelLabel(payload["model"].stringValue)
                    session.state = .idle
                }
            }
            if created != nil { await SessionSoundGate.playStart(for: sessionID) }

        case .promptSubmitted:
            let updated = await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: kind, cwd: cwd) { session in
                    session.terminal = identity
                    session.lastPrompt = firstString(payload, promptFields)
                    session.state = .working
                    session.recap = nil
                }
            }
            guard updated != nil else { return HookResponse.empty }
            SoundEngine.shared.play(.taskAcknowledge)

        case .toolStarting:
            let (tool, input) = resolveTool(payload)
            await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: kind, cwd: cwd) { session in
                    session.terminal = identity
                    session.lastActivity = ActivityFormatter.describe(tool: tool, input: input)
                    session.lastActivityAt = Date()
                    if !session.state.isBlocked { session.state = .working }
                }
            }

        case .toolFinished:
            await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: kind, cwd: cwd) { session in
                    session.lastActivityAt = Date()
                }
            }

        case .permissionRequest:
            return await handlePermission(
                payload: payload,
                sessionID: sessionID,
                cwd: cwd,
                identity: identity
            )

        case .notification:
            await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: kind, cwd: cwd) { session in
                    session.lastActivity = firstString(payload, messageFields)
                    if !session.state.isBlocked { session.state = .needsAnswer }
                }
            }
            SoundEngine.shared.play(.approvalNeeded)

        case .turnComplete:
            await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: kind, cwd: cwd) { session in
                    session.state = .complete
                    session.recap = firstString(payload, messageFields)
                    session.lastActivity = nil
                    session.revealedAt = Date()
                }
                if let session = SessionStore.shared.session(id: sessionID) {
                    NotchController.shared.reveal(for: session)
                }
            }
            SoundEngine.shared.play(.taskComplete)

        case .turnFailed:
            await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: kind, cwd: cwd) { session in
                    session.state = .failed
                    session.errorMessage = firstString(payload, messageFields)
                }
            }
            SoundEngine.shared.play(.taskError)

        case .subagentStart:
            let agentID = payload["agent_id"].stringValue ?? UUID().uuidString
            let type = payload["agent_type"].stringValue ?? "Agent"
            await MainActor.run {
                SessionStore.shared.startSubagent(sessionID: sessionID, agentID: agentID, type: type)
            }

        case .subagentStop:
            let agentID = payload["agent_id"].stringValue ?? ""
            await MainActor.run {
                SessionStore.shared.finishSubagent(sessionID: sessionID, agentID: agentID)
            }

        case .sessionEnd:
            await MainActor.run {
                PendingRequestRegistry.shared.cancel(sessionID: sessionID)
                SessionStore.shared.sessionDidEnd(id: sessionID)
            }

        case .unknown:
            break
        }

        return HookResponse.empty
    }

    /// Work out what tool is running and what it is acting on.
    ///
    /// Claude-style payloads carry `tool_name` plus a `tool_input` object. Cursor instead puts the
    /// interesting value at the top level — `command` for a shell call, `file_path` for a read —
    /// with no tool name at all. Without this the card could only ever say "Tool", which is the
    /// detail that goes missing on Cursor sessions.
    private func resolveTool(_ payload: JSONValue) -> (name: String, input: JSONValue) {
        let name = firstString(payload, toolFields)
        let input = firstValue(payload, toolInputFields)

        if let name, !input.isNull { return (name, input) }

        if let command = payload["command"].stringValue, !command.isEmpty {
            return (name ?? "Bash", .object(["command": .string(command)]))
        }
        if let path = payload["file_path"].stringValue, !path.isEmpty {
            let edits = payload["edits"].arrayValue
            return (name ?? (edits == nil ? "Read" : "Edit"), .object(["file_path": .string(path)]))
        }
        if let url = payload["url"].stringValue, !url.isEmpty {
            return (name ?? "WebFetch", .object(["url": .string(url)]))
        }
        if let server = payload["server_name"].stringValue, !server.isEmpty {
            let tool = payload["tool_name"].stringValue ?? server
            return ("mcp__\(server)__\(tool)", input)
        }

        return (name ?? "Tool", input)
    }

    /// Working directory, from whichever field this agent uses. Cursor sends an array of
    /// workspace roots rather than a single `cwd`.
    private func resolveCwd(_ payload: JSONValue, envelope: HookEnvelope) -> String {
        for key in cwdFields {
            if let value = payload[key].stringValue, !value.isEmpty { return value }
        }
        if let roots = payload["workspace_roots"].arrayValue,
           let first = roots.first?.stringValue, !first.isEmpty
        {
            return first
        }
        return envelope.env.cwd ?? NSHomeDirectory()
    }

    private func handlePermission(
        payload: JSONValue,
        sessionID: String,
        cwd: String,
        identity: TerminalIdentity
    ) async -> String {
        let (tool, input) = resolveTool(payload)
        let requestID = UUID().uuidString

        let request = await MainActor.run { () -> ApprovalRequest? in
            let created = SessionStore.shared.upsert(id: sessionID, agent: kind, cwd: cwd) { session in
                session.terminal = identity
                session.state = .needsApproval
                session.lastActivity = ActivityFormatter.describe(tool: tool, input: input)
            }
            guard created != nil else { return nil }
            NotchController.shared.demandAttention(sessionID: sessionID)
            return ApprovalRequest(
                id: requestID,
                sessionID: sessionID,
                agent: kind,
                kind: .permission(tool: tool, input: input)
            )
        }

        guard let request else { return HookResponse.empty }
        SoundEngine.shared.play(.approvalNeeded)

        let outcome = await PendingRequestRegistry.shared.park(request)

        await MainActor.run {
            SessionStore.shared.setState(.working, for: sessionID)
            NotchController.shared.attentionResolved()
        }

        guard supportsPermissionDecisions else { return HookResponse.empty }

        if usesFlatPermissionResponse {
            switch outcome {
            case .allow, .allowAlways:
                return HookResponse.encode(["permission": "allow"])
            case .deny:
                return HookResponse.encode(["permission": "deny"])
            default:
                // "ask" hands the decision back to the agent's own prompt.
                return HookResponse.empty
            }
        }

        switch outcome {
        case .allow:
            return decisionResponse(["behavior": "allow"])
        case .allowAlways:
            return decisionResponse([
                "behavior": "allow",
                "applyRules": PermissionRule.forAlwaysAllow(tool: tool, input: input),
            ])
        case let .deny(reason):
            var decision: [String: Any] = ["behavior": "deny"]
            if let reason, !reason.isEmpty { decision["message"] = reason }
            return decisionResponse(decision)
        default:
            return HookResponse.empty
        }
    }

    private func decisionResponse(_ decision: [String: Any]) -> String {
        HookResponse.encode([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ])
    }

    // MARK: - Field lookup

    private func firstString(_ payload: JSONValue, _ keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key].stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    private func firstValue(_ payload: JSONValue, _ keys: [String]) -> JSONValue {
        for key in keys where !payload[key].isNull {
            return payload[key]
        }
        return .null
    }
}

// MARK: - Concrete agents

/// Codex ships Claude-compatible hook names in `~/.codex/hooks.json`.
struct CodexAdapter: AgentAdapter {
    let kind: AgentKind = .codex

    private let generic = GenericAdapter(
        kind: .codex,
        eventMap: [
            "SessionStart": .sessionStart,
            "UserPromptSubmit": .promptSubmitted,
            "PreToolUse": .toolStarting,
            "PostToolUse": .toolFinished,
            "PermissionRequest": .permissionRequest,
            "Notification": .notification,
            "Stop": .turnComplete,
            "SubagentStart": .subagentStart,
            "SubagentStop": .subagentStop,
            "SessionEnd": .sessionEnd,
        ]
    )

    func handle(_ envelope: HookEnvelope) async -> String {
        await generic.handle(envelope)
    }
}

/// Gemini CLI uses Before/After naming in `~/.gemini/settings.json`.
struct GeminiAdapter: AgentAdapter {
    let kind: AgentKind = .gemini

    private let generic = GenericAdapter(
        kind: .gemini,
        eventMap: [
            "SessionStart": .sessionStart,
            "BeforeAgent": .promptSubmitted,
            "BeforeTool": .toolStarting,
            "AfterTool": .toolFinished,
            "Notification": .notification,
            "AfterAgent": .turnComplete,
            "SessionEnd": .sessionEnd,
        ],
        // Gemini's hook contract does not document a permission decision response, so we surface
        // the card for visibility but let its own prompt make the call.
        supportsPermissionDecisions: false
    )

    func handle(_ envelope: HookEnvelope) async -> String {
        await generic.handle(envelope)
    }
}

/// Cursor Agent. Event names are detected leniently because its hook API is still moving.
struct CursorAdapter: AgentAdapter {
    let kind: AgentKind = .cursor

    private let generic = GenericAdapter(
        kind: .cursor,
        eventMap: [
            "beforeSubmitPrompt": .promptSubmitted,
            // Deliberately activity, not a permission request. Cursor fires these before *every*
            // shell and MCP call, whether or not it intends to ask you anything — they are a
            // chance to weigh in, not a signal that the agent is blocked. Treating them as
            // approvals invented prompts Cursor never made, and worse, held its hook open so the
            // agent stalled waiting on a card while Cursor itself showed nothing.
            "beforeShellExecution": .toolStarting,
            "beforeMCPExecution": .toolStarting,
            "beforeReadFile": .toolStarting,
            "afterFileEdit": .toolFinished,
            "afterShellExecution": .toolFinished,
            "afterMCPExecution": .toolFinished,
            "afterAgentResponse": .turnComplete,
            "stop": .turnComplete,
            "subagentStart": .subagentStart,
            "subagentStop": .subagentStop,
        ],
        sessionFields: ["conversation_id", "conversationId", "session_id", "sessionId", "thread_id"],
        promptFields: ["prompt", "prompt_text", "text", "message"],
        usesFlatPermissionResponse: true
    )

    func handle(_ envelope: HookEnvelope) async -> String {
        await generic.handle(envelope)
    }
}
