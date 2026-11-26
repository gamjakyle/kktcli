import Foundation
import Testing
@testable import KktcliCore

@Suite("Send: exact text, preview, setting, verification")
struct SendModelTests {
    @Test("The exact text: line endings unified, trailing whitespace removed, nothing added")
    func exactText() {
        #expect(SendText.exact("내일 3시 회의실 A") == "내일 3시 회의실 A")
        #expect(SendText.exact("확인 부탁드려요\n\n  ") == "확인 부탁드려요")
        #expect(SendText.exact("a\r\nb\rc") == "a\nb\nc")
        #expect(SendText.exact("  앞 공백은 그대로") == "  앞 공백은 그대로")
        #expect(SendText.lineCount("a\nb") == 2)
        #expect(SendText.lineCount("") == 0)
    }

    @Test("Preview: kind, counts, same-name warning")
    func preview() throws {
        let text = SendText.exact("내일 3시 회의실 A\n자료는 https://example.com/a")
        let preview = SendPreview(
            title: "팀채팅, 테스트방", memberCount: 5, chatID: "chat_1", listPreview: "좋아요", listTime: "오후 3:12",
            lastMessages: [SendContextMessage(author: "홍길동", time: "2026-11-26 15:12", body: "좋아요")],
            sameNameRows: 1, text: text, method: "chat_list_menu + AXValue + 전송 button"
        )
        #expect(preview.kind == .team)
        #expect(preview.lines == 2)
        #expect(preview.characters == text.count)
        #expect(preview.checks.count == 1)
        #expect(preview.checks[0].hasPrefix("1 other chat(s) have the same name"))
        #expect(preview.humanText.contains("자료는 https://example.com/a"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preview)) as? [String: Any]
        #expect(json?["same_name_rows"] as? Int == 1)
        #expect(json?["kind"] as? String == "team")
        #expect(RoomKind.of(rowTitle: "홍길동", memberCount: nil) == .oneToOne)
        #expect(RoomKind.of(rowTitle: "테스트방", memberCount: 4) == .group)
        #expect(RoomKind.of(rowTitle: "나와의 채팅, 홍길동", memberCount: nil) == .selfChat)
        #expect(RoomKind.of(rowTitle: "오픈채팅, 테스트방", memberCount: nil) == .open)
        #expect(SendPreview.checks(text: "안녕", sameNameRows: 0).isEmpty)
    }

    @Test("Only the chat window's own 전송 button is exempt; 전송 메뉴 and menu items are not")
    func sendButton() {
        #expect(SendButtonSafety.isSendButton(role: "AXButton", title: "전송", description: nil))
        #expect(SendButtonSafety.isSendButton(role: "AXButton", title: nil, description: "전송"))
        #expect(!SendButtonSafety.isSendButton(role: "AXButton", title: "전송 메뉴", description: nil))
        #expect(!SendButtonSafety.isSendButton(role: "AXButton", title: "", description: "전송 메뉴"))
        #expect(!SendButtonSafety.isSendButton(role: "AXMenuItem", title: "전송", description: nil))
        #expect(MenuItemSafety.isBlocked(title: "전송", description: nil, identifier: nil))
    }

    @Test("Sending is off by default; config get/set send on|off")
    func config() throws {
        #expect(KktcliConfig.defaults.send == false)
        #expect(KktcliConfig.decode(nil) == .defaults)
        #expect(KktcliConfig.decode(Data("not json".utf8)) == .defaults)
        #expect(KktcliConfig.decode(Data("{}".utf8)).send == false)
        #expect(KktcliConfig.decode(Data(#"{"send":true}"#.utf8)).send == true)
        let on = try KktcliConfig.defaults.setting("send", to: "ON")
        #expect(try on.value(of: "send") == "on")
        #expect(try on.setting("send", to: "off").send == false)
        #expect(throws: KktcliConfig.ValueError.invalidValue(key: "send", value: "yes")) { try KktcliConfig.defaults.setting("send", to: "yes") }
        #expect(throws: KktcliConfig.ValueError.unknownKey("dialog")) { try KktcliConfig.defaults.value(of: "dialog") }
        #expect(KktcliExitStatus.sendDisabled == 9)
    }

    @Test("Bubble verification: a new outgoing bubble with the exact text at the end")
    func bubble() {
        let text = "내일 3시\n회의실 A"
        func item(_ body: String, side: TranscriptItem.Side) -> TranscriptItem {
            TranscriptItem(kind: .message, side: side, author: side == .me ? "(me)" : "홍길동", body: body, rowIndex: 0)
        }
        let before = [item("안녕", side: .other)]
        #expect(SendVerification.bubbleSent(text: text, before: before, after: before + [item(text, side: .me)]))
        #expect(SendVerification.bubbleSent(text: text, before: before, after: before + [item("내일 3시\r회의실 A", side: .me)]))
        #expect(!SendVerification.bubbleSent(text: text, before: before, after: before))
        #expect(!SendVerification.bubbleSent(text: text, before: before, after: before + [item(text, side: .other)]))
        #expect(!SendVerification.bubbleSent(text: text, before: before, after: before + [item("내일 3시", side: .me)]))
        // An identical earlier message does not count as the new one.
        let earlier = before + [item(text, side: .me)]
        #expect(!SendVerification.bubbleSent(text: text, before: earlier, after: earlier))
        #expect(SendVerification.bubbleSent(text: text, before: earlier, after: earlier + [item(text, side: .me)]))
        // Images: a new outgoing bubble with an image at the end.
        var photo = item("[사진]", side: .me)
        photo.imageCount = 1
        #expect(SendVerification.imageSent(before: before, after: before + [photo]))
        #expect(!SendVerification.imageSent(before: before + [photo], after: before + [photo]))
        #expect(!SendVerification.imageSent(before: before, after: before + [item("[사진]", side: .me)]))
        // A long text shows only its beginning and "…".
        let long = String(repeating: "가", count: 700)
        #expect(SendVerification.bubbleSent(text: long, before: [], after: [item(String(long.prefix(500)) + "…", side: .me)]))
    }
}
