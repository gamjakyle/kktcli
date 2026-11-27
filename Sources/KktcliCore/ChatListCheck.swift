import Foundation

/// Is the table in KakaoTalk's main window really the chat list (채팅 tab)?
public enum ChatListVerification: Equatable, Sendable {
    case chatList
    /// The rows do not look like chat-list rows (another tab, e.g. 친구).
    case notChatList(sampled: Int, chatLike: Int, timed: Int)
    /// The table has no rows (an empty or filtered chat list, or another tab).
    case empty
    /// The main window shows no table at all.
    case noTable
    /// The window shows another tab (the 친구 tab's outline), whatever its rows look like.
    case otherTab(MainWindowTab)
    /// The list is not an AXTable (e.g. the 친구 tab's AXOutline).
    case wrongContainer(role: String)

    public var isChatList: Bool { self == .chatList }
}

/// Positive verification of the chat list before anything reads it as one or writes chat_ids.
///
/// Live finding (KakaoTalk 26.10.0): with the main window on the 친구 tab, `chats` read 250
/// friend rows as chats (only 38 had anything in the preview slot) and wrote them into the
/// registry. A chat-list row has its title in the `_NS:40` label plus the last-message time
/// `_NS:69`, a preview `_NS:87`/`_NS:91` (the empty open-chat list preview counts) or a member
/// count (`Count Label`, "N명": a group room without messages shows nothing else). The first
/// `sampleSize` rows decide: at least `chatLikeShare` of them must look like that and at least
/// `timedShare` must show a time or a member count, which friend rows do not.
///
/// Live finding (2026-11-27): a query left in the search field filtered the list down to two
/// rooms, one of them empty, and the shares failed; `read` stopped with
/// CHAT_LIST_UNAVAILABLE before list recovery could clear the query. On the positively
/// identified 채팅 tab with a query in its search field the table is the (filtered) chat list,
/// since KakaoTalk's chat search lists rooms only (`verify(containerRole:tab:summaries:searchQuery:)`).
public enum ChatListCheck {
    public static let sampleSize = 12
    public static let chatLikeShare = 0.7
    public static let timedShare = 0.5

    public static func isChatListRow(_ summary: ChatRowSummary) -> Bool {
        summary.titleSource == .titleLabel
            && (hasText(summary.timeLabel) || hasText(summary.preview) || summary.memberCount != nil)
    }

    /// What only chat rows show: a last-message time or a member count. Friend rows show neither.
    public static func hasChatOnlyEvidence(_ summary: ChatRowSummary) -> Bool {
        summary.titleSource == .titleLabel && (hasText(summary.timeLabel) || summary.memberCount != nil)
    }

    /// The container role and the tab come first: only an AXTable on a window that does not
    /// show the 친구 tab can be the chat list; then the rows decide (`verify(_:)`).
    ///
    /// `searchQuery` is the text of the visible search field, read only on the 채팅 tab. With a
    /// query on the positively identified 채팅 tab, a filtered table is the chat list even when
    /// its few rows miss the shares (every sampled row must still carry the title label) or
    /// when no room matches (empty), so list recovery may clear the query.
    public static func verify(
        containerRole: String?,
        tab: MainWindowTab,
        summaries: [ChatRowSummary],
        searchQuery: String? = nil
    ) -> ChatListVerification {
        if tab == .friends {
            return .otherTab(.friends)
        }
        guard let containerRole else { return .noTable }
        guard MainWindowLayout.isChatListContainer(role: containerRole) else {
            return .wrongContainer(role: containerRole)
        }
        let verification = verify(summaries)
        guard tab == .chats, hasText(searchQuery) else {
            return verification
        }
        switch verification {
        case .empty:
            return .chatList
        case .notChatList:
            let sample = summaries.prefix(sampleSize)
            return sample.allSatisfy { $0.titleSource == .titleLabel } ? .chatList : verification
        default:
            return verification
        }
    }

    public static func verify(_ summaries: [ChatRowSummary]) -> ChatListVerification {
        let sample = Array(summaries.prefix(sampleSize))
        guard !sample.isEmpty else { return .empty }
        let chatLike = sample.filter(isChatListRow).count
        let timed = sample.filter(hasChatOnlyEvidence).count
        let count = Double(sample.count)
        if Double(chatLike) >= chatLikeShare * count, Double(timed) >= timedShare * count {
            return .chatList
        }
        return .notChatList(sampled: sample.count, chatLike: chatLike, timed: timed)
    }

    private static func hasText(_ text: String?) -> Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// KakaoTalk's own 창 menu item that shows the chat tab: "채팅" with ⌘2 (live: 친구 ⌘1,
/// 채팅 ⌘2, 더보기 ⌘3; the `_NS` identifiers are hints only). Nothing else in that menu is
/// ever pressed.
public enum ChatTabMenu {
    public static let windowMenuTitles: Set<String> = ["창", "Window"]
    public static let title = "채팅"
    public static let commandCharacter = "2"
    /// Tabs that are never pressed.
    public static let neverPressed: Set<String> = ["친구", "더보기"]

    public static func isChatTabItem(role: String, title: String?, commandCharacter: String?) -> Bool {
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return role == AXRoleName.menuItem
            && title == Self.title
            && !neverPressed.contains(title)
            && (commandCharacter ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == Self.commandCharacter
    }

    public enum Decision: Equatable, Sendable {
        /// Use the table as the chat list.
        case useTable
        /// Press 채팅 in the 창 menu, then verify again.
        case switchTab
        /// Not the chat list and no switch allowed or already tried: nothing is read or written.
        case notChatTab
    }

    /// An empty table is used as it is (an empty or filtered chat list); list recovery decides
    /// about filters. Any other unverified table is never used as the chat list.
    public static func decide(_ verification: ChatListVerification, mayPress: Bool, alreadySwitched: Bool) -> Decision {
        switch verification {
        case .chatList, .empty:
            return .useTable
        case .notChatList, .noTable, .otherTab, .wrongContainer:
            return mayPress && !alreadySwitched ? .switchTab : .notChatTab
        }
    }
}
