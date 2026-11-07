import Foundation
import SQLite3
import Testing
@testable import FarolCore

private func writeHistory(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
}

private func historyDatabase(at file: URL, statements: String) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    try #require(sqlite3_open(file.path, &database) == SQLITE_OK)
    try #require(sqlite3_exec(database, statements, nil, nil, nil) == SQLITE_OK)
}

@Test func localConversationHistoryReadsClaudeAndPiTitles() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let claude = AgentFolder(kind: .claude, directory: home.appendingPathComponent(".claude"))
    try writeHistory("""
        {"type":"user","isMeta":true,"cwd":"/work/one","message":{"content":"A hidden prelude"}}
        {"type":"user","cwd":"/work/one","message":{"content":"Original request"}}
        {"type":"custom-title","customTitle":"Named Claude session"}
        """, to: claude.directory.appendingPathComponent("projects/-work-one/root.jsonl"))
    try writeHistory("""
        {"type":"user","cwd":"/work/one","message":{"content":"A child"}}
        """, to: claude.directory.appendingPathComponent("projects/-work-one/root/subagents/child.jsonl"))

    let pi = AgentFolder(kind: .pi, directory: home.appendingPathComponent(".pi/agent"))
    try writeHistory("""
        {"type":"session","version":3,"id":"saved-pi","cwd":"/work/two"}
        {"type":"message","message":{"role":"user","content":[{"type":"text","text":"A prompt"}]}}
        {"type":"session_info","name":"Named Pi session"}
        """, to: pi.directory.appendingPathComponent("sessions/--work-two--/saved.jsonl"))

    let entries = ConversationHistory.list(in: [claude, pi]).sorted { $0.title < $1.title }
    #expect(entries.map(\.title) == ["Named Claude session", "Named Pi session"])
    #expect(entries.map(\.directory) == ["/work/one", "/work/two"])
    #expect(entries.map(\.id) == ["root", "saved-pi"])
}

@Test func historyRemovalSurvivesRescansWithoutChangingTheAgentLog() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let suite = "farol.history.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let agent = AgentFolder(kind: .claude, directory: home.appendingPathComponent(".claude"))
    let file = agent.directory.appendingPathComponent("projects/-work/first.jsonl")
    let first = #"{"type":"user","cwd":"/work","message":{"content":"A prompt"}}"#
    try writeHistory(first, to: file)
    let snapshot = ConversationHistory.list(in: [agent], defaults: defaults)
    let entry = try #require(snapshot.first)

    ConversationHistory.remove(entry, defaults: defaults)
    ConversationHistory.remove(entry, defaults: defaults)
    #expect(ConversationHistory.filterRemoved(from: snapshot, defaults: defaults).isEmpty)
    #expect(try String(contentsOf: file, encoding: .utf8) == first)

    let edited = first + "\n" + #"{"type":"custom-title","customTitle":"New title"}"#
    try writeHistory(edited, to: file)
    try writeHistory(first, to: agent.directory.appendingPathComponent("projects/-work/second.jsonl"))
    let reopened = try #require(UserDefaults(suiteName: suite))
    #expect(ConversationHistory.list(in: [agent], defaults: reopened).map(\.id) == ["second"])
    #expect(try String(contentsOf: file, encoding: .utf8) == edited)
}

@Test func localConversationHistoryReadsCodexDatabaseAndLegacyRollouts() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let agent = AgentFolder(kind: .codex, directory: home)
    try historyDatabase(at: home.appendingPathComponent("state_5.sqlite"), statements: """
        CREATE TABLE threads (id TEXT, rollout_path TEXT, cwd TEXT, title TEXT, source TEXT, archived INTEGER,
                              updated_at INTEGER, updated_at_ms INTEGER, history_mode TEXT, thread_source TEXT);
        INSERT INTO threads VALUES
          ('root', '/missing.jsonl', '/work/new', 'SQLite session', 'vscode', 0, 1, 4000, 'paginated', 'user'),
          ('review', '/missing.jsonl', '/work/new', 'Guardian review', 'vscode', 0, 1, 9000, 'paginated', 'guardian_review'),
          ('archived', '/missing.jsonl', '/work/new', 'Archived', 'vscode', 1, 1, 9000, 'paginated', 'user');
        """)
    try writeHistory("""
        {"id":"legacy","thread_name":"Old label"}
        {"id":"legacy","thread_name":"Latest label"}
        """, to: home.appendingPathComponent("session_index.jsonl"))
    let sessions = home.appendingPathComponent("sessions/2026/11/07")
    let legacy = sessions.appendingPathComponent("legacy.jsonl")
    try writeHistory("""
        {"type":"session_meta","payload":{"id":"legacy","cwd":"/work/old","source":"cli"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"Original request"}}
        """, to: legacy)
    try writeHistory("""
        {"type":"session_meta","payload":{"id":"child","cwd":"/work/old","source":{"subagent":"review"}}}
        """, to: sessions.appendingPathComponent("child.jsonl"))

    let entries = ConversationHistory.list(in: [agent])
    #expect(entries.map(\.id) == ["legacy", "root"])
    #expect(entries.map(\.title) == ["Latest label", "SQLite session"])
    #expect(entries.first?.log.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == legacy.resolvingSymlinksInPath())
    #expect(entries.last?.log == nil)
    #expect(entries.last?.updated == Date(timeIntervalSince1970: 4))
}

@Test func localConversationHistoryReadsOpenCodeStorageWithoutAnAgentProcess() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let agent = AgentFolder(kind: .opencode, directory: home.appendingPathComponent(".config/opencode"))
    let data = home.appendingPathComponent(".local/share/opencode")
    try writeHistory("""
        {
          "id": "ses_old",
          "directory": "/work/old",
          "title": "Old OpenCode session",
          "time": {"updated": 1000}
        }
        """, to: data.appendingPathComponent("storage/session/global/ses_old.json"))
    #expect(ConversationHistory.openCode(in: agent, home: home, environment: [:]).map(\.id) == ["ses_old"])

    try historyDatabase(at: data.appendingPathComponent("opencode.db"), statements: """
        CREATE TABLE session_v2 (id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_updated INTEGER, time_archived INTEGER);
        INSERT INTO session_v2 VALUES
          ('ses_new', NULL, '/work/new', 'New OpenCode session', 2000, NULL),
          ('ses_child', 'ses_new', '/work/new', 'A child', 3000, NULL),
          ('ses_archived', NULL, '/work/new', 'Archived', 4000, 4000);
        """)
    let entries = ConversationHistory.openCode(in: agent, home: home, environment: [:])
    #expect(entries.map(\.id) == ["ses_new"])
    #expect(entries.first?.updated == Date(timeIntervalSince1970: 2))
}
