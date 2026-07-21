import OSLog

enum Log {
    private static let subsystem = "app.quiet.QuietVibeStatus"

    static let bridge = Logger(subsystem: subsystem, category: "bridge")
    static let sessions = Logger(subsystem: subsystem, category: "sessions")
    static let integrations = Logger(subsystem: subsystem, category: "integrations")
    static let jump = Logger(subsystem: subsystem, category: "jump")
    static let sound = Logger(subsystem: subsystem, category: "sound")
    static let usage = Logger(subsystem: subsystem, category: "usage")
}
