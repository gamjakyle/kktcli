import Testing
@testable import KmsgCore

@Suite("Chat-list rows: title extraction and unread badge detection")
struct ChatRowAnalyzerTests {
    private func rowNodes(_ children: [AXNodeSnapshot]) -> [AXNodeSnapshot] {
        [Fixture.node("AXRow", depth: 0), Fixture.node("AXCell", depth: 1)] + children
    }

    private func text(_ id: String, _ value: String) -> AXNodeSnapshot {
        Fixture.node("AXStaticText", id: id, value: value)
    }

    @Test("Title comes from _NS:40 even when the unread badge precedes it")
    func titleIgnoresBadge() {
        let summary = ChatRowAnalyzer.summarize(rowNodes([
            Fixture.node("AXButton", id: "_NS:11", desc: "프로필"),
            text("_NS:138", "안읽음 3"),
            text("_NS:40", "프로젝트방"),
            text("Count Label", "9명"),
            text("_NS:69", "오후 3:10"),
            text("_NS:91", "회의 시작합니다"),
        ]))
        #expect(summary.title == "프로젝트방")
        #expect(summary.titleSource == .titleLabel)
        #expect(summary.unread == .count(3))
        #expect(summary.unread.isUnread)
        #expect(summary.memberCount == 9)
        #expect(summary.timeLabel == "오후 3:10")
        #expect(summary.preview == "회의 시작합니다")
    }

    @Test("A row without a badge is read; the member count is not an unread count")
    func readRow() {
        let summary = ChatRowAnalyzer.summarize(rowNodes([
            text("_NS:40", "홍길동"),
            text("Count Label", "2명"),
            text("_NS:69", "어제"),
            text("_NS:87", "내일 봬요"),
        ]))
        #expect(summary.title == "홍길동")
        #expect(summary.unread == .none)
        #expect(!summary.unread.isUnread)
        #expect(summary.memberCount == 2)
        #expect(summary.preview == "내일 봬요")
    }

    @Test("_NS:138 without readable text still counts as unread")
    func emptyBadge() {
        let summary = ChatRowAnalyzer.summarize(rowNodes([
            text("_NS:40", "가족"),
            text("_NS:138", ""),
        ]))
        #expect(summary.unread == .unknown("_NS:138"))
        #expect(summary.unread.isUnread)
    }

    @Test("_NS:138 with any role counts as unread")
    func badgeWithUnexpectedRole() {
        let summary = ChatRowAnalyzer.summarize(rowNodes([
            text("_NS:40", "가족"),
            Fixture.node("AXGroup", id: "_NS:138"),
        ]))
        #expect(summary.unread.isUnread)
    }

    @Test("An unknown count-like text is treated as a possible unread badge")
    func unknownCountLikeText() {
        let summary = ChatRowAnalyzer.summarize(rowNodes([
            text("_NS:40", "동호회"),
            text("_NS:200", "5"),
        ]))
        #expect(summary.unread == .unknown("5"))
        #expect(summary.unknownTexts == ["_NS:200=5"])
    }

    @Test("Any text starting with 안읽음 counts as unread, whatever its identifier")
    func unreadPrefixAnywhere() {
        let summary = ChatRowAnalyzer.summarize(rowNodes([
            text("_NS:40", "동호회"),
            text("_NS:91", "안읽음 표시 테스트"),
        ]))
        #expect(summary.unread.isUnread)
        #expect(summary.preview == nil)
    }

    @Test("Pinned rows: the time label suffix is stripped")
    func pinnedRow() {
        let summary = ChatRowAnalyzer.summarize(rowNodes([
            text("_NS:40", "공지"),
            text("_NS:69", "어제, 핀 설정됨"),
        ]))
        #expect(summary.isPinned)
        #expect(summary.timeLabel == "어제")
        #expect(summary.unread == .none)
    }

    @Test("Without _NS:40 the first plausible text is used, never a badge, time, or count")
    func fallbackTitle() {
        let summary = ChatRowAnalyzer.summarize(rowNodes([
            text("", "안읽음 2"),
            text("", "오후 3:10"),
            text("", "4명"),
            text("", "가족"),
            text("", "저녁 뭐 먹어?"),
        ]))
        #expect(summary.title == "가족")
        #expect(summary.titleSource == .fallback)
        #expect(summary.preview == "저녁 뭐 먹어?")
        #expect(summary.unread == .count(2))
    }

    @Test("A row with no usable text has no title")
    func missingTitle() {
        let summary = ChatRowAnalyzer.summarize(rowNodes([Fixture.node("AXButton", id: "_NS:11", desc: "프로필")]))
        #expect(summary.title == nil)
        #expect(summary.titleSource == .missing)
    }
}
