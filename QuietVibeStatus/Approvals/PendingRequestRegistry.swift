import Combine
import Foundation

/// Holds the approval requests currently on screen and the continuations waiting on them.
///
/// An adapter parks a request here and awaits it; the card's buttons resolve it. If the app quits
/// or the agent disconnects, `cancelAll` releases every waiter with `.defer_` so no agent is left
/// hanging on a decision that will never come.
@MainActor
final class PendingRequestRegistry: ObservableObject {
    static let shared = PendingRequestRegistry()

    @Published private(set) var requests: [ApprovalRequest] = []

    private var continuations: [String: CheckedContinuation<ApprovalOutcome, Never>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]

    private init() {}

    func requests(for sessionID: String) -> [ApprovalRequest] {
        requests.filter { $0.sessionID == sessionID }
    }

    /// Shows the request and suspends until the user (or a timeout) resolves it.
    ///
    /// The agent's hook is blocked for as long as this runs — permission hooks are installed with a
    /// 24-hour timeout — so an unanswered card is an agent that cannot make progress. After the
    /// configured wait we resolve it as `.defer_`, which releases the hook and lets the agent fall
    /// back to its own terminal prompt. Nothing is approved or denied on the user's behalf.
    func park(_ request: ApprovalRequest) async -> ApprovalOutcome {
        // Cancellation means the agent stopped waiting on us — see `abandon`.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                requests.append(request)
                continuations[request.id] = continuation
                startTimeout(for: request.id)
                // Posted from here, and withdrawn in `resolve`, so a banner can never outlive the
                // card it belongs to however the decision was made.
                ApprovalNotifier.shared.post(
                    for: request,
                    projectName: SessionStore.shared.session(id: request.sessionID)?.projectName
                )
                DebugLog.write("registry: parked \(request.id), now \(self.requests.count) pending")
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.abandon(request.id) }
        }
    }

    /// The agent is no longer waiting for this decision, so the card is stale.
    ///
    /// A hook that hangs up has moved on without us: you answered the same prompt in the agent's own
    /// terminal, the CLI exited, or it was interrupted. The card used to stay on screen — still
    /// offering Allow and Deny for a question already settled elsewhere — until the approval timeout
    /// eventually swept it up. Resolving as `.defer_` matches what actually happened: the decision
    /// was made somewhere else, and nothing is approved or denied here.
    func abandon(_ id: String) {
        guard continuations[id] != nil else { return }
        DebugLog.write("registry: \(id) abandoned — the agent stopped waiting")
        resolve(id, with: .defer_)
    }

    func resolve(_ id: String, with outcome: ApprovalOutcome) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        requests.removeAll { $0.id == id }
        ApprovalNotifier.shared.withdraw(id)
        DebugLog.write("registry: resolve \(id) -> \(outcome)")
        continuation.resume(returning: outcome)
    }

    private func startTimeout(for id: String) {
        let minutes = Preferences.shared.approvalTimeoutMinutes
        guard minutes > 0 else { return }

        timeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            guard let self, self.continuations[id] != nil else { return }
            DebugLog.write("registry: \(id) timed out after \(minutes)m, handing back to the agent")
            self.resolve(id, with: .defer_)
        }
    }

    /// Clear a card whose tool call has already run.
    ///
    /// The agent reports every completed tool call, and a completion for a call we are still asking
    /// about means the decision was made somewhere else — you answered the same prompt in the
    /// agent's own terminal. The card is then stale: it offers Allow and Deny for something that has
    /// already happened, and until now it sat there until the approval timeout swept it up.
    ///
    /// Resolved as `.defer_`, which is the truth — this app decided nothing. Only the oldest match
    /// is cleared, so an agent running the same command twice in parallel loses one card per
    /// completion rather than both at once.
    func settleExternally(sessionID: String, tool: String, input: JSONValue) {
        let match = requests.first { request in
            guard request.sessionID == sessionID else { return false }
            guard case let .permission(pendingTool, pendingInput) = request.kind else { return false }
            return pendingTool == tool && pendingInput == input
        }
        guard let match else { return }
        DebugLog.write("registry: \(match.id) already ran — answered outside the panel")
        resolve(match.id, with: .defer_)
    }

    /// Answer every queued *permission* request from one session the same way.
    ///
    /// An agent working through a list can stack up several permissions before you look, and
    /// clicking Allow six times to unblock one session is the common case. Scoped to permissions on
    /// purpose: plans and questions each need their own answer, and sweeping them into a batch would
    /// decide something you never read.
    func resolveAll(sessionID: String, with outcome: ApprovalOutcome) {
        let batch = requests.filter { request in
            guard request.sessionID == sessionID else { return false }
            if case .permission = request.kind { return true }
            return false
        }
        DebugLog.write("registry: batch \(outcome) for \(batch.count) in \(sessionID)")
        for request in batch {
            resolve(request.id, with: outcome)
        }
    }

    /// Queued permission requests for one session, oldest first — what a batch would act on.
    func batchablePermissions(for sessionID: String) -> [ApprovalRequest] {
        requests.filter { request in
            guard request.sessionID == sessionID else { return false }
            if case .permission = request.kind { return true }
            return false
        }
    }

    /// Drop every request belonging to a session, e.g. when its card is dismissed.
    func cancel(sessionID: String) {
        for request in requests where request.sessionID == sessionID {
            resolve(request.id, with: .defer_)
        }
    }

    func cancelAll() {
        for request in requests {
            resolve(request.id, with: .defer_)
        }
    }
}
