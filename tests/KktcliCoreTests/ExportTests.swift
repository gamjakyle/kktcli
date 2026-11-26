import Foundation
import Testing
@testable import KktcliCore

@Suite("export: readable output of the local store")
struct ExportTests {
    private let messages = [
        ExportMessage(chatID: "chat_b", chat: "테스트방", date: "2026-11-26", time: "15:12", author: "홍길동", body: "내일 3시 회의실 A\n자료는 https://example.com/a"),
        ExportMessage(chatID: "chat_b", chat: "테스트방", date: "2026-11-25", time: "09:00", author: "(me)", body: "[AXImage]", imageCount: 1),
        ExportMessage(chatID: "chat_b", chat: "테스트방", date: "2026-11-25", time: "09:01", author: "김철수", body: "회의자료_v2.pdf 3.2MB", attachmentCount: 1),
        ExportMessage(chatID: "chat_a", chat: "가족", date: "2026-11-26", time: "08:00", author: nil, body: "홍길동님이 들어왔습니다.", kind: "system"),
    ]

    @Test("Markdown: room, day headings with weekday, time name: body; attachments; links kept")
    func markdown() {
        let selected = ExportFormatter.select(messages, filter: ExportFilter(chatIDs: ["chat_b"]))
        let text = ExportFormatter.markdown(selected)
        #expect(text == """
        # 테스트방

        ## 2026-11-25 (수)

        - 09:00 나: [사진]
        - 09:01 김철수: [파일: 회의자료_v2.pdf]

        ## 2026-11-26 (목)

        - 15:12 홍길동: 내일 3시 회의실 A
          자료는 https://example.com/a

        """)
    }

    @Test("Bodies: system lines, several photos, files without a name, cut long messages")
    func bodies() {
        #expect(ExportFormatter.renderBody(messages[3]) == "(알림) 홍길동님이 들어왔습니다.")
        #expect(ExportFormatter.renderBody(ExportMessage(chatID: "c", chat: "c", date: nil, time: nil, author: nil, body: "[AXImage,AXImage]", imageCount: 2)) == "[사진 2장]")
        #expect(ExportFormatter.renderBody(ExportMessage(chatID: "c", chat: "c", date: nil, time: nil, author: nil, body: "[첨부]", attachmentCount: 1)) == "[파일]")
        #expect(ExportFormatter.renderBody(ExportMessage(chatID: "c", chat: "c", date: nil, time: nil, author: nil, body: "가나다…", truncated: true)) == "가나다… (앞부분만 저장됨)")
        #expect(ExportFormatter.dayHeading("2026-11-29") == "2026-11-29 (일)")
        #expect(ExportFormatter.dayHeading(nil) == "날짜 없음")
    }

    @Test("Filters: chat_ids keep their order, since/until inclusive, author, grep with or without spaces")
    func filters() {
        let both = ExportFormatter.select(messages, filter: ExportFilter(chatIDs: ["chat_b", "chat_a"]))
        #expect(both.map(\.chatID) == ["chat_b", "chat_b", "chat_b", "chat_a"])
        #expect(ExportFormatter.select(messages, filter: ExportFilter(since: "2026-11-26")).count == 2)
        #expect(ExportFormatter.select(messages, filter: ExportFilter(until: "2026-11-25")).count == 2)
        #expect(ExportFormatter.select(messages, filter: ExportFilter(since: "2026-11-25T09:01", until: "2026-11-25T09:01")).count == 1)
        #expect(ExportFormatter.select(messages, filter: ExportFilter(author: "홍길")).count == 1)
        #expect(ExportFormatter.select(messages, filter: ExportFilter(grep: "회의실A")).count == 1)
        #expect(ExportFormatter.select(messages, filter: ExportFilter(grep: "없는말")).isEmpty)
    }

    @Test("CSV: BOM, header, CRLF and quoting; JSON document")
    func csvAndJSON() throws {
        let csv = ExportFormatter.csv([messages[0]])
        #expect(csv.hasPrefix("\u{FEFF}chat,chat_id,date,time,author,body,kind\r\n"))
        #expect(csv.contains("\"내일 3시 회의실 A\n자료는 https://example.com/a\""))
        #expect(csv.hasSuffix("message\r\n"))
        #expect(ExportFormatter.csv([ExportMessage(chatID: "c", chat: "a,b", date: nil, time: nil, author: "x\"y", body: "z")]).contains("\"a,b\",c,,,\"x\"\"y\",z,message"))
        let json = try ExportFormatter.json([messages[1]])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(object?["count"] as? Int == 1)
        #expect(object?["ok"] as? Bool == true)
    }
}
