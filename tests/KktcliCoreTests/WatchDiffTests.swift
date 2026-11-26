import Testing
@testable import KktcliCore

@Suite("watch: chat-list changes and new transcript items")
struct WatchDiffTests {
    private func entry(_ id: String, _ preview: String?, time: String? = "오후 3:00", unread: Int? = nil) -> ChatListEntrySnapshot {
        ChatListEntrySnapshot(chatID: id, title: "테스트방", preview: preview, time: time, unreadCount: unread, hasUnread: unread != nil)
    }

    @Test("The first poll is the baseline")
    func baseline() {
        #expect(WatchDiff.chatListChanges(previous: nil, current: [entry("a", "x")], knownChatIDs: []).isEmpty)
    }

    @Test("Preview or time change is a new message; badge change alone is unread_changed")
    func changes() {
        let previous = [entry("a", "안녕"), entry("b", "ㅇㅇ", unread: 1), entry("c", "회의")]
        let current = [entry("a", "내일 봐"), entry("b", "ㅇㅇ", unread: nil), entry("c", "회의", time: "오후 3:05")]
        let events = WatchDiff.chatListChanges(previous: previous, current: current, knownChatIDs: ["a", "b", "c"])
        #expect(events.map(\.change) == [.newMessage, .unreadChanged, .newMessage])
        #expect(events.map(\.entry.chatID) == ["a", "b", "c"])
    }

    @Test("A row new to the watched rows: known ID moved up (new message), unknown ID is a new room")
    func newRows() {
        let previous = [entry("a", "안녕")]
        let current = [entry("z", "처음"), entry("old", "다시"), entry("a", "안녕")]
        let events = WatchDiff.chatListChanges(previous: previous, current: current, knownChatIDs: ["a", "old"])
        #expect(events.map(\.change) == [.newRoom, .newMessage])
        #expect(WatchDiff.chatListChanges(previous: current, current: current, knownChatIDs: ["a", "old", "z"]).isEmpty)
    }

    @Test("New transcript items after the anchored tail, also with repeated messages")
    func transcript() {
        let a = SendVerification.Key(author: "홍길동", time: "15:00", body: "안녕")
        let b = SendVerification.Key(author: "(me)", time: "15:01", body: "ㅋㅋ")
        let c = SendVerification.Key(author: "홍길동", time: "15:02", body: "내일 봐")
        #expect(WatchDiff.newTranscriptItems(previous: [a, b], current: [a, b, c]) == (1, false))
        #expect(WatchDiff.newTranscriptItems(previous: [a, b], current: [a, b, b]) == (1, false))
        #expect(WatchDiff.newTranscriptItems(previous: [a, b], current: [a, b]) == (0, false))
        #expect(WatchDiff.newTranscriptItems(previous: [a, b], current: [b, c]) == (1, false))
        #expect(WatchDiff.newTranscriptItems(previous: [a], current: [c]) == (1, true))
        #expect(WatchDiff.newTranscriptItems(previous: [], current: [a, b]) == (2, false))
    }
}
