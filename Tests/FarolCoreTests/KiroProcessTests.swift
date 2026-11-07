import Foundation
import Testing
@testable import FarolCore

@Test func kiroReadsItsOwnProfileAfterTheProcessArguments() {
    let home = URL(fileURLWithPath: "/Users/test")
    func args(profile: String) -> Data {
        var argc: Int32 = 3
        var bytes = withUnsafeBytes(of: &argc) { Data($0) }
        bytes.append(Data("/bin/kiro-cli\0\0/bin/kiro-cli\0KIRO_HOME=/from-argument\0\0PATH=/bin\0KIRO_HOME=\(profile)\0".utf8))
        return bytes
    }
    #expect(KiroActiveConversation.configuration(in: args(profile: "/Users/test/kiro-profile"), home: home) == "/Users/test/kiro-profile")
    #expect(KiroActiveConversation.configuration(in: args(profile: "/Users"), home: home) == nil)
    #expect(KiroActiveConversation.configuration(in: args(profile: "relative"), home: home) == nil)
}
