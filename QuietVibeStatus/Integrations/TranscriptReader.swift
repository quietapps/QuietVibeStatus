import Foundation

/// Pulls details out of an agent's conversation transcript.
///
/// The model name is only carried on `SessionStart`, which is no help for the common cases: hooks
/// installed mid-session, or the app launched after the agent. Every hook payload includes
/// `transcript_path` though, and the transcript records the model on each assistant message — so
/// the answer is always available even when the event that would have told us has long passed.
enum TranscriptReader {
    /// Read only the tail. Transcripts grow to megabytes and the newest entry is the one we want.
    private static let tailBytes = 64 * 1024

    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    /// Most recent model recorded in the transcript, e.g. `claude-opus-4-8`.
    static func model(fromTranscriptAt path: String) -> String? {
        lock.lock()
        if let cached = cache[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let model = scanForModel(path) else { return nil }

        lock.lock()
        cache[path] = model
        lock.unlock()
        return model
    }

    /// Total token usage recorded in a transcript.
    ///
    /// Unlike the model lookup this reads the whole file — usage accumulates per assistant message,
    /// so a tail scan would undercount a long session. Callers must keep it off the hot path.
    static func usage(fromTranscriptAt path: String) -> TokenUsage? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        var total = TokenUsage()
        var found = false

        for line in text.components(separatedBy: .newlines) {
            guard line.contains("\"usage\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Usage hangs off the assistant message, but some agents put it at the top level.
            let message = root["message"] as? [String: Any]
            guard let usage = (message?["usage"] ?? root["usage"]) as? [String: Any] else { continue }

            found = true
            total = total + TokenUsage(
                input: usage["input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0,
                cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0
            )
        }

        return found ? total : nil
    }

    private static func scanForModel(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)

        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        // Newest last, so walk backwards to find the model in play right now rather than the one
        // the conversation happened to start with.
        for line in text.components(separatedBy: .newlines).reversed() {
            guard line.contains("\"model\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let message = root["message"] as? [String: Any],
               let model = message["model"] as? String, !model.isEmpty
            {
                return model
            }
            if let model = root["model"] as? String, !model.isEmpty {
                return model
            }
        }

        return nil
    }
}
