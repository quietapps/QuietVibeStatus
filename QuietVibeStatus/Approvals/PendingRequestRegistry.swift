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
        await withCheckedContinuation { continuation in
            requests.append(request)
            continuations[request.id] = continuation
            startTimeout(for: request.id)
            DebugLog.write("registry: parked \(request.id), now \(self.requests.count) pending")
        }
    }

    func resolve(_ id: String, with outcome: ApprovalOutcome) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        requests.removeAll { $0.id == id }
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
