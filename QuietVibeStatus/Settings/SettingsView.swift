import SwiftUI

/// Settings shell.
///
/// Uses `NavigationSplitView` with a real sidebar `List` rather than a hand-built column, so the
/// selection highlight, material, translucency, row metrics and toolbar all come from AppKit. That
/// means it looks like the rest of the system today and keeps matching it after an OS update,
/// instead of freezing whatever the conventions happened to be when it was written.
struct SettingsView: View {
    @State private var selection: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsSection.allCases) { section in
                    if let title = section.title {
                        Section(title) { rows(in: section) }
                    } else {
                        Section { rows(in: section) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            pane
                .navigationTitle(selection?.title ?? "Settings")
        }
        .frame(minWidth: 820, minHeight: 660)
    }

    private func rows(in section: SettingsSection) -> some View {
        ForEach(SettingsPane.panes(in: section)) { pane in
            // A plain Label lets the List own selection and highlighting; the icon keeps the
            // System Settings look of a tinted rounded tile.
            Label {
                Text(pane.title)
            } icon: {
                PaneIcon(pane: pane)
            }
            .tag(pane)
        }
    }

    @ViewBuilder
    private var pane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch selection ?? .general {
                case .general: GeneralPane()
                case .integrations: IntegrationsPane()
                case .notifications: NotificationsPane()
                case .display: DisplayPane()
                case .sound: SoundPane()
                case .usage: UsagePane()
                case .history: HistoryPane()
                case .shortcuts: ShortcutsPane()
                case .labs: LabsPane()
                case .about: AboutPane()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case main
    case advanced
    case app

    var id: String { rawValue }

    var title: String? {
        switch self {
        case .main: return nil
        case .advanced: return "Advanced"
        case .app: return "Quiet Vibe Status"
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, integrations, notifications, display, sound, usage, history
    case shortcuts, labs
    case about

    var id: String { rawValue }

    var section: SettingsSection {
        switch self {
        case .general, .integrations, .notifications, .display, .sound, .usage, .history: return .main
        case .shortcuts, .labs: return .advanced
        case .about: return .app
        }
    }

    static func panes(in section: SettingsSection) -> [SettingsPane] {
        allCases.filter { $0.section == section }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .integrations: return "Integrations"
        case .notifications: return "Notifications"
        case .display: return "Display"
        case .sound: return "Sound"
        case .usage: return "Usage"
        case .history: return "History"
        case .shortcuts: return "Shortcuts"
        case .labs: return "Labs"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .integrations: return "puzzlepiece.extension.fill"
        case .notifications: return "bell.fill"
        case .display: return "textformat.size"
        case .sound: return "speaker.wave.2.fill"
        case .usage: return "gauge.with.needle"
        case .history: return "clock.arrow.circlepath"
        case .shortcuts: return "keyboard.fill"
        case .labs: return "flask.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .integrations: return Theme.blue400
        case .notifications: return .red
        case .display: return .purple
        case .sound: return .green
        case .usage: return .pink
        case .history: return .teal
        case .shortcuts: return .indigo
        case .labs: return .orange
        case .about: return Theme.blue
        }
    }
}

struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(pane.tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: pane.icon)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Shared building blocks

/// A titled group of rows, matching macOS Settings' grouped-list look.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 12)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(format(value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07))
                    )
            }
            Slider(value: $value, in: range, step: step)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 12) }
    }
}
