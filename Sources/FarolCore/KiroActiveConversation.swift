import Foundation

/// Kiro V3's runtime log names the conversation after it resolves a new session or a resume.
public enum KiroActiveConversation {
    public static func read(pids: Set<Int32>, started: Date, directory: String?,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser, configDirectory: String? = nil) -> PaneResume? {
        guard !pids.isEmpty else { return nil }
        if let configDirectory, !configDirectory.hasPrefix("/") || configDirectory.rangeOfCharacter(from: .controlCharacters) != nil {
            return nil
        }
        let config = configDirectory.map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(AgentFolder.Kind.kiro.defaultFolder)
        let roots = (try? FileManager.default.contentsOfDirectory(
            at: config.appendingPathComponent("logs"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        let matches = roots.filter { root in
            let parts = root.lastPathComponent.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[1]), pids.contains(pid), parts[0].utf8.count == 18,
                  let timestamp = logDate.date(from: String(parts[0])) else { return false }
            // The runtime starts after the terminal process. Check its start to avoid an old log from a reused PID.
            return (-1...120).contains(timestamp.timeIntervalSince(started))
        }
        guard matches.count == 1, let root = matches.first,
              let id = lastTransition(in: root.appendingPathComponent("kiro.log")) else { return nil }
        return PaneResume(kiroID: id, configDirectory: configDirectory, workingDirectory: directory)
    }

    private static let logDate: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyyMMdd'T'HHmmssSSS"
        return format
    }()

    private struct LogLine: Decodable {
        let message: String
    }

    private struct Transition: Decodable {
        let sessionId: String
        let outcome: String?
    }

    private static let loaded = "session.load.timing "
    private static let events = ["session.new.total ", loaded]
    private static let markers = events.map { Data($0.utf8) }

    private static func lastTransition(in file: URL) -> String? {
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let limit: UInt64 = 16 << 20
        let chunkSize: UInt64 = 128 << 10
        let maxRecord = 16 << 10
        let newline = UInt8(ascii: "\n")
        guard var end = try? handle.seekToEnd() else { return nil }
        let lowerBound = end > limit ? end - limit : 0
        var fragment: Data? = Data()
        while end > lowerBound {
            let length = min(chunkSize, end - lowerBound)
            let offset = end - length
            guard (try? handle.seek(toOffset: offset)) != nil,
                  var bytes = try? handle.read(upToCount: Int(length)), bytes.count == Int(length) else { return nil }
            end = offset
            // Save the partial first line for the previous chunk. Large records cannot be session transitions.
            if let fragment {
                bytes.append(fragment)
            } else if let lastNewline = bytes.lastIndex(of: newline) {
                bytes = bytes.prefix(through: lastNewline)
            } else {
                continue
            }
            let lines = bytes.split(separator: newline, omittingEmptySubsequences: false)[...]
            if let id = lastTransition(in: offset == 0 ? lines : lines.dropFirst(), maxRecord: maxRecord) { return id }
            fragment = lines.first.flatMap { $0.count <= maxRecord ? Data($0) : nil }
        }
        return nil
    }

    private static func lastTransition(in lines: ArraySlice<Data>, maxRecord: Int) -> String? {
        let decoder = JSONDecoder()
        for line in lines.reversed() {
            guard line.count <= maxRecord, markers.contains(where: { line.range(of: $0) != nil }),
                  let record = try? decoder.decode(LogLine.self, from: line),
                  let event = events.first(where: { record.message.hasPrefix($0) }),
                  let details = try? decoder.decode(Transition.self, from: Data(record.message.dropFirst(event.count).utf8)),
                  event == loaded || details.outcome == "resolved",
                  PaneResume.isKiroID(details.sessionId) else { continue }
            return details.sessionId
        }
        return nil
    }
}
