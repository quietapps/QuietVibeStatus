import Foundation

/// Appends to `~/.quietvibestatus/debug.log`.
///
/// The bridge runs off the main thread and much of the interesting behavior happens before any UI
/// exists, where `OSLog` is awkward to read back. This is a plain file you can `tail -f`.
enum DebugLog {
    private static let queue = DispatchQueue(label: "app.quiet.qvs.debuglog")

    static var url: URL {
        BridgeServer.supportDirectory.appendingPathComponent("debug.log")
    }

    static func write(_ message: String) {
        queue.async {
            let line = "[\(Self.timestamp())] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
