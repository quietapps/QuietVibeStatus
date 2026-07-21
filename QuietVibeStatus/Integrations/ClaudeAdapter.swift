import Foundation

/// Maps Claude Code's hook events onto sessions, approval cards, and hook responses.
///
/// Event and response field names come from the Claude Code hooks reference; anything unrecognized
/// falls through to an empty response so a future event can never wedge a session.
struct ClaudeAdapter: AgentAdapter {
    let kind: AgentKind = .claude

    func handle(_ envelope: HookEnvelope) async -> String {
        let payload = envelope.payload
        guard let event = payload["hook_event_name"].stringValue else { return HookResponse.empty }

        let sessionID = payload["session_id"].stringValue ?? UUID().uuidString
        let cwd = payload["cwd"].stringValue ?? envelope.env.cwd ?? NSHomeDirectory()
        let identity = envelope.env.identity

        switch event {
        case "SessionStart":
            await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: .claude, cwd: cwd) { session in
                    session.terminal = identity
                    session.model = ActivityFormatter.modelLabel(payload["model"].stringValue)
                    session.sessionTitle = payload["session_title"].stringValue
                    session.state = .idle
                    session.lastActivity = nil
                }
            }
            SoundEngine.shared.play(.sessionStart)

        case "UserPromptSubmit":
            await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: .claude, cwd: cwd) { session in
                    session.terminal = identity
                    session.lastPrompt = payload["prompt_text"].stringValue
                    session.state = .working
                    session.recap = nil
                    session.errorMessage = nil
                    session.lastActivity = nil
                }
            }
            SoundEngine.shared.play(.taskAcknowledge)
            await PromptRateMonitor.shared.record(sessionID: sessionID)

        case "PreToolUse":
            let tool = payload["tool_name"].stringValue ?? "Tool"
            let activity = ActivityFormatter.describe(tool: tool, input: payload["tool_input"])
            await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: .claude, cwd: cwd) { session in
                    session.terminal = identity
                    session.lastActivity = activity
                    session.lastActivityAt = Date()
                    if !session.state.isBlocked { session.state = .working }
                }
            }

        case "PermissionRequest":
            return await handlePermissionRequest(
                payload: payload,
                sessionID: sessionID,
                cwd: cwd,
                identity: identity
            )

        case "PostToolUse", "PostToolUseFailure":
            await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: .claude, cwd: cwd) { session in
                    session.lastActivityAt = Date()
                    if event == "PostToolUseFailure" {
                        session.lastActivity = "Tool failed"
                    }
                }
            }

        case "Notification":
            await handleNotification(payload: payload, sessionID: sessionID, cwd: cwd)

        case "Stop":
            await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: .claude, cwd: cwd) { session in
                    session.state = .complete
                    session.recap = payload["last_assistant_message"].stringValue
                    session.lastActivity = nil
                    session.revealedAt = Date()
                }
                if let session = SessionStore.shared.session(id: sessionID) {
                    NotchController.shared.reveal(for: session)
                }
            }
            SoundEngine.shared.play(.taskComplete)

        case "StopFailure":
            await MainActor.run {
                SessionStore.shared.upsert(id: sessionID, agent: .claude, cwd: cwd) { session in
                    session.state = .failed
                    session.errorMessage = payload["error_type"].stringValue
                    session.revealedAt = Date()
                }
                if let session = SessionStore.shared.session(id: sessionID) {
                    NotchController.shared.reveal(for: session)
                }
            }
            SoundEngine.shared.play(.taskError)

        case "SubagentStart":
            let agentID = payload["agent_id"].stringValue ?? UUID().uuidString
            let type = payload["agent_type"].stringValue ?? "Agent"
            await MainActor.run {
                SessionStore.shared.startSubagent(sessionID: sessionID, agentID: agentID, type: type)
            }

        case "SubagentStop":
            let agentID = payload["agent_id"].stringValue ?? ""
            await MainActor.run {
                SessionStore.shared.finishSubagent(sessionID: sessionID, agentID: agentID)
            }
            if Preferences.shared.subagentNotifications == .immediately {
                SoundEngine.shared.play(.taskComplete)
            }

        case "PreCompact":
            await MainActor.run {
                SessionStore.shared.setState(.compacting, for: sessionID)
            }
            // Compaction is the observable signal that the context window filled up.
            SoundEngine.shared.play(.contextLimit)

        case "PostCompact":
            await MainActor.run {
                SessionStore.shared.setState(.working, for: sessionID)
            }

        case "SessionEnd":
            await MainActor.run {
                PendingRequestRegistry.shared.cancel(sessionID: sessionID)
                SessionStore.shared.sessionDidEnd(id: sessionID)
            }

        default:
            break
        }

        // Backfill the model when we don't already have it. SessionStart is the only event that
        // carries it and it has usually long gone. Runs *after* the switch on purpose: the event
        // above is what creates the session, and writing a model to a session that doesn't exist
        // yet is a silent no-op.
        await resolveModelIfNeeded(sessionID: sessionID, payload: payload)

        return HookResponse.empty
    }

    /// Fill in the model for a session that never gave us one.
    private func resolveModelIfNeeded(sessionID: String, payload: JSONValue) async {
        let needsModel = await MainActor.run {
            SessionStore.shared.session(id: sessionID)?.model == nil
        }
        guard needsModel else { return }

        // Prefer the event's own field; fall back to reading the transcript.
        var raw = payload["model"].stringValue
        if raw == nil, let path = payload["transcript_path"].stringValue {
            raw = await Task.detached(priority: .utility) {
                TranscriptReader.model(fromTranscriptAt: path)
            }.value
        }

        guard let label = ActivityFormatter.modelLabel(raw) else { return }
        await MainActor.run {
            SessionStore.shared.setModel(label, for: sessionID)
        }
    }

    // MARK: - Blocking events

    /// Everything that makes the agent wait on the user. The connection stays open for as long as
    /// this function runs, which is what turns the notch into the approval surface.
    private func handlePermissionRequest(
        payload: JSONValue,
        sessionID: String,
        cwd: String,
        identity: TerminalIdentity
    ) async -> String {
        let tool = payload["tool_name"].stringValue ?? "Tool"
        let input = payload["tool_input"]
        let requestID = UUID().uuidString

        let kind: ApprovalKind
        let state: SessionState

        switch tool {
        case "ExitPlanMode":
            kind = .planReview(plan: input["plan"].stringValue ?? "")
            state = .needsPlanReview
        case "AskUserQuestion":
            guard let questions = QuestionParser.parse(input) else {
                return HookResponse.empty
            }
            kind = .question(questions)
            state = .needsAnswer
        default:
            kind = .permission(tool: tool, input: input)
            state = .needsApproval
        }

        let request = await MainActor.run { () -> ApprovalRequest? in
            let created = SessionStore.shared.upsert(id: sessionID, agent: .claude, cwd: cwd) { session in
                session.terminal = identity
                session.state = state
                session.lastActivity = ActivityFormatter.describe(tool: tool, input: input)
            }
            guard created != nil else { return nil }
            NotchController.shared.demandAttention(sessionID: sessionID)
            return ApprovalRequest(id: requestID, sessionID: sessionID, agent: .claude, kind: kind)
        }

        // Session was filtered out — stay out of the way entirely.
        guard let request else { return HookResponse.empty }

        SoundEngine.shared.play(.approvalNeeded)

        let outcome = await PendingRequestRegistry.shared.park(request)

        await MainActor.run {
            SessionStore.shared.setState(.working, for: sessionID)
            NotchController.shared.attentionResolved()
        }

        return response(for: outcome, tool: tool, input: input)
    }

    private func response(for outcome: ApprovalOutcome, tool: String, input: JSONValue) -> String {
        switch outcome {
        case .allow, .approvePlan:
            var decision: [String: Any] = ["behavior": "allow"]
            if case let .approvePlan(autoMode) = outcome, autoMode {
                // Matches Claude Code's own "auto-accept edits" choice after a plan.
                decision["applyRules"] = "acceptEdits"
            }
            return HookResponse.encode([
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": decision,
                ],
            ])

        case .allowAlways:
            return HookResponse.encode([
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "applyRules": PermissionRule.forAlwaysAllow(tool: tool, input: input),
                    ],
                ],
            ])

        case let .deny(reason):
            var decision: [String: Any] = ["behavior": "deny"]
            if let reason, !reason.isEmpty { decision["message"] = reason }
            return HookResponse.encode([
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": decision,
                ],
            ])

        case let .rejectPlan(feedback):
            return HookResponse.encode([
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "deny",
                        "message": feedback.isEmpty ? "Plan rejected." : feedback,
                    ],
                ],
            ])

        case let .answered(answers):
            // Allow the tool through with the user's answers already filled in, which is how the
            // question gets answered without the terminal ever prompting.
            var updated = input.objectValue?.mapValues(\.foundationValue) ?? [:]
            updated["answers"] = answers
            return HookResponse.encode([
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updated,
                    ],
                ],
            ])

        case .defer_:
            // No opinion — Claude Code shows its own prompt in the terminal.
            return HookResponse.empty
        }
    }

    private func handleNotification(payload: JSONValue, sessionID: String, cwd: String) async {
        let type = payload["notification_type"].stringValue ?? ""
        let message = payload["message"].stringValue

        await MainActor.run {
            SessionStore.shared.upsert(id: sessionID, agent: .claude, cwd: cwd) { session in
                switch type {
                case "idle_prompt":
                    session.state = .idle
                case "agent_needs_input", "permission_prompt":
                    // The approval card handles the real decision; this only marks the card.
                    if !session.state.isBlocked { session.state = .needsAnswer }
                case "agent_completed":
                    session.state = .complete
                default:
                    break
                }
                if let message { session.lastActivity = message }
            }
        }

        if type == "idle_prompt" {
            SoundEngine.shared.play(.idleReminder)
        }
    }
}

/// Builds the `applyRules` string that makes "Always allow" stick for future calls.
enum PermissionRule {
    static func forAlwaysAllow(tool: String, input: JSONValue) -> String {
        switch tool {
        case "Bash":
            // Scope the rule to the command's head, so "npm test" doesn't allow all of npm.
            let command = input["command"].stringValue ?? ""
            let head = command.split(separator: " ").prefix(2).joined(separator: " ")
            return head.isEmpty ? "Bash" : "Bash(\(head):*)"
        case "Read", "Edit", "Write":
            return tool
        default:
            return tool
        }
    }
}

/// Reads the `AskUserQuestion` tool input into something the wizard can render.
enum QuestionParser {
    static func parse(_ input: JSONValue) -> QuestionSet? {
        guard let rawQuestions = input["questions"].arrayValue, !rawQuestions.isEmpty else {
            return nil
        }

        let items: [QuestionItem] = rawQuestions.compactMap { raw in
            guard let question = raw["question"].stringValue else { return nil }
            let options = (raw["options"].arrayValue ?? []).compactMap { option -> QuestionItem.Option? in
                guard let label = option["label"].stringValue else { return nil }
                return QuestionItem.Option(
                    label: label,
                    description: option["description"].stringValue ?? ""
                )
            }
            return QuestionItem(
                header: raw["header"].stringValue ?? "Question",
                question: question,
                options: options,
                multiSelect: raw["multiSelect"].boolValue ?? false
            )
        }

        guard !items.isEmpty else { return nil }
        return QuestionSet(items: items, rawInput: input)
    }
}
