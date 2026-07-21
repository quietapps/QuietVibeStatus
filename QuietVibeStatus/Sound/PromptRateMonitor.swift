import Foundation

/// Detects a burst of prompts in one session — the "you are typing faster than the agent can
/// think" case that the spam detection sound exists for.
actor PromptRateMonitor {
    static let shared = PromptRateMonitor()

    private var timestamps: [String: [Date]] = [:]

    /// Matches the description shown in Settings: 3 or more prompts within 10 seconds.
    private let threshold = 3
    private let window: TimeInterval = 10

    private init() {}

    func record(sessionID: String) {
        let now = Date()
        var recent = (timestamps[sessionID] ?? []).filter { now.timeIntervalSince($0) < window }
        recent.append(now)
        timestamps[sessionID] = recent

        guard recent.count >= threshold else { return }
        // Reset so a sustained burst fires once per group rather than on every prompt after the third.
        timestamps[sessionID] = []
        SoundEngine.shared.play(.spamDetection)
    }
}
