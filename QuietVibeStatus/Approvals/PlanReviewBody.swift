import SwiftUI

/// Plan review: the agent's plan rendered as Markdown, with approve / auto / reject.
struct PlanReviewBody: View {
    let plan: String
    let request: ApprovalRequest

    @EnvironmentObject private var prefs: Preferences
    @State private var feedback = ""
    @State private var showingFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            ScrollView(.vertical) {
                MarkdownText(plan, fontSize: prefs.contentFontSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .padding(Theme.s2)
            .background(
                RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                    .fill(Color.black.opacity(0.45))
            )

            if showingFeedback {
                TextField("What should change?", text: $feedback, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(prefs.contentFontSize))
                    .foregroundStyle(Theme.onDark)
                    .lineLimit(1 ... 3)
                    .padding(Theme.s2)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                            .fill(Theme.dark2)
                    )
                    .onSubmit(reject)
            }

            HStack(spacing: Theme.s2) {
                ActionButton(title: "Approve", shortcut: "⌘Y", style: .primary) {
                    PendingRequestRegistry.shared.resolve(
                        request.id,
                        with: .approvePlan(autoMode: false)
                    )
                }
                ActionButton(title: "Approve + auto-accept edits", style: .secondary) {
                    PendingRequestRegistry.shared.resolve(
                        request.id,
                        with: .approvePlan(autoMode: true)
                    )
                }
                ActionButton(
                    title: showingFeedback ? "Send feedback" : "Reject",
                    shortcut: showingFeedback ? nil : "⌘N",
                    style: .destructive
                ) {
                    if showingFeedback {
                        reject()
                    } else {
                        withAnimation(Theme.ease) { showingFeedback = true }
                    }
                }
                Spacer(minLength: 0)
                ActionButton(title: "In terminal", style: .quiet) {
                    PendingRequestRegistry.shared.resolve(request.id, with: .defer_)
                }
            }
        }
    }

    private func reject() {
        PendingRequestRegistry.shared.resolve(request.id, with: .rejectPlan(feedback: feedback))
    }
}

/// Minimal Markdown rendering for plans: headings, bullets, code fences, and inline styling.
///
/// `AttributedString(markdown:)` handles inline formatting well but flattens block structure, so
/// blocks are split here and only the inline pass is delegated to it.
struct MarkdownText: View {
    private let blocks: [Block]
    private let fontSize: CGFloat

    init(_ markdown: String, fontSize: CGFloat) {
        self.fontSize = fontSize
        blocks = Self.parse(markdown)
    }

    enum Block: Identifiable {
        case heading(level: Int, text: String)
        case bullet(text: String, indent: Int)
        case code(text: String)
        case paragraph(text: String)

        var id: String {
            switch self {
            case let .heading(level, text): return "h\(level)-\(text)"
            case let .bullet(text, indent): return "b\(indent)-\(text)"
            case let .code(text): return "c-\(text.prefix(24))"
            case let .paragraph(text): return "p-\(text.prefix(24))"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(blocks) { block in
                switch block {
                case let .heading(level, text):
                    Text(inline(text))
                        .font(Theme.ui(fontSize + (level == 1 ? 4 : level == 2 ? 2 : 1), weight: .semibold))
                        .foregroundStyle(Theme.onDark)
                        .padding(.top, 4)

                case let .bullet(text, indent):
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(Theme.onDark3)
                        Text(inline(text))
                            .foregroundStyle(Theme.onDark2)
                    }
                    .font(Theme.ui(fontSize))
                    .padding(.leading, CGFloat(indent) * 12)

                case let .code(text):
                    Text(text)
                        .font(Theme.mono(fontSize - 1))
                        .foregroundStyle(Theme.accentTeal)
                        .padding(Theme.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.rSm - 2, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                        )

                case let .paragraph(text):
                    Text(inline(text))
                        .font(Theme.ui(fontSize))
                        .foregroundStyle(Theme.onDark2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var codeBuffer: [String] = []
        var inCodeFence = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCodeFence {
                    blocks.append(.code(text: codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll()
                }
                inCodeFence.toggle()
                continue
            }

            if inCodeFence {
                codeBuffer.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(level, 3), text: text))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let leadingSpaces = line.prefix { $0 == " " }.count
                blocks.append(
                    .bullet(text: String(trimmed.dropFirst(2)), indent: leadingSpaces / 2)
                )
                continue
            }

            blocks.append(.paragraph(text: trimmed))
        }

        if !codeBuffer.isEmpty {
            blocks.append(.code(text: codeBuffer.joined(separator: "\n")))
        }

        return blocks
    }
}
