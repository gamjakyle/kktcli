import CoreGraphics
import Foundation
import Testing
@testable import KmsgCore

@Suite("Transcript parsing: dates, sides, authors, burst times")
struct TranscriptParserTests {
    private let options = TranscriptParseOptions(transcriptFrame: Fixture.transcriptFrame)

    private func messages(_ rows: [TranscriptRow], initialDate: String? = nil) -> [TranscriptItem] {
        let parsed = TranscriptParser.parse(
            rows,
            options: TranscriptParseOptions(transcriptFrame: Fixture.transcriptFrame, initialDate: initialDate)
        )
        return parsed.filter { $0.kind == .message }
    }

    @Test("Dates come from the nearest preceding separator; sides from profile/meta geometry")
    func datesAndSides() {
        let items = messages([
            Fixture.otherFirst("홍길동", "잘 자요", meta: "오후 11:58"),
            Fixture.dateSeparator("2026년 11월 23일 일요일"),
            Fixture.mine("좋은 아침", meta: "오전 8:01"),
        ])
        #expect(items.count == 2)
        #expect(items[0].side == .other)
        #expect(items[0].author == "홍길동")
        #expect(items[0].date == nil)
        #expect(items[0].time?.hhmm == "23:58")
        #expect(items[0].timeSource == .label)
        #expect(items[1].side == .me)
        #expect(items[1].author == TranscriptItem.meAuthor)
        #expect(items[1].date == "2026-11-23")
        #expect(items[1].time?.hhmm == "08:01")
    }

    @Test("initialDate applies until the first separator in the slice")
    func initialDate() {
        let items = messages([
            Fixture.mine("첫 줄", meta: "오후 1:00"),
            Fixture.dateSeparator("2026년 11월 24일 월요일"),
            Fixture.mine("둘째 줄", meta: "오전 9:00"),
        ], initialDate: "2026-11-23")
        #expect(items.map(\.date) == ["2026-11-23", "2026-11-24"])
    }

    @Test("Unlabeled messages of a run take the next label's time")
    func burstInference() {
        let items = messages([
            Fixture.dateSeparator("2026년 11월 23일 일요일"),
            Fixture.otherFirst("홍길동", "하나"),
            Fixture.otherNext("둘"),
            Fixture.otherNext("셋", meta: "오후 5:10"),
        ])
        #expect(items.map(\.author) == ["홍길동", "홍길동", "홍길동"])
        #expect(items.map { $0.time?.hhmm } == ["17:10", "17:10", "17:10"])
        #expect(items.map(\.timeSource) == [.inferred, .inferred, .label])
        #expect(items[0].time?.raw == "오후 5:10")
    }

    @Test("An unread-only meta still leaves the time to be inferred")
    func unreadOnlyMeta() {
        let items = messages([
            Fixture.mine("먼저", meta: "안읽음 1"),
            Fixture.mine("나중", meta: "오후 5:12, 안읽음 1"),
        ])
        #expect(items[0].side == .me)
        #expect(items[0].unreadCount == 1)
        #expect(items[0].time?.hhmm == "17:12")
        #expect(items[0].timeSource == .inferred)
        #expect(items[1].timeSource == .label)
    }

    @Test("Inference stops at an author change")
    func burstStopsAtAuthorChange() {
        let items = messages([
            Fixture.otherFirst("홍길동", "답장 주세요"),
            Fixture.otherFirst("김철수", "네", meta: "오후 5:10"),
        ])
        #expect(items[0].time == nil)
        #expect(items[0].timeSource == nil)
        #expect(items[1].time?.hhmm == "17:10")
    }

    @Test("Inference stops at a date change")
    func burstStopsAtDateChange() {
        let items = messages([
            Fixture.dateSeparator("2026년 11월 22일 토요일"),
            Fixture.mine("어제 보낸 것"),
            Fixture.dateSeparator("2026년 11월 23일 일요일"),
            Fixture.mine("오늘 보낸 것", meta: "오전 7:30"),
        ])
        #expect(items[0].time == nil)
        #expect(items[1].time?.hhmm == "07:30")
    }

    @Test("Inference stops at a system message")
    func burstStopsAtSystemMessage() {
        let items = messages([
            Fixture.mine("공지 전"),
            Fixture.system("홍길동님이 들어왔습니다."),
            Fixture.mine("공지 후", meta: "오후 2:00"),
        ])
        #expect(items[0].time == nil)
        #expect(items[1].timeSource == .label)
    }

    @Test("Continuation rows inherit the previous named author; unnamed leading rows stay unknown")
    func authorCarryForward() {
        let leading = messages([
            Fixture.otherNext("이름이 안 보이는 줄", meta: "오후 1:00"),
            Fixture.otherFirst("홍길동", "이름 있는 줄", meta: "오후 1:01"),
            Fixture.otherNext("이어지는 줄", meta: "오후 1:02"),
        ])
        #expect(leading.map(\.author) == [nil, "홍길동", "홍길동"])
        #expect(leading[0].side == .other)
        let missing = TranscriptSelection.missingContext(leading)
        #expect(missing.author)
        #expect(missing.date)
    }

    @Test("System lines, history controls and the auth notice")
    func systemAndControlRows() {
        let parsed = TranscriptParser.parse([
            Fixture.row([Fixture.node("AXButton", title: "지난 대화 보기")]),
            Fixture.row([Fixture.node("AXStaticText", value: "대화 내용을 불러오기 위해 인증이 필요합니다. 인증하기")]),
            Fixture.system("홍길동님이 들어왔습니다."),
            Fixture.mine("안녕하세요", meta: "오후 3:00"),
        ], options: options)
        #expect(parsed.map(\.kind) == [.control, .control, .system, .message])
        #expect(parsed[0].body == TranscriptParser.olderHistoryButtonTitle)
        #expect(parsed[1].body == TranscriptParser.authenticationControlBody)
        #expect(parsed[2].author == nil)
        #expect(TranscriptSelection.reachedHistoryTop(parsed))

        let withoutSystem = TranscriptSelection.lastItems(parsed, limit: 10, includeSystem: false)
        #expect(withoutSystem.map(\.body) == ["안녕하세요"])
        let withSystem = TranscriptSelection.lastItems(parsed, limit: 10, includeSystem: true)
        #expect(withSystem.map(\.kind) == [.system, .message])
    }

    @Test("A full-width channel banner is never attributed to (me)")
    func fullWidthBanner() {
        let banner = Fixture.row([
            Fixture.node("AXGroup", desc: "채널 소식", frame: CGRect(x: 4, y: 0, width: 372, height: 120)),
        ])
        let parsed = TranscriptParser.parse([banner], options: options)
        #expect(parsed.count == 1)
        #expect(parsed[0].side == .unknown)
        #expect(parsed[0].author == nil)
        #expect(parsed[0].body == "[채널 소식]")
        #expect(ReadMessageJSON(item: parsed[0]).author == nil)
    }

    @Test("Right-aligned content without a meta label is mine")
    func rightAlignedWithoutMeta() {
        let items = messages([Fixture.mine("메타 없는 내 메시지")])
        #expect(items[0].side == .me)
        #expect(items[0].author == TranscriptItem.meAuthor)
    }

    @Test("수정됨 marks an edit and is not mistaken for a sender name")
    func editedMarker() {
        let row = Fixture.row([
            Fixture.node("AXStaticText", value: "수정됨", frame: CGRect(x: 120, y: 16, width: 30, height: 14)),
            Fixture.node("AXStaticText", value: "오후 4:00", frame: CGRect(x: 152, y: 16, width: 60, height: 14)),
            Fixture.node("AXTextArea", value: "고친 메시지", frame: CGRect(x: 226, y: 0, width: 140, height: 30)),
        ])
        let items = messages([row])
        #expect(items[0].edited)
        #expect(items[0].side == .me)
        #expect(items[0].explicitAuthor == nil)
    }

    @Test("Photo-only messages get a placeholder body and an image count")
    func photoMessage() {
        let row = Fixture.row([
            Fixture.node("AXStaticText", value: "오후 4:01", frame: CGRect(x: 150, y: 90, width: 60, height: 14)),
            Fixture.node("AXImage", desc: "사진", frame: CGRect(x: 216, y: 0, width: 150, height: 100)),
        ])
        let items = messages([row])
        #expect(items[0].body == "[사진]")
        #expect(items[0].imageCount == 1)
        #expect(items[0].contentKinds == ["media:사진"])
    }

    @Test("A shortened URL is replaced by the AXLink target")
    func truncatedLink() {
        let row = Fixture.row([
            Fixture.node("AXTextArea", value: "https://example.com/very/lo...", frame: CGRect(x: 226, y: 0, width: 140, height: 30)),
            Fixture.node("AXLink", title: "https://example.com/very/long/path", depth: 3),
        ])
        let items = messages([row])
        #expect(items[0].body == "https://example.com/very/long/path")
        #expect(items[0].linkCount == 1)
    }

    @Test("Text around a URL is kept; only a shortened URL token is expanded")
    func linkExpansionKeepsText() {
        let plain = Fixture.row([
            Fixture.node("AXTextArea", value: "https://youtu.be/x 대박...", frame: CGRect(x: 226, y: 0, width: 140, height: 30)),
            Fixture.node("AXLink", title: "https://youtu.be/x", depth: 3),
        ])
        #expect(messages([plain])[0].body == "https://youtu.be/x 대박...")

        let mixed = Fixture.row([
            Fixture.node("AXTextArea", value: "이거 보세요 https://example.com/a/lo... 재밌어요", frame: CGRect(x: 226, y: 0, width: 140, height: 30)),
            Fixture.node("AXLink", title: "https://example.com/a/long", depth: 3),
        ])
        #expect(messages([mixed])[0].body == "이거 보세요 https://example.com/a/long 재밌어요")

        // A link that only appears in a quoted reply/preview card is not used for expansion.
        let quoted = Fixture.row([
            Fixture.node("AXGroup", desc: "답장", frame: CGRect(x: 226, y: 0, width: 140, height: 20)),
            Fixture.node("AXLink", title: "https://example.com/other", depth: 3),
            Fixture.node("AXTextArea", value: "https://example.com/o...", frame: CGRect(x: 226, y: 22, width: 140, height: 30)),
        ])
        #expect(messages([quoted])[0].body == "https://example.com/o...")
    }

    @Test("A full-width row is unknown even when it carries a time label")
    func fullWidthWithMeta() {
        let banner = Fixture.row([
            Fixture.node("AXGroup", desc: "채널 소식", frame: CGRect(x: 4, y: 0, width: 372, height: 120)),
            Fixture.node("AXStaticText", value: "오후 3:00", frame: CGRect(x: 300, y: 122, width: 60, height: 14)),
        ])
        let items = TranscriptParser.parse([Fixture.otherFirst("홍길동", "안녕", meta: "오후 2:59"), banner], options: options)
        #expect(items[1].side == .unknown)
        #expect(items[1].author == nil)
    }

    @Test("lastItems keeps the newest messages in chronological order")
    func selection() {
        let parsed = TranscriptParser.parse([
            Fixture.mine("1", meta: "오후 1:00"),
            Fixture.mine("2", meta: "오후 1:01"),
            Fixture.mine("3", meta: "오후 1:02"),
        ], options: options)
        #expect(TranscriptSelection.lastItems(parsed, limit: 2, includeSystem: false).map(\.body) == ["2", "3"])
        #expect(TranscriptSelection.lastItems(parsed, limit: 0, includeSystem: false).isEmpty)
    }

    @Test("Message JSON keeps legacy keys and writes explicit nulls")
    func messageJSON() throws {
        let items = messages([Fixture.mine("안녕", meta: "오후 5:10, 안읽음 1")])
        let data = try JSONEncoder().encode(ReadMessageJSON(item: items[0]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["author"] as? String == "(me)")
        #expect(object["time_raw"] as? String == "오후 5:10")
        #expect(object["time"] as? String == "17:10")
        #expect(object["time_source"] as? String == "label")
        #expect(object["unread_count"] as? Int == 1)
        #expect(object["date"] is NSNull)
        for key in ["body", "has_image", "image_count", "link_count", "has_attachment", "attachment_count", "side", "kind", "edited"] {
            #expect(object[key] != nil, "missing key \(key)")
        }
    }

    @Test("Error JSON shape")
    func errorJSON() throws {
        let payload = ReadErrorJSON(code: "UNREAD_REFUSED", message: "m", hint: nil, chat: "가족", chatID: nil)
        let data = try JSONEncoder().encode(payload)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "UNREAD_REFUSED")
        #expect(error["hint"] is NSNull)
        #expect(object["chat_id"] is NSNull)
    }
}
