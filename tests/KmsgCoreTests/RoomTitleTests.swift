import Testing
@testable import KmsgCore

@Suite("Chat-list row title vs. chat window title")
struct RoomTitleTests {
    @Test("A team-chat row opens a window titled without the 팀채팅 prefix")
    func teamChatPrefix() {
        #expect(RoomTitle.expectedWindowTitle(forRowTitle: "팀채팅, 스터디 모임") == "스터디 모임")
        #expect(RoomTitle.windowMatchesRow(windowTitle: "스터디 모임", rowTitle: "팀채팅, 스터디 모임"))
    }

    @Test("Self chat prefix is handled the same way")
    func selfChatPrefix() {
        #expect(RoomTitle.windowMatchesRow(windowTitle: "홍길동", rowTitle: "나와의 채팅, 홍길동"))
    }

    @Test("Plain rooms still need the same title")
    func plainRooms() {
        #expect(RoomTitle.windowMatchesRow(windowTitle: "홍길동", rowTitle: "홍길동"))
        #expect(!RoomTitle.windowMatchesRow(windowTitle: "홍길동", rowTitle: "김철수"))
        #expect(!RoomTitle.windowMatchesRow(windowTitle: "", rowTitle: "홍길동"))
    }

    @Test("Only a short single label may precede the window title of a just-opened window")
    func unknownLabel() {
        #expect(RoomTitle.openedWindowMatchesRow(windowTitle: "모임", rowTitle: "오픈채팅, 모임"))
        #expect(!RoomTitle.openedWindowMatchesRow(windowTitle: "모임", rowTitle: "아주 긴 다른 방 이름 일부, 모임"))
        #expect(!RoomTitle.openedWindowMatchesRow(windowTitle: "모임", rowTitle: "a, b, 모임"))
        #expect(RoomTitle.openedWindowMatchesRow(windowTitle: "스터디 모임", rowTitle: "팀채팅, 스터디 모임"))
    }

    @Test("An unnamed group row never matches an already open 1:1 window of one member")
    func groupMemberListIsNotATypeLabel() {
        #expect(!RoomTitle.windowMatchesRow(windowTitle: "아빠", rowTitle: "엄마, 아빠"))
        #expect(!RoomTitle.windowMatchesRow(windowTitle: "모임", rowTitle: "오픈채팅, 모임"))
        #expect(RoomTitle.windowMatchesRow(windowTitle: "엄마, 아빠", rowTitle: "엄마, 아빠"))
    }
}
