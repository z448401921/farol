import Foundation
import Testing
@testable import FarolCore

@Test func restoresOlderPaneConversationRecords() throws {
    let log = "/home/example/.claude-work/projects/project/session.jsonl"
    let old = AgentConversation(id: "session", log: log)
    let record = try JSONDecoder().decode(PaneResume.self, from: JSONEncoder().encode(old))

    #expect(record.loggedConversation == old)
    #expect(record.command(fileExists: { $0 == log }) == "CLAUDE_CONFIG_DIR='/home/example/.claude-work' claude --resume 'session'")
    #expect(record.command(fileExists: { _ in false }) == nil)
    #expect(try JSONDecoder().decode(AgentConversation.self, from: JSONEncoder().encode(record)) == old)
}

@Test func savesAnExactKiroResumeTargetWithoutATranscript() throws {
    let id = "sess_12345678-1111-4111-8111-123456789012"
    let record = try #require(PaneResume(kiroID: id, configDirectory: "/home/example/Kiro's work", workingDirectory: "/work/project"))
    let restored = try JSONDecoder().decode(PaneResume.self, from: JSONEncoder().encode(record))

    #expect(restored == record)
    #expect(restored.isKiro)
    #expect(restored.workingDirectory == "/work/project")
    #expect(restored.loggedConversation == nil)
    let command = try #require(restored.command(fileExists: { _ in false }))
    #expect(command.hasPrefix(#"KIRO_HOME='/home/example/Kiro'\''s work' "#))
    #expect(command.hasSuffix(" chat --v3 --resume-id '\(id)'"))
    #expect(try #require(PaneResume(kiroID: id)?.command()).hasPrefix("KIRO_HOME=") == false)
}

@Test func rejectsMalformedKiroResumeRecordsEvenAfterDecoding() throws {
    let id = "12345678-1111-4111-8111-123456789012"
    #expect(PaneResume.isKiroID(id))
    #expect(!PaneResume.isKiroID("sess_" + id + "x"))
    #expect(PaneResume(kiroID: "--resume", workingDirectory: "/work/project") == nil)
    #expect(PaneResume(kiroID: id, configDirectory: "relative/profile") == nil)
    #expect(PaneResume(kiroID: id, workingDirectory: "/work\nproject") == nil)

    let decoder = JSONDecoder()
    let invalidID = try decoder.decode(PaneResume.self, from: Data(#"{"kind":"kiro","id":"--resume"}"#.utf8))
    #expect(invalidID.command() == nil)
    let invalidDirectory = try decoder.decode(PaneResume.self, from: Data(#"{"kind":"kiro","id":"\#(id)","workingDirectory":"relative"}"#.utf8))
    #expect(invalidDirectory.workingDirectory == nil)
    #expect(invalidDirectory.command() == nil)
}
