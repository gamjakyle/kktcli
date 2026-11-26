import ApplicationServices.HIServices
import Foundation
import KktcliCore

/// Finds and opens one room the way `read` does, for `send`, `send-image` and their previews:
/// the user-activity guard, the main-window policy and the chat-list context menu
/// (채팅방 열기). No search typing, no Enter, no activation.
final class RoomSession {
    struct Located {
        let row: LocatedChatRow
        let access: ChatListAccess
        /// Other chat-list rows with the same normalized name.
        let sameNameRows: Int
        let chatID: String?
    }

    struct Opened {
        let window: UIElement
        let openedByUs: Bool
        let title: String
    }

    let runner: AXActionRunner
    let kakao: KakaoTalkApp
    let locator: ChatListLocator
    let activity: UserActivityGuard
    let mainWindowAccess: MainWindowAccess

    /// Permission, main-window policy (before the login check) and login state.
    init(traceAX: Bool, idleSeconds: Double, waitForIdle: Double, allowActivate: Bool) throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ReadFailure(
                code: "ACCESSIBILITY_PERMISSION_DENIED",
                message: "Accessibility permission is not granted to kktcli.",
                hint: "Grant it in System Settings > Privacy & Security > Accessibility (손쉬운 사용)."
            )
        }
        let runner = AXActionRunner(traceEnabled: traceAX)
        let activity = UserActivityGuard(idleSeconds: idleSeconds, waitBudget: waitForIdle, runner: runner)
        let access = MainWindowAccess(runner: runner, activity: activity, allowActivate: allowActivate)
        if KakaoTalkApp.isRunning, let early = try? KakaoTalkApp(autoLaunch: false) {
            let earlyLocator = ChatListLocator(kakao: early, runner: runner)
            if earlyLocator.mainWindow() == nil, case .pressed = try access.reopen(kakao: early, locator: earlyLocator) {
                _ = earlyLocator.waitForMainWindow(timeout: 3.0)
            }
        }
        let kakao: KakaoTalkApp
        do {
            kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        } catch {
            throw ReadFailure(code: "KAKAO_UNAVAILABLE", message: "\(error)")
        }
        self.runner = runner
        self.kakao = kakao
        self.activity = activity
        self.mainWindowAccess = access
        self.locator = ChatListLocator(kakao: kakao, runner: runner)
    }

    private func listAccess() throws -> ChatListAccess {
        let (mainWindow, _) = try locator.requireMainWindow(allowOpenCommand: false, access: mainWindowAccess)
        return try locator.verifiedAccess(in: mainWindow, activity: activity).access
    }

    /// Rows whose normalized title is `normalizedName`, with their indices.
    private func sameNameRows(_ normalizedName: String, rows: [AXUIElement]) throws -> [LocatedChatRow] {
        var result: [LocatedChatRow] = []
        for index in rows.indices {
            try ReadInterruption.check("while scanning the chat list")
            guard let title = locator.title(of: rows[index]), ChatTextNormalizer.normalize(title) == normalizedName else { continue }
            result.append(locator.located(index, title: title, rows: rows))
        }
        return result
    }

    /// A chat_id must point at exactly one row (preview match or one-to-one elimination).
    func locate(chatID: String) throws -> Located {
        let registry = ChatIdentityRegistryStore.shared
        guard let record = registry.record(for: chatID) else {
            throw ReadFailure(code: "UNKNOWN_CHAT_ID", message: "Unknown chat_id '\(chatID)'.", hint: "Run 'kktcli chats' first.")
        }
        if record.isRetired {
            throw ChatListLocator.staleChatID(chatID, record: record)
        }
        let access = try listAccess()
        let rows = AXNodeReader.rows(of: access.table)
        let candidates = try sameNameRows(record.normalizedName, rows: rows)
        guard !candidates.isEmpty else {
            throw ReadFailure(code: "CHAT_NOT_IN_LIST", message: "No chat-list row is titled '\(record.displayName)'.", hint: "Run 'kktcli chats' to refresh chat_ids.")
        }
        switch registry.resolution(of: chatID, among: candidates.map(ChatListLocator.discovery)) {
        case .row(let position):
            registry.refresh(chatID: chatID, with: ChatListLocator.discovery(candidates[position]))
            return Located(row: candidates[position], access: access, sameNameRows: candidates.count - 1, chatID: chatID)
        case .stale:
            throw ChatListLocator.staleChatID(chatID, record: record)
        case .ambiguous:
            throw ChatListLocator.ambiguousChatID(chatID, record: record, candidates: candidates)
        case .notFound:
            throw ReadFailure(code: "CHAT_NOT_IN_LIST", message: "The room of chat_id '\(chatID)' is not in the chat list.", hint: "Run 'kktcli chats' to refresh chat_ids.")
        }
    }

    /// A name must match exactly one row (exact title, or the only row with that normalized
    /// name); several rooms with that name need a chat_id.
    func locate(name: String) throws -> Located {
        let access = try listAccess()
        let rows = AXNodeReader.rows(of: access.table)
        let wanted = ChatListLocator.trimmed(name)
        let candidates = try sameNameRows(ChatTextNormalizer.normalize(RoomTitle.expectedWindowTitle(forRowTitle: wanted)), rows: rows)
            + (try sameNameRows(ChatTextNormalizer.normalize(wanted), rows: rows))
        var unique: [LocatedChatRow] = []
        for row in candidates where !unique.contains(where: { $0.index == row.index }) {
            unique.append(row)
        }
        let exact = unique.filter { $0.title == wanted || RoomTitle.windowMatchesRow(windowTitle: wanted, rowTitle: $0.title) }
        guard unique.count <= 1 else {
            throw ReadFailure(
                code: "AMBIGUOUS_CHAT",
                message: "\(unique.count) chats are named like '\(name)'" + (exact.count == 1 ? " (one exactly)" : "") + "; nothing was sent.",
                hint: "Use --chat-id from 'kktcli chats' and check the room by its preview.",
                exitCode: KktcliExitStatus.ambiguousChatID,
                details: ["candidates": unique.map { "\($0.title) | \($0.summary.preview ?? "-") | \($0.summary.timeLabel ?? "-")" }.joined(separator: "\n")]
            )
        }
        guard let row = unique.first else {
            throw ReadFailure(code: "CHAT_NOT_IN_LIST", message: "No chat-list row is named '\(name)'.", hint: "Check the name with 'kktcli chats'.")
        }
        return Located(row: row, access: access, sameNameRows: 0, chatID: nil)
    }

    /// Opens the room through its context menu (waits for the user-activity guard). When
    /// other rooms share the name, an already open window cannot be told apart by its title,
    /// so the window must be one that appeared after the press.
    func open(_ located: Located) throws -> Opened {
        let opener = ChatRoomMenuOpener(kakao: kakao, runner: runner, activity: activity)
        let room = try opener.open(located.row, access: located.access, skipUnread: false)
        if !room.isNewWindow, located.sameNameRows > 0 {
            throw ReadFailure(
                code: "SEND_TARGET_UNCERTAIN",
                message: "A window titled '\(located.row.title)' was already open and \(located.sameNameRows) other room(s) share the name, so the right window cannot be confirmed; nothing was sent.",
                hint: "Close the open window(s) of that name and retry.",
                exitCode: KktcliExitStatus.sendUnverified
            )
        }
        let title = OpenedWindowRule.isUntitled(room.window.title)
            ? RoomTitle.expectedWindowTitle(forRowTitle: located.row.title)
            : (room.window.title ?? located.row.title)
        return Opened(window: room.window, openedByUs: room.isNewWindow, title: title)
    }

    /// The newest `limit` messages of an open chat window (no scrollback).
    func tail(of window: UIElement, limit: Int, justOpened: Bool) -> [TranscriptItem] {
        let parts = justOpened
            ? StructuredTranscriptReader.waitForParts(in: window, timeout: 1.5)
            : StructuredTranscriptReader.parts(in: window)
        guard let parts else { return [] }
        return StructuredTranscriptReader(runner: runner).read(
            parts,
            options: TranscriptReadOptions(limit: limit, includeSystem: false, scrollback: false, scrollbackTimeout: 0)
        ).items
    }

    /// Closes a window this command opened (its own close button; title not checked).
    @discardableResult
    func close(_ opened: Opened, keep: Bool) -> String {
        guard opened.openedByUs else { return "untouched" }
        guard !keep else { return "kept_open" }
        let outcome = ChatWindowCloser(kakao: kakao, runner: runner).close(opened.window, expectedTitle: nil)
        return outcome == .closed ? "closed" : "left_open (\(outcome.code))"
    }

    /// The window is still there (same element) and shows the same room.
    func stillShows(_ opened: Opened) -> Bool {
        guard kakao.windows.contains(where: { CFEqual($0.axElement, opened.window.axElement) }) else { return false }
        let title = opened.window.title
        return OpenedWindowRule.isUntitled(title) || ChatListLocator.trimmed(title) == ChatListLocator.trimmed(opened.title)
    }
}
