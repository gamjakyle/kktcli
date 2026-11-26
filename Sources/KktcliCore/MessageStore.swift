import Foundation

/// One saved message: a line of the local message store (`<chat_id>.jsonl`).
///
/// Every key is always written, as null when unknown. `occurrence` numbers the messages of
/// one read that share date, time, author and body (0, 1, 2, ...), so legitimate repeats
/// such as three identical "ㅋㅋ" in the same minute stay apart.
public struct StoredMessage: Codable, Equatable, Sendable {
    public var chatID: String
    /// Room title at read time (open chats may have an empty title).
    public var chat: String
    /// "YYYY-MM-DD".
    public var date: String?
    /// 24-hour "HH:MM".
    public var time: String?
    /// The time label as KakaoTalk printed it, e.g. "오후 3:12".
    public var timeRaw: String?
    /// A name, "(me)" for your own messages, or nil when unknown.
    public var author: String?
    public var side: String
    public var kind: String
    public var body: String
    public var occurrence: Int
    public var edited: Bool
    public var truncated: Bool
    /// ISO-8601 time the record was saved.
    public var savedAt: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case chat
        case date
        case time
        case timeRaw = "time_raw"
        case author
        case side
        case kind
        case body
        case occurrence
        case edited
        case truncated
        case savedAt = "saved_at"
    }

    public init(
        chatID: String,
        chat: String,
        date: String?,
        time: String?,
        timeRaw: String?,
        author: String?,
        side: String,
        kind: String,
        body: String,
        occurrence: Int,
        edited: Bool,
        truncated: Bool,
        savedAt: String
    ) {
        self.chatID = chatID
        self.chat = chat
        self.date = date
        self.time = time
        self.timeRaw = timeRaw
        self.author = author
        self.side = side
        self.kind = kind
        self.body = body
        self.occurrence = occurrence
        self.edited = edited
        self.truncated = truncated
        self.savedAt = savedAt
    }

    /// chat_id and body are required; other missing keys take neutral defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatID = try container.decode(String.self, forKey: .chatID)
        chat = try container.decodeIfPresent(String.self, forKey: .chat) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date)
        time = try container.decodeIfPresent(String.self, forKey: .time)
        timeRaw = try container.decodeIfPresent(String.self, forKey: .timeRaw)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        side = try container.decodeIfPresent(String.self, forKey: .side) ?? TranscriptItem.Side.unknown.rawValue
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? TranscriptItem.Kind.message.rawValue
        body = try container.decode(String.self, forKey: .body)
        occurrence = try container.decodeIfPresent(Int.self, forKey: .occurrence) ?? 0
        edited = try container.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        savedAt = try container.decodeIfPresent(String.self, forKey: .savedAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Optional values are written as explicit nulls so consumers can rely on every key.
        try container.encode(chatID, forKey: .chatID)
        try container.encode(chat, forKey: .chat)
        try container.encode(date, forKey: .date)
        try container.encode(time, forKey: .time)
        try container.encode(timeRaw, forKey: .timeRaw)
        try container.encode(author, forKey: .author)
        try container.encode(side, forKey: .side)
        try container.encode(kind, forKey: .kind)
        try container.encode(body, forKey: .body)
        try container.encode(occurrence, forKey: .occurrence)
        try container.encode(edited, forKey: .edited)
        try container.encode(truncated, forKey: .truncated)
        try container.encode(savedAt, forKey: .savedAt)
    }
}

/// Pure logic of the local message store: records from a read, de-duplication, search and
/// the JSON-lines format. File access lives in the executable (`MessageArchive`).
public enum MessageStore {
    public static let fileExtension = "jsonl"
    public static let defaultSearchLimit = 50

    // MARK: chat_ids and file names

    /// chat_ids become file names, so only `[A-Za-z0-9_-]+` is accepted (no "/", "..", etc.).
    public static func isValidChatID(_ chatID: String) -> Bool {
        !chatID.isEmpty && chatID.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D:  // 0-9 A-Z a-z _ -
                return true
            default:
                return false
            }
        }
    }

    /// "<chat_id>.jsonl", or nil when the chat_id is not valid.
    public static func fileName(chatID: String) -> String? {
        isValidChatID(chatID) ? "\(chatID).\(fileExtension)" : nil
    }

    /// The chat_id of a store file name, or nil for any other name.
    public static func chatID(fromFileName name: String) -> String? {
        let suffix = ".\(fileExtension)"
        guard name.hasSuffix(suffix) else { return nil }
        let chatID = String(name.dropLast(suffix.count))
        return isValidChatID(chatID) ? chatID : nil
    }

    // MARK: Records of one read

    /// Messages that share these values are told apart by `occurrence`.
    struct GroupKey: Hashable {
        var date: String?
        var time: String?
        var author: String?
        var body: String
    }

    /// What makes a stored message unique within its chat.
    struct DedupKey: Hashable {
        var group: GroupKey
        var occurrence: Int

        init(_ record: StoredMessage) {
            group = GroupKey(date: record.date, time: record.time, author: record.author, body: record.body)
            occurrence = record.occurrence
        }
    }

    /// The messages and system lines of one read, in order (control rows such as
    /// "지난 대화 보기" are skipped). `occurrence` counts, in order, the earlier items of the
    /// same read with the same date, time, author and body.
    public static func records(from items: [TranscriptItem], chatID: String, chat: String, savedAt: String) -> [StoredMessage] {
        var seen: [GroupKey: Int] = [:]
        var records: [StoredMessage] = []
        for item in items where item.kind == .message || item.kind == .system {
            let time = item.time?.hhmm
            let key = GroupKey(date: item.date, time: time, author: item.author, body: item.body)
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            records.append(StoredMessage(
                chatID: chatID,
                chat: chat,
                date: item.date,
                time: time,
                timeRaw: item.time?.raw,
                author: item.author,
                side: item.side.rawValue,
                kind: item.kind.rawValue,
                body: item.body,
                occurrence: occurrence,
                edited: item.edited,
                truncated: item.truncated,
                savedAt: savedAt
            ))
        }
        return records
    }

    /// The incoming records to append, in incoming order: those whose (date, time, author,
    /// body, occurrence) is in neither `existing` nor earlier in `incoming`.
    ///
    /// A read that shows three identical "ㅋㅋ" in the same minute (occurrences 0, 1, 2) while
    /// the store has two (0, 1) adds exactly one; a later read whose window shows only one of
    /// them (occurrence 0) adds none.
    public static func merge(existing: [StoredMessage], incoming: [StoredMessage]) -> [StoredMessage] {
        var known = Set(existing.map(DedupKey.init))
        return incoming.filter { known.insert(DedupKey($0)).inserted }
    }

    // MARK: Search

    /// A `--since` / `--until` bound: "YYYY-MM-DD" (the whole day) or "YYYY-MM-DDTHH:MM"
    /// ("YYYY-MM-DD HH:MM" is accepted too).
    public struct SearchBound: Equatable, Sendable {
        /// "YYYY-MM-DD".
        public var date: String
        /// "HH:MM", or nil for the whole day.
        public var time: String?

        public init?(_ text: String) {
            let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard chars.count == 10 || chars.count == 16 else { return nil }
            guard
                chars[4] == "-", chars[7] == "-",
                let year = Self.number(chars[0..<4]),
                let month = Self.number(chars[5..<7]),
                let day = Self.number(chars[8..<10]),
                (1...12).contains(month),
                (1...Self.days(inMonth: month, year: year)).contains(day)
            else {
                return nil
            }
            date = String(chars[0..<10])
            guard chars.count == 16 else {
                time = nil
                return
            }
            guard
                chars[10] == "T" || chars[10] == " ",
                chars[13] == ":",
                let hour = Self.number(chars[11..<13]),
                let minute = Self.number(chars[14..<16]),
                (0...23).contains(hour),
                (0...59).contains(minute)
            else {
                return nil
            }
            time = String(chars[11..<16])
        }

        /// As a lower bound: the record is on or after it.
        func admitsFromBelow(_ record: StoredMessage) -> Bool {
            guard let recordDate = record.date else { return false }
            if recordDate != date {
                return recordDate > date
            }
            // A message without a time is kept on the boundary day.
            guard let time, let recordTime = record.time else { return true }
            return recordTime >= time
        }

        /// As an upper bound: the record is on or before it.
        func admitsFromAbove(_ record: StoredMessage) -> Bool {
            guard let recordDate = record.date else { return false }
            if recordDate != date {
                return recordDate < date
            }
            guard let time, let recordTime = record.time else { return true }
            return recordTime <= time
        }

        private static func number(_ chars: ArraySlice<Character>) -> Int? {
            guard chars.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(String(chars))
        }

        private static func days(inMonth month: Int, year: Int) -> Int {
            switch month {
            case 2:
                let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
                return leap ? 29 : 28
            case 4, 6, 9, 11:
                return 30
            default:
                return 31
            }
        }
    }

    /// What `kktcli search` looks for.
    public struct SearchQuery: Equatable, Sendable {
        /// Matched case-insensitively against the body, also with all whitespace removed from
        /// both; an empty text matches every message.
        public var text: String
        /// Only this chat.
        public var chatID: String?
        /// Inclusive lower bound.
        public var since: SearchBound?
        /// Inclusive upper bound.
        public var until: SearchBound?
        /// The author equals it or contains it case-insensitively; empty means any author.
        public var author: String?
        /// The newest `limit` hits are returned.
        public var limit: Int

        public init(
            text: String,
            chatID: String? = nil,
            since: SearchBound? = nil,
            until: SearchBound? = nil,
            author: String? = nil,
            limit: Int = MessageStore.defaultSearchLimit
        ) {
            self.text = text
            self.chatID = chatID
            self.since = since
            self.until = until
            self.author = author
            self.limit = limit
        }
    }

    /// True when `since` lies after `until`, so nothing can match.
    public static func isEmptyRange(since: SearchBound?, until: SearchBound?) -> Bool {
        guard let since, let until else { return false }
        return (since.date, since.time ?? "00:00") > (until.date, until.time ?? "23:59")
    }

    /// The records that match `query`, newest first (by date, then time, then later position
    /// in `records`), at most `query.limit` of them. Records without a date sort last and never
    /// match `since`/`until`.
    public static func search(_ records: [StoredMessage], query: SearchQuery) -> [StoredMessage] {
        let text = TextMatcher(query.text)
        let author = query.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let loweredAuthor = author.lowercased()
        let hits = records.enumerated().filter { _, record in
            if let chatID = query.chatID, record.chatID != chatID {
                return false
            }
            if !author.isEmpty, !matchesAuthor(record.author, query: author, lowered: loweredAuthor) {
                return false
            }
            if let since = query.since, !since.admitsFromBelow(record) {
                return false
            }
            if let until = query.until, !until.admitsFromAbove(record) {
                return false
            }
            return text.matches(record.body)
        }
        let newestFirst = hits.sorted { lhs, rhs in
            (lhs.element.date ?? "", lhs.element.time ?? "", lhs.offset) > (rhs.element.date ?? "", rhs.element.time ?? "", rhs.offset)
        }
        return newestFirst.prefix(max(0, query.limit)).map(\.element)
    }

    /// Case-insensitive substring match, retried with all whitespace removed from both sides.
    /// (Lowercasing plus a native `contains` is several times faster than a bridged
    /// case-insensitive `range(of:options:)` on large stores.)
    struct TextMatcher {
        let lowered: String
        let compact: String

        init(_ text: String) {
            lowered = text.lowercased()
            compact = MessageStore.removingWhitespace(lowered)
        }

        func matches(_ body: String) -> Bool {
            if lowered.isEmpty {
                return true
            }
            let loweredBody = body.lowercased()
            if loweredBody.contains(lowered) {
                return true
            }
            // "안녕 하세요" finds "안녕하세요" and the other way round.
            return compact.isEmpty || MessageStore.removingWhitespace(loweredBody).contains(compact)
        }
    }

    static func matchesAuthor(_ author: String?, query: String, lowered: String) -> Bool {
        guard let author else { return false }
        return author == query || author.lowercased().contains(lowered)
    }

    static func removingWhitespace(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    /// One `kktcli search` text line: "date time author (chat): body", on a single line.
    public static func textLine(_ record: StoredMessage) -> String {
        let author = record.author ?? (record.kind == TranscriptItem.Kind.system.rawValue ? "(system)" : "(unknown)")
        let chat = record.chat.isEmpty ? record.chatID : record.chat
        let body = record.body.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "\(record.date ?? "-") \(record.time ?? "-") \(author) (\(chat)): \(body)"
    }

    // MARK: JSON lines

    /// Each record as one compact JSON object followed by "\n".
    public static func encodeLines(_ records: [StoredMessage]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for record in records {
            // Compact JSON escapes line breaks inside strings, so a record never spans lines.
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        return data
    }

    /// The records of a store file in file order. Lines that are not a record (for example a
    /// line cut short by a crash) are skipped and counted.
    public static func decodeLines(_ data: Data) -> (records: [StoredMessage], unreadableLines: Int) {
        let decoder = JSONDecoder()
        var records: [StoredMessage] = []
        var unreadable = 0
        for line in data.split(separator: 0x0A) {
            guard line.contains(where: { !isJSONWhitespace($0) }) else { continue }
            if let record = try? decoder.decode(StoredMessage.self, from: Data(line)) {
                records.append(record)
            } else {
                unreadable += 1
            }
        }
        return (records, unreadable)
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }

    /// `saved_at` value: ISO-8601 with fractional seconds, e.g. "2026-11-20T05:12:03.120Z".
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
