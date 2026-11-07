import Foundation

extension ConversationHistory {
    static func kiro(in folder: AgentFolder) -> [Entry] {
        let configuration = kiroHistoryConfiguration(in: folder)
        // Kiro's CLI can omit V3 sessions even though it still lists the older V2 sessions.
        return kiroLocalV3(in: folder, configuration: URL(fileURLWithPath: configuration))
            + kiroCLI(in: folder, configuration: configuration)
    }

    static func kiroHistoryConfiguration(in folder: AgentFolder,
                                         environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let fallback = folder.directory.standardizedFileURL
        guard let path = environment["KIRO_HOME"], path.hasPrefix("/"),
              path.rangeOfCharacter(from: .controlCharacters) == nil else { return fallback.path }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = fallback.deletingLastPathComponent().path
        guard resolved != "/", resolved != home, !home.hasPrefix(resolved + "/") else { return fallback.path }
        return resolved
    }

    private static func kiroCLI(in folder: AgentFolder, configuration: String) -> [Entry] {
        let home = folder.directory.deletingLastPathComponent()
        guard let executable = folder.kind.executable(in: home.path) else { return [] }
        let arguments = ["chat", "--list-sessions", "--all-cwds", "--format", "json"]
        let timer = Perf.shared.begin(executable, arguments, named: "Kiro conversation history")
        defer { Perf.shared.end(timer) }

        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent("farol-kiro-\(UUID().uuidString)")
        // A private file keeps titles off stdout and lets us wait with a deadline even if the CLI gets stuck.
        guard (try? files.createDirectory(at: temporary, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])) != nil else { return [] }
        defer { try? files.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent("sessions.json")
        guard files.createFile(atPath: file.path, contents: nil), let output = try? FileHandle(forWritingTo: file) else { return [] }
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = home
        var environment = ProcessInfo.processInfo.environment
        environment["KIRO_HOME"] = configuration
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return [] }
        guard finished.wait(timeout: .now() + 5) == .success else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return []
        }

        // Kiro sends one array for all workspaces. Cap what a faulty CLI can make us decode.
        let limit = 32 << 20
        guard process.terminationStatus == 0, let input = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? input.close() }
        guard let data = try? input.read(upToCount: limit + 1), data.count <= limit else { return [] }
        return parseKiro(data, in: folder, profile: configuration)
    }

    static func parseKiro(_ data: Data, in folder: AgentFolder, profile: String? = nil) -> [Entry] {
        guard let workspaces = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return workspaces.flatMap { workspace -> [Entry] in
            guard let workspace = workspace as? [String: Any],
                  let directory = workspace["cwd"] as? String, directory.hasPrefix("/"),
                  let sessions = workspace["sessions"] as? [Any] else { return [] }
            return sessions.compactMap { session in
                guard let session = session as? [String: Any],
                      let id = session["sessionId"] as? String, PaneResume.isKiroID(id),
                      let date = session["updatedAt"] as? String,
                      let updated = kiroDate(date) else { return nil }
                return Entry(agent: folder, id: id, directory: directory,
                             title: session["title"] as? String ?? "", updated: updated, profile: profile)
            }
        }
    }

    private struct KiroV3Metadata: Decodable {
        let id: String
        let title: String?
        let lastModifiedAt: String
        let workspacePaths: [String]?
        let rootPaths: [String]?
    }

    static func kiroLocalV3(in folder: AgentFolder, configuration: URL) -> [Entry] {
        let root = configuration.appendingPathComponent("sessions", isDirectory: true)
        let profile = configuration.standardizedFileURL.path
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        func directories(in parent: URL) -> [URL] {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
            return children.filter { (try? $0.resourceValues(forKeys: keys).isDirectory) == true }
        }
        let decoder = JSONDecoder()
        return directories(in: root).flatMap { workspace -> [Entry] in
            guard !Task.isCancelled else { return [] }
            return directories(in: workspace).compactMap { session in
                let id = session.lastPathComponent
                guard id.hasPrefix("sess_"), PaneResume.isKiroID(id) else { return nil }
                let messages = session.appendingPathComponent("messages.jsonl")
                // A new chat can have metadata before its first message is saved.
                guard let values = try? messages.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, (values.fileSize ?? 0) > 0,
                      let metadata = kiroMetadata(in: session, decoder: decoder), metadata.id == id,
                      let updated = kiroDate(metadata.lastModifiedAt) else { return nil }
                let paths = (metadata.workspacePaths ?? []) + (metadata.rootPaths ?? [])
                guard let directory = paths.first(where: {
                    $0.hasPrefix("/") && $0.rangeOfCharacter(from: .controlCharacters) == nil
                }) else { return nil }
                return Entry(agent: folder, id: id, directory: directory, title: metadata.title ?? "", updated: updated,
                             profile: profile)
            }
        }
    }

    private static func kiroMetadata(in session: URL, decoder: JSONDecoder) -> KiroV3Metadata? {
        let file = session.appendingPathComponent("session.json")
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let input = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? input.close() }
        let limit = 1 << 20
        guard let data = try? input.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return try? decoder.decode(KiroV3Metadata.self, from: data)
    }

    private static func kiroDate(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}
