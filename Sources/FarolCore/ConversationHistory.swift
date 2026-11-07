import Foundation

public enum ConversationHistory {
    private static let removalsKey = "history.removedConversations"
    private static let removalsLock = NSLock()

    public struct Entry: Equatable, Sendable {
        public let agent: AgentFolder
        public let id: String
        public let directory: String
        public let title: String
        public let updated: Date
        public let log: String?
        private let profile: String

        init(agent: AgentFolder, id: String, directory: String, title: String, updated: Date, log: String? = nil,
             profile: String? = nil) {
            self.agent = agent
            self.id = id
            self.directory = directory
            let words = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let clean = words.components(separatedBy: .controlCharacters).joined()
            self.title = clean.isEmpty ? "Untitled conversation" : String(clean.prefix(240))
            self.updated = updated
            self.log = log
            self.profile = profile ?? (agent.kind == .kiro
                ? ConversationHistory.kiroHistoryConfiguration(in: agent) : agent.directory.standardizedFileURL.path)
        }

        fileprivate var removalKey: [String] { [agent.kind.rawValue, profile, id] }

        public var resumeCommand: String {
            if agent.kind == .kiro, id.hasPrefix("sess_"),
               let command = PaneResume(kiroID: id, configDirectory: profile)?.command() {
                return command
            }
            return agent.resumeFromHistory(id)
        }

        /// Logs can contain arbitrary text. Only identifiers can be passed to an agent's resume option.
        var canResume: Bool {
            let bytes = id.utf8
            func alphanumeric(_ byte: UInt8) -> Bool {
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            }
            return bytes.count <= 256 && bytes.first.map(alphanumeric) == true
                && bytes.allSatisfy { alphanumeric($0) || [45, 46, 95].contains($0) }
                && directory.hasPrefix("/") && directory.rangeOfCharacter(from: .controlCharacters) == nil
                && updated.timeIntervalSince1970.isFinite
        }
    }

    /// The same connections Settings shows, including Kiro's built-in support.
    public static func enabledAgents() -> [AgentFolder] {
        AgentFolder.find().filter { folder in
            if folder.kind == .kiro { return true }
            return AgentSetup.setup(for: folder).map { $0.state() != .disconnected } ?? false
        }
    }

    /// Keep an exclusion in Farol's preferences so a history scan cannot add the record back.
    public static func remove(_ entry: Entry, defaults: UserDefaults = .standard) {
        removalsLock.withLock {
            var records = removedKeys(in: defaults)
            let key = entry.removalKey
            guard !records.contains(key) else { return }
            records.append(key)
            defaults.set(records, forKey: removalsKey)
        }
    }

    /// Apply exclusions again when publishing a snapshot that may have finished before a removal.
    public static func filterRemoved(from entries: [Entry], defaults: UserDefaults = .standard) -> [Entry] {
        let removed = Set(removedKeys(in: defaults))
        guard !removed.isEmpty else { return entries }
        return entries.filter { !removed.contains($0.removalKey) }
    }

    private static func removedKeys(in defaults: UserDefaults) -> [[String]] {
        defaults.array(forKey: removalsKey)?.compactMap { $0 as? [String] } ?? []
    }

    /// Reads the connected agents' local history. Call off the main thread.
    public static func list(in folders: [AgentFolder], defaults: UserDefaults = .standard) -> [Entry] {
        var result: [Entry] = []
        for folder in folders {
            if Task.isCancelled { break }
            let entries = folder.kind == .kiro ? kiro(in: folder) : local(in: folder)
            var seen = Set<String>()
            result += entries.filter(\.canResume).sorted { $0.updated > $1.updated }.filter { seen.insert($0.id).inserted }
        }
        return filterRemoved(from: result, defaults: defaults).sorted { $0.updated > $1.updated }
    }
}
