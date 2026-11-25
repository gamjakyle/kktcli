import Foundation

/// Chat-list row titles vs. chat window titles.
///
/// Observed on KakaoTalk for Mac 26.10.0 (build 2010): the chat-list title label of some room
/// types carries the room type in front, e.g. "팀채팅, 스터디 모임", while the chat
/// window that opens for that row is titled without it ("스터디 모임").
/// Waiting for a window titled exactly like the row therefore never succeeds for those rooms.
public enum RoomTitle {
    /// Room-type prefixes seen in chat-list row titles.
    public static let knownTypePrefixes = ["팀채팅, ", "나와의 채팅, "]

    /// The chat window title expected for a chat-list row title.
    public static func expectedWindowTitle(forRowTitle rowTitle: String) -> String {
        let row = rowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in knownTypePrefixes where row.hasPrefix(prefix) {
            return String(row.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return row
    }

    /// True when `windowTitle` is the window of the chat-list row titled `rowTitle`: the same
    /// title, or the title without a known room-type prefix. Safe for windows that were already
    /// open (used to find an existing window and to recognise it while waiting).
    public static func windowMatchesRow(windowTitle: String?, rowTitle: String) -> Bool {
        let window = (windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let row = rowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty, !row.isEmpty else { return false }
        return window == row || window == expectedWindowTitle(forRowTitle: row)
    }

    /// Looser test, only for the single window that appeared right after 채팅방 열기 was pressed
    /// on the row: additionally accepts a type label not listed above, "<short label>, <window
    /// title>". Never used for windows that were open before: the row of an unnamed group
    /// chat such as "엄마, 아빠" would otherwise match a separate 1:1 window titled "아빠".
    public static func openedWindowMatchesRow(windowTitle: String?, rowTitle: String) -> Bool {
        if windowMatchesRow(windowTitle: windowTitle, rowTitle: rowTitle) {
            return true
        }
        let window = (windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let row = rowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = ", "
        guard !window.isEmpty, row.hasSuffix(separator + window) else { return false }
        let label = String(row.dropLast(separator.count + window.count))
        return !label.isEmpty && label.count <= 8 && !label.contains(",")
    }
}
