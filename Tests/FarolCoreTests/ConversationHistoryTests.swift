import Foundation
import Testing
@testable import FarolCore

@Test func historyResumesAnExactIdentifierFromItsOriginalAccount() {
    let folder = AgentFolder(kind: .codex, directory: URL(fileURLWithPath: "/test/.codex"))
    let entry = ConversationHistory.Entry(agent: folder, id: "session-1", directory: "/repo with spaces",
                                          title: " Review\n the changes\u{1B}", updated: .now)
    #expect(entry.canResume)
    #expect(entry.title == "Review the changes")
    #expect(entry.resumeCommand.hasPrefix("CODEX_HOME='/test/.codex' "))
    #expect(entry.resumeCommand.hasSuffix(" resume 'session-1'"))
}

@Test func historyRejectsFlagsAndShellInputAsSessionIdentifiers() {
    let folder = AgentFolder(kind: .kiro, directory: URL(fileURLWithPath: "/test/.kiro"))
    func record(_ id: String, in directory: String) -> ConversationHistory.Entry {
        ConversationHistory.Entry(agent: folder, id: id, directory: directory, title: "", updated: .now)
    }
    #expect(!record("--last", in: "/repo").canResume)
    #expect(!record("session\necho", in: "/repo").canResume)
    #expect(!record("ses_123", in: "relative/repo").canResume)
    #expect(record("ses_123", in: "/repo").canResume)
}

@Test func historyRemovalIsScopedToTheAgentAndProfile() throws {
    let suite = "farol.history.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = "/test/.kiro"
    let folder = URL(fileURLWithPath: profile)
    func record(_ kind: AgentFolder.Kind, profile: String) -> ConversationHistory.Entry {
        ConversationHistory.Entry(agent: AgentFolder(kind: kind, directory: folder), id: "same-id", directory: "/repo",
                                  title: "", updated: .now, profile: profile)
    }
    let entry = record(.kiro, profile: profile)
    let otherProfile = record(.kiro, profile: "/test/.kiro-work")
    let otherAgent = record(.codex, profile: profile)
    ConversationHistory.remove(entry, defaults: defaults)

    let records = [otherProfile, otherAgent]
    #expect(ConversationHistory.filterRemoved(from: [entry] + records, defaults: defaults) == records)
}
