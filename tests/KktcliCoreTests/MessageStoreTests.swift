import Foundation
import Testing
@testable import KktcliCore

@Suite("Local message store: records, de-duplication, search and JSON lines")
struct MessageStoreTests {
    private static let savedAt = "2026-11-20T05:10:00.000Z"

    private static func message(
        _ body: String,
        author: String? = "홍길동",
        date: String? = "2026-11-20",
        time: (hour: Int, minute: Int)? = (14, 5),
        side: TranscriptItem.Side = .other,
        edited: Bool = false,
        truncated: Bool = false
    ) -> TranscriptItem {
        TranscriptItem(
            kind: .message,
            side: side,
            author: author,
            body: body,
            date: date,
            time: time.map { ClockTime(raw: label(hour: $0.hour, minute: $0.minute), hour: $0.hour, minute: $0.minute) },
            edited: edited,
            rowIndex: 0,
            truncated: truncated
        )
    }

    /// The label KakaoTalk prints, e.g. "오후 2:05".
    private static func label(hour: Int, minute: Int) -> String {
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(hour < 12 ? "오전" : "오후") \(hour12):\(String(format: "%02d", minute))"
    }

    private static func records(_ items: [TranscriptItem]) -> [StoredMessage] {
        MessageStore.records(from: items, chatID: "chat_test", chat: "테스트방", savedAt: savedAt)
    }

    private static func stored(
        _ body: String,
        author: String? = "홍길동",
        date: String? = "2026-11-20",
        time: String? = "14:05",
        chatID: String = "chat_test",
        kind: String = "message"
    ) -> StoredMessage {
        StoredMessage(
            chatID: chatID,
            chat: "테스트방",
            date: date,
            time: time,
            timeRaw: nil,
            author: author,
            side: kind == "system" ? "system" : "other",
            kind: kind,
            body: body,
            occurrence: 0,
            edited: false,
            truncated: false,
            savedAt: savedAt
        )
    }

    private static func bodies(_ records: [StoredMessage], _ query: MessageStore.SearchQuery) -> [String] {
        MessageStore.search(records, query: query).map(\.body)
    }

    // MARK: Records of one read

    @Test("occurrence numbers identical messages of one read in order; control rows are skipped")
    func occurrenceNumbering() {
        let items = [
            Self.message("ㅋㅋ"),
            Self.message("안녕하세요"),
            Self.message("ㅋㅋ"),
            TranscriptItem(kind: .control, side: .system, body: "지난 대화 보기", date: "2026-11-20", rowIndex: 3),
            Self.message("ㅋㅋ"),
            Self.message("ㅋㅋ", author: "김철수"),
            Self.message("ㅋㅋ", time: (14, 6)),
            Self.message("ㅋㅋ", date: "2026-11-21"),
            TranscriptItem(kind: .system, side: .system, body: "김철수님이 들어왔습니다.", date: "2026-11-21", rowIndex: 8),
        ]
        let records = Self.records(items)
        #expect(records.count == 8)
        #expect(!records.contains { $0.kind == "control" })
        // Same date, minute, author and body: 0, 1, 2. Another author, minute or day: its own group.
        #expect(records.map(\.occurrence) == [0, 0, 1, 2, 0, 0, 0, 0])
        #expect(records[0].time == "14:05")
        #expect(records[0].timeRaw == "오후 2:05")
        #expect(records[0].chatID == "chat_test")
        #expect(records[0].chat == "테스트방")
        #expect(records[0].savedAt == Self.savedAt)
        #expect(records[0].side == "other")
        #expect(records[7].kind == "system")
        #expect(records[7].side == "system")
        #expect(records[7].author == nil)
        #expect(records[7].time == nil)
    }

    @Test("edited and truncated are carried into the record")
    func flags() {
        let records = Self.records([Self.message("안녕하세요", edited: true), Self.message("안녕", truncated: true)])
        #expect(records[0].edited && !records[0].truncated)
        #expect(!records[1].edited && records[1].truncated)
    }

    // MARK: Merge

    @Test("Legitimate repeats: 3 shown while 2 are stored adds 1; a later window showing 1 adds none")
    func mergeKeepsLegitimateRepeats() {
        let stored = Self.records([Self.message("ㅋㅋ"), Self.message("ㅋㅋ")])
        let read = Self.records([Self.message("ㅋㅋ"), Self.message("ㅋㅋ"), Self.message("ㅋㅋ")])

        let added = MessageStore.merge(existing: stored, incoming: read)
        #expect(added.count == 1)
        #expect(added.first?.occurrence == 2)

        let store = stored + added
        // Reading the same window again adds nothing.
        #expect(MessageStore.merge(existing: store, incoming: read).isEmpty)
        // A window that shows only the last of them (occurrence 0 in that read) plus a new message.
        let later = Self.records([Self.message("ㅋㅋ"), Self.message("안녕하세요", time: (14, 7))])
        #expect(MessageStore.merge(existing: store, incoming: later).map(\.body) == ["안녕하세요"])
    }

    @Test("Merge keeps incoming order and drops repeats inside the incoming records")
    func mergeOrder() {
        let read = Self.records([
            Self.message("첫째", time: (9, 0)),
            Self.message("둘째", time: (9, 1)),
            Self.message("셋째", time: (9, 2)),
        ])
        let added = MessageStore.merge(existing: [read[1]], incoming: read + read)
        #expect(added.map(\.body) == ["첫째", "셋째"])
        #expect(MessageStore.merge(existing: [], incoming: read) == read)
    }

    @Test("Messages without time or author group on their nulls")
    func missingTimeAndAuthor() {
        let records = Self.records([
            Self.message("공지", author: nil, date: nil, time: nil, side: .unknown),
            Self.message("공지", author: nil, date: nil, time: nil, side: .unknown),
            Self.message("공지", author: nil, time: nil, side: .unknown),
            Self.message("공지", time: nil),
        ])
        #expect(records.map(\.occurrence) == [0, 1, 0, 0])
        #expect(records.prefix(3).allSatisfy { $0.author == nil && $0.time == nil && $0.timeRaw == nil })
        #expect(records[0].date == nil)
        #expect(MessageStore.merge(existing: Array(records.prefix(1)), incoming: records).count == 3)
        // The same text with a time is another record.
        let timed = Self.records([Self.message("공지", author: nil, date: nil, time: (10, 0), side: .unknown)])
        #expect(MessageStore.merge(existing: records, incoming: timed).count == 1)
    }

    // MARK: chat_ids

    @Test("Only [A-Za-z0-9_-]+ chat_ids become file names")
    func chatIDs() {
        for valid in ["chat_7f42c5e1d9ab", "chat_7f42c5e1d9ab_2", "A-z_09"] {
            #expect(MessageStore.isValidChatID(valid))
            #expect(MessageStore.fileName(chatID: valid) == "\(valid).jsonl")
            #expect(MessageStore.chatID(fromFileName: "\(valid).jsonl") == valid)
        }
        for invalid in ["", ".", "..", "../chat_1", "chat/1", "chat.1", "chat 1", "채팅", "chat_１", "chat\u{0}1", "~chat"] {
            #expect(!MessageStore.isValidChatID(invalid), "\(invalid)")
            #expect(MessageStore.fileName(chatID: invalid) == nil)
        }
        #expect(MessageStore.chatID(fromFileName: "chat_1.json") == nil)
        #expect(MessageStore.chatID(fromFileName: ".jsonl") == nil)
        #expect(MessageStore.chatID(fromFileName: "chat 1.jsonl") == nil)
        #expect(MessageStore.chatID(fromFileName: "notes.txt") == nil)
    }

    // MARK: Search

    @Test("Text: case-insensitive substring, also with spaces removed; empty text matches all")
    func searchText() {
        let records = [Self.stored("Hello 안녕하세요"), Self.stored("안녕 하세요"), Self.stored("잘 가요")]
        #expect(Self.bodies(records, .init(text: "HELLO")) == ["Hello 안녕하세요"])
        // Same date and time: the later record comes first.
        #expect(Self.bodies(records, .init(text: "안녕하세요")) == ["안녕 하세요", "Hello 안녕하세요"])
        #expect(Self.bodies(records, .init(text: "안녕 하세요")) == ["안녕 하세요", "Hello 안녕하세요"])
        #expect(Self.bodies(records, .init(text: "o안녕")) == ["Hello 안녕하세요"])
        #expect(Self.bodies(records, .init(text: "")).count == 3)
        #expect(Self.bodies(records, .init(text: "없는 말")).isEmpty)
    }

    @Test("Author: exact or case-insensitive part; chat_id: exact")
    func searchAuthorAndChat() {
        let records = [
            Self.stored("가", author: "홍길동"),
            Self.stored("나", author: "김철수", chatID: "chat_other"),
            Self.stored("다", author: TranscriptItem.meAuthor),
            Self.stored("라", author: "TestUser"),
            Self.stored("마", author: nil),
        ]
        #expect(Self.bodies(records, .init(text: "", author: "홍길동")) == ["가"])
        #expect(Self.bodies(records, .init(text: "", author: "길동")) == ["가"])
        #expect(Self.bodies(records, .init(text: "", author: "testuser")) == ["라"])
        #expect(Self.bodies(records, .init(text: "", author: "(me)")) == ["다"])
        #expect(Self.bodies(records, .init(text: "", author: " ")).count == 5)
        #expect(Self.bodies(records, .init(text: "", chatID: "chat_other")) == ["나"])
        #expect(Self.bodies(records, .init(text: "", chatID: "chat_other", author: "홍길동")).isEmpty)
    }

    @Test("since/until: inclusive days or minutes; no date never matches a bound")
    func searchBounds() throws {
        let records = [
            Self.stored("19일 23:59", date: "2026-11-19", time: "23:59"),
            Self.stored("20일 00:00", date: "2026-11-20", time: "00:00"),
            Self.stored("20일 09:30", date: "2026-11-20", time: "09:30"),
            Self.stored("20일 시간 없음", date: "2026-11-20", time: nil),
            Self.stored("21일 08:00", date: "2026-11-21", time: "08:00"),
            Self.stored("날짜 없음", date: nil, time: nil),
        ]
        func bound(_ text: String) throws -> MessageStore.SearchBound {
            try #require(MessageStore.SearchBound(text))
        }
        func matching(since: String? = nil, until: String? = nil) throws -> Set<String> {
            let query = MessageStore.SearchQuery(text: "", since: try since.map(bound), until: try until.map(bound))
            return Set(Self.bodies(records, query))
        }

        #expect(try matching(since: "2026-11-20") == ["20일 00:00", "20일 09:30", "20일 시간 없음", "21일 08:00"])
        #expect(try matching(until: "2026-11-20") == ["19일 23:59", "20일 00:00", "20일 09:30", "20일 시간 없음"])
        #expect(try matching(since: "2026-11-20", until: "2026-11-20") == ["20일 00:00", "20일 09:30", "20일 시간 없음"])
        // Minutes are inclusive too; a message without a time stays on the boundary day.
        #expect(try matching(since: "2026-11-20T09:30") == ["20일 09:30", "20일 시간 없음", "21일 08:00"])
        #expect(try matching(until: "2026-11-20T09:29") == ["19일 23:59", "20일 00:00", "20일 시간 없음"])
        #expect(try matching(since: "2026-11-19T23:59", until: "2026-11-20T00:00") == ["19일 23:59", "20일 00:00", "20일 시간 없음"])
        #expect(try matching().count == 6)

        #expect(MessageStore.isEmptyRange(since: try bound("2026-11-21"), until: try bound("2026-11-20")))
        #expect(MessageStore.isEmptyRange(since: try bound("2026-11-20T10:00"), until: try bound("2026-11-20T09:59")))
        #expect(!MessageStore.isEmptyRange(since: try bound("2026-11-20T10:00"), until: try bound("2026-11-20")))
        #expect(!MessageStore.isEmptyRange(since: try bound("2026-11-20"), until: try bound("2026-11-20T00:00")))
        #expect(!MessageStore.isEmptyRange(since: nil, until: try bound("2026-11-20")))
    }

    @Test("Bounds parse YYYY-MM-DD and YYYY-MM-DDTHH:MM only, with real dates and times")
    func boundParsing() {
        #expect(MessageStore.SearchBound("2026-11-20")?.date == "2026-11-20")
        #expect(MessageStore.SearchBound("2026-11-20")?.time == nil)
        #expect(MessageStore.SearchBound("2026-11-20T09:30")?.time == "09:30")
        #expect(MessageStore.SearchBound("2026-11-20 09:30")?.date == "2026-11-20")
        #expect(MessageStore.SearchBound("2024-02-29") != nil)
        for invalid in [
            "", "2026-02-29", "2026-13-01", "2026-00-10", "2026-11-31", "2026-11-00", "2026-11-20T24:00",
            "2026-11-20T09:60", "2026/11/20", "20261120", "2026-1-2", "2026-11-20T9:30", "２０２６-11-20",
            "2026-11-20T09:30:00", "yesterday",
        ] {
            #expect(MessageStore.SearchBound(invalid) == nil, "\(invalid)")
        }
    }

    @Test("Newest first by date, time, then file order; limit keeps the newest")
    func searchOrderAndLimit() {
        let records = [
            Self.stored("a", date: "2026-11-20", time: "10:00"),
            Self.stored("b", date: "2026-11-21", time: "09:00"),
            Self.stored("c", date: "2026-11-20", time: "10:00"),
            Self.stored("d", date: nil, time: nil),
            Self.stored("e", date: "2026-11-20", time: nil),
            Self.stored("f", date: "2026-11-21", time: "09:00"),
        ]
        #expect(Self.bodies(records, .init(text: "")) == ["f", "b", "c", "a", "e", "d"])
        #expect(Self.bodies(records, .init(text: "", limit: 2)) == ["f", "b"])
        #expect(Self.bodies(records, .init(text: "", limit: 0)).isEmpty)
        #expect(MessageStore.SearchQuery(text: "").limit == 50)
        let many = (0..<60).map { Self.stored("메시지 \($0)", time: String(format: "%02d:%02d", $0 / 60 + 10, $0 % 60)) }
        let found = Self.bodies(many, .init(text: "메시지"))
        #expect(found.count == 50)
        #expect(found.first == "메시지 59")
        #expect(found.last == "메시지 10")
    }

    @Test("Text line: date time author (chat): body, on one line")
    func textLine() {
        #expect(MessageStore.textLine(Self.stored("첫 줄\n둘째 줄")) == "2026-11-20 14:05 홍길동 (테스트방): 첫 줄 둘째 줄")
        var system = Self.stored("김철수님이 들어왔습니다.", author: nil, time: nil, kind: "system")
        system.chat = ""
        #expect(MessageStore.textLine(system) == "2026-11-20 - (system) (chat_test): 김철수님이 들어왔습니다.")
        #expect(MessageStore.textLine(Self.stored("안녕하세요", author: nil, date: nil, time: nil)) == "- - (unknown) (테스트방): 안녕하세요")
    }

    // MARK: JSON lines

    @Test("One compact line per record: snake_case keys, explicit nulls, round trip")
    func jsonLines() throws {
        let record = Self.records([Self.message("첫 줄\n둘째 줄", author: nil, time: nil, side: .unknown)])[0]
        let data = try MessageStore.encodeLines([record, Self.stored("안녕하세요")])
        let text = try #require(String(data: data, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        #expect(lines[2].isEmpty)

        let object = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(Set(object.keys) == [
            "chat_id", "chat", "date", "time", "time_raw", "author", "side", "kind", "body", "occurrence",
            "edited", "truncated", "saved_at",
        ])
        #expect(object["author"] is NSNull)
        #expect(object["time"] is NSNull)
        #expect(object["time_raw"] is NSNull)
        #expect(object["body"] as? String == "첫 줄\n둘째 줄")
        #expect(object["occurrence"] as? Int == 0)
        #expect(object["chat_id"] as? String == "chat_test")
        #expect(object["saved_at"] as? String == Self.savedAt)

        let decoded = MessageStore.decodeLines(data)
        #expect(decoded.records == [record, Self.stored("안녕하세요")])
        #expect(decoded.unreadableLines == 0)
    }

    @Test("Decoding skips a line cut short, blank lines and garbage; missing keys take defaults")
    func decodeDamagedFile() throws {
        var data = try MessageStore.encodeLines([Self.stored("안녕하세요")])
        data.append(Data(#"{"chat_id":"chat_test","bo"#.utf8))
        data.append(Data("\n\n  \n".utf8))
        data.append(try MessageStore.encodeLines([Self.stored("반가워요")]))
        data.append(Data("not json\n".utf8))
        let decoded = MessageStore.decodeLines(data)
        #expect(decoded.records.map(\.body) == ["안녕하세요", "반가워요"])
        #expect(decoded.unreadableLines == 2)

        let minimal = MessageStore.decodeLines(Data(#"{"chat_id":"chat_test","body":"안녕하세요"}"#.utf8)).records
        #expect(minimal.count == 1)
        #expect(minimal.first?.occurrence == 0)
        #expect(minimal.first?.kind == "message")
        #expect(minimal.first?.date == nil)
        #expect(MessageStore.decodeLines(Data(#"{"body":"안녕하세요"}"#.utf8)).records.isEmpty)
    }

    @Test("saved_at is ISO-8601 with milliseconds in UTC")
    func timestamp() {
        #expect(MessageStore.timestamp(Date(timeIntervalSince1970: 1_795_151_400.25)) == "2026-11-20T05:10:00.250Z")
    }
}
