import Foundation

/// A KakaoTalk window seen while waiting for the room that 채팅방 열기 opens.
public struct OpenedWindowCandidate: Equatable, Sendable {
    public var title: String?
    /// The window was not among the windows that existed before the press.
    public var isNew: Bool
    /// The window shows a chat: the transcript scroll area (`_NS:32` holding an AXTable) or
    /// the message input (`_NS:51`). Only checked for an untitled new window; nil = not checked.
    public var isChatWindow: Bool?

    public init(title: String?, isNew: Bool, isChatWindow: Bool? = nil) {
        self.title = title
        self.isNew = isNew
        self.isChatWindow = isChatWindow
    }
}

public enum OpenedWindowMatch: Equatable, Sendable {
    /// The window (index into the candidates) is titled for the row.
    case titled(Int)
    /// The only new window has no title but shows a chat. Open chats ("오픈채팅, <name>")
    /// open such windows on KakaoTalk for Mac 26.10.0.
    case untitled(Int)
    case none
}

/// Decides which window is the room that was just opened from a chat-list row.
public enum OpenedWindowRule {
    /// How an untitled window is listed in `unexpected_new_windows` and similar details.
    public static let untitledPlaceholder = "(untitled)"

    public static func isUntitled(_ title: String?) -> Bool {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The window title for reports; "(untitled)" for an empty or missing title.
    public static func label(_ title: String?) -> String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? untitledPlaceholder : trimmed
    }

    /// Index of the window whose chat content must be checked before `match` can accept it:
    /// the single new window, when it is untitled.
    public static func untitledNewWindow(in candidates: [OpenedWindowCandidate]) -> Int? {
        let new = candidates.indices.filter { candidates[$0].isNew }
        guard new.count == 1, isUntitled(candidates[new[0]].title) else { return nil }
        return new[0]
    }

    /// 1. Any window titled for the row (the row title, or the title without a known
    ///    room-type prefix). Untitled windows never match by title.
    /// 2. Otherwise only the single window that appeared after the press: titled with an
    ///    unlisted short type label or a title equal after normalisation, or untitled when
    ///    it shows a chat. Several new windows are never guessed between.
    public static func match(rowTitle: String, candidates: [OpenedWindowCandidate]) -> OpenedWindowMatch {
        if let index = candidates.firstIndex(where: { RoomTitle.windowMatchesRow(windowTitle: $0.title, rowTitle: rowTitle) }) {
            return .titled(index)
        }
        let new = candidates.indices.filter { candidates[$0].isNew }
        guard new.count == 1 else { return .none }
        let index = new[0]
        let window = candidates[index]
        if isUntitled(window.title) {
            return window.isChatWindow == true ? .untitled(index) : .none
        }
        if RoomTitle.openedWindowMatchesRow(windowTitle: window.title, rowTitle: rowTitle) {
            return .titled(index)
        }
        let target = ChatQueryMatcher.normalize(RoomTitle.expectedWindowTitle(forRowTitle: rowTitle))
        if !target.isEmpty, ChatQueryMatcher.normalize(window.title ?? "") == target {
            return .titled(index)
        }
        return .none
    }
}
