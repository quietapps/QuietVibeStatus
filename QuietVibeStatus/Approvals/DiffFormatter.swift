import Foundation

/// One rendered line of a diff.
struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case context
        case removed
        case added
        /// Stands in for a run of unchanged lines that was collapsed away.
        case elision
    }

    let id: Int
    let kind: Kind
    let text: String
}

/// Turns an Edit or Write payload into the diff the approval card shows.
///
/// The card used to print the raw tool input, so approving an edit meant reading a JSON blob with
/// the old and new text quoted end to end and spotting the difference yourself. What matters is
/// which lines change, so that is what this produces: changed lines with a little context, and long
/// unchanged runs collapsed.
enum DiffFormatter {
    /// Lines of context kept either side of a change.
    private static let context = 2
    /// Above this, aligning line by line is neither fast nor useful — see `summary`.
    private static let maxComparableLines = 600

    /// A unified diff of two texts, or nil when the inputs are too large to align.
    static func diff(old: String, new: String, limit: Int = 60) -> [DiffLine]? {
        // Empty means "no content", not "one empty line" — otherwise a Write of a new file opens
        // with a removed blank line that was never there.
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        guard oldLines.count <= maxComparableLines, newLines.count <= maxComparableLines else {
            return nil
        }

        let raw = unified(oldLines, newLines)
        let trimmed = collapseUnchanged(raw)
        return Array(trimmed.prefix(limit)).enumerated().map { index, line in
            DiffLine(id: index, kind: line.kind, text: line.text)
        }
    }

    /// One-line description for payloads too big to diff, or for a plain file creation.
    static func summary(old: String?, new: String) -> String {
        let newCount = new.components(separatedBy: "\n").count
        guard let old, !old.isEmpty else {
            return "Creates \(newCount) \(newCount == 1 ? "line" : "lines")"
        }
        let oldCount = old.components(separatedBy: "\n").count
        return "Replaces \(oldCount) \(oldCount == 1 ? "line" : "lines") with \(newCount)"
    }

    // MARK: - Alignment

    private struct Line {
        let kind: DiffLine.Kind
        let text: String
    }

    /// Classic longest-common-subsequence diff. Quadratic, which is why `maxComparableLines` caps
    /// the input: an Edit payload is a hunk, not a repository.
    private static func unified(_ old: [String], _ new: [String]) -> [Line] {
        let n = old.count
        let m = new.count
        var lengths = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)

        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i][j] = old[i] == new[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var result: [Line] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if old[i] == new[j] {
                result.append(Line(kind: .context, text: old[i]))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                result.append(Line(kind: .removed, text: old[i]))
                i += 1
            } else {
                result.append(Line(kind: .added, text: new[j]))
                j += 1
            }
        }
        while i < n {
            result.append(Line(kind: .removed, text: old[i]))
            i += 1
        }
        while j < m {
            result.append(Line(kind: .added, text: new[j]))
            j += 1
        }

        return result
    }

    /// Keeps `context` unchanged lines around each change and replaces longer runs with one marker.
    private static func collapseUnchanged(_ lines: [Line]) -> [Line] {
        let changedIndexes = lines.indices.filter { lines[$0].kind != .context }
        guard !changedIndexes.isEmpty else { return [] }

        var keep = Set<Int>()
        for index in changedIndexes {
            for offset in -context ... context {
                let neighbour = index + offset
                if lines.indices.contains(neighbour) { keep.insert(neighbour) }
            }
        }

        var result: [Line] = []
        var elided = false
        for index in lines.indices {
            if keep.contains(index) {
                result.append(lines[index])
                elided = false
            } else if !elided {
                result.append(Line(kind: .elision, text: "⋯"))
                elided = true
            }
        }
        return result
    }
}
