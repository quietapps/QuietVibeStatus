import SwiftUI

/// A one-line warning strip above a permission card's detail.
///
/// Colour carries the level and the sentence says what the command does, because the pattern that
/// matched ("contains `rm -rf`") is not the thing you need to know at approval time.
struct RiskStrip: View {
    let finding: RiskFinding

    var body: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: finding.level == .danger ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                .font(.system(size: 10, weight: .semibold))
            Text(finding.reason)
                .font(Theme.ui(10, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.s2)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                .fill(tint.opacity(0.14))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint)
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
        }
    }

    private var tint: Color {
        finding.level == .danger ? Theme.danger : Theme.warning
    }
}

/// What an Edit-shaped tool call would do to a file.
struct EditPreview {
    let path: String?
    let lines: [DiffLine]?
    let summary: String
    /// Set when a MultiEdit carries more hunks than the one shown.
    let extraEdits: Int

    /// Builds a preview for the tools that change a file, and returns nil for everything else so
    /// the card falls back to its plain detail line.
    init?(tool: String, input: JSONValue) {
        switch tool {
        case "Edit":
            let old = input["old_string"].stringValue ?? ""
            guard let new = input["new_string"].stringValue else { return nil }
            path = input["file_path"].stringValue
            lines = DiffFormatter.diff(old: old, new: new)
            summary = DiffFormatter.summary(old: old, new: new)
            extraEdits = 0

        case "MultiEdit":
            guard let edits = input["edits"].arrayValue, let first = edits.first else { return nil }
            let old = first["old_string"].stringValue ?? ""
            guard let new = first["new_string"].stringValue else { return nil }
            path = input["file_path"].stringValue
            lines = DiffFormatter.diff(old: old, new: new)
            summary = DiffFormatter.summary(old: old, new: new)
            extraEdits = edits.count - 1

        case "Write":
            guard let content = input["content"].stringValue else { return nil }
            path = input["file_path"].stringValue
            lines = DiffFormatter.diff(old: "", new: content)
            summary = DiffFormatter.summary(old: nil, new: content)
            extraEdits = 0

        default:
            return nil
        }
    }
}

/// The diff itself: path, a change summary, then the changed lines.
struct DiffPreview: View {
    let preview: EditPreview

    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.s2) {
                if let path = preview.path {
                    Text((path as NSString).lastPathComponent)
                        .font(Theme.mono(prefs.contentFontSize - 1, weight: .medium))
                        .foregroundStyle(Theme.onDark)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
                Text(preview.summary)
                    .font(Theme.ui(9))
                    .foregroundStyle(Theme.onDark3)
                if preview.extraEdits > 0 {
                    Text("+\(preview.extraEdits) more \(preview.extraEdits == 1 ? "edit" : "edits")")
                        .font(Theme.ui(9))
                        .foregroundStyle(Theme.warning)
                }
                Spacer(minLength: 0)
            }

            if let lines = preview.lines, !lines.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            row(for: line)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(Theme.s2)
                .background(
                    RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                )
            }
        }
    }

    private func row(for line: DiffLine) -> some View {
        HStack(spacing: 6) {
            Text(marker(for: line.kind))
                .font(Theme.mono(prefs.contentFontSize - 1, weight: .semibold))
                .foregroundStyle(colour(for: line.kind))
                .frame(width: 8, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
                .font(Theme.mono(prefs.contentFontSize - 1))
                .foregroundStyle(colour(for: line.kind))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .background(background(for: line.kind))
    }

    private func marker(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        case .elision: return " "
        }
    }

    private func colour(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Theme.success
        case .removed: return Theme.danger
        case .context: return Theme.onDark3
        case .elision: return Theme.onDark3.opacity(0.6)
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Theme.success.opacity(0.10)
        case .removed: return Theme.danger.opacity(0.10)
        default: return .clear
        }
    }
}
