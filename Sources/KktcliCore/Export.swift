import Foundation

/// One stored message as `kktcli export` renders it.
public struct ExportMessage: Codable, Equatable, Sendable {
    public var chatID: String
    public var chat: String
    /// "YYYY-MM-DD", nil when unknown.
    public var date: String?
    /// "HH:MM", nil when unknown.
    public var time: String?
    public var author: String?
    public var body: String
    /// "message" or "system".
    public var kind: String
    public var imageCount: Int
    public var attachmentCount: Int
    /// Only the beginning of a long message was stored.
    public var truncated: Bool

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case chat, date, time, author, body, kind
        case imageCount = "image_count"
        case attachmentCount = "attachment_count"
        case truncated
    }

    public init(
        chatID: String,
        chat: String,
        date: String?,
        time: String?,
        author: String?,
        body: String,
        kind: String = "message",
        imageCount: Int = 0,
        attachmentCount: Int = 0,
        truncated: Bool = false
    ) {
        self.chatID = chatID
        self.chat = chat
        self.date = date
        self.time = time
        self.author = author
        self.body = body
        self.kind = kind
        self.imageCount = imageCount
        self.attachmentCount = attachmentCount
        self.truncated = truncated
    }
}

extension ExportMessage {
    public init(stored: StoredMessage) {
        self.init(
            chatID: stored.chatID,
            chat: stored.chat,
            date: stored.date,
            time: stored.time,
            author: stored.author,
            body: stored.body,
            kind: stored.kind,
            imageCount: stored.imageCount,
            attachmentCount: stored.attachmentCount,
            truncated: stored.truncated
        )
    }
}

public struct ExportFilter: Equatable, Sendable {
    public var chatIDs: [String]
    /// Inclusive bounds: "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM".
    public var since: String?
    public var until: String?
    public var author: String?
    public var grep: String?

    public init(chatIDs: [String] = [], since: String? = nil, until: String? = nil, author: String? = nil, grep: String? = nil) {
        self.chatIDs = chatIDs
        self.since = since
        self.until = until
        self.author = author
        self.grep = grep
    }

    public func matches(_ message: ExportMessage) -> Bool {
        if !chatIDs.isEmpty, !chatIDs.contains(message.chatID) { return false }
        let stamp = (message.date ?? "") + "T" + (message.time ?? "00:00")
        if let since, !since.isEmpty {
            guard message.date != nil, stamp >= Self.lowerBound(since) else { return false }
        }
        if let until, !until.isEmpty {
            guard message.date != nil, stamp <= Self.upperBound(until) else { return false }
        }
        if let author, !author.isEmpty {
            guard let name = message.author, name.localizedCaseInsensitiveContains(author) else { return false }
        }
        if let grep, !grep.isEmpty {
            let squeezed = { (text: String) in text.replacingOccurrences(of: " ", with: "") }
            guard message.body.localizedCaseInsensitiveContains(grep)
                || squeezed(message.body).localizedCaseInsensitiveContains(squeezed(grep))
            else { return false }
        }
        return true
    }

    static func lowerBound(_ value: String) -> String {
        value.contains("T") ? value : value + "T00:00"
    }

    static func upperBound(_ value: String) -> String {
        value.contains("T") ? value : value + "T23:59"
    }
}

/// Readable output of the local message store (pure; no KakaoTalk involved).
public enum ExportFormatter {
    public enum Format: String, CaseIterable, Sendable {
        case md
        case json
        case csv
    }

    /// Filtered and ordered: chats in the order of `filter.chatIDs` (else by name), then by
    /// date and time; messages without a date last; ties keep their stored order.
    public static func select(_ messages: [ExportMessage], filter: ExportFilter) -> [ExportMessage] {
        let kept = messages.enumerated().filter { filter.matches($0.element) }
        func chatRank(_ message: ExportMessage) -> Int {
            filter.chatIDs.firstIndex(of: message.chatID) ?? filter.chatIDs.count
        }
        return kept.sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            if chatRank(left) != chatRank(right) { return chatRank(left) < chatRank(right) }
            if left.chat != right.chat { return left.chat < right.chat }
            if left.chatID != right.chatID { return left.chatID < right.chatID }
            let leftKey = (left.date ?? "9999-99-99") + (left.time ?? "99:99")
            let rightKey = (right.date ?? "9999-99-99") + (right.time ?? "99:99")
            if leftKey != rightKey { return leftKey < rightKey }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The body as shown: attachments as [사진] or [파일: name], system lines marked, links
    /// and long texts kept as stored.
    public static func renderBody(_ message: ExportMessage) -> String {
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.kind == "system" {
            return "(알림) " + body
        }
        let placeholder = body.hasPrefix("[") && body.hasSuffix("]") && !body.dropFirst().dropLast().contains("[")
        if message.imageCount > 0, placeholder || body.isEmpty {
            return message.imageCount > 1 ? "[사진 \(message.imageCount)장]" : "[사진]"
        }
        if message.attachmentCount > 0 {
            if let range = body.range(of: #"[^\s/\[\]]+\.(?i:pdf|png|jpe?g|gif|webp|zip|hwp|hwpx|docx?|pptx?|xlsx?|txt|csv|mp4|mov)"#, options: .regularExpression) {
                return "[파일: \(body[range])]"
            }
            if placeholder || body.isEmpty {
                return "[파일]"
            }
        }
        return message.truncated ? body + " (앞부분만 저장됨)" : body
    }

    static func authorName(_ author: String?) -> String {
        guard let author, !author.isEmpty else { return "(알 수 없음)" }
        return author == TranscriptItem.meAuthor ? "나" : author
    }

    /// "2026-11-26 (목)"; the raw value when it is not a date.
    public static func dayHeading(_ date: String?) -> String {
        guard let date else { return "날짜 없음" }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return date }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        guard let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return date }
        let names = ["일", "월", "화", "수", "목", "금", "토"]
        return "\(date) (\(names[calendar.component(.weekday, from: day) - 1]))"
    }

    public static func markdown(_ messages: [ExportMessage]) -> String {
        var lines: [String] = []
        var currentChat: String?
        var currentDay: String??
        for message in messages {
            if currentChat != message.chatID {
                if !lines.isEmpty { lines.append("") }
                lines.append("# \(message.chat)")
                currentChat = message.chatID
                currentDay = .none
            }
            if currentDay != .some(message.date) {
                lines.append("")
                lines.append("## \(dayHeading(message.date))")
                lines.append("")
                currentDay = .some(message.date)
            }
            let body = renderBody(message).components(separatedBy: "\n")
            lines.append("- \(message.time ?? "--:--") \(authorName(message.author)): \(body[0])")
            lines.append(contentsOf: body.dropFirst().map { "  " + $0 })
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    public static func json(_ messages: [ExportMessage]) throws -> String {
        struct Document: Encodable {
            let ok = true
            let count: Int
            let messages: [ExportMessage]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Document(count: messages.count, messages: messages))
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// UTF-8 with a byte-order mark (so Excel on the Mac shows Korean), CRLF line ends,
    /// RFC 4180 quoting.
    public static func csv(_ messages: [ExportMessage]) -> String {
        func field(_ value: String?) -> String {
            let value = value ?? ""
            guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = ["chat,chat_id,date,time,author,body,kind"]
        for message in messages {
            rows.append([message.chat, message.chatID, message.date, message.time, authorName(message.author), renderBody(message), message.kind].map(field).joined(separator: ","))
        }
        return "\u{FEFF}" + rows.joined(separator: "\r\n") + "\r\n"
    }

    public static func render(_ messages: [ExportMessage], format: Format) throws -> String {
        switch format {
        case .md: return markdown(messages)
        case .json: return try json(messages)
        case .csv: return csv(messages)
        }
    }
}
