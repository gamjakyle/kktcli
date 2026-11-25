import Foundation

/// JSON shape of one message printed by `kktcli read --json`.
///
/// Keys kept from earlier releases: author, time_raw, body, date, has_image, image_count,
/// link_count, has_attachment, attachment_count. `author` is "(me)" for your own messages and
/// null when the sender could not be established (system lines, banners, unnamed rows).
public struct ReadMessageJSON: Encodable, Equatable, Sendable {
    public var author: String?
    public var side: String
    public var kind: String
    public var body: String
    public var date: String?
    public var time: String?
    public var timeRaw: String?
    public var timeSource: String?
    public var unreadCount: Int?
    public var edited: Bool
    public var imageCount: Int
    public var linkCount: Int
    public var attachmentCount: Int
    /// Only the beginning of a long message was read (the bubble's "…" + 전체보기).
    public var truncated: Bool
    /// The body is the full text read through 전체보기 (`read --full-text`).
    public var fullTextFetched: Bool

    enum CodingKeys: String, CodingKey {
        case author
        case side
        case kind
        case body
        case date
        case time
        case timeRaw = "time_raw"
        case timeSource = "time_source"
        case unreadCount = "unread_count"
        case edited
        case hasImage = "has_image"
        case imageCount = "image_count"
        case linkCount = "link_count"
        case hasAttachment = "has_attachment"
        case attachmentCount = "attachment_count"
        case truncated
        case fullTextFetched = "full_text_fetched"
    }

    public init(item: TranscriptItem) {
        author = item.author
        side = item.side.rawValue
        kind = item.kind.rawValue
        body = item.body
        date = item.date
        time = item.time?.hhmm
        timeRaw = item.time?.raw
        timeSource = item.timeSource?.rawValue
        unreadCount = item.unreadCount
        edited = item.edited
        imageCount = item.imageCount
        linkCount = item.linkCount
        attachmentCount = item.attachmentCount
        truncated = item.truncated
        fullTextFetched = item.fullTextFetched
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Optional values are written as explicit nulls so consumers can rely on every key.
        try container.encode(author, forKey: .author)
        try container.encode(side, forKey: .side)
        try container.encode(kind, forKey: .kind)
        try container.encode(body, forKey: .body)
        try container.encode(date, forKey: .date)
        try container.encode(time, forKey: .time)
        try container.encode(timeRaw, forKey: .timeRaw)
        try container.encode(timeSource, forKey: .timeSource)
        try container.encode(unreadCount, forKey: .unreadCount)
        try container.encode(edited, forKey: .edited)
        try container.encode(imageCount > 0, forKey: .hasImage)
        try container.encode(imageCount, forKey: .imageCount)
        try container.encode(linkCount, forKey: .linkCount)
        try container.encode(attachmentCount > 0, forKey: .hasAttachment)
        try container.encode(attachmentCount, forKey: .attachmentCount)
        try container.encode(truncated, forKey: .truncated)
        try container.encode(fullTextFetched, forKey: .fullTextFetched)
    }
}

/// JSON error document printed by `kktcli read --json` on failure (exit status is non-zero).
public struct ReadErrorJSON: Encodable, Equatable, Sendable {
    public struct Detail: Encodable, Equatable, Sendable {
        public var code: String
        public var message: String
        public var hint: String?

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
            try container.encode(hint, forKey: .hint)
        }

        enum CodingKeys: String, CodingKey {
            case code
            case message
            case hint
        }
    }

    public var ok: Bool
    public var error: Detail
    public var chat: String?
    public var chatID: String?
    public var details: [String: String]

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case chat
        case chatID = "chat_id"
        case details
    }

    public init(code: String, message: String, hint: String?, chat: String?, chatID: String?, details: [String: String] = [:]) {
        ok = false
        error = Detail(code: code, message: message, hint: hint)
        self.chat = chat
        self.chatID = chatID
        self.details = details
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
        try container.encode(chat, forKey: .chat)
        try container.encode(chatID, forKey: .chatID)
        try container.encode(details, forKey: .details)
    }
}
