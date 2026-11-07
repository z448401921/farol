import Foundation
import SQLite3

extension ConversationHistory {
    static func local(in folder: AgentFolder) -> [Entry] {
        switch folder.kind {
        case .claude: claude(in: folder)
        case .codex: codex(in: folder)
        case .pi: pi(in: folder)
        case .opencode: openCode(in: folder)
        case .kiro: []
        }
    }

    private static func claude(in agent: AgentFolder) -> [Entry] {
        logs(under: agent.directory.appendingPathComponent("projects"), depth: 2) { file, updated in
            let id = file.deletingPathExtension().lastPathComponent
            let records = jsonLines(in: file, bytes: 256 << 10)
                .filter { $0["isSidechain"] as? Bool != true }
            guard let directory = records.lazy.compactMap({ $0["cwd"] as? String }).first else { return nil }
            let tail = jsonLines(in: file, bytes: 128 << 10, tail: true)
            let title = tail.reversed().lazy.compactMap { row -> String? in
                guard row["type"] as? String == "custom-title" else { return nil }
                return row["customTitle"] as? String
            }.first ?? records.lazy.filter { $0["type"] as? String == "user" }.compactMap { row in
                ClaudeLog.messages(in: row, id: id).first(where: { $0.role == .you })?.text
            }.first
            return localEntry(agent, id, directory, title, updated, log: file.path)
        }
    }

    private static func codex(in agent: AgentFolder) -> [Entry] {
        let index = jsonLines(in: agent.directory.appendingPathComponent("session_index.jsonl"), bytes: 4 << 20, tail: true)
        var titles: [String: String] = [:]
        for row in index {
            if let id = row["id"] as? String, let title = row["thread_name"] as? String {
                titles[id] = title
            }
        }
        let indexed = codexDatabase(in: agent, titles: titles)
        let indexedIDs = Set(indexed.map(\.id))
        let indexedPaths = Set(indexed.compactMap(\.log))
        let files = logs(under: agent.directory.appendingPathComponent("sessions"), depth: 4) { file, updated -> Entry? in
            guard !indexedPaths.contains(file.path) else { return nil }
            let records = jsonLines(in: file, bytes: 256 << 10)
            guard let header = records.first, header["type"] as? String == "session_meta",
                  let session = header["payload"] as? [String: Any], let id = session["id"] as? String,
                  !indexedIDs.contains(id), session["parent_thread_id"] as? String == nil,
                  !codexChild(session["source"] as? String, session["thread_source"] as? String),
                  (session["source"] as? [String: Any])?["subagent"] == nil,
                  let directory = session["cwd"] as? String else { return nil }
            let title = titles[id] ?? records.lazy.compactMap { row -> String? in
                guard let item = row["payload"] as? [String: Any] else { return nil }
                if item["type"] as? String == "user_message" { return item["message"] as? String }
                guard item["type"] as? String == "message", item["role"] as? String == "user" else { return nil }
                return firstText(item["content"], type: "input_text")
            }.first
            return localEntry(agent, id, directory, title, updated, log: file.path)
        }
        return indexed + files
    }

    /// A paginated Codex history can live entirely in its databases, with no rollout file left to read.
    private static func codexDatabase(in agent: AgentFolder, titles: [String: String]) -> [Entry] {
        let state = ProcessInfo.processInfo.environment["CODEX_SQLITE_HOME"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? agent.directory
        let databases = (try? FileManager.default.contentsOfDirectory(at: state, includingPropertiesForKeys: nil)) ?? []
        let candidates = databases.filter {
            $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite"
        }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        for file in candidates {
            if let entries = readOnly(file, { db -> [Entry]? in
                let columns = columnNames(in: "threads", db: db)
                guard columns.isSuperset(of: ["id", "rollout_path", "cwd", "updated_at", "archived", "source", "title"]) else {
                    return nil
                }
                func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
                let query = """
                SELECT id, rollout_path, cwd, title, updated_at, source, \(column("thread_source")),
                       \(column("name")), \(column("first_user_message")), \(column("updated_at_ms")), \(column("history_mode"))
                FROM threads WHERE archived = 0
                """
                return rows(db, query) { row in
                    guard let id = string(row, 0), let directory = string(row, 2),
                          !codexChild(string(row, 5), string(row, 6)) else { return nil }
                    let log = string(row, 1).flatMap { path in
                        path.hasPrefix("/") && FileManager.default.fileExists(atPath: path) ? path : nil
                    }
                    guard log != nil || string(row, 10) == "paginated" else { return nil }
                    let milliseconds = sqlite3_column_int64(row, 9)
                    let updated = Date(timeIntervalSince1970: milliseconds > 0 ? Double(milliseconds) / 1000 : sqlite3_column_double(row, 4))
                    let title = [string(row, 7), titles[id], string(row, 3), string(row, 8)]
                        .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    return localEntry(agent, id, directory, title, updated, log: log)
                }
            }) { return entries }
        }
        return []
    }

    private static func codexChild(_ source: String?, _ threadSource: String?) -> Bool {
        threadSource == "subagent" || threadSource == "guardian_review" || source == "subagent"
            || source?.hasPrefix(#"{"subagent":"#) == true
    }

    private static func pi(in agent: AgentFolder) -> [Entry] {
        logs(under: agent.directory.appendingPathComponent("sessions"), depth: 2) { file, updated in
            let records = jsonLines(in: file, bytes: 128 << 10)
            guard let session = records.first, session["type"] as? String == "session",
                  let id = session["id"] as? String, let directory = session["cwd"] as? String else { return nil }
            let tail = jsonLines(in: file, bytes: 128 << 10, tail: true)
            let name = tail.reversed().first { $0["type"] as? String == "session_info" }?["name"] as? String
            let title = name ?? records.lazy.compactMap { row -> String? in
                guard row["type"] as? String == "message", let message = row["message"] as? [String: Any],
                      message["role"] as? String == "user" else { return nil }
                return firstText(message["content"], type: "text")
            }.first
            return localEntry(agent, id, directory, title, updated, log: file.path)
        }
    }

    static func openCode(in agent: AgentFolder, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> [Entry] {
        let data = (environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".local/share")).appendingPathComponent("opencode")
        let name = environment["OPENCODE_DB"].flatMap { $0.isEmpty ? nil : $0 } ?? "opencode.db"
        guard name != ":memory:" else { return [] }
        let database = name.hasPrefix("/") ? URL(fileURLWithPath: name) : data.appendingPathComponent(name)
        if let entries = readOnly(database, { db -> [Entry]? in
            // The V2 migration keeps the old table beside the new one.
            let table = columnNames(in: "session_v2", db: db).contains("directory") ? "session_v2" : "session"
            let columns = columnNames(in: table, db: db)
            guard columns.isSuperset(of: ["id", "directory", "title", "time_updated", "parent_id"]) else { return nil }
            let active = columns.contains("time_archived") ? " AND time_archived IS NULL" : ""
            return rows(db, "SELECT id, directory, title, time_updated FROM \(table) WHERE parent_id IS NULL\(active)") { row in
                guard let id = string(row, 0), let directory = string(row, 1) else { return nil }
                let updated = Date(timeIntervalSince1970: sqlite3_column_double(row, 3) / 1000)
                return localEntry(agent, id, directory, string(row, 2), updated)
            }
        }) { return entries }

        return logs(under: data.appendingPathComponent("storage/session"), depth: 2, fileExtension: "json") { file, updated in
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: (64 << 10) + 1), data.count <= 64 << 10,
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = record["id"] as? String, let directory = record["directory"] as? String,
                  record["parentID"] as? String == nil else { return nil }
            let time = record["time"] as? [String: Any]
            guard time?["archived"] as? Double == nil else { return nil }
            let date = (time?["updated"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? updated
            return localEntry(agent, id, directory, record["title"] as? String, date)
        }
    }

    private static func localEntry(_ agent: AgentFolder, _ id: String, _ directory: String, _ title: String?,
                                   _ updated: Date, log: String? = nil) -> Entry? {
        guard !id.isEmpty, !id.hasPrefix("-"), directory.hasPrefix("/") else { return nil }
        return Entry(agent: agent, id: id, directory: directory, title: title ?? "", updated: updated, log: log)
    }

    private static func firstText(_ content: Any?, type: String) -> String? {
        if let text = content as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return (content as? [[String: Any]])?.lazy
            .filter { $0["type"] as? String == type }.compactMap { $0["text"] as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("<") }
    }

    private static func logs(under folder: URL, depth: Int, fileExtension: String = "jsonl",
                             read: (URL, Date) -> Entry?) -> [Entry] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                                                        options: .skipsHiddenFiles) else { return [] }
        var entries: [Entry] = []
        for case let file as URL in files {
            guard files.level == depth else { continue }
            files.skipDescendants()
            guard file.pathExtension == fileExtension, let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            if let entry = autoreleasepool(invoking: { read(file, values.contentModificationDate ?? .distantPast) }) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Conversation logs can contain many megabytes of tools and images. History needs only the first prompt and recent title.
    private static func jsonLines(in file: URL, bytes: Int, tail: Bool = false) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = tail && size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: bytes) else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)[...]
        if offset > 0 { lines = lines.dropFirst() }
        if offset + UInt64(data.count) < size { lines = lines.dropLast() }
        return lines.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    private static func readOnly(_ file: URL, _ read: (OpaquePointer) -> [Entry]?) -> [Entry]? {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_PRIVATECACHE, nil) == SQLITE_OK,
              let database else { return nil }
        return read(database)
    }

    private static func columnNames(in table: String, db: OpaquePointer) -> Set<String> {
        Set(rows(db, "PRAGMA table_info(\(table))") { string($0, 1) })
    }

    private static func rows<T>(_ database: OpaquePointer, _ query: String, read: (OpaquePointer) -> T?) -> [T] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = read(statement) { result.append(value) }
        }
        return result
    }

    private static func string(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }
}
