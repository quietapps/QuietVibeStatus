import SwiftUI

/// Answers a multi-question `AskUserQuestion` prompt from the notch.
///
/// Questions are paginated so a four-question prompt doesn't overflow the panel; the answer is
/// only sent back once every question has a selection.
struct QuestionWizard: View {
    let questions: QuestionSet
    let request: ApprovalRequest

    @EnvironmentObject private var prefs: Preferences
    @State private var page = 0
    /// question index -> selected option labels
    @State private var selections: [Int: Set<String>] = [:]
    @State private var otherText: [Int: String] = [:]

    private var current: QuestionItem { questions.items[page] }
    private var isLastPage: Bool { page == questions.items.count - 1 }

    private var currentSelection: Set<String> {
        selections[page] ?? []
    }

    private var canAdvance: Bool {
        !currentSelection.isEmpty || !(otherText[page] ?? "").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            if questions.items.count > 1 {
                HStack(spacing: Theme.s1) {
                    Text(current.header.uppercased())
                        .font(Theme.ui(9, weight: .semibold))
                        .foregroundStyle(Theme.attention)
                        .tracking(0.8)
                    Spacer(minLength: 0)
                    Text("\(page + 1) of \(questions.items.count)")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.onDark3)
                }
            }

            Text(current.question)
                .font(Theme.ui(prefs.contentFontSize + 1, weight: .medium))
                .foregroundStyle(Theme.onDark)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                ForEach(Array(current.options.enumerated()), id: \.offset) { index, option in
                    OptionRow(
                        option: option,
                        index: index,
                        selected: currentSelection.contains(option.label),
                        multiSelect: current.multiSelect
                    ) {
                        toggle(option.label)
                    }
                }

                TextField("Other…", text: binding(for: page))
                    .textFieldStyle(.plain)
                    .font(Theme.ui(prefs.contentFontSize))
                    .foregroundStyle(Theme.onDark)
                    .padding(Theme.s2)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                            .fill(Theme.dark2)
                    )
            }

            HStack(spacing: Theme.s2) {
                if page > 0 {
                    ActionButton(title: "Back", style: .quiet) {
                        withAnimation(Theme.ease) { page -= 1 }
                    }
                }
                ActionButton(
                    title: isLastPage ? "Send answer" : "Next",
                    style: .primary
                ) {
                    advance()
                }
                .disabled(!canAdvance)
                .opacity(canAdvance ? 1 : 0.45)

                Spacer(minLength: 0)
                ActionButton(title: "In terminal", style: .quiet) {
                    PendingRequestRegistry.shared.resolve(request.id, with: .defer_)
                }
            }
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { otherText[index] ?? "" },
            set: { otherText[index] = $0 }
        )
    }

    private func toggle(_ label: String) {
        var selection = currentSelection
        if current.multiSelect {
            if selection.contains(label) {
                selection.remove(label)
            } else {
                selection.insert(label)
            }
        } else {
            selection = [label]
        }
        selections[page] = selection
    }

    private func advance() {
        guard canAdvance else { return }
        if isLastPage {
            submit()
        } else {
            withAnimation(Theme.ease) { page += 1 }
        }
    }

    /// The tool expects `answers` keyed by question text, with comma-joined labels for
    /// multi-select. Free text typed into "Other" wins when the user provided it.
    private func submit() {
        var answers: [String: String] = [:]
        for (index, item) in questions.items.enumerated() {
            let typed = (otherText[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty {
                answers[item.question] = typed
            } else if let selection = selections[index], !selection.isEmpty {
                answers[item.question] = selection.sorted().joined(separator: ", ")
            }
        }
        PendingRequestRegistry.shared.resolve(request.id, with: .answered(answers))
    }
}

struct OptionRow: View {
    let option: QuestionItem.Option
    let index: Int
    let selected: Bool
    let multiSelect: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.s2) {
                Image(
                    systemName: multiSelect
                        ? (selected ? "checkmark.square.fill" : "square")
                        : (selected ? "largecircle.filled.circle" : "circle")
                )
                .font(.system(size: 11))
                .foregroundStyle(selected ? Theme.blue : Theme.onDark3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(Theme.ui(11, weight: .medium))
                        .foregroundStyle(Theme.onDark)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(Theme.ui(10))
                            .foregroundStyle(Theme.onDark3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.onDark3)
                        .opacity(hovering ? 1 : 0.4)
                }
            }
            .padding(Theme.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                    .fill(selected ? Theme.blue.opacity(0.16) : (hovering ? Theme.dark3 : Theme.dark2))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
