import Testing
@testable import KktcliCore

@Suite("Chat list verification and the 채팅 tab switch")
struct ChatListCheckTests {
    private func row(title: String? = "테스트방", source: ChatRowSummary.TitleSource = .titleLabel, time: String? = nil, preview: String? = nil) -> ChatRowSummary {
        ChatRowSummary(title: title, titleSource: source, memberCount: nil, timeLabel: time, isPinned: false, preview: preview, unread: .none)
    }

    @Test("Chat rows: title label plus time or preview; a mostly timed sample is the chat list")
    func chatList() {
        let rows = (0..<20).map { index in row(time: index % 5 == 0 ? nil : "오후 3:1\(index % 10)", preview: "안녕하세요") }
        #expect(ChatListCheck.verify(rows) == .chatList)
        #expect(ChatListCheck.isChatListRow(row(time: "어제")))
        #expect(ChatListCheck.isChatListRow(row(preview: "대화 중인 오픈채팅방이 없습니다.")))
        #expect(!ChatListCheck.isChatListRow(row(source: .fallback, time: "어제")))
        #expect(!ChatListCheck.isChatListRow(row()))
    }

    @Test("Friend rows (name, sometimes a status line, no time) are not the chat list")
    func friendsTab() {
        let friends = (0..<30).map { index in row(title: "홍길동\(index)", preview: index % 3 == 0 ? "상태 메시지" : nil) }
        guard case .notChatList(let sampled, let chatLike, let timed) = ChatListCheck.verify(friends) else {
            Issue.record("expected notChatList")
            return
        }
        #expect(sampled == 12)
        #expect(chatLike == 4)
        #expect(timed == 0)
        // Even when every sampled friend shows a status line, no time means no chat list.
        #expect(!ChatListCheck.verify((0..<12).map { _ in row(preview: "상태 메시지") }).isChatList)
        #expect(ChatListCheck.verify([]) == .empty)
    }

    @Test("Only 채팅 with ⌘2 is the menu item to press; 친구 and 더보기 never")
    func menuItem() {
        #expect(ChatTabMenu.isChatTabItem(role: "AXMenuItem", title: "채팅", commandCharacter: "2"))
        #expect(!ChatTabMenu.isChatTabItem(role: "AXMenuItem", title: "채팅", commandCharacter: "1"))
        #expect(!ChatTabMenu.isChatTabItem(role: "AXMenuItem", title: "친구", commandCharacter: "1"))
        #expect(!ChatTabMenu.isChatTabItem(role: "AXMenuItem", title: "더보기", commandCharacter: "3"))
        #expect(!ChatTabMenu.isChatTabItem(role: "AXMenuItem", title: "채팅방 열기", commandCharacter: "2"))
        #expect(!ChatTabMenu.isChatTabItem(role: "AXButton", title: "채팅", commandCharacter: "2"))
        #expect(!ChatTabMenu.isChatTabItem(role: "AXMenuItem", title: "채팅", commandCharacter: nil))
    }

    @Test("Switch decision: use a verified or empty table, switch once otherwise, never twice")
    func decisions() {
        let other = ChatListVerification.notChatList(sampled: 12, chatLike: 2, timed: 0)
        #expect(ChatTabMenu.decide(.chatList, mayPress: true, alreadySwitched: false) == .useTable)
        #expect(ChatTabMenu.decide(.empty, mayPress: false, alreadySwitched: false) == .useTable)
        #expect(ChatTabMenu.decide(other, mayPress: true, alreadySwitched: false) == .switchTab)
        #expect(ChatTabMenu.decide(.noTable, mayPress: true, alreadySwitched: false) == .switchTab)
        #expect(ChatTabMenu.decide(other, mayPress: true, alreadySwitched: true) == .notChatTab)
        #expect(ChatTabMenu.decide(other, mayPress: false, alreadySwitched: false) == .notChatTab)
    }

    @Test("Switching the tab waits while KakaoTalk is in use, like opening a room")
    func activity() {
        #expect(!UserActivityPress.switchToChatTab.activatesKakaoTalk)
        let busy = UserActivityState(kakaoTalkMayBeFrontmost: true, secondsSinceLastInput: 1)
        #expect(!UserActivityPolicy.mayPress(.switchToChatTab, state: busy, idleSeconds: 10))
        #expect(UserActivityPolicy.mayPress(.switchToChatTab, state: UserActivityState(kakaoTalkMayBeFrontmost: false, secondsSinceLastInput: 1), idleSeconds: 10))
    }
}
