import Foundation
import Testing
@testable import FarolCore

@Test func readsKiroHistoryAcrossWorkspaces() throws {
    let folder = AgentFolder(kind: .kiro, directory: URL(fileURLWithPath: "/home/test/.kiro"))
    let entries = ConversationHistory.parseKiro(Data("""
    [
      {
        "cwd": "/work/project",
        "sessions": [
          {"sessionId": "5d7de3f7-1718-4f10-8fc5-2cb94dd52711", "title": "  Fix search  ", "updatedAt": "2026-11-07T12:00:00.250Z", "source": "v3"},
          {"sessionId": "", "title": "Broken record", "updatedAt": "2026-11-07T12:01:00.000Z"},
          {"sessionId": "615e77a8-d08f-40dc-b9d8-89de9327462a", "updatedAt": "bad timestamp"}
        ],
        "complete": true
      },
      {
        "cwd": "/work/other",
        "sessions": [{"sessionId": "e7e74352-0f6e-42fc-9dcc-83e8b9a4520d", "updatedAt": "2026-11-07T12:05:00Z", "source": "v2"}],
        "complete": true
      }
    ]
    """.utf8), in: folder)
    #expect(entries.map(\.directory) == ["/work/project", "/work/other"])
    #expect(entries.map(\.title) == ["Fix search", "Untitled conversation"])
    let first = try #require(entries.first)
    #expect(first.agent == folder)
    #expect(first.log == nil)
    #expect(first.id == "5d7de3f7-1718-4f10-8fc5-2cb94dd52711")
    #expect(first.updated == Date(timeIntervalSince1970: 1_794_052_800.25))
}

@Test func readsSavedKiroV3HistoryFromMetadata() throws {
    let files = FileManager.default
    let configuration = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = AgentFolder(kind: .kiro, directory: configuration)
    defer { try? files.removeItem(at: configuration) }

    let workspace = configuration.appendingPathComponent("sessions/workspace")
    func save(_ id: String, metadata: [String: Any], messages: String?) throws {
        let session = workspace.appendingPathComponent(id)
        try files.createDirectory(at: session, withIntermediateDirectories: true)
        var record: [String: Any] = ["id": id, "lastModifiedAt": "2026-11-07T12:00:00.250Z"]
        record.merge(metadata) { _, override in override }
        try JSONSerialization.data(withJSONObject: record).write(to: session.appendingPathComponent("session.json"))
        if let messages {
            // History must be readable without decoding the transcript.
            try Data(messages.utf8).write(to: session.appendingPathComponent("messages.jsonl"))
        }
    }

    let firstID = "sess_5d7de3f7-1718-4f10-8fc5-2cb94dd52711"
    let nextID = "sess_e7e74352-0f6e-42fc-9dcc-83e8b9a4520d"
    try save(firstID, metadata: ["title": "  Fix search  ", "workspacePaths": ["/work/project"]], messages: "opaque")
    try save(nextID, metadata: ["rootPaths": ["/work/other"]], messages: "")
    try save("sess_615e77a8-d08f-40dc-b9d8-89de9327462a",
             metadata: ["id": firstID, "workspacePaths": ["/work/ignored"]], messages: "opaque")

    let entries = ConversationHistory.kiroLocalV3(in: folder, configuration: configuration)
    #expect(entries.map(\.id) == [firstID])
    let first = try #require(entries.first)
    #expect(first.directory == "/work/project")
    #expect(first.title == "Fix search")
    #expect(first.updated == Date(timeIntervalSince1970: 1_794_052_800.25))
    #expect(first.log == nil)

    try save(nextID, metadata: ["rootPaths": ["/work/other"]], messages: "opaque")
    let refreshed = ConversationHistory.kiroLocalV3(in: folder, configuration: configuration)
    let added = try #require(refreshed.first { $0.id == nextID })
    #expect(added.directory == "/work/other")
    #expect(added.title == "Untitled conversation")
}

@Test func selectsTheSameKiroProfileForReadingAndResumingHistory() {
    let folder = AgentFolder(kind: .kiro, directory: URL(fileURLWithPath: "/home/test/.kiro"))
    #expect(ConversationHistory.kiroHistoryConfiguration(in: folder, environment: [:]) == "/home/test/.kiro")
    #expect(ConversationHistory.kiroHistoryConfiguration(
        in: folder, environment: ["KIRO_HOME": "/work/profiles/../kiro work"]) == "/work/kiro work")
    #expect(ConversationHistory.kiroHistoryConfiguration(
        in: folder, environment: ["KIRO_HOME": "/home/test"]) == "/home/test/.kiro")
}
