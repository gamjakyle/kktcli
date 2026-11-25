import CoreGraphics
import Foundation

/// One transcript table row, flattened depth-first (depth 0 = the AXRow,
/// 1 = its cell, 2 = the cell's children).
public struct TranscriptRow: Equatable, Sendable {
    public var nodes: [AXNodeSnapshot]

    public init(nodes: [AXNodeSnapshot]) {
        self.nodes = nodes
    }
}

public struct TranscriptItem: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case message
        case system
        /// Non-message rows such as "지난 대화 보기" or the history authentication notice.
        case control
    }

    public enum Side: String, Sendable {
        case me
        case other
        /// Neither side could be established (for example a full-width channel banner).
        case unknown
        case system
    }

    public enum TimeSource: String, Sendable {
        /// The message carried its own time label.
        case label
        /// Taken from the next time label of the same author on the same date.
        case inferred
    }

    public static let meAuthor = "(me)"

    public var kind: Kind
    public var side: Side
    /// Name printed next to the bubble, when present.
    public var explicitAuthor: String?
    /// Resolved author: a name, "(me)", or nil when unknown.
    public var author: String?
    public var body: String
    /// "YYYY-MM-DD" from the nearest preceding date separator.
    public var date: String?
    public var time: ClockTime?
    public var timeSource: TimeSource?
    public var unreadCount: Int?
    public var edited: Bool
    public var links: [String]
    public var imageCount: Int
    public var linkCount: Int
    public var attachmentCount: Int
    public var contentKinds: [String]
    /// Index of the source row inside the parsed slice.
    public var rowIndex: Int

    public init(
        kind: Kind,
        side: Side,
        explicitAuthor: String? = nil,
        author: String? = nil,
        body: String,
        date: String? = nil,
        time: ClockTime? = nil,
        timeSource: TimeSource? = nil,
        unreadCount: Int? = nil,
        edited: Bool = false,
        links: [String] = [],
        imageCount: Int = 0,
        linkCount: Int = 0,
        attachmentCount: Int = 0,
        contentKinds: [String] = [],
        rowIndex: Int
    ) {
        self.kind = kind
        self.side = side
        self.explicitAuthor = explicitAuthor
        self.author = author
        self.body = body
        self.date = date
        self.time = time
        self.timeSource = timeSource
        self.unreadCount = unreadCount
        self.edited = edited
        self.links = links
        self.imageCount = imageCount
        self.linkCount = linkCount
        self.attachmentCount = attachmentCount
        self.contentKinds = contentKinds
        self.rowIndex = rowIndex
    }
}

public struct TranscriptParseOptions: Sendable {
    /// Frame of the transcript scroll area; used to tell left (others) from right (me).
    public var transcriptFrame: CGRect?
    /// Date in effect before the first row of the slice (from an earlier separator).
    public var initialDate: String?

    public init(transcriptFrame: CGRect? = nil, initialDate: String? = nil) {
        self.transcriptFrame = transcriptFrame
        self.initialDate = initialDate
    }
}

/// Parser for KakaoTalk for Mac 26.10 chat-window transcript rows.
///
/// Row layout (cell children):
/// - date separator: a single AXButton described "YYYY년 M월 D일 X요일"
/// - system message: AXTextArea `_NS:30`
/// - other people: "프로필" AXButton + name AXStaticText + content + meta to the right
/// - continuation: content + meta, left aligned
/// - me: content right aligned, meta to the LEFT of the content
/// - meta: "오후 5:10, 안읽음 2" | "오후 5:10" | "안읽음 2" | nothing (bursts)
public enum TranscriptParser {
    public static let systemMessageIdentifier = "_NS:30"
    public static let profileDescription = "프로필"
    public static let editedMarker = "수정됨"
    public static let olderHistoryButtonTitle = "지난 대화 보기"
    public static let authenticationNoticePrefix = "대화 내용을 불러오기 위해 인증이 필요합니다"
    public static let authenticationControlBody = "AUTH_REQUIRED_FOR_OLDER_HISTORY"

    /// Distance from the right edge within which content counts as right aligned.
    static let rightAlignmentSlack: CGFloat = 30
    /// Content starting this close to the left edge and reaching the right edge spans the
    /// whole transcript (banners, cards); such rows are never attributed to "(me)".
    static let fullWidthLeftFraction: CGFloat = 0.15

    public static func parse(_ rows: [TranscriptRow], options: TranscriptParseOptions = TranscriptParseOptions()) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var currentDate = options.initialDate

        for (rowIndex, row) in rows.enumerated() {
            let nodes = row.nodes
            let top = nodes.indices.filter { nodes[$0].depth == 2 }
            guard !top.isEmpty else { continue }

            if top.count == 1, nodes[top[0]].role == AXRoleName.button {
                let node = nodes[top[0]]
                let label = nonEmpty(node.desc) ?? nonEmpty(node.title) ?? ""
                if let date = KakaoText.dateSeparator(label) {
                    currentDate = date
                } else {
                    items.append(TranscriptItem(kind: .control, side: .system, body: label, date: currentDate, rowIndex: rowIndex))
                }
                continue
            }

            if top.contains(where: { nodes[$0].role == AXRoleName.staticText && nodes[$0].text.hasPrefix(authenticationNoticePrefix) }) {
                items.append(TranscriptItem(kind: .control, side: .system, body: authenticationControlBody, date: currentDate, rowIndex: rowIndex))
                continue
            }

            if let systemIndex = top.first(where: { nodes[$0].role == AXRoleName.textArea && nodes[$0].identifier == systemMessageIdentifier }) {
                items.append(TranscriptItem(kind: .system, side: .system, body: nodes[systemIndex].text, date: currentDate, rowIndex: rowIndex))
                continue
            }

            if let item = parseMessageRow(nodes: nodes, top: top, rowIndex: rowIndex, date: currentDate, transcriptFrame: options.transcriptFrame) {
                items.append(item)
            }
        }

        resolveAuthors(&items)
        inferBurstTimes(&items)
        return items
    }

    private static func parseMessageRow(
        nodes: [AXNodeSnapshot],
        top: [Int],
        rowIndex: Int,
        date: String?,
        transcriptFrame: CGRect?
    ) -> TranscriptItem? {
        let profile = top.filter { nodes[$0].role == AXRoleName.button && nodes[$0].desc == profileDescription }
        let metas = top.filter { nodes[$0].role == AXRoleName.staticText && KakaoText.isMetaLabel(nodes[$0].text) }
        let editedMarkers = top.filter { nodes[$0].role == AXRoleName.staticText && nodes[$0].text == editedMarker }
        let names = top.filter {
            nodes[$0].role == AXRoleName.staticText && !metas.contains($0) && !editedMarkers.contains($0)
        }
        let content = top.filter { !profile.contains($0) && !metas.contains($0) && !names.contains($0) && !editedMarkers.contains($0) }

        let texts = content
            .filter { nodes[$0].role == AXRoleName.textArea }
            .map { nodes[$0].text }
            .filter { !$0.isEmpty }
        let contentSubtrees = content.flatMap { subtree(of: $0, in: nodes) }
        let textLinks = content
            .filter { nodes[$0].role == AXRoleName.textArea }
            .flatMap { subtree(of: $0, in: nodes) }
            .filter { nodes[$0].role == AXRoleName.link }
            .compactMap { linkTarget(nodes[$0]) }
        let rowDescendants = nodes.indices.filter { nodes[$0].depth >= 2 }
        let links = rowDescendants
            .filter { nodes[$0].role == AXRoleName.link }
            .compactMap { linkTarget(nodes[$0]) }
        let images = contentSubtrees.filter { nodes[$0].role == AXRoleName.image }
        let media = content
            .filter { nodes[$0].role == AXRoleName.image }
            .map { nonEmpty(nodes[$0].desc) ?? nodes[$0].role }
        let otherControls = content.filter { nodes[$0].role != AXRoleName.textArea && nodes[$0].role != AXRoleName.image }

        var body = texts.joined(separator: "\n")
        var kinds: [String] = []
        if !texts.isEmpty {
            kinds.append("text")
            body = expandShortenedURLs(in: body, links: textLinks)
        }
        kinds.append(contentsOf: media.map { "media:\($0)" })
        if body.isEmpty, !media.isEmpty {
            body = "[" + media.joined(separator: ",") + "]"
        }
        if body.isEmpty, !otherControls.isEmpty {
            let label = otherControls
                .map { nodes[$0].label }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            body = "[\(label.isEmpty ? "첨부" : label)]"
            kinds.append("other")
        }
        if body.isEmpty, names.isEmpty, metas.isEmpty {
            return nil
        }

        let side = inferSide(
            nodes: nodes,
            hasProfileOrName: !profile.isEmpty || !names.isEmpty,
            metas: metas,
            content: content,
            transcriptFrame: transcriptFrame
        )

        var time: ClockTime?
        var unread: Int?
        for meta in metas {
            let text = nodes[meta].text
            if let parsed = KakaoText.firstTime(in: text) {
                time = parsed
            }
            if let count = KakaoText.unreadCount(in: text) {
                unread = count
            }
        }

        let rowTexts = rowDescendants
            .filter { nodes[$0].role == AXRoleName.staticText }
            .map { nodes[$0].text }
        let buttonTitles = rowDescendants
            .filter { nodes[$0].role == AXRoleName.button }
            .compactMap { nonEmpty(nodes[$0].title) }
        let attachmentCount = rowTexts.filter(AttachmentHeuristics.isAttachmentMetadata).count
            + buttonTitles.filter(AttachmentHeuristics.isAttachmentAction).count

        return TranscriptItem(
            kind: .message,
            side: side,
            explicitAuthor: names.first.map { nodes[$0].text },
            body: body,
            date: date,
            time: time,
            unreadCount: unread,
            edited: !editedMarkers.isEmpty,
            links: links,
            imageCount: images.count,
            linkCount: max(links.count, countURLs(in: body)),
            attachmentCount: attachmentCount,
            contentKinds: kinds,
            rowIndex: rowIndex
        )
    }

    private static func inferSide(
        nodes: [AXNodeSnapshot],
        hasProfileOrName: Bool,
        metas: [Int],
        content: [Int],
        transcriptFrame: CGRect?
    ) -> TranscriptItem.Side {
        if hasProfileOrName {
            return .other
        }

        let contentFrames = content.compactMap { nodes[$0].frame }
        let contentMinX = contentFrames.map(\.minX).min()
        let contentMaxX = contentFrames.map(\.maxX).max()

        var reachesRight: Bool?
        if let contentMinX, let contentMaxX, let transcriptFrame, transcriptFrame.width > 0 {
            let right = contentMaxX >= transcriptFrame.maxX - rightAlignmentSlack
            let startsAtLeft = contentMinX <= transcriptFrame.minX + transcriptFrame.width * fullWidthLeftFraction
            if right && startsAtLeft {
                // Spans the whole transcript (channel banner, card): never a bubble of mine,
                // whatever labels sit next to it.
                return .unknown
            }
            reachesRight = right
        }

        if let metaFrame = metas.lazy.compactMap({ nodes[$0].frame }).first, let contentMinX {
            // KakaoTalk puts my meta label to the LEFT of my bubble and others' to the right.
            return metaFrame.minX < contentMinX ? .me : .other
        }

        guard let reachesRight else {
            return .unknown
        }
        return reachesRight ? .me : .other
    }

    /// Indices of `index` and all of its descendants in a depth-first flatten.
    static func subtree(of index: Int, in nodes: [AXNodeSnapshot]) -> [Int] {
        var result = [index]
        var cursor = index + 1
        while cursor < nodes.count, nodes[cursor].depth > nodes[index].depth {
            result.append(cursor)
            cursor += 1
        }
        return result
    }

    // MARK: Authors

    /// Carries the last explicit name forward to left-side continuation rows.
    public static func resolveAuthors(_ items: inout [TranscriptItem]) {
        var lastOther: String?
        for index in items.indices where items[index].kind == .message {
            switch items[index].side {
            case .me:
                items[index].author = TranscriptItem.meAuthor
            case .other:
                if let explicit = items[index].explicitAuthor {
                    lastOther = explicit
                    items[index].author = explicit
                } else {
                    items[index].author = lastOther
                }
            case .unknown, .system:
                items[index].author = nil
            }
        }
    }

    // MARK: Times

    /// KakaoTalk prints the time only on the LAST message of a same-author run; earlier
    /// unlabeled messages of that run take the next label's time (same author, same date).
    /// The run ends at any author change, date change, system/control row, or a row whose
    /// side is unknown.
    public static func inferBurstTimes(_ items: inout [TranscriptItem]) {
        var nextTime: ClockTime?
        var nextKey: String?
        for index in items.indices.reversed() {
            let item = items[index]
            guard item.kind == .message, item.side == .me || item.side == .other else {
                nextTime = nil
                nextKey = nil
                continue
            }

            let key = "\(item.side.rawValue)|\(item.author ?? "?")|\(item.date ?? "?")"
            if let time = item.time {
                items[index].timeSource = .label
                nextTime = time
                nextKey = key
            } else if let nextTime, key == nextKey {
                items[index].time = nextTime
                items[index].timeSource = .inferred
            } else {
                items[index].timeSource = nil
                nextTime = nil
                nextKey = key
            }
        }
    }

    // MARK: Links

    private static func linkTarget(_ node: AXNodeSnapshot) -> String? {
        for candidate in [node.title, node.value, node.desc] {
            if let candidate, isURL(candidate) {
                return candidate.kmsgTrimmed
            }
        }
        return nil
    }

    private static func isURL(_ text: String) -> Bool {
        let lowered = text.kmsgTrimmed.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }

    /// KakaoTalk shortens long URLs in the bubble ("https://exam..."); the message text's AXLink
    /// child keeps the full target. Only a URL token that ends with an ellipsis and is a prefix of
    /// one of those links is replaced; all other text is kept as is.
    static func expandShortenedURLs(in body: String, links: [String]) -> String {
        guard !links.isEmpty else { return body }
        var result = ""
        var token = ""
        func flush() {
            result += expandToken(token, links: links)
            token = ""
        }
        for character in body {
            if character.isWhitespace {
                flush()
                result.append(character)
            } else {
                token.append(character)
            }
        }
        flush()
        return result
    }

    private static func expandToken(_ token: String, links: [String]) -> String {
        guard isURL(token) else { return token }
        let prefix: String
        if token.hasSuffix("...") {
            prefix = String(token.dropLast(3))
        } else if token.hasSuffix("…") {
            prefix = String(token.dropLast())
        } else {
            return token
        }
        guard !prefix.isEmpty,
              let full = links.filter({ $0.hasPrefix(prefix) && $0.count > prefix.count }).max(by: { $0.count < $1.count })
        else {
            return token
        }
        return full
    }

    static func countURLs(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { isURL(String($0)) }.count
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.kmsgTrimmed
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Selection helpers shared by the CLI and the tests.
public enum TranscriptSelection {
    /// Items `read` prints: messages, plus system messages when requested.
    public static func outputItems(_ items: [TranscriptItem], includeSystem: Bool) -> [TranscriptItem] {
        items.filter { $0.kind == .message || (includeSystem && $0.kind == .system) }
    }

    /// The newest `limit` output items, oldest first.
    public static func lastItems(_ items: [TranscriptItem], limit: Int, includeSystem: Bool) -> [TranscriptItem] {
        Array(outputItems(items, includeSystem: includeSystem).suffix(max(0, limit)))
    }

    /// Whether the selected window still lacks a date (no separator read yet) or an author
    /// for a left-side continuation row (its named row was not read yet).
    public static func missingContext(_ selected: [TranscriptItem]) -> (date: Bool, author: Bool) {
        let date = selected.first.map { $0.date == nil } ?? false
        let author = selected.contains { $0.kind == .message && $0.side == .other && $0.author == nil }
        return (date, author)
    }

    /// True when the parsed slice starts at the top of the locally available history.
    public static func reachedHistoryTop(_ items: [TranscriptItem]) -> Bool {
        guard let first = items.first, first.kind == .control else { return false }
        return first.body == TranscriptParser.olderHistoryButtonTitle || first.body == TranscriptParser.authenticationControlBody
    }
}

enum AttachmentHeuristics {
    static func isAttachmentMetadata(_ token: String) -> Bool {
        let trimmed = token.kmsgTrimmed
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("expiry") || lowered.hasPrefix("size:") {
            return true
        }
        if lowered.contains("만료") || lowered.contains("용량") {
            return true
        }
        return lowered.range(of: #"\.(pdf|png|jpe?g|gif|webp|zip|hwp|docx?|pptx?|xlsx?)$"#, options: .regularExpression) != nil
    }

    static func isAttachmentAction(_ title: String) -> Bool {
        let lowered = title.kmsgTrimmed.lowercased()
        return lowered == "save" || lowered == "save as" || lowered == "저장" || lowered == "다른 이름으로 저장"
    }
}
