import Testing
@testable import KktcliCore

@Suite("Which window is the room that 채팅방 열기 opened")
struct OpenedWindowRuleTests {
    private func window(_ title: String?, new: Bool, chat: Bool? = nil) -> OpenedWindowCandidate {
        OpenedWindowCandidate(title: title, isNew: new, isChatWindow: chat)
    }

    @Test("The only new window may be untitled when it shows a chat (open chats)")
    func untitledSingleNewChatWindow() {
        let candidates = [window("가족", new: false), window("", new: true, chat: true)]
        #expect(OpenedWindowRule.untitledNewWindow(in: candidates) == 1)
        #expect(OpenedWindowRule.match(rowTitle: "오픈채팅, 맥 개발자 모임", candidates: candidates) == .untitled(1))
        // A missing title (nil) or only whitespace counts as untitled too.
        #expect(OpenedWindowRule.match(rowTitle: "오픈채팅, 모임", candidates: [window(nil, new: true, chat: true)]) == .untitled(0))
        #expect(OpenedWindowRule.match(rowTitle: "오픈채팅, 모임", candidates: [window("  ", new: true, chat: true)]) == .untitled(0))
    }

    @Test("An untitled window is not accepted unless it is verified as a chat window")
    func untitledNeedsChatContent() {
        #expect(OpenedWindowRule.match(rowTitle: "오픈채팅, 모임", candidates: [window("", new: true)]) == .none)
        #expect(OpenedWindowRule.match(rowTitle: "오픈채팅, 모임", candidates: [window("", new: true, chat: false)]) == .none)
    }

    @Test("Untitled windows that existed before the press are never accepted")
    func untitledOldWindow() {
        let candidates = [window("", new: false, chat: true)]
        #expect(OpenedWindowRule.untitledNewWindow(in: candidates) == nil)
        #expect(OpenedWindowRule.match(rowTitle: "오픈채팅, 모임", candidates: candidates) == .none)
    }

    @Test("Several new windows are never guessed between")
    func severalNewWindows() {
        let candidates = [window("", new: true, chat: true), window("", new: true, chat: true)]
        #expect(OpenedWindowRule.untitledNewWindow(in: candidates) == nil)
        #expect(OpenedWindowRule.match(rowTitle: "오픈채팅, 모임", candidates: candidates) == .none)
        let mixed = [window("다른 방", new: true), window("", new: true, chat: true)]
        #expect(OpenedWindowRule.match(rowTitle: "오픈채팅, 모임", candidates: mixed) == .none)
    }

    @Test("A titled window for the row wins, and open-chat titles drop the prefix")
    func titledWindows() {
        let candidates = [window("", new: true, chat: true), window("모임", new: false)]
        #expect(OpenedWindowRule.match(rowTitle: "오픈채팅, 모임", candidates: candidates) == .titled(1))
        #expect(OpenedWindowRule.match(rowTitle: "오픈채팅, 모임", candidates: [window("모임", new: true)]) == .titled(0))
        #expect(OpenedWindowRule.match(rowTitle: "팀채팅, 스터디", candidates: [window("스터디", new: true)]) == .titled(0))
        // A single new window whose title only differs in spacing or punctuation.
        #expect(OpenedWindowRule.match(rowTitle: "홍 길동!", candidates: [window("홍길동", new: true)]) == .titled(0))
        // A single new window titled for another room is not the room.
        #expect(OpenedWindowRule.match(rowTitle: "오픈채팅, 모임", candidates: [window("다른 방", new: true)]) == .none)
    }

    @Test("Reports list untitled windows with a placeholder")
    func labels() {
        #expect(OpenedWindowRule.label("") == "(untitled)")
        #expect(OpenedWindowRule.label(nil) == "(untitled)")
        #expect(OpenedWindowRule.label(" ") == "(untitled)")
        #expect(OpenedWindowRule.label(" 모임 ") == "모임")
        #expect(OpenedWindowRule.isUntitled(""))
        #expect(!OpenedWindowRule.isUntitled("모임"))
    }
}
