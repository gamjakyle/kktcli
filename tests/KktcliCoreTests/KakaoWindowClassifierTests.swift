import CoreGraphics
import Testing
@testable import KktcliCore

@Suite("What the window 채팅방 열기 opened is")
struct KakaoWindowClassifierTests {
    private func node(_ role: String, id: String = "", value: String? = nil, desc: String? = nil, depth: Int) -> AXNodeSnapshot {
        AXNodeSnapshot(role: role, identifier: id, value: value, desc: desc, depth: depth)
    }

    /// The window an "오픈채팅, …" row opened live (KakaoTalk 26.10.0): a list of
    /// 1:1 open-chat conversations, no transcript and no input.
    private func openChatListWindow(rows: [(String, String?)]) -> [AXNodeSnapshot] {
        var nodes = [
            node("AXWindow", id: "_NS:8", depth: 0),
            node("AXImage", id: "_NS:81", depth: 1),
            node("AXScrollArea", id: "_NS:14", depth: 1),
            node("AXTable", id: "_NS:18", depth: 2),
        ]
        for (title, time) in rows {
            nodes += [
                node("AXRow", depth: 3),
                node("AXCell", depth: 4),
                node("AXButton", id: "_NS:11", desc: "프로필", depth: 5),
                node("AXStaticText", id: "_NS:40", value: title, depth: 5),
                node("AXStaticText", id: "_NS:69", value: time, depth: 5),
                node("AXScrollArea", id: "_NS:87", depth: 5),
            ]
        }
        nodes += [
            node("AXColumn", depth: 3),
            node("AXButton", id: "_NS:167", desc: "버튼", depth: 1),
            node("AXButton", depth: 1),
        ]
        return nodes
    }

    @Test("The live open-chat list window is classified with its conversations")
    func openChatList() {
        let kind = KakaoWindowClassifier.classify(openChatListWindow(rows: [("대화상대 없음", nil), ("대화상대 없음", "")]))
        guard case .openChatList(let list) = kind else {
            Issue.record("expected an open-chat list, got \(kind)")
            return
        }
        #expect(list.conversations == [
            OpenChatList.Conversation(title: "대화상대 없음", time: nil),
            OpenChatList.Conversation(title: "대화상대 없음", time: nil),
        ])
        let timed = KakaoWindowClassifier.classify(openChatListWindow(rows: [("홍길동", "오후 3:12")]))
        #expect(timed == .openChatList(OpenChatList(conversations: [.init(title: "홍길동", time: "오후 3:12")])))
    }

    @Test("A transcript or a message input makes it a chat, even next to a list")
    func chats() {
        let transcript = [
            node("AXWindow", depth: 0),
            node("AXScrollArea", id: "_NS:32", depth: 1),
            node("AXTable", depth: 2),
        ]
        #expect(KakaoWindowClassifier.classify(transcript) == .chat)
        let inputOnly = [node("AXWindow", depth: 0), node("AXTextArea", id: "_NS:51", depth: 1)]
        #expect(KakaoWindowClassifier.classify(inputOnly) == .chat)
        let both = openChatListWindow(rows: [("홍길동", nil)]) + [node("AXTextArea", id: "_NS:51", depth: 1)]
        #expect(KakaoWindowClassifier.classify(both) == .chat)
    }

    @Test("Anything else is unknown: no rows, no titles, wrong identifiers, a transcript without table")
    func unknown() {
        #expect(KakaoWindowClassifier.classify([node("AXWindow", depth: 0)]) == .unknown)
        #expect(KakaoWindowClassifier.classify(openChatListWindow(rows: [])) == .unknown)
        #expect(KakaoWindowClassifier.classify(openChatListWindow(rows: [("", nil)])) == .unknown)
        let otherTable = [
            node("AXWindow", depth: 0),
            node("AXScrollArea", id: "_NS:14", depth: 1),
            node("AXTable", id: "_NS:99", depth: 2),
            node("AXRow", depth: 3),
            node("AXCell", depth: 4),
            node("AXStaticText", id: "_NS:40", value: "홍길동", depth: 5),
        ]
        #expect(KakaoWindowClassifier.classify(otherTable) == .unknown)
        let emptyTranscript = [node("AXWindow", depth: 0), node("AXScrollArea", id: "_NS:32", depth: 1)]
        #expect(KakaoWindowClassifier.classify(emptyTranscript) == .unknown)
        // A list next to an (empty) transcript area is not the open-chat list.
        let listAndTranscript = openChatListWindow(rows: [("홍길동", nil)]) + [node("AXScrollArea", id: "_NS:32", depth: 1)]
        #expect(KakaoWindowClassifier.classify(listAndTranscript) == .unknown)
    }
}
