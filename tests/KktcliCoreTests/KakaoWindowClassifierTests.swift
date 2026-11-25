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

    @Test("An empty open-chat list (zero rows, header image) is still the list")
    func emptyOpenChatList() {
        // Shaped like the live capture of a list with no conversations.
        let empty = [
            node("AXWindow", id: "_NS:8", depth: 0),
            node("AXImage", id: "_NS:81", depth: 1),
            node("AXScrollArea", id: "_NS:14", depth: 1),
            node("AXTable", id: "_NS:18", depth: 2),
            node("AXColumn", value: "AutomaticTableColumnIdentifier.0", depth: 3),
            node("AXStaticText", value: "내 오픈채팅방 링크를 공유하고\n대화를 시작해 보세요.", depth: 1),
            node("AXButton", id: "_NS:167", desc: "버튼", depth: 1),
            node("AXButton", depth: 1),
            node("AXButton", depth: 1),
        ]
        #expect(KakaoWindowClassifier.classify(empty) == .openChatList(OpenChatList(conversations: [])))
        // Without the header image an empty table proves nothing.
        let noImage = empty.filter { $0.identifier != "_NS:81" }
        #expect(KakaoWindowClassifier.classify(noImage) == .unknown)
        // Never with a transcript or an input anywhere.
        #expect(KakaoWindowClassifier.classify(empty + [node("AXTextArea", id: "_NS:51", depth: 1)]) == .chat)
        #expect(KakaoWindowClassifier.classify(empty + [node("AXScrollArea", id: "_NS:32", depth: 1)]) == .unknown)
    }

    @Test("The empty-list preview is only a shortcut for open-chat rows")
    func emptyListPreview() {
        #expect(KakaoWindowClassifier.isEmptyOpenChatListRow(title: "오픈채팅, 새벽 산책", preview: "대화 중인 오픈채팅방이 없습니다."))
        #expect(KakaoWindowClassifier.isEmptyOpenChatListRow(title: "오픈채팅, 새벽 산책", preview: " 대화 중인 오픈채팅방이 없습니다.\n"))
        #expect(!KakaoWindowClassifier.isEmptyOpenChatListRow(title: "새벽 산책", preview: "대화 중인 오픈채팅방이 없습니다."))
        #expect(!KakaoWindowClassifier.isEmptyOpenChatListRow(title: "오픈채팅, 새벽 산책", preview: "대화 중인 오픈채팅방이 없습니다. 지금"))
        #expect(!KakaoWindowClassifier.isEmptyOpenChatListRow(title: "오픈채팅, 새벽 산책", preview: nil))
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
        // Without the header image, rows without titles prove nothing.
        let untitledRowsNoImage = openChatListWindow(rows: [("", nil)]).filter { $0.identifier != "_NS:81" }
        #expect(KakaoWindowClassifier.classify(untitledRowsNoImage) == .unknown)
        // With the header image the structure alone decides (titles may be empty).
        #expect(KakaoWindowClassifier.classify(openChatListWindow(rows: [("", nil)])) == .openChatList(OpenChatList(conversations: [])))
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
