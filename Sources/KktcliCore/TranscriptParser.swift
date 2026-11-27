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
    /// The row starts another person's group: it shows their profile button (and name).
    public var hasSenderHeader: Bool
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
    /// The bubble shows only the beginning of a long message ("…" plus 전체보기).
    public var truncated: Bool
    /// The cut text exactly as the bubble's text area shows it (for re-identifying the row).
    public var cutText: String?
    /// The body was replaced by the full text read through 전체보기 (`read --full-text`).
    public var fullTextFetched: Bool

    public init(
        kind: Kind,
        side: Side,
        hasSenderHeader: Bool = false,
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
        rowIndex: Int,
        truncated: Bool = false,
        cutText: String? = nil,
        fullTextFetched: Bool = false
    ) {
        self.kind = kind
        self.side = side
        self.hasSenderHeader = hasSenderHeader
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
        self.truncated = truncated
        self.cutText = cutText
        self.fullTextFetched = fullTextFetched
    }
}

/// Rows are measured against their own AXCell/AXRow frame (`TranscriptParser.referenceFrame`),
/// read in the same snapshot as their content, never against a transcript frame read at
/// another moment: such a frame goes stale when the window moves or resizes before the rows
/// are read (live 2026-11-27: other people's unlabeled bubbles were then read as right
/// aligned, i.e. as "(me)").
public struct TranscriptParseOptions: Sendable {
    /// Date in effect before the first row of the slice (from an earlier separator).
    public var initialDate: String?

    public init(initialDate: String? = nil) {
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
///
/// Live geometry (KakaoTalk 26.10.0, 380 pt wide window, 2026-11-27): the profile button is a
/// 36 pt square 10 pt from the row's left edge and the name sits right of it; other people's
/// bubbles start 60–65 pt from the left and end 80 pt or more before the right edge; mine end
/// 18–23 pt before the right edge and start 105 pt or more from the left. Shared cards hold
/// static texts of their own (a song title, say), which are content and never a sender name.
///
/// "(me)" is attributed only on positive evidence and never next to a contradiction: the
/// side comes from the row's own geometry and its meta label, which must not disagree, and
/// `resolveAuthors` checks every result against KakaoTalk's grouping rule. Anything else is
/// side `.unknown` with a nil author.
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
    /// Right-aligned content counts as mine only when its left gap exceeds its right gap by
    /// at least this much (live: 105 pt or more against 23 pt or less).
    static let minimumSideMargin: CGFloat = 40
    /// How far content or labels may stick out of the frame they are compared with before the
    /// comparison is not trusted (a window that moved while one row was read).
    static let frameTolerance: CGFloat = 4
    /// A profile button without its description: an untitled square of this size near the top
    /// left corner of its row.
    static let profileButtonSizes: ClosedRange<CGFloat> = 28...48
    static let profileButtonMaxOffset: CGFloat = 24

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

            if let item = parseMessageRow(nodes: nodes, top: top, rowIndex: rowIndex, date: currentDate) {
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
        date: String?
    ) -> TranscriptItem? {
        let reference = referenceFrame(of: nodes)
        let profile = top.filter { isProfileButton(nodes[$0], reference: reference) }
        let metas = top.filter { nodes[$0].role == AXRoleName.staticText && KakaoText.isMetaLabel(nodes[$0].text) }
        let editedMarkers = top.filter { nodes[$0].role == AXRoleName.staticText && nodes[$0].text == editedMarker }
        // Only a header row (another person's profile button) names its sender: the first plain
        // static text after the profile button. Every other static text is content, e.g. the
        // title inside a shared card, and never a sender name.
        let names = profile.first.flatMap { profileIndex in
            top.first {
                $0 > profileIndex && nodes[$0].role == AXRoleName.staticText && !metas.contains($0) && !editedMarkers.contains($0)
            }
        }.map { [$0] } ?? []
        let content = top.filter { !profile.contains($0) && !metas.contains($0) && !names.contains($0) && !editedMarkers.contains($0) }

        let textAreas = content.filter { nodes[$0].role == AXRoleName.textArea }
        let texts = textAreas
            .map { nodes[$0].text }
            .filter { !$0.isEmpty }
        // A long message shows only its beginning, "…" and a 전체보기 control below the text.
        let cutText = textAreas.lazy
            .filter { LongMessage.looksCut(nodes[$0].text) }
            .filter { LongMessage.isTruncated(text: nodes[$0].text, hasSeeAllControl: LongMessage.seeAllControl(for: $0, in: nodes) != nil) }
            .map { nodes[$0].text }
            .first
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
            hasSenderHeader: !profile.isEmpty,
            metas: metas,
            content: content,
            reference: reference
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
            hasSenderHeader: !profile.isEmpty,
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
            rowIndex: rowIndex,
            truncated: cutText != nil,
            cutText: cutText
        )
    }

    /// Side of a message row.
    ///
    /// A sender header (profile button) means another person. Without one, two independent
    /// pieces of evidence are read: where the content sits inside the row's own frame
    /// (`geometry`) and on which side of the bubble the meta label sits (`metaSide`). One of
    /// them decides when the other is silent; when they disagree, or both are silent, the side
    /// is `.unknown`. Content spanning the whole row (banners) is always `.unknown`.
    static func inferSide(
        nodes: [AXNodeSnapshot],
        hasSenderHeader: Bool,
        metas: [Int],
        content: [Int],
        reference: CGRect?
    ) -> TranscriptItem.Side {
        if hasSenderHeader {
            return .other
        }

        guard let contentBox = union(content.compactMap { nodes[$0].frame }) else {
            return .unknown
        }
        // The bubble proper (text and images); small controls such as reaction buttons and
        // card parts only count when there is nothing else.
        let bubbleRoles: Set<String> = [AXRoleName.textArea, AXRoleName.image]
        let bubble = union(content.filter { bubbleRoles.contains(nodes[$0].role) }.compactMap { nodes[$0].frame }) ?? contentBox

        let geometry = geometry(of: bubble, in: reference)
        if geometry == .fullWidth {
            // Spans the whole row (channel banner, card): never a bubble of mine, whatever
            // labels sit next to it.
            return .unknown
        }
        let meta = metaSide(union(metas.compactMap { nodes[$0].frame }), bubble: bubble)

        switch (meta, geometry) {
        case (.me, .right), (.me, .ambiguous), (.me, .unavailable), (nil, .right):
            return .me
        case (.other, .left), (.other, .ambiguous), (.other, .unavailable), (nil, .left):
            return .other
        default:
            // The two disagree, or neither says anything.
            return .unknown
        }
    }

    enum RowGeometry: Equatable {
        /// Ends near the right edge and starts well inside: my bubble.
        case right
        /// Starts closer to the left edge than it ends to the right edge: another person's bubble.
        case left
        /// Starts near the left edge and ends near the right edge.
        case fullWidth
        case ambiguous
        /// No reference frame, or the content lies outside it (an inconsistent snapshot).
        case unavailable
    }

    /// Where `box` sits inside `reference` (the row's own frame).
    static func geometry(of box: CGRect, in reference: CGRect?) -> RowGeometry {
        guard let reference, reference.width > 0,
              box.minX >= reference.minX - frameTolerance,
              box.maxX <= reference.maxX + frameTolerance
        else {
            return .unavailable
        }
        let leftGap = box.minX - reference.minX
        let rightGap = reference.maxX - box.maxX
        if rightGap <= rightAlignmentSlack {
            if leftGap <= reference.width * fullWidthLeftFraction {
                return .fullWidth
            }
            return leftGap >= rightGap + minimumSideMargin ? .right : .ambiguous
        }
        return leftGap < rightGap ? .left : .ambiguous
    }

    /// KakaoTalk puts my meta label to the LEFT of my bubble and other people's to the right.
    /// nil without a meta label or when it overlaps the bubble.
    static func metaSide(_ meta: CGRect?, bubble: CGRect) -> TranscriptItem.Side? {
        guard let meta else { return nil }
        if meta.maxX <= bubble.minX + frameTolerance {
            return .me
        }
        if meta.minX >= bubble.maxX - frameTolerance {
            return .other
        }
        return nil
    }

    /// The frame a row's content is measured against: the row's own AXCell (else AXRow) frame,
    /// read in the same snapshot as the content, so a window that moved or resized between
    /// reads cannot shift one against the other. nil when the row has no frame: then only the
    /// meta label can tell the side (`inferSide`).
    static func referenceFrame(of nodes: [AXNodeSnapshot]) -> CGRect? {
        for depth in [1, 0] {
            if let frame = nodes.first(where: { $0.depth == depth })?.frame, frame.width > 0 {
                return frame
            }
        }
        return nil
    }

    /// The profile button that starts another person's group: described "프로필", or, should
    /// the description change, an untitled square button of profile size at the top left
    /// corner of the row.
    static func isProfileButton(_ node: AXNodeSnapshot, reference: CGRect?) -> Bool {
        guard node.role == AXRoleName.button else { return false }
        if node.desc == profileDescription {
            return true
        }
        guard (node.title ?? "").kktTrimmed.isEmpty, let frame = node.frame, let reference else {
            return false
        }
        return abs(frame.width - frame.height) <= 2
            && profileButtonSizes.contains(frame.width)
            && frame.minX >= reference.minX - frameTolerance
            && frame.minX - reference.minX <= profileButtonMaxOffset
            && frame.minY >= reference.minY - frameTolerance
            && frame.minY - reference.minY <= profileButtonMaxOffset
    }

    private static func union(_ frames: [CGRect]) -> CGRect? {
        let usable = frames.filter { $0.width > 0 || $0.height > 0 }
        guard let first = usable.first else { return nil }
        return usable.dropFirst().reduce(first) { $0.union($1) }
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

    /// Authors, checked against how KakaoTalk groups messages.
    ///
    /// A group is one sender's run of messages: KakaoTalk prints the time only on its last
    /// message, and another person's group after anyone else's message (mine included), a
    /// system line or a date separator starts with their sender header (profile button and
    /// name). Live 2026-11-27: every row after a date separator had a header; the same person
    /// writing on in a later minute may get no new header. Groups are read as: message rows on
    /// one date with nothing between them, up to and including the first row with a time
    /// label; a header always starts a new group.
    ///
    /// - A group whose rows read as mine is "(me)".
    /// - Another person's group with a header has the header's name. Without one it continues
    ///   the other person's group directly above it (same author); at the start of the slice
    ///   its header was not read (author nil, side kept).
    /// - Contradictions, which KakaoTalk cannot produce, mean a side was misread: a group mixing
    ///   my rows and another person's, a header-less group of another person directly below my
    ///   group, a system line, an unknown or mixed group or a date change. Then every "(me)"
    ///   involved becomes `.unknown`, and so does a header-less group with no author to
    ///   continue. "(me)" is never kept next to evidence that it may be wrong.
    public static func resolveAuthors(_ items: inout [TranscriptItem]) {
        var groups: [ClosedRange<Int>] = []
        var start = items.startIndex
        while start < items.endIndex {
            guard items[start].kind == .message else {
                start += 1
                continue
            }
            var end = start
            while items[end].time == nil, end + 1 < items.endIndex {
                let next = items[end + 1]
                guard next.kind == .message, next.date == items[start].date, !next.hasSenderHeader else { break }
                end += 1
            }
            groups.append(start...end)
            start = end + 1
        }

        func demoteMine(_ range: ClosedRange<Int>) {
            for index in range where items[index].side == .me {
                items[index].side = .unknown
                items[index].author = nil
            }
        }

        /// The group directly above, when nothing (system line, date change) lies between.
        var above: (range: ClosedRange<Int>, side: TranscriptItem.Side, author: String?)?
        for range in groups {
            let first = items[range.lowerBound]
            let sides = Set(items[range].map(\.side)).intersection([.me, .other])
            let mixed = sides.count > 1
            let adjacent = above.flatMap { previous in
                previous.range.upperBound + 1 == range.lowerBound && items[previous.range.upperBound].date == first.date ? previous : nil
            }

            var otherSide = TranscriptItem.Side.other
            var otherAuthor: String?
            if first.hasSenderHeader {
                otherAuthor = first.explicitAuthor
            } else if sides.contains(.other) {
                if range.lowerBound == items.startIndex {
                    otherAuthor = nil
                } else if let adjacent, adjacent.side == .other {
                    otherAuthor = adjacent.author
                } else {
                    otherSide = .unknown
                    if let adjacent, adjacent.side == .me {
                        demoteMine(adjacent.range)
                    }
                }
            }

            for index in range {
                switch items[index].side {
                case .me:
                    items[index].author = TranscriptItem.meAuthor
                case .other:
                    items[index].side = otherSide
                    items[index].author = otherSide == .other ? otherAuthor : nil
                case .unknown, .system:
                    items[index].author = nil
                }
            }
            if mixed {
                demoteMine(range)
            }

            let groupSide: TranscriptItem.Side
            if mixed {
                groupSide = .unknown
            } else if sides == [.me] {
                groupSide = .me
            } else if sides == [.other], otherSide == .other {
                groupSide = .other
            } else {
                groupSide = .unknown
            }
            above = (range, groupSide, otherAuthor)
        }

        for index in items.indices where items[index].kind != .message {
            items[index].author = nil
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
                return candidate.kktTrimmed
            }
        }
        return nil
    }

    private static func isURL(_ text: String) -> Bool {
        let lowered = text.kktTrimmed.lowercased()
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
        let trimmed = text.kktTrimmed
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
        let trimmed = token.kktTrimmed
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
        let lowered = title.kktTrimmed.lowercased()
        return lowered == "save" || lowered == "save as" || lowered == "저장" || lowered == "다른 이름으로 저장"
    }
}
