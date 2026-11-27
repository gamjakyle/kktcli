import Testing
@testable import KktcliCore

/// Regression tests for 2026-11-27: a query left in the chat search field filtered the list to
/// a room and an empty room, the list check failed, and `read` stopped before list recovery.
@Suite("Chat list check: empty rooms and a leftover search filter")
struct ChatListFilterTests {
    private func room(_ title: String = "테스트방", source: ChatRowSummary.TitleSource = .titleLabel, members: Int? = nil, time: String? = nil, preview: String? = nil) -> ChatRowSummary {
        ChatRowSummary(title: title, titleSource: source, memberCount: members, timeLabel: time, isPinned: false, preview: preview, unread: .none)
    }

    @Test("An empty group room (title and member count only) is a chat row; friend rows still are not")
    func emptyRoom() {
        #expect(ChatListCheck.isChatListRow(room(members: 13)))
        #expect(ChatListCheck.hasChatOnlyEvidence(room(members: 13)))
        #expect(!ChatListCheck.isChatListRow(room()))
        #expect(!ChatListCheck.hasChatOnlyEvidence(room(preview: "상태 메시지")))
        #expect(!ChatListCheck.isChatListRow(room(source: .fallback, members: 13)))
    }

    @Test("The reported filtered list (a room and an empty room) is the chat list")
    func reportedFilteredList() {
        let filtered = [room("테스트방", members: 13, time: "오후 3:47", preview: "안녕하세요"), room("테스트방 공지", members: 13)]
        #expect(ChatListCheck.verify(filtered) == .chatList)
        #expect(ChatListCheck.verify(containerRole: "AXTable", tab: .chats, summaries: filtered, searchQuery: "테스트") == .chatList)
    }

    @Test("A query on the 채팅 tab: a filtered table is the chat list, also an empty one")
    func queryOnChatTab() {
        let oneToOneEmpty = [room("홍길동"), room("김철수")]
        #expect(!ChatListCheck.verify(oneToOneEmpty).isChatList)
        #expect(ChatListCheck.verify(containerRole: "AXTable", tab: .chats, summaries: oneToOneEmpty, searchQuery: "홍") == .chatList)
        #expect(ChatListCheck.verify(containerRole: "AXTable", tab: .chats, summaries: [], searchQuery: "없는 이름") == .chatList)
        #expect(ChatListCheck.verify(containerRole: "AXTable", tab: .chats, summaries: [], searchQuery: nil) == .empty)
        #expect(ChatListCheck.verify(containerRole: "AXTable", tab: .chats, summaries: [], searchQuery: "  ") == .empty)
    }

    @Test("The query relaxes nothing anywhere else")
    func queryElsewhere() {
        let oneToOneEmpty = [room("홍길동"), room("김철수")]
        #expect(!ChatListCheck.verify(containerRole: "AXTable", tab: .unknown, summaries: oneToOneEmpty, searchQuery: "홍").isChatList)
        #expect(ChatListCheck.verify(containerRole: "AXTable", tab: .friends, summaries: oneToOneEmpty, searchQuery: "홍") == .otherTab(.friends))
        #expect(ChatListCheck.verify(containerRole: "AXOutline", tab: .chats, summaries: oneToOneEmpty, searchQuery: "홍") == .wrongContainer(role: "AXOutline"))
        let fallbackTitles = [room("홍길동", source: .fallback), room("김철수", source: .fallback)]
        #expect(!ChatListCheck.verify(containerRole: "AXTable", tab: .chats, summaries: fallbackTitles, searchQuery: "홍").isChatList)
        // Friend rows (a name, sometimes a status line) stay rejected without a query.
        let friends = (0..<12).map { index in room("홍길동\(index)", preview: index % 3 == 0 ? "상태 메시지" : nil) }
        #expect(!ChatListCheck.verify(containerRole: "AXTable", tab: .chats, summaries: friends).isChatList)
    }
}
