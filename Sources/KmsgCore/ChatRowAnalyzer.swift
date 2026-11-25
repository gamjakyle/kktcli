import Foundation

/// Unread state shown on a chat-list row.
public enum UnreadBadge: Equatable, Sendable {
    case none
    /// "안읽음 N" (or a bare count) with a readable N.
    case count(Int)
    /// Something that looks like an unread badge but whose count could not be read.
    /// The associated text is the evidence (node text or identifier).
    case unknown(String)

    public var isUnread: Bool {
        self != .none
    }

    public var count: Int? {
        if case .count(let value) = self { return value }
        return nil
    }

    public var evidence: String? {
        switch self {
        case .none:
            return nil
        case .count(let value):
            return "\(KakaoText.unreadPrefix) \(value)"
        case .unknown(let text):
            return text
        }
    }
}

/// Interpretation of one chat-list row (KakaoTalk for Mac 26.10).
public struct ChatRowSummary: Equatable, Sendable {
    public enum TitleSource: String, Sendable {
        /// Read from the `_NS:40` title label.
        case titleLabel
        /// No `_NS:40` label; the first plausible unlabeled text was used.
        case fallback
        case missing
    }

    public var title: String?
    public var titleSource: TitleSource
    public var memberCount: Int?
    public var timeLabel: String?
    public var isPinned: Bool
    public var preview: String?
    public var unread: UnreadBadge
    /// "identifier=text" for texts with identifiers this analyzer does not know.
    public var unknownTexts: [String]

    public init(
        title: String? = nil,
        titleSource: TitleSource = .missing,
        memberCount: Int? = nil,
        timeLabel: String? = nil,
        isPinned: Bool = false,
        preview: String? = nil,
        unread: UnreadBadge = .none,
        unknownTexts: [String] = []
    ) {
        self.title = title
        self.titleSource = titleSource
        self.memberCount = memberCount
        self.timeLabel = timeLabel
        self.isPinned = isPinned
        self.preview = preview
        self.unread = unread
        self.unknownTexts = unknownTexts
    }
}

/// Reads chat-list rows by element identifier instead of by position or role
/// order, so the unread badge can never be mistaken for the room title.
///
/// Row cell children observed on KakaoTalk 26.10.0 (build 2010):
/// `_NS:11` profile button, `_NS:40` title, `Count Label` member count ("N명"),
/// `_NS:69` time (suffix ", 핀 설정됨" when pinned), `_NS:87`/`_NS:91` preview,
/// `_NS:138` unread badge ("안읽음 N").
public enum ChatRowAnalyzer {
    public static let titleIdentifier = "_NS:40"
    public static let memberCountIdentifier = "Count Label"
    public static let timeIdentifier = "_NS:69"
    public static let previewIdentifiers: Set<String> = ["_NS:87", "_NS:91"]
    public static let unreadBadgeIdentifier = "_NS:138"

    public static func summarize(_ nodes: [AXNodeSnapshot]) -> ChatRowSummary {
        var summary = ChatRowSummary()
        var unreadEvidence: [UnreadBadge] = []
        var fallbackTitle: String?

        for node in nodes {
            let text = node.text.kmsgTrimmed

            if node.identifier == unreadBadgeIdentifier {
                unreadEvidence.append(badge(fromText: text, evidence: text.isEmpty ? unreadBadgeIdentifier : text))
                continue
            }

            guard node.role == AXRoleName.staticText || node.role == AXRoleName.textArea else {
                continue
            }

            // Conservative: any text starting with "안읽음" counts as an unread badge,
            // even when it sits under an unexpected identifier.
            if text.hasPrefix(KakaoText.unreadPrefix) {
                unreadEvidence.append(badge(fromText: text, evidence: text))
                continue
            }

            switch node.identifier {
            case titleIdentifier:
                if summary.title == nil, !text.isEmpty {
                    summary.title = text
                    summary.titleSource = .titleLabel
                }
            case memberCountIdentifier:
                if summary.memberCount == nil {
                    summary.memberCount = KakaoText.memberCount(text)
                }
            case timeIdentifier:
                if summary.timeLabel == nil, !text.isEmpty {
                    if text.hasSuffix(KakaoText.pinnedSuffix) {
                        summary.isPinned = true
                        summary.timeLabel = String(text.dropLast(KakaoText.pinnedSuffix.count)).kmsgTrimmed
                    } else {
                        summary.timeLabel = text
                    }
                }
            case let identifier where previewIdentifiers.contains(identifier):
                if summary.preview == nil, !text.isEmpty {
                    summary.preview = text
                }
            default:
                guard !text.isEmpty else { continue }
                summary.unknownTexts.append("\(node.identifier)=\(text)")
                if KakaoText.isCountLike(text) {
                    // An unexpected bare number is treated as a possible unread badge.
                    unreadEvidence.append(.unknown(text))
                    continue
                }
                if fallbackTitle == nil, node.role == AXRoleName.staticText, isPlausibleFallbackTitle(text) {
                    fallbackTitle = text
                }
            }
        }

        if summary.title == nil, let fallbackTitle {
            summary.title = fallbackTitle
            summary.titleSource = .fallback
        }

        if let counted = unreadEvidence.first(where: { $0.count != nil }) {
            summary.unread = counted
        } else if let first = unreadEvidence.first {
            summary.unread = first
        }

        return summary
    }

    private static func badge(fromText text: String, evidence: String) -> UnreadBadge {
        if let count = KakaoText.unreadCount(in: text) {
            return .count(count)
        }
        if KakaoText.isCountLike(text), let count = KakaoText.leadingCount(text) {
            return .count(count)
        }
        return .unknown(evidence)
    }

    private static func isPlausibleFallbackTitle(_ text: String) -> Bool {
        if text.hasPrefix(KakaoText.unreadPrefix) { return false }
        if KakaoText.isCountLike(text) { return false }
        if KakaoText.memberCount(text) != nil { return false }
        if KakaoText.isChatListTimeLabel(text) { return false }
        return true
    }
}
