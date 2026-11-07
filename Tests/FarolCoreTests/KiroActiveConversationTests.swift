import Foundation
import Testing
@testable import FarolCore

private struct KiroLogFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("farol-kiro-log-\(UUID().uuidString)")
    let started = Date(timeIntervalSince1970: 1_794_048_300)
    let first = "sess_12345678-1111-4111-8111-123456789012"
    let second = "sess_12345678-1111-4111-8111-123456789013"

    func log(_ directory: String, messages: [String], config: URL? = nil) throws {
        let root = (config ?? home.appendingPathComponent(".kiro")).appendingPathComponent("logs/" + directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lines = try messages.map { message in
            let data = try JSONSerialization.data(withJSONObject: ["message": message])
            return String(decoding: data, as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("kiro.log"), atomically: true, encoding: .utf8)
    }

    func new(_ id: String, outcome: String = "resolved") -> String {
        #"session.new.total {"sessionId":"\#(id)","outcome":"\#(outcome)","durationMs":5}"#
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

@Test func kiroFindsTheLastCompletedTransitionInThePanesRuntimeLog() throws {
    let fixture = KiroLogFixture()
    defer { fixture.remove() }
    try fixture.log("20261107T104501000-112", messages: [
        fixture.new(fixture.first),
        #"session.load.timing {"sessionId":"\#(fixture.second)","totalMs":19}"#,
        fixture.new(fixture.first, outcome: "rejected"),
        #"fs.loadSession.ok {"sessionId":"\#(fixture.first)","durationMs":5}"#,
    ])
    try fixture.log("20261107T104502000-115", messages: [fixture.new(fixture.first)])
    try fixture.log("20261106T104501000-112", messages: [fixture.new(fixture.first)])

    let active = KiroActiveConversation.read(pids: [111, 112], started: fixture.started,
                                             directory: "/work/project", home: fixture.home)
    #expect(active == PaneResume(kiroID: fixture.second, workingDirectory: "/work/project"))
    #expect(KiroActiveConversation.read(pids: [112, 115], started: fixture.started, directory: nil, home: fixture.home) == nil)
    #expect(KiroActiveConversation.read(pids: [114], started: fixture.started, directory: nil, home: fixture.home) == nil)
    #expect(KiroActiveConversation.read(pids: [112], started: fixture.started + 3_600, directory: nil, home: fixture.home) == nil)
}

@Test func kiroReadsOnlyTheBoundedTailOfItsExplicitProfile() throws {
    let fixture = KiroLogFixture()
    defer { fixture.remove() }
    let profile = fixture.home.appendingPathComponent("work-profile")
    try fixture.log("20261107T104501000-112", messages: [
        fixture.new(fixture.first),
        String(repeating: "x", count: 2 << 20),
    ], config: profile)
    let older = KiroActiveConversation.read(pids: [112], started: fixture.started, directory: nil,
                                            home: fixture.home, configDirectory: profile.path)
    #expect(older == PaneResume(kiroID: fixture.first, configDirectory: profile.path))

    try fixture.log("20261107T104501000-112", messages: [
        String(repeating: "x", count: 2 << 20),
        fixture.new(fixture.second),
    ], config: profile)
    let active = KiroActiveConversation.read(pids: [112], started: fixture.started, directory: nil,
                                             home: fixture.home, configDirectory: profile.path)
    #expect(active == PaneResume(kiroID: fixture.second, configDirectory: profile.path))

    let file = profile.appendingPathComponent("logs/20261107T104501000-112/kiro.log")
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    // The final transition straddles a read boundary when a large record follows.
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: UInt8(ascii: "x"), count: (128 << 10) - 8))
    #expect(KiroActiveConversation.read(pids: [112], started: fixture.started, directory: nil,
                                        home: fixture.home, configDirectory: profile.path) == active)

    try handle.truncate(atOffset: 20 << 20)
    #expect(KiroActiveConversation.read(pids: [112], started: fixture.started, directory: nil,
                                        home: fixture.home, configDirectory: profile.path) == nil)
}
