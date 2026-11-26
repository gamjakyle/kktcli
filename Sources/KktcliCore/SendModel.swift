import Foundation

/// The exact text of a send.
public enum SendText {
    /// What is shown in the preview, put into the input and verified in the
    /// bubble: line endings as "\n", trailing whitespace and newlines removed. No footer or
    /// anything else is ever added.
    public static func exact(_ text: String) -> String {
        normalizeLineEndings(text).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    public static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : normalizeLineEndings(text).components(separatedBy: "\n").count
    }
}

/// Room kinds shown in the send preview.
public enum RoomKind: String, Codable, Sendable {
    case oneToOne = "1:1"
    case group
    case team
    case open
    case selfChat = "self"

    public static func of(rowTitle: String, memberCount: Int?) -> RoomKind {
        let title = rowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("팀채팅, ") { return .team }
        if title.hasPrefix("나와의 채팅, ") { return .selfChat }
        if title.hasPrefix("오픈채팅, ") { return .open }
        if let memberCount, memberCount >= 3 { return .group }
        return .oneToOne
    }
}

/// One message line in the send preview.
public struct SendContextMessage: Codable, Equatable, Sendable {
    public var author: String?
    public var time: String?
    public var body: String

    public init(author: String?, time: String?, body: String) {
        self.author = author
        self.time = time
        self.body = body
    }

    public init(item: TranscriptItem) {
        author = item.author
        time = [item.date, item.time?.hhmm].compactMap { $0 }.joined(separator: " ")
        if time?.isEmpty == true { time = nil }
        body = item.body
    }
}

/// What `send --preview` prints.
public struct SendPreview: Codable, Equatable, Sendable {
    public var title: String
    public var kind: RoomKind
    public var memberCount: Int?
    public var chatID: String?
    public var listPreview: String?
    public var listTime: String?
    public var lastMessages: [SendContextMessage]
    /// Other chat-list rows with the same name (0 when the name is unique).
    public var sameNameRows: Int
    public var text: String
    public var lines: Int
    public var characters: Int
    public var method: String
    public var checks: [String]

    enum CodingKeys: String, CodingKey {
        case title, kind
        case memberCount = "member_count"
        case chatID = "chat_id"
        case listPreview = "list_preview"
        case listTime = "list_time"
        case lastMessages = "last_messages"
        case sameNameRows = "same_name_rows"
        case text, lines, characters, method, checks
    }

    public init(
        title: String,
        memberCount: Int?,
        chatID: String?,
        listPreview: String?,
        listTime: String?,
        lastMessages: [SendContextMessage],
        sameNameRows: Int,
        text: String,
        method: String
    ) {
        self.title = title
        kind = RoomKind.of(rowTitle: title, memberCount: memberCount)
        self.memberCount = memberCount
        self.chatID = chatID
        self.listPreview = listPreview
        self.listTime = listTime
        self.lastMessages = lastMessages
        self.sameNameRows = sameNameRows
        self.text = text
        lines = SendText.lineCount(text)
        characters = text.count
        self.method = method
        checks = Self.checks(text: text, sameNameRows: sameNameRows)
    }

    public static func checks(text: String, sameNameRows: Int) -> [String] {
        sameNameRows > 0 ? ["\(sameNameRows) other chat(s) have the same name: check the room by its last messages"] : []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(memberCount, forKey: .memberCount)
        try container.encode(chatID, forKey: .chatID)
        try container.encode(listPreview, forKey: .listPreview)
        try container.encode(listTime, forKey: .listTime)
        try container.encode(lastMessages, forKey: .lastMessages)
        try container.encode(sameNameRows, forKey: .sameNameRows)
        try container.encode(text, forKey: .text)
        try container.encode(lines, forKey: .lines)
        try container.encode(characters, forKey: .characters)
        try container.encode(method, forKey: .method)
        try container.encode(checks, forKey: .checks)
    }

    /// The short human-readable block.
    public var humanText: String {
        var lines: [String] = []
        let members = memberCount.map { ", \($0) members" } ?? ""
        lines.append("To:      \(title) (\(kind.rawValue)\(members))" + (chatID.map { "  [\($0)]" } ?? ""))
        if let listPreview {
            lines.append("List:    \(listPreview)" + (listTime.map { "  · \($0)" } ?? ""))
        }
        if !lastMessages.isEmpty {
            lines.append("Last messages:")
            for message in lastMessages {
                let who = message.author ?? "?"
                lines.append("  [\(message.time ?? "-")] \(who): \(message.body.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        lines.append("Method:  \(method)")
        lines.append("Text (\(self.lines) line(s), \(characters) characters):")
        lines.append(contentsOf: text.components(separatedBy: "\n").map { "  │ " + $0 })
        for check in checks {
            lines.append("Check:   \(check)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Verification of the sent bubble.
public enum SendVerification {
    public struct Key: Equatable, Sendable {
        public var author: String?
        public var time: String?
        public var body: String

        public init(item: TranscriptItem) {
            author = item.author
            time = item.time?.hhmm
            body = SendText.normalizeLineEndings(item.body)
        }

        public init(author: String?, time: String?, body: String) {
            self.author = author
            self.time = time
            self.body = body
        }
    }

    /// True when the transcript now ends with an outgoing bubble showing `text` that was not
    /// there before. A long text shows only its beginning and "…" in the bubble.
    public static func bubbleSent(text: String, before: [TranscriptItem], after: [TranscriptItem]) -> Bool {
        let messages = after.filter { $0.kind == .message }
        guard let last = messages.last, last.side == .me, matches(bubble: last.body, text: text) else {
            return false
        }
        let count = { (items: [TranscriptItem]) in
            items.filter { $0.kind == .message && $0.side == .me && matches(bubble: $0.body, text: text) }.count
        }
        return count(after) > count(before)
    }

    /// True when the transcript now ends with a new outgoing bubble that holds an image.
    public static func imageSent(before: [TranscriptItem], after: [TranscriptItem]) -> Bool {
        let isOutgoingImage = { (item: TranscriptItem) in item.kind == .message && item.side == .me && item.imageCount > 0 }
        guard let last = after.last(where: { $0.kind == .message }), isOutgoingImage(last) else {
            return false
        }
        return after.filter(isOutgoingImage).count > before.filter(isOutgoingImage).count
    }

    static func matches(bubble: String, text: String) -> Bool {
        let shown = trimmed(SendText.normalizeLineEndings(bubble))
        let sent = trimmed(SendText.normalizeLineEndings(text))
        if shown == sent { return true }
        if LongMessage.looksCut(shown) {
            return sent.hasPrefix(String(shown.dropLast()))
        }
        return false
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The one JSON document `send --json` / `send-image --json` print (also parsed by the MCP
/// server).
public struct SendReport: Codable, Equatable, Sendable {
    public struct ErrorInfo: Codable, Equatable, Sendable {
        public var code: String
        public var message: String
        public var hint: String?

        public init(code: String, message: String, hint: String?) {
            self.code = code
            self.message = message
            self.hint = hint
        }
    }

    public var ok: Bool
    /// "preview" or "send".
    public var mode: String
    public var sent: Bool
    public var cancelled: Bool
    public var bubbleVerified: Bool
    public var preview: SendPreview?
    /// Image sends: file name and size instead of a text preview.
    public var file: String?
    public var window: String?
    public var method: String?
    public var error: ErrorInfo?
    public var details: [String: String]

    enum CodingKeys: String, CodingKey {
        case ok, mode, sent, cancelled
        case bubbleVerified = "bubble_verified"
        case preview, file, window, method, error, details
    }

    public init(mode: String) {
        ok = false
        self.mode = mode
        sent = false
        cancelled = false
        bubbleVerified = false
        details = [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(mode, forKey: .mode)
        try container.encode(sent, forKey: .sent)
        try container.encode(cancelled, forKey: .cancelled)
        try container.encode(bubbleVerified, forKey: .bubbleVerified)
        try container.encode(preview, forKey: .preview)
        try container.encode(file, forKey: .file)
        try container.encode(window, forKey: .window)
        try container.encode(method, forKey: .method)
        try container.encode(error, forKey: .error)
        try container.encode(details, forKey: .details)
    }
}
