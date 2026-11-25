import Testing
@testable import KktcliCore

@Suite("Unread badge before and after opening a room")
struct UnreadReceiptTests {
    private let incomplete = UnreadBadge.unknown(ChatRowAnalyzer.incompleteReadEvidence)

    @Test("A badge that disappeared means the room was marked read")
    func badgeGone() {
        #expect(UnreadReceipt.markedRead(before: .count(3), after: UnreadBadge.none) == true)
        #expect(UnreadReceipt.markedRead(before: .unknown("5"), after: UnreadBadge.none) == true)
    }

    @Test("A badge that is still there means it was not marked read")
    func badgeStillThere() {
        #expect(UnreadReceipt.markedRead(before: .count(3), after: .count(3)) == false)
        #expect(UnreadReceipt.markedRead(before: .count(3), after: .count(4)) == false)
    }

    @Test("No badge before, an uncertain read, or no second read: unknown")
    func unknownCases() {
        #expect(UnreadReceipt.markedRead(before: UnreadBadge.none, after: UnreadBadge.none) == nil)
        #expect(UnreadReceipt.markedRead(before: .count(3), after: nil) == nil)
        #expect(UnreadReceipt.markedRead(before: incomplete, after: UnreadBadge.none) == nil)
        #expect(UnreadReceipt.markedRead(before: .count(3), after: incomplete) == nil)
    }

    @Test("JSON evidence is the badge text, or nil without a badge")
    func evidence() {
        #expect(UnreadReceipt.evidence(.count(3)) == "안읽음 3")
        #expect(UnreadReceipt.evidence(.unknown("999+")) == "999+")
        #expect(UnreadReceipt.evidence(UnreadBadge.none) == nil)
        #expect(UnreadReceipt.evidence(nil) == nil)
    }
}
