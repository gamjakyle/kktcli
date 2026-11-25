import CoreGraphics
import Testing
@testable import KktcliCore

@Suite("Frontmost guard, menu safety, scrolling and query matching")
struct PolicyTests {
    @Test("Keyboard input is allowed only when KakaoTalk is verifiably frontmost")
    func keyboardPolicy() {
        let allowed = FrontmostPolicy.keyboard(FrontmostEvidence(kakaoPID: 42, focusedApplicationPID: 42, kakaoReportsFrontmost: true))
        #expect(allowed.allowed)

        let focusedElsewhere = FrontmostPolicy.keyboard(FrontmostEvidence(kakaoPID: 42, focusedApplicationPID: 7, kakaoReportsFrontmost: true))
        #expect(!focusedElsewhere.allowed)

        let background = FrontmostPolicy.keyboard(FrontmostEvidence(kakaoPID: 42, focusedApplicationPID: 42, kakaoReportsFrontmost: false))
        #expect(!background.allowed)

        let unverifiable = FrontmostPolicy.keyboard(FrontmostEvidence(kakaoPID: 42, focusedApplicationPID: nil, kakaoReportsFrontmost: nil))
        #expect(!unverifiable.allowed)

        let onlyAppSays = FrontmostPolicy.keyboard(FrontmostEvidence(kakaoPID: 42, focusedApplicationPID: nil, kakaoReportsFrontmost: true))
        #expect(onlyAppSays.allowed)

        // KakaoTalk busy: its AXFrontmost read timed out, but the system says it has focus.
        let busy = FrontmostPolicy.keyboard(FrontmostEvidence(kakaoPID: 42, focusedApplicationPID: 42, kakaoReportsFrontmost: nil))
        #expect(busy.allowed)

        let contradicting = FrontmostPolicy.keyboard(FrontmostEvidence(kakaoPID: 42, focusedApplicationPID: 42, kakaoReportsFrontmost: false))
        #expect(!contradicting.allowed)

        let notRunning = FrontmostPolicy.keyboard(FrontmostEvidence(kakaoPID: nil, focusedApplicationPID: 42, kakaoReportsFrontmost: true))
        #expect(!notRunning.allowed)
    }

    @Test("Clicks additionally require KakaoTalk to own the point")
    func pointerPolicy() {
        let front = FrontmostEvidence(kakaoPID: 42, focusedApplicationPID: 42, kakaoReportsFrontmost: true)
        #expect(FrontmostPolicy.pointer(front, pointOwnerPID: 42).allowed)
        #expect(!FrontmostPolicy.pointer(front, pointOwnerPID: 99).allowed)
        #expect(!FrontmostPolicy.pointer(front, pointOwnerPID: nil).allowed)
        let back = FrontmostEvidence(kakaoPID: 42, focusedApplicationPID: 7, kakaoReportsFrontmost: false)
        #expect(!FrontmostPolicy.pointer(back, pointOwnerPID: 42).allowed)
    }

    @Test("Only 채팅방 열기 / openChatRoom: may be pressed")
    func menuSafety() {
        #expect(MenuItemSafety.isOpenChatRoomItem(title: "채팅방 열기", identifier: "openChatRoom:"))
        #expect(!MenuItemSafety.isBlocked(title: "채팅방 열기", description: nil, identifier: "openChatRoom:"))
        #expect(!MenuItemSafety.isOpenChatRoomItem(title: "채팅방 열기", identifier: "markAsRead:"))
        #expect(!MenuItemSafety.isOpenChatRoomItem(title: "읽음 처리", identifier: "openChatRoom:"))

        #expect(MenuItemSafety.isBlocked(title: "읽음 처리", description: nil, identifier: "markAsRead:"))
        #expect(MenuItemSafety.isBlocked(title: "채팅방 나가기", description: nil, identifier: "leaveChatRoom:"))
        #expect(MenuItemSafety.isBlocked(title: "보이스톡", description: nil, identifier: "callVoiceTalk:"))
        #expect(MenuItemSafety.isBlocked(title: "페이스톡", description: nil, identifier: "callFaceTalk:"))
        #expect(MenuItemSafety.isBlocked(title: "지난 대화 보기", description: nil, identifier: nil))
        #expect(MenuItemSafety.isBlocked(title: nil, description: "인증하기", identifier: nil))
    }

    @Test("Row visibility and the scroll value that centers a row")
    func listScrollMath() {
        let visible = CGRect(x: 0, y: 100, width: 300, height: 400)
        #expect(ListScrollMath.isRowVisible(rowFrame: CGRect(x: 0, y: 120, width: 300, height: 60), visibleFrame: visible))
        #expect(!ListScrollMath.isRowVisible(rowFrame: CGRect(x: 0, y: 480, width: 300, height: 60), visibleFrame: visible))
        #expect(!ListScrollMath.isRowVisible(rowFrame: CGRect(x: 0, y: 120, width: 300, height: 0), visibleFrame: visible))

        // Table 2,000 pt tall starting at the visible top; row at offset 1,000.
        let table = CGRect(x: 0, y: 100, width: 300, height: 2_000)
        let row = CGRect(x: 0, y: 1_100, width: 300, height: 60)
        let value = ListScrollMath.scrollValueCentering(rowFrame: row, tableFrame: table, visibleFrame: visible)
        #expect(abs(value - (1_000 - 200 + 30) / 1_600) < 0.0001)
        #expect(ListScrollMath.scrollValueCentering(rowFrame: CGRect(x: 0, y: 100, width: 300, height: 60), tableFrame: table, visibleFrame: visible) == 0)
        #expect(ListScrollMath.scrollValueCentering(rowFrame: CGRect(x: 0, y: 2_040, width: 300, height: 60), tableFrame: table, visibleFrame: visible) == 1)
    }

    @Test("Scrollback target grows with the number of missing messages")
    func scrollbackTarget() {
        #expect(ScrollbackMath.targetRowCount(currentRows: 50, missingMessages: 0) == 50)
        #expect(ScrollbackMath.targetRowCount(currentRows: 50, missingMessages: 20) == 50 + 25 + 8)
    }

    @Test("Query matching scores and the row choice")
    func queryMatching() {
        #expect(ChatQueryMatcher.score(query: "홍 길동", candidate: "홍길동") == ChatQueryMatcher.exactScore)
        #expect(ChatQueryMatcher.score(query: "홍길", candidate: "홍길동") == 10_500)
        #expect(ChatQueryMatcher.score(query: "길동", candidate: "홍길동") == 9_800)
        #expect(ChatQueryMatcher.score(query: "홍길동님", candidate: "홍길동") == 8_800)
        #expect(ChatQueryMatcher.score(query: "abc", candidate: "홍길동") == 0)

        let titles = [(index: 0, title: "프로젝트 A"), (index: 1, title: "프로젝트 B"), (index: 2, title: "가족")]
        #expect(ChatQueryMatcher.choose(query: "가족", titles: titles) == .match(index: 2, title: "가족", exact: true))
        #expect(ChatQueryMatcher.choose(query: "프로젝트", titles: titles) == .ambiguous(["프로젝트 A", "프로젝트 B"]))
        #expect(ChatQueryMatcher.choose(query: "프로젝트 B", titles: titles) == .match(index: 1, title: "프로젝트 B", exact: true))
        #expect(ChatQueryMatcher.choose(query: "회사", titles: titles) == .none)

        // Titles that differ only in symbols/emoji normalize to the same text: never guess.
        let lookalikes = [(index: 0, title: "가족🏠"), (index: 1, title: "가족🌸")]
        #expect(ChatQueryMatcher.choose(query: "가족", titles: lookalikes) == .ambiguous(["가족🏠", "가족🌸"]))
    }
}
