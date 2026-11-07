import Foundation
import Testing
@testable import FarolCore

@Test func kiroReportsItsTurnAndApproval() {
    #expect(KiroStatus("state=idle:app=kiro-cli")?.event == .start)
    #expect(KiroStatus("state=working:app=kiro")?.event == .working)
    let blocked = KiroStatus("app=kiro:state=blocked:kind=permission:msg=UnVuIGdpdCBzdGF0dXM/")
    #expect(blocked?.event == .waiting)
    #expect(blocked?.asking == "Run git status?")
    #expect(KiroStatus("state=blocked:kind=question:app=kiro")?.asking == "Waiting for an answer")
    #expect(KiroStatus("app=kiro:state=done")?.event == .done)
    #expect(KiroStatus("app=kiro:state=error")?.event == .done)
    #expect(KiroStatus("state=clear", continuing: true)?.event == .clear)
}

@Test func kiroStatusIgnoresOtherProgramsAndMalformedReports() {
    #expect(KiroStatus("state=working:app=codex", continuing: true) == nil)
    #expect(KiroStatus("state=clear") == nil)
    #expect(KiroStatus("state=done:app=kiro:id=child") == nil)
    #expect(KiroStatus("state=blocked:app=kiro:msg=?") == nil)
    #expect(KiroStatus("state=blocked:app=kiro:msg=Chs=") == nil)
    #expect(KiroStatus("state=blocked:app=kiro:msg=Z28")?.asking == "go")
}
