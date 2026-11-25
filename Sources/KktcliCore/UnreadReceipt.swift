import Foundation

/// Whether opening a room cleared its chat-list unread badge.
///
/// `read` records the row's badge before opening the room and reads the row again after the
/// window is closed. It is not yet verified on every KakaoTalk build whether a room opened
/// while KakaoTalk is in the background is marked read, so this is reported, not assumed.
public enum UnreadReceipt {
    /// - Parameters:
    ///   - before: the badge seen on the row right before opening.
    ///   - after: the badge seen when the row was read again; nil when it could not be read.
    /// - Returns: true when a badge seen before is gone, false when a badge is still shown,
    ///   nil when there was no (certain) badge before or the row could not be checked.
    public static func markedRead(before: UnreadBadge, after: UnreadBadge?) -> Bool? {
        guard before.isUnread, !isIncompleteRead(before), let after, !isIncompleteRead(after) else {
            return nil
        }
        return !after.isUnread
    }

    /// The badge as printed in JSON (`unread_before` / `unread_after`); nil when there is none.
    public static func evidence(_ badge: UnreadBadge?) -> String? {
        guard let badge, badge.isUnread else { return nil }
        return badge.evidence
    }

    private static func isIncompleteRead(_ badge: UnreadBadge) -> Bool {
        badge == .unknown(ChatRowAnalyzer.incompleteReadEvidence)
    }
}
