import Foundation

/// Turns a tool call into the one-line "what is it doing right now" string on a session card.
enum ActivityFormatter {
    static func describe(tool: String, input: JSONValue) -> String {
        switch tool {
        case "Bash":
            let command = input["command"].stringValue ?? ""
            return "Running \(truncate(firstLine(command), 48))"
        case "Read":
            return "Reading \(fileName(input["file_path"].stringValue))"
        case "Edit", "NotebookEdit":
            return "Editing \(fileName(input["file_path"].stringValue))"
        case "Write":
            return "Writing \(fileName(input["file_path"].stringValue))"
        case "Grep":
            return "Grep: \(truncate(input["pattern"].stringValue ?? "", 36))"
        case "Glob":
            return "Glob: \(truncate(input["pattern"].stringValue ?? "", 36))"
        case "WebFetch":
            return "Fetching \(host(input["url"].stringValue))"
        case "WebSearch":
            return "Searching \(truncate(input["query"].stringValue ?? "", 36))"
        case "Agent", "Task":
            let description = input["description"].stringValue ?? input["subagent_type"].stringValue ?? ""
            return "Agent: \(truncate(description, 40))"
        case "ExitPlanMode":
            return "Presenting a plan"
        case "AskUserQuestion":
            return "Asking a question"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_").filter { !$0.isEmpty }
                return "MCP: \(parts.last.map(String.init) ?? tool)"
            }
            return tool
        }
    }

    static func fileName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "file" }
        return (path as NSString).lastPathComponent
    }

    static func host(_ urlString: String?) -> String {
        guard let urlString, let url = URL(string: urlString), let host = url.host else {
            return "page"
        }
        return host
    }

    static func firstLine(_ string: String) -> String {
        string.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? string
    }

    static func truncate(_ string: String, _ limit: Int) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// A short model label for the card chip: "claude-opus-4-8" reads better as "Opus 4.8".
    static func modelLabel(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        let known: [(String, String)] = [
            ("opus-4-8", "Opus 4.8"),
            ("opus-4-7", "Opus 4.7"),
            ("sonnet-5", "Sonnet 5"),
            ("haiku-4-5", "Haiku 4.5"),
            ("fable-5", "Fable 5"),
            ("gpt-5", "GPT-5"),
            ("gemini-3", "Gemini 3"),
        ]
        for (needle, label) in known where model.contains(needle) {
            return label
        }
        return model.count > 18 ? String(model.prefix(18)) : model
    }
}
