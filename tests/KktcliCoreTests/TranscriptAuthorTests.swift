import CoreGraphics
import Foundation
import Testing
@testable import KktcliCore

/// Regression tests for the 2026-11-27 misattributions: other people's unlabeled bubbles read
/// as "(me)" after the window moved between reads, and a shared card's title read as a sender.
/// "(me)" must only ever come from positive, uncontradicted evidence.
@Suite("Authors and sides: (me) only on positive evidence")
struct TranscriptAuthorTests {
    private func messages(_ rows: [TranscriptRow]) -> [TranscriptItem] {
        TranscriptParser.parse(rows).filter { $0.kind == .message }
    }

    @Test("Another person's unlabeled bubbles stay theirs, also when the window moved between rows")
    func movedWindow() {
        // The reported shape: a header row, two rows with neither header nor time (one with
        // reaction buttons), then the row with the time. Rows 3 and 4 were read after the
        // window had moved left and right.
        let items = messages([
            LiveRow.otherFirst(x: 1521, "홍길동", "첫째", bodyWidth: 48),
            LiveRow.otherNext(x: 1521, "둘째", bodyWidth: 179, reactions: true),
            LiveRow.otherNext(x: 1300, "셋째", bodyWidth: 111),
            LiveRow.otherNext(x: 1650, "넷째", bodyWidth: 138, meta: "오후 10:35", reactions: true),
        ])
        #expect(items.map(\.side) == [.other, .other, .other, .other])
        #expect(items.map(\.author) == ["홍길동", "홍길동", "홍길동", "홍길동"])
        #expect(items.map { $0.time?.hhmm } == ["22:35", "22:35", "22:35", "22:35"])
        #expect(!items.contains { $0.author == TranscriptItem.meAuthor })
    }

    @Test("My bubbles are mine wherever the window is, with or without a meta label")
    func mineAnywhere() {
        let items = messages([
            LiveRow.mine(x: 1521, "하나", bodyWidth: 108),
            LiveRow.mine(x: 900, "둘", bodyWidth: 90),
            LiveRow.mine(x: 1521, "셋", bodyWidth: 67, meta: "오후 8:22"),
        ])
        #expect(items.map(\.side) == [.me, .me, .me])
        #expect(items.map(\.author) == Array(repeating: TranscriptItem.meAuthor, count: 3))
        #expect(items.map(\.timeSource) == [.inferred, .inferred, .label])
    }

    @Test("A shared card's title is content, never a sender: my card stays mine")
    func cardTitleIsNotASender() {
        let items = messages([
            LiveRow.otherFirst(x: 0, "홍길동", "노래 추천해 줘", meta: "오후 8:16"),
            LiveRow.myCard(x: 0, title: "노래 제목", caption: "가수 이름"),
            LiveRow.mine(x: 0, "들어 봐", meta: "오후 8:17"),
        ])
        #expect(items[1].side == .me)
        #expect(items[1].author == TranscriptItem.meAuthor)
        #expect(items[1].explicitAuthor == nil)
        #expect(!items[1].hasSenderHeader)
        #expect(items[1].body == "가수 이름")
        #expect(items[2].author == TranscriptItem.meAuthor)
    }

    @Test("Another person's card: the header names the sender, not the card title")
    func otherPersonsCard() {
        let card = LiveRow.row(x: 0, height: 420, [
            Fixture.node("AXButton", desc: "프로필", frame: CGRect(x: 10, y: 10, width: 36, height: 36)),
            Fixture.node("AXStaticText", value: "홍길동", frame: CGRect(x: 55, y: 9, width: 36, height: 18)),
            Fixture.node("AXButton", title: "버튼", frame: CGRect(x: 60, y: 30, width: 212, height: 380)),
            Fixture.node("AXImage", frame: CGRect(x: 60, y: 70, width: 212, height: 275)),
            Fixture.node("AXStaticText", value: "노래 제목", frame: CGRect(x: 91, y: 42, width: 171, height: 18)),
            Fixture.node("AXTextArea", value: "가수 이름", frame: CGRect(x: 71, y: 354, width: 190, height: 13)),
            Fixture.node("AXStaticText", value: "오후 8:18", frame: CGRect(x: 281, y: 395, width: 48, height: 16)),
        ])
        let items = messages([card])
        #expect(items[0].side == .other)
        #expect(items[0].hasSenderHeader)
        #expect(items[0].explicitAuthor == "홍길동")
        #expect(items[0].author == "홍길동")
    }

    @Test("A profile button without its description still starts a group; reaction buttons never do")
    func profileWithoutDescription() {
        let items = messages([
            LiveRow.otherFirst(x: 0, "김철수", "안녕", profileDesc: nil),
            LiveRow.otherNext(x: 0, "반가워", meta: "오후 1:00", reactions: true),
        ])
        #expect(items.map(\.author) == ["김철수", "김철수"])
        #expect(items[0].hasSenderHeader)
        #expect(!items[1].hasSenderHeader)

        let reference = CGRect(x: 0, y: 0, width: 380, height: 65)
        let reaction = Fixture.node("AXButton", frame: CGRect(x: 95, y: 39, width: 24, height: 24))
        #expect(!TranscriptParser.isProfileButton(reaction, reference: reference))
        let photo = Fixture.node("AXButton", frame: CGRect(x: 54, y: 10, width: 120, height: 120))
        #expect(!TranscriptParser.isProfileButton(photo, reference: reference))
    }

    @Test("A group that mixes sides keeps no (me): the misread row becomes unknown")
    func mixedGroup() {
        // Without a time label 홍길동's first row is not the last of the group, so the next row is
        // theirs too; a right-aligned row there was misread and must not stay "(me)".
        let items = messages([
            LiveRow.otherFirst(x: 0, "홍길동", "첫째"),
            LiveRow.mine(x: 0, "둘째"),
            LiveRow.otherNext(x: 0, "셋째", meta: "오후 3:00"),
        ])
        #expect(items.map(\.side) == [.other, .unknown, .other])
        #expect(items.map(\.author) == ["홍길동", nil, "홍길동"])
    }

    @Test("Another person's group without a header right below my group: neither is attributed")
    func orphanBelowMine() {
        let items = messages([
            LiveRow.mine(x: 0, "내 말", meta: "오후 2:00"),
            LiveRow.otherNext(x: 0, "누구 말", meta: "오후 2:01"),
        ])
        #expect(items.map(\.side) == [.unknown, .unknown])
        #expect(items.map(\.author) == [nil, nil])
    }

    @Test("A group without a header continues only another person's group directly above it")
    func headerlessGroups() {
        let parsed = TranscriptParser.parse([
            Fixture.system("홍길동님이 들어왔습니다."),
            LiveRow.otherNext(x: 0, "시스템 줄 다음", meta: "오후 4:00"),
            LiveRow.otherFirst(x: 0, "김철수", "하나", meta: "오후 4:01"),
            LiveRow.otherNext(x: 0, "다음 분에 이어서", meta: "오후 4:02"),
            Fixture.dateSeparator("2026년 11월 24일 월요일"),
            LiveRow.otherNext(x: 0, "날짜 다음", meta: "오전 9:00"),
        ])
        let items = parsed.filter { $0.kind == .message }
        #expect(items.map(\.side) == [.unknown, .other, .other, .unknown])
        #expect(items.map(\.author) == [nil, "김철수", "김철수", nil])
    }

    @Test("The first group of a slice keeps its side; its author waits for the header")
    func sliceStart() {
        let items = messages([
            LiveRow.otherNext(x: 0, "앞부분이 잘린 줄"),
            LiveRow.otherNext(x: 0, "이어지는 줄", meta: "오후 5:00"),
            LiveRow.otherFirst(x: 0, "홍길동", "새 그룹", meta: "오후 5:01"),
        ])
        #expect(items.map(\.side) == [.other, .other, .other])
        #expect(items.map(\.author) == [nil, nil, "홍길동"])
        #expect(TranscriptSelection.missingContext(items).author)
    }

    @Test("Geometry and meta label that disagree leave the side unknown")
    func conflictingEvidence() {
        let row = LiveRow.row(x: 0, [
            Fixture.node("AXStaticText", value: "오후 6:00", frame: CGRect(x: 5, y: 19, width: 48, height: 16)),
            Fixture.node("AXTextArea", value: "모순", frame: CGRect(x: 60, y: 13, width: 120, height: 16)),
        ])
        let items = messages([row])
        #expect(items[0].side == .unknown)
        #expect(items[0].author == nil)
    }

    @Test("Without a row frame only the meta label can tell the side; with neither it is unknown")
    func noRowFrame() {
        func frameless(_ children: [AXNodeSnapshot]) -> TranscriptRow {
            TranscriptRow(nodes: [Fixture.node("AXRow", depth: 0), Fixture.node("AXCell", depth: 1)] + children)
        }
        let bare = messages([frameless([
            Fixture.node("AXTextArea", value: "프레임 없음", frame: CGRect(x: 272, y: 13, width: 90, height: 16)),
        ])])
        #expect(bare[0].side == .unknown)
        #expect(bare[0].author == nil)

        let labeled = messages([frameless([
            Fixture.node("AXStaticText", value: "오후 7:00", frame: CGRect(x: 214, y: 19, width: 48, height: 16)),
            Fixture.node("AXTextArea", value: "메타 있음", frame: CGRect(x: 272, y: 13, width: 90, height: 16)),
        ])])
        #expect(labeled[0].side == .me)
        #expect(labeled[0].author == TranscriptItem.meAuthor)
    }

    @Test("Row geometry: thresholds from the live dump")
    func geometryThresholds() {
        let row = CGRect(x: 1521, y: 0, width: 380, height: 36)
        // Other people: 60–65 pt from the left, 80 pt or more from the right.
        #expect(TranscriptParser.geometry(of: CGRect(x: 1581, y: 0, width: 235, height: 16), in: row) == .left)
        #expect(TranscriptParser.geometry(of: CGRect(x: 1586, y: 0, width: 33, height: 16), in: row) == .left)
        // Mine: 18–23 pt from the right, 105 pt or more from the left.
        #expect(TranscriptParser.geometry(of: CGRect(x: 1626, y: 0, width: 252, height: 16), in: row) == .right)
        #expect(TranscriptParser.geometry(of: CGRect(x: 1816, y: 0, width: 67, height: 16), in: row) == .right)
        // Banners span the row; content outside the row is an inconsistent snapshot.
        #expect(TranscriptParser.geometry(of: CGRect(x: 1525, y: 0, width: 372, height: 16), in: row) == .fullWidth)
        #expect(TranscriptParser.geometry(of: CGRect(x: 1300, y: 0, width: 120, height: 16), in: row) == .unavailable)
        #expect(TranscriptParser.geometry(of: CGRect(x: 1581, y: 0, width: 120, height: 16), in: nil) == .unavailable)
    }
}
