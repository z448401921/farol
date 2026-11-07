import Foundation

/// The root OSC 7501 report from Kiro's interactive terminal.
public struct KiroStatus: Equatable {
    public let event: AgentEvent
    public let asking: String?

    public init?(_ report: String, continuing: Bool = false) {
        var fields: [Substring: Substring] = [:]
        for field in report.split(separator: ":") {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            fields[pair[0]] = pair[1]
        }
        guard fields["id"] == nil else { return nil }
        if let app = fields["app"] {
            guard app == "kiro" || app == "kiro-cli" else { return nil }
        } else if !continuing {
            return nil
        }
        let message = fields["msg"].flatMap { Self.decode($0, limit: 2732) }
        if fields["msg"] != nil, message == nil { return nil }
        if let title = fields["title"], Self.decode(title, limit: 256) == nil { return nil }
        switch fields["state"] {
        case "idle": event = .start
        case "working": event = .working
        case "blocked": event = .waiting
        case "done", "error": event = .done
        case "clear": event = .clear
        default: return nil
        }
        let reason = switch fields["kind"] {
        case "permission": "Approval required"
        case "question": "Waiting for an answer"
        case "auth": "Sign in to Kiro"
        default: "Kiro needs your attention"
        }
        asking = event == .waiting ? message.flatMap { $0.isEmpty ? nil : $0 } ?? reason : nil
    }

    private static func decode(_ value: Substring, limit: Int) -> String? {
        guard value.utf8.count <= limit else { return nil }
        let padding = String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: String(value) + padding),
              let text = String(data: bytes, encoding: .utf8),
              text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
