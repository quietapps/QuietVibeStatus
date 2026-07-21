import AppKit

/// The terminals and IDEs a session can be running inside.
///
/// Identified from `TERM_PROGRAM` (set by the terminal itself) with a bundle-id fallback, since
/// some hosts — notably VS Code forks — share a `TERM_PROGRAM` value.
enum TerminalApp: String, CaseIterable {
    case iTerm2
    case appleTerminal
    case warp
    case ghostty
    case vscode
    case cursor
    case windsurf
    case wezterm
    case kitty
    case alacritty
    case hyper
    case zed
    case unknown

    var displayName: String {
        switch self {
        case .iTerm2: return "iTerm2"
        case .appleTerminal: return "Terminal"
        case .warp: return "Warp"
        case .ghostty: return "Ghostty"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .wezterm: return "WezTerm"
        case .kitty: return "Kitty"
        case .alacritty: return "Alacritty"
        case .hyper: return "Hyper"
        case .zed: return "Zed"
        case .unknown: return "Terminal"
        }
    }

    var bundleID: String? {
        switch self {
        case .iTerm2: return "com.googlecode.iterm2"
        case .appleTerminal: return "com.apple.Terminal"
        case .warp: return "dev.warp.Warp-Stable"
        case .ghostty: return "com.mitchellh.ghostty"
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .windsurf: return "com.exafunction.windsurf"
        case .wezterm: return "com.github.wez.wezterm"
        case .kitty: return "net.kovidgoyal.kitty"
        case .alacritty: return "org.alacritty"
        case .hyper: return "co.zeit.hyper"
        case .zed: return "dev.zed.Zed"
        case .unknown: return nil
        }
    }

    static var allBundleIDs: Set<String> {
        Set(allCases.compactMap(\.bundleID))
    }

    /// Resolve from the environment the bridge captured.
    static func resolve(from identity: TerminalIdentity) -> TerminalApp {
        if identity.ghostty { return .ghostty }

        switch identity.termProgram?.lowercased() {
        case "iterm.app": return .iTerm2
        case "apple_terminal": return .appleTerminal
        case "warpterminal", "warp": return .warp
        case "ghostty": return .ghostty
        case "wezterm": return .wezterm
        case "kitty": return .kitty
        case "alacritty": return .alacritty
        case "hyper": return .hyper
        case "zed": return .zed
        case "vscode":
            // VS Code forks all report TERM_PROGRAM=vscode; disambiguate by what's running.
            let running = Set(
                NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            )
            if running.contains(TerminalApp.cursor.bundleID ?? "") { return .cursor }
            if running.contains(TerminalApp.windsurf.bundleID ?? "") { return .windsurf }
            return .vscode
        default:
            return .unknown
        }
    }

    var isRunning: Bool {
        guard let bundleID else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}
