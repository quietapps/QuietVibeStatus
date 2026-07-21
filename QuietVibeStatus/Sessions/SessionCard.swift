import SwiftUI

/// One session, rendered as a card in the open panel.
struct SessionCard: View {
    let session: Session

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var prefs: Preferences
    @State private var hovering = false

    private var font: CGFloat { prefs.contentFontSize }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            // Per-row activity gutter. One glyph in the header could only ever say "something is
            // running"; a glyph per row says *which* session is running.
            ActivityGlyph(
                active: session.state == .working || session.state == .compacting,
                color: session.state.dotColor,
                size: 14
            )
            .padding(.top, 1)

            content
        }
        .padding(.vertical, Theme.s2)
        .padding(.horizontal, Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard !prefs.disableClickToJump else { return }
            TerminalJumper.jump(to: session)
        }
        .contextMenu { contextMenu }
        .animation(Theme.ease, value: session.state)
    }

    /// Flat by default — a border and fill on every row turns the list into a grid of boxes. Only a
    /// row that needs a decision earns chrome, so attention is the thing that stands out.
    @ViewBuilder
    private var rowBackground: some View {
        if session.state.isBlocked {
            RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous)
                .fill(Theme.attention.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous)
                        .strokeBorder(Theme.attention.opacity(0.5), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.05) : .clear)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleRow
            if let prompt = session.lastPrompt, !prompt.isEmpty {
                Text("You: \(prompt)")
                    .font(Theme.ui(font))
                    .foregroundStyle(Theme.onDark2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if prefs.showActivityDetail { activityRow }
            if let recap = session.recap, session.state == .idle || session.state == .complete {
                Text(recap)
                    .font(Theme.ui(font - 1))
                    .foregroundStyle(Theme.onDark3)
                    .lineLimit(2)
            }
            if prefs.showSubagents, !session.subagents.isEmpty {
                SubagentList(subagents: session.subagents, font: font)
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: Theme.s2) {
            if prefs.showProjectName {
                Text(session.projectName)
                    .font(Theme.ui(font + 1, weight: .semibold))
                    .foregroundStyle(Theme.onDark)
            }

            if prefs.showWorktree, let branch = session.branch {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: font - 2))
                    Text(branch)
                        .font(Theme.mono(font - 1))
                }
                .foregroundStyle(Theme.onDark3)
            }

            // The separator belongs to the project name, not the headline — otherwise hiding the
            // project leaves a stray "·" at the start of the row.
            Text(prefs.showProjectName ? "· \(session.headline)" : session.headline)
                .font(Theme.ui(font + 1, weight: .semibold))
                .foregroundStyle(Theme.onDark)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: Theme.s2)

            Chip(text: session.agent.displayName, tint: session.agent.tint, font: font - 2)
            if prefs.showModel, let model = session.model {
                Chip(text: model, tint: Theme.onDark3, font: font - 2)
            }
            // Only name a host we can still see running. A chip claiming iTerm2 when iTerm2 has
            // been closed is worse than no chip: it implies a click will land somewhere it can't.
            if let host = session.runningHost {
                Chip(text: host.displayName, tint: Theme.onDark3, font: font - 2)
            }

            Text(Self.elapsedText(session.startedAt))
                .font(Theme.mono(font - 2))
                .foregroundStyle(Theme.onDark3)

            ArchiveButton(visible: hovering) {
                store.archive(id: session.id)
            }
        }
    }

    @ViewBuilder
    private var activityRow: some View {
        if let activity = session.lastActivity {
            HStack(spacing: Theme.s1) {
                Text(activity)
                    .font(Theme.ui(font - 1))
                    .foregroundStyle(Theme.onDark3)
                    .lineLimit(1)
                if let since = session.lastActivityAt {
                    Text("· \(Self.elapsedText(since))")
                        .font(Theme.mono(font - 2))
                        .foregroundStyle(Theme.onDark3)
                }
            }
        } else {
            Text(session.state.label)
                .font(Theme.ui(font - 1))
                .foregroundStyle(session.state.dotColor)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Jump to terminal") { TerminalJumper.jump(to: session) }
        Button("Copy working directory") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.cwd, forType: .string)
        }
        Divider()
        Button("Hide sessions in this directory") {
            prefs.directoryFilters.append(session.cwd)
            store.remove(id: session.id)
        }
        if let prompt = session.lastPrompt, !prompt.isEmpty {
            Button("Hide sessions starting with this prompt") {
                prefs.promptFilters.append(String(prompt.prefix(60)))
                store.remove(id: session.id)
            }
        }
        Divider()
        Button("Archive") { store.archive(id: session.id) }
    }

    static func elapsedText(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

/// Removes a session from the panel.
///
/// Only fully visible on hover so a row of buttons doesn't compete with the status information —
/// but it keeps a reserved slot either way, so cards don't reflow as the pointer moves down the
/// list. Marked as a plain button rather than part of the card so it doesn't trigger click-to-jump.
struct ArchiveButton: View {
    let visible: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hovering ? Theme.onDark : Theme.onDark3)
                .frame(width: 14, height: 14)
                .background(
                    Circle().fill(hovering ? Theme.dark3 : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(Theme.ease, value: visible)
        .help("Archive this session")
    }
}

struct StatusDot: View {
    let state: SessionState
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(state.dotColor)
            .frame(width: 7, height: 7)
            .opacity(shouldPulse ? (pulse ? 0.35 : 1) : 1)
            .onAppear {
                guard shouldPulse else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }

    private var shouldPulse: Bool {
        state == .working || state == .compacting || state.isBlocked
    }
}

struct Chip: View {
    let text: String
    let tint: Color
    var font: CGFloat = 9

    var body: some View {
        Text(text)
            .font(Theme.ui(font, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.rSm - 2, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .lineLimit(1)
    }
}

struct SubagentList: View {
    let subagents: [Subagent]
    let font: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.s1) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: font - 2))
                Text("Agents")
                    .font(Theme.ui(font - 1, weight: .medium))
                Text("(\(subagents.count))")
                    .font(Theme.mono(font - 2))
            }
            .foregroundStyle(Theme.onDark3)

            ForEach(subagents) { sub in
                HStack(spacing: Theme.s2) {
                    Circle()
                        .fill(sub.isRunning ? Theme.blue : Theme.success)
                        .frame(width: 5, height: 5)
                    Text(sub.type)
                        .font(Theme.ui(font - 1))
                        .foregroundStyle(Theme.onDark2)
                    if let activity = sub.lastActivity {
                        Text("└ \(activity)")
                            .font(Theme.ui(font - 2))
                            .foregroundStyle(Theme.onDark3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(sub.isRunning ? "\(Int(sub.elapsed))s" : "Done")
                        .font(Theme.mono(font - 2))
                        .foregroundStyle(Theme.onDark3)
                }
                .padding(.leading, Theme.s2)
            }
        }
        .padding(.top, 2)
    }
}
