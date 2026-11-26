import Foundation

/// One chat-list row as `watch --all` sees it.
public struct ChatListEntrySnapshot: Equatable, Sendable {
    public var chatID: String
    public var title: String
    public var preview: String?
    public var time: String?
    public var unreadCount: Int?
    public var hasUnread: Bool

    public init(chatID: String, title: String, preview: String?, time: String?, unreadCount: Int?, hasUnread: Bool) {
        self.chatID = chatID
        self.title = title
        self.preview = preview
        self.time = time
        self.unreadCount = unreadCount
        self.hasUnread = hasUnread
    }
}

public enum ChatListChange: String, Codable, Sendable {
    case newMessage = "new_message"
    case unreadChanged = "unread_changed"
    case newRoom = "new_room"
}

public struct ChatListChangeEvent: Equatable, Sendable {
    public var entry: ChatListEntrySnapshot
    public var change: ChatListChange
}

/// Change detection for `watch` (pure).
public enum WatchDiff {
    /// Changes between two polls of the top chat-list rows. The first poll (`previous` nil) is
    /// the baseline and yields nothing. A row that was not in the previous poll is a new
    /// message when its chat_id was already known (it moved up into the watched rows), and a
    /// new room otherwise. Rows that dropped out of the watched rows are ignored.
    public static func chatListChanges(
        previous: [ChatListEntrySnapshot]?,
        current: [ChatListEntrySnapshot],
        knownChatIDs: Set<String>
    ) -> [ChatListChangeEvent] {
        guard let previous else { return [] }
        let before = Dictionary(previous.map { ($0.chatID, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [ChatListChangeEvent] = []
        for entry in current {
            guard let old = before[entry.chatID] else {
                events.append(.init(entry: entry, change: knownChatIDs.contains(entry.chatID) ? .newMessage : .newRoom))
                continue
            }
            if old.preview != entry.preview || old.time != entry.time {
                events.append(.init(entry: entry, change: .newMessage))
            } else if old.unreadCount != entry.unreadCount || old.hasUnread != entry.hasUnread {
                events.append(.init(entry: entry, change: .unreadChanged))
            }
        }
        return events
    }

    /// How many items at the end of `current` are new since `previous` (both oldest first),
    /// anchored on the longest tail of `previous` (up to 5 items) found in `current`.
    /// `gap` is true when no anchor was found: everything in `current` counts as new.
    public static func newTranscriptItems(previous: [SendVerification.Key], current: [SendVerification.Key]) -> (count: Int, gap: Bool) {
        guard !previous.isEmpty else { return (current.count, false) }
        for length in stride(from: min(5, previous.count), through: 1, by: -1) {
            let anchor = Array(previous.suffix(length))
            guard current.count >= length else { continue }
            for end in stride(from: current.count, through: length, by: -1) where Array(current[(end - length)..<end]) == anchor {
                return (current.count - end, false)
            }
        }
        return (current.count, true)
    }
}
