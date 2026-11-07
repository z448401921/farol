import Darwin
import Foundation

extension KiroActiveConversation {
    /// The runtime writes its own log under a different PID than the interactive terminal client.
    public static func read(pid: Int32, started: Date, directory: String?) -> PaneResume? {
        let pids = Ports.descendants(of: [pid], parents: Ports.parents())
        let home = FileManager.default.homeDirectoryForCurrentUser
        let profile = configuration(of: pid) ?? home.appendingPathComponent(AgentFolder.Kind.kiro.defaultFolder).path
        return read(pids: pids, started: started, directory: directory, home: home, configDirectory: profile)
    }

    private static func configuration(of pid: Int32) -> String? {
        var query = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, 3, nil, &size, nil, 0) == 0, size > 0, size <= 1 << 20 else { return nil }
        var bytes = Data(count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&query, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return configuration(in: bytes.prefix(size), home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// macOS puts the executable path and arguments before the environment. Only retain Kiro's profile path.
    static func configuration(in bytes: Data, home: URL) -> String? {
        let start = MemoryLayout<Int32>.size
        guard bytes.count > start, let executableEnd = bytes[start...].firstIndex(of: 0) else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= bytes.count else { return nil }
        var index = executableEnd + 1
        while index < bytes.endIndex, bytes[index] == 0 { index += 1 }
        for _ in 0..<argc {
            guard let end = bytes[index...].firstIndex(of: 0) else { return nil }
            index = end + 1
        }
        let prefix = Data("KIRO_HOME=".utf8)
        guard let entry = bytes[index...].split(separator: 0).first(where: { $0.starts(with: prefix) }),
              let path = String(data: entry.dropFirst(prefix.count), encoding: .utf8),
              path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard resolved != "/", resolved != homePath, !homePath.hasPrefix(resolved + "/") else { return nil }
        return resolved
    }
}
