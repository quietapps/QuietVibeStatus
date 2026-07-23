import SwiftUI

/// The card shown when an agent is waiting on a decision.
struct ApprovalCard: View {
    let request: ApprovalRequest

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var prefs: Preferences

    private var session: Session? { store.session(id: request.sessionID) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            header

            switch request.kind {
            case let .permission(tool, input):
                PermissionBody(tool: tool, input: input, request: request)
            case let .planReview(plan):
                PlanReviewBody(plan: plan, request: request)
            case let .question(set):
                QuestionWizard(questions: set, request: request)
            }
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous)
                .fill(Theme.attention.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous)
                .strokeBorder(Theme.attention.opacity(0.55), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.attention)
            Text(headline)
                .font(Theme.ui(prefs.contentFontSize + 1, weight: .semibold))
                .foregroundStyle(Theme.onDark)
            Spacer(minLength: Theme.s2)
            if let session {
                Text(session.projectName)
                    .font(Theme.ui(prefs.contentFontSize - 1))
                    .foregroundStyle(Theme.onDark3)
                Chip(text: request.agent.displayName, tint: request.agent.tint, font: 9)
            }
        }
    }

    private var iconName: String {
        switch request.kind {
        case .permission: return "hand.raised"
        case .planReview: return "list.bullet.rectangle"
        case .question: return "questionmark.circle"
        }
    }

    private var headline: String {
        switch request.kind {
        case let .permission(tool, _): return "\(tool) needs permission"
        case .planReview: return "Review this plan"
        case .question: return "Answer a question"
        }
    }
}

/// Permission body: what the tool wants to do, plus Allow / Always / Deny.
struct PermissionBody: View {
    let tool: String
    let input: JSONValue
    let request: ApprovalRequest

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var prefs: Preferences

    private var cwd: String? { store.session(id: request.sessionID)?.cwd }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            if prefs.showRiskWarnings,
               let risk = CommandRisk.headline(tool: tool, input: input, cwd: cwd) {
                RiskStrip(finding: risk)
            }

            if let edit = EditPreview(tool: tool, input: input) {
                DiffPreview(preview: edit)
            } else if let detail {
                ScrollView(.vertical) {
                    Text(detail)
                        .font(Theme.mono(prefs.contentFontSize - 1))
                        .foregroundStyle(Theme.onDark2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(Theme.s2)
                .background(
                    RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                )
            }

            HStack(spacing: Theme.s2) {
                ActionButton(title: "Allow", shortcut: "⌘Y", style: .primary) {
                    PendingRequestRegistry.shared.resolve(request.id, with: .allow)
                }
                .keyboardShortcut("y", modifiers: .command)
                ActionButton(title: "Always allow", style: .secondary) {
                    PendingRequestRegistry.shared.resolve(request.id, with: .allowAlways)
                }
                ActionButton(title: "Deny", shortcut: "⌘N", style: .destructive) {
                    PendingRequestRegistry.shared.resolve(request.id, with: .deny(reason: nil))
                }
                .keyboardShortcut("n", modifiers: .command)
                Spacer(minLength: 0)
                ActionButton(title: "In terminal", style: .quiet) {
                    PendingRequestRegistry.shared.resolve(request.id, with: .defer_)
                }
            }
        }
    }

    /// The most useful single field for the tool at hand — the command, the path, the URL.
    private var detail: String? {
        switch tool {
        case "Bash":
            return input["command"].stringValue
        case "Read", "Edit", "Write":
            return input["file_path"].stringValue
        case "WebFetch":
            return input["url"].stringValue
        default:
            guard let object = input.objectValue, !object.isEmpty else { return nil }
            let data = try? JSONSerialization.data(
                withJSONObject: input.foundationValue,
                options: [.prettyPrinted, .sortedKeys]
            )
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}

/// Buttons in the notch use their own style so they read correctly on a black panel and stay
/// legible at the small sizes the panel uses.
struct ActionButton: View {
    enum Style {
        case primary
        case secondary
        case destructive
        case quiet
    }

    let title: String
    var shortcut: String?
    var style: Style = .secondary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(Theme.ui(11, weight: .medium))
                if let shortcut {
                    Text(shortcut)
                        .font(Theme.mono(9))
                        .opacity(0.6)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return Theme.onDark
        case .destructive: return hovering ? .white : Theme.danger
        case .quiet: return Theme.onDark3
        }
    }

    private var background: Color {
        switch style {
        case .primary: return hovering ? Theme.blue600 : Theme.blue
        case .secondary: return hovering ? Theme.dark3 : Theme.dark2
        case .destructive: return hovering ? Theme.danger : Theme.danger.opacity(0.14)
        case .quiet: return hovering ? Theme.dark3 : .clear
        }
    }

    private var border: Color {
        style == .quiet ? .clear : Theme.darkLine
    }
}
