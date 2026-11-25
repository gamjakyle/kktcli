import CoreGraphics
import Foundation
import Testing
@testable import KktcliCore

@Suite("Long messages cut at 500 characters with 전체보기")
struct LongMessageTests {
    private static let visible = String(repeating: "가나다라마 ", count: 100)  // 600 characters
    /// What the bubble shows: the first 500 characters and "…" (501 scalars, as in the dumps).
    private static let cut = String(visible.prefix(500)) + "…"
    private static let textFrame = CGRect(x: 52, y: 18, width: 300, height: 320)
    /// Shaped like the 26.10.0 dumps: no label at all, 35 pt tall, starting where the text ends.
    private static let seeAll = Fixture.node("AXButton", frame: CGRect(x: 46, y: 338, width: 312, height: 35))

    private func longRow(_ text: String, control: AXNodeSnapshot? = seeAll) -> TranscriptRow {
        var children = [
            Fixture.node("AXButton", desc: "프로필", frame: CGRect(x: 8, y: 0, width: 36, height: 36)),
            Fixture.node("AXStaticText", value: "홍길동", frame: CGRect(x: 52, y: 0, width: 80, height: 16)),
            Fixture.node("AXTextArea", value: text, frame: Self.textFrame),
        ]
        if let control {
            children.append(control)
        }
        children.append(Fixture.node("AXStaticText", value: "오후 1:31", frame: CGRect(x: 362, y: 356, width: 45, height: 16)))
        return Fixture.row(children)
    }

    @Test("The cut text: ends with … and is about 500 characters long")
    func cutText() {
        #expect(Self.cut.unicodeScalars.count == 501)
        #expect(LongMessage.looksCut(Self.cut))
        #expect(LongMessage.isExactCut(Self.cut))
        #expect(!LongMessage.looksCut(String(Self.visible.prefix(498))))
        #expect(!LongMessage.looksCut("짧은 말…"))
        #expect(!LongMessage.isExactCut(String(Self.visible.prefix(400)) + "…"))
    }

    @Test("The see-all control: unlabeled button right below the text, or labelled 전체보기")
    func seeAllControl() {
        #expect(LongMessage.isSeeAllControl(Self.seeAll, textFrame: Self.textFrame))
        let labelled = Fixture.node("AXLink", title: "전체보기", frame: CGRect(x: 300, y: 500, width: 60, height: 16))
        #expect(LongMessage.isSeeAllControl(labelled, textFrame: Self.textFrame))
        // Reaction buttons, profile buttons, identified or distant buttons are not it.
        let reaction = Fixture.node("AXButton", frame: CGRect(x: 60, y: 340, width: 24, height: 24))
        #expect(!LongMessage.isSeeAllControl(reaction, textFrame: Self.textFrame))
        let profile = Fixture.node("AXButton", desc: "프로필", frame: CGRect(x: 46, y: 338, width: 312, height: 35))
        #expect(!LongMessage.isSeeAllControl(profile, textFrame: Self.textFrame))
        let identified = Fixture.node("AXButton", id: "_NS:99", frame: CGRect(x: 46, y: 338, width: 312, height: 35))
        #expect(!LongMessage.isSeeAllControl(identified, textFrame: Self.textFrame))
        let distant = Fixture.node("AXButton", frame: CGRect(x: 46, y: 400, width: 312, height: 35))
        #expect(!LongMessage.isSeeAllControl(distant, textFrame: Self.textFrame))
        #expect(!LongMessage.isSeeAllControl(Self.seeAll, textFrame: nil))
    }

    @Test("Parser marks the cut message truncated and keeps the visible text")
    func parserMarksTruncated() {
        let items = TranscriptParser.parse([longRow(Self.cut)], options: TranscriptParseOptions(transcriptFrame: Fixture.transcriptFrame))
        #expect(items.count == 1)
        #expect(items[0].truncated)
        #expect(items[0].cutText == Self.cut)
        #expect(items[0].body == Self.cut)
        #expect(items[0].author == "홍길동")
        #expect(items[0].attachmentCount == 0)
    }

    @Test("Without … or with a short text, a button below does not mean truncated")
    func parserKeepsCompleteMessages() {
        let complete = String(Self.visible.prefix(498))
        #expect(!TranscriptParser.parse([longRow(complete, control: nil)])[0].truncated)
        #expect(!TranscriptParser.parse([longRow(complete)])[0].truncated)
        #expect(!TranscriptParser.parse([longRow("사진 보냈어요…")])[0].truncated)
    }

    @Test("KakaoTalk's exact cut counts even when the control could not be read")
    func exactCutWithoutControl() {
        let items = TranscriptParser.parse([longRow(Self.cut, control: nil)])
        #expect(items[0].truncated)
    }

    @Test("Full text must be longer than the visible part and start with it")
    func fullTextMatch() {
        #expect(LongMessage.isFullText(Self.visible, of: Self.cut))
        // Line breaks and spacing may differ in the full-text view.
        #expect(LongMessage.isFullText(Self.visible.replacingOccurrences(of: " ", with: "\n"), of: Self.cut))
        #expect(!LongMessage.isFullText(String(Self.visible.prefix(300)), of: Self.cut))
        #expect(!LongMessage.isFullText(String(repeating: "다른 내용 ", count: 120), of: Self.cut))
        #expect(!LongMessage.isFullText(Self.cut, of: Self.cut))
    }

    @Test("Message JSON reports truncated and full_text_fetched")
    func json() throws {
        var item = TranscriptParser.parse([longRow(Self.cut)])[0]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReadMessageJSON(item: item))) as? [String: Any]
        #expect(object?["truncated"] as? Bool == true)
        #expect(object?["full_text_fetched"] as? Bool == false)
        item.body = Self.visible
        item.truncated = false
        item.fullTextFetched = true
        object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReadMessageJSON(item: item))) as? [String: Any]
        #expect(object?["truncated"] as? Bool == false)
        #expect(object?["full_text_fetched"] as? Bool == true)
    }
}
