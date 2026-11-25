import ApplicationServices.HIServices
import CoreGraphics
import Foundation
import KktcliCore

/// Opens a chat-list row through its context menu using Accessibility actions only:
/// scroll the list (scroll-bar AXValue) until the row is visible, AXShowMenu on the row's
/// cell, then AXPress on the single item identified as `openChatRoom:` / "채팅방 열기".
/// No keyboard or mouse events are posted, so KakaoTalk may stay in the background.
///
/// The row is re-verified (title unchanged; with `skipUnread`, no unread badge) before
/// scrolling, before the menu is shown and right before the press. Any other outcome cancels
/// the menu (AXCancel); nothing else is ever pressed. Opening a room with unread messages
/// sends read receipts, exactly as opening it by hand does.
///
/// A window that appears after the press and did not exist before was opened by this
/// command. If none of them is accepted as the room, every such window is closed with its own
/// close button before the error is reported, so no window is left behind.
///
/// While the user is busy with KakaoTalk in front, a window opened now would become key and
/// take their typing, so the menu is shown only after `UserActivityGuard` allows it, and the
/// press is re-checked right before it happens (the menu is cancelled and the wait resumes
/// when the user became active in between).
struct ChatRoomMenuOpener {
    struct OpenedRoom {
        let window: UIElement
        /// The row's unread badge as read right before 채팅방 열기 was pressed.
        let unreadBefore: UnreadBadge
        /// KakaoTalk gave the window no title (open chats on 26.10.0); it was accepted as the
        /// only new window, after checking that it shows a chat.
        let windowTitleEmpty: Bool
        /// The window appeared after the press (it did not exist before), so this command
        /// opened it. False when 채팅방 열기 only brought up a window that was already open.
        let isNewWindow: Bool
    }

    /// AX messaging timeout for AXShowMenu / AXPress / AXCancel (the process default is 0.25 s).
    private static let menuMessagingTimeout: Float = 2.0
    /// AX messaging timeout for reading menu elements while the menu is tracking.
    private static let menuReadTimeout: Float = 1.0
    private static let popupMenuWindowLayer = 101

    /// Exit status for a row that opens something that is not a chat (OPEN_CHAT_LIST).
    static let notAChatExitCode: Int32 = 4

    let kakao: KakaoTalkApp
    let runner: AXActionRunner
    let activity: UserActivityGuard

    func open(_ row: LocatedChatRow, access: ChatListAccess, skipUnread: Bool) throws -> OpenedRoom {
        while true {
            try activity.waitUntilClear(.openChatRoom)
            if let opened = try openOnce(row, access: access, skipUnread: skipUnread) {
                return opened
            }
            // The user became active right before the press: the menu was cancelled; wait again.
        }
    }

    /// One attempt; nil when the user-activity re-check right before the press said no.
    private func openOnce(_ row: LocatedChatRow, access: ChatListAccess, skipUnread: Bool) throws -> OpenedRoom? {
        try ensureListIsShowing(access)
        try verify(row, skipUnread: skipUnread, stage: "before scrolling the list")

        let scrollState = try revealRow(row, access: access)
        defer { restoreListScroll(scrollState) }

        try verify(row, skipUnread: skipUnread, stage: "before showing the context menu")

        guard let cell = AXNodeReader.read(row.element).children.first else {
            throw ReadFailure(code: "MENU_UNAVAILABLE", message: "The chat-list row has no cell to show a context menu on.")
        }
        AXNodeReader.setMessagingTimeout(cell, seconds: Self.menuMessagingTimeout)

        try ReadInterruption.check("before showing the context menu")
        let windowsBefore = kakao.windows.map(\.axElement)
        let showStatus = AXNodeReader.perform(cell, "AXShowMenu")
        runner.log("read: AXShowMenu status=\(showStatus.rawValue)")

        guard let menu = waitForMenu(on: cell) else {
            let cancelled = cancelStrayMenus()
            throw ReadFailure(
                code: "MENU_UNAVAILABLE",
                message: "The chat-list context menu did not appear (AXShowMenu status \(showStatus.rawValue)).",
                hint: "Retry; if it keeps failing use --legacy-open while KakaoTalk is frontmost.",
                details: ["menus_cancelled": "\(cancelled)"]
            )
        }
        AXNodeReader.setMessagingTimeout(menu, seconds: Self.menuMessagingTimeout)

        let items = AXNodeReader.children(menu).map { element -> AXLiveNode in
            // Menu tracking can slow KakaoTalk's replies; the process-wide default is 0.25 s.
            AXNodeReader.setMessagingTimeout(element, seconds: Self.menuReadTimeout)
            return AXNodeReader.read(element)
        }
        guard let item = items.first(where: {
            MenuItemSafety.isOpenChatRoomItem(title: $0.snapshot.title, identifier: $0.snapshot.identifier)
        }) else {
            cancel(menu)
            let seen = items
                .map { "\($0.snapshot.identifier)=\($0.snapshot.title ?? "")" }
                .joined(separator: ", ")
            throw ReadFailure(
                code: "MENU_ITEM_MISSING",
                message: "The context menu has no '\(MenuItemSafety.openChatRoomTitle)' (\(MenuItemSafety.openChatRoomIdentifier)) item; the menu was cancelled.",
                details: ["menu_items": seen]
            )
        }
        guard !MenuItemSafety.isBlocked(title: item.snapshot.title, description: item.snapshot.desc, identifier: item.snapshot.identifier) else {
            cancel(menu)
            throw ReadFailure(code: "MENU_ITEM_BLOCKED", message: "Refused to press menu item '\(item.snapshot.title ?? "")'.")
        }

        let unreadBefore: UnreadBadge
        do {
            try ReadInterruption.check("before pressing \(MenuItemSafety.openChatRoomTitle)")
            unreadBefore = try verify(row, skipUnread: skipUnread, stage: "right before pressing \(MenuItemSafety.openChatRoomTitle)")
        } catch {
            cancel(menu)
            throw error
        }
        guard activity.mayPressNow(.openChatRoom) else {
            cancel(menu)
            return nil
        }

        AXNodeReader.setMessagingTimeout(item.element, seconds: Self.menuMessagingTimeout)
        let pressStatus = AXNodeReader.perform(item.element, kAXPressAction)
        runner.log("read: pressed \(MenuItemSafety.openChatRoomIdentifier) status=\(pressStatus.rawValue)")

        let opened = waitForChatWindow(title: row.title, windowsBefore: windowsBefore)
        if let window = opened.window {
            return OpenedRoom(window: window, unreadBefore: unreadBefore, windowTitleEmpty: opened.untitled, isNewWindow: opened.isNew)
        }

        if menuIsOpen(on: cell) {
            cancel(menu)
        }
        let details = closeWindowsOpenedByThePress(windowsBefore: windowsBefore)
        if let list = opened.openChatList {
            throw Self.openChatListFailure(row: row, list: list, rowCount: opened.listRowCount, details: details)
        }
        throw ReadFailure(
            code: "CHAT_WINDOW_NOT_OPENED",
            message: "No chat window for '\(row.title)' was recognised after pressing \(MenuItemSafety.openChatRoomTitle) (AXPress status \(pressStatus.rawValue)).",
            hint: "Retry, or check KakaoTalk for a dialog.",
            details: details
        )
    }

    /// The row opened KakaoTalk's list of 1:1 open-chat conversations instead of a chat.
    /// Nothing in that window was pressed; it has been closed with its own close button.
    static func openChatListFailure(row: LocatedChatRow, list: OpenChatList, rowCount: Int?, details: [String: String]) -> ReadFailure {
        let count = rowCount ?? list.conversations.count
        var details = details
        details["conversation_count"] = String(count)
        details["conversations"] = list.conversations
            .map { conversation in conversation.time.map { "\(conversation.title) (\($0))" } ?? conversation.title }
            .joined(separator: "\n")
        return ReadFailure(
            code: "OPEN_CHAT_LIST",
            message: "'\(row.title)' opens a list of \(count) 1:1 open-chat conversation(s), not a chat, so nothing was read.",
            hint: "Reading the conversations in that list is not supported; the list window was closed without pressing anything in it.",
            exitCode: notAChatExitCode,
            details: details
        )
    }

    /// Windows that exist now but did not before the press (never the main window).
    private func newWindows(since windowsBefore: [AXUIElement]) -> [UIElement] {
        kakao.windows.filter { window in
            window.identifier != ChatListLocator.mainWindowIdentifier
                && !windowsBefore.contains { CFEqual($0, window.axElement) }
        }
    }

    /// No window was accepted as the room. Every window that appeared after the press was
    /// opened by it, so each is closed with its own close button (titles are not checked:
    /// they may be empty). Returns the details for the error document.
    private func closeWindowsOpenedByThePress(windowsBefore: [AXUIElement]) -> [String: String] {
        let windows = newWindows(since: windowsBefore)
        guard !windows.isEmpty else { return [:] }
        // Labels first: a closed window can no longer be read.
        let labels = windows.map { OpenedWindowRule.label($0.title) }
        let closer = ChatWindowCloser(kakao: kakao, runner: runner)
        var closed: [String] = []
        var leftOpen: [String] = []
        for (window, label) in zip(windows, labels) {
            let outcome = closer.close(window, expectedTitle: nil)
            runner.log("read: unrecognised new window '\(label)' after the press: \(outcome.code)")
            if outcome == .closed {
                closed.append(label)
            } else {
                leftOpen.append("\(label) (\(outcome.code))")
            }
        }
        var details = ["unexpected_new_windows": labels.joined(separator: ", ")]
        if !closed.isEmpty {
            details["closed_new_windows"] = closed.joined(separator: ", ")
        }
        if !leftOpen.isEmpty {
            details["left_open_windows"] = leftOpen.joined(separator: ", ")
        }
        return details
    }

    // MARK: Verification

    /// Returns the row's current unread badge.
    @discardableResult
    private func verify(_ row: LocatedChatRow, skipUnread: Bool, stage: String) throws -> UnreadBadge {
        let summary = ChatListScanner.summarize(row: row.element)
        let currentTitle = ChatListLocator.trimmed(summary.title)
        // Exact comparison: rooms whose titles differ only in emoji or punctuation must not pass.
        guard currentTitle == ChatListLocator.trimmed(row.title) else {
            throw ReadFailure(
                code: "ROW_CHANGED",
                message: "The chat list changed \(stage): row \(row.index) is now '\(currentTitle)', not '\(row.title)'.",
                hint: "Retry; the list reorders when new messages arrive."
            )
        }
        if summary.unread.isUnread, skipUnread {
            throw Self.unreadRefusal(title: row.title, badge: summary.unread)
        }
        return summary.unread
    }

    static func unreadRefusal(title: String, badge: UnreadBadge) -> ReadFailure {
        if badge == .unknown(ChatRowAnalyzer.incompleteReadEvidence) {
            return ReadFailure(
                code: "UNREAD_UNVERIFIED",
                message: "'\(title)': the chat-list row could not be read completely, so an unread badge cannot be ruled out; --skip-unread does not open such rooms.",
                hint: "Retry, or run without --skip-unread (opening sends read receipts if there are unread messages).",
                exitCode: ReadFailure.refusedExitCode
            )
        }
        return ReadFailure(
            code: "UNREAD_REFUSED",
            message: "'\(title)' shows unread messages (\(badge.evidence ?? "badge")); --skip-unread does not open it because that would send read receipts.",
            hint: "Run without --skip-unread to open it; that sends read receipts like opening it by hand.",
            exitCode: ReadFailure.refusedExitCode,
            details: ["unread_before": badge.evidence ?? ""]
        )
    }

    private func ensureListIsShowing(_ access: ChatListAccess) throws {
        if AXNodeReader.boolAttribute(access.window.axElement, kAXMinimizedAttribute) == true {
            throw ReadFailure(
                code: "MAIN_WINDOW_MINIMIZED",
                message: "KakaoTalk's main window is minimized, so its chat list cannot show a context menu.",
                hint: "Restore the KakaoTalk window (it may stay in the background) and retry."
            )
        }
        if AXNodeReader.boolAttribute(kakao.applicationElement.axElement, kAXHiddenAttribute) == true {
            throw ReadFailure(
                code: "KAKAO_HIDDEN",
                message: "KakaoTalk is hidden, so its chat list cannot show a context menu.",
                hint: "Unhide KakaoTalk (it may stay in the background) and retry."
            )
        }
    }

    // MARK: List scrolling

    private struct ListScrollState {
        let scrollBar: AXUIElement
        let originalValue: Double
    }

    /// Makes the row visible inside the list's scroll area by setting the vertical scroll bar's
    /// AXValue (AXScrollToVisible is unsupported). A context menu for an off-screen row would
    /// open at the screen edge.
    private func revealRow(_ row: LocatedChatRow, access: ChatListAccess) throws -> ListScrollState? {
        let visibleFrame = access.scrollArea.flatMap(AXNodeReader.frame) ?? access.window.frame
        guard let visibleFrame else {
            throw rowNotVisible(row, detail: "the list frame is unavailable")
        }
        if let rowFrame = AXNodeReader.frame(row.element),
           ListScrollMath.isRowVisible(rowFrame: rowFrame, visibleFrame: visibleFrame)
        {
            return nil
        }

        guard
            let scrollArea = access.scrollArea,
            let scrollBar = AXNodeReader.elementAttribute(scrollArea, kAXVerticalScrollBarAttribute),
            let originalValue = AXNodeReader.doubleValue(scrollBar),
            let tableFrame = AXNodeReader.frame(access.table),
            let rowFrame = AXNodeReader.frame(row.element)
        else {
            throw rowNotVisible(row, detail: "the list cannot be scrolled through Accessibility")
        }

        let target = ListScrollMath.scrollValueCentering(rowFrame: rowFrame, tableFrame: tableFrame, visibleFrame: visibleFrame)
        let status = AXNodeReader.setNumber(scrollBar, kAXValueAttribute, target)
        runner.log("read: list scroll \(String(format: "%.3f", originalValue)) -> \(String(format: "%.3f", target)) status=\(status.rawValue)")

        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.03)
            if let frame = AXNodeReader.frame(row.element),
               ListScrollMath.isRowVisible(rowFrame: frame, visibleFrame: visibleFrame)
            {
                return ListScrollState(scrollBar: scrollBar, originalValue: originalValue)
            }
        }

        AXNodeReader.setNumber(scrollBar, kAXValueAttribute, originalValue)
        throw rowNotVisible(row, detail: "the row stayed outside the visible list after scrolling")
    }

    private func restoreListScroll(_ state: ListScrollState?) {
        guard let state else { return }
        let status = AXNodeReader.setNumber(state.scrollBar, kAXValueAttribute, state.originalValue)
        runner.log("read: list scroll restored to \(String(format: "%.3f", state.originalValue)) status=\(status.rawValue)")
    }

    private func rowNotVisible(_ row: LocatedChatRow, detail: String) -> ReadFailure {
        ReadFailure(
            code: "ROW_NOT_VISIBLE",
            message: "Row \(row.index) ('\(row.title)') could not be made visible: \(detail). The context menu was not shown.",
            hint: "Make the KakaoTalk main window larger or scroll the chat list, then retry."
        )
    }

    // MARK: Menu

    private func waitForMenu(on cell: AXUIElement) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            if let menu = menuChild(of: cell) {
                return menu
            }
            Thread.sleep(forTimeInterval: 0.025)
        } while Date() < deadline && !ReadInterruption.requested
        return nil
    }

    private func menuChild(of cell: AXUIElement) -> AXUIElement? {
        AXNodeReader.children(cell).reversed().first { child in
            AXNodeReader.setMessagingTimeout(child, seconds: Self.menuReadTimeout)
            return AXNodeReader.read(child).snapshot.role == AXRoleName.menu
        }
    }

    private func menuIsOpen(on cell: AXUIElement) -> Bool {
        menuChild(of: cell) != nil
    }

    private func cancel(_ menu: AXUIElement) {
        let status = AXNodeReader.perform(menu, kAXCancelAction)
        runner.log("read: context menu cancelled status=\(status.rawValue)")
    }

    /// The menu was not found under the cell: cancel any KakaoTalk menu that is open anyway
    /// (an application-level AXMenu child, or an on-screen popup-menu window owned by KakaoTalk,
    /// located by hit-testing its center). Only AXCancel is ever performed.
    private func cancelStrayMenus() -> Int {
        var cancelled = 0
        let application = kakao.applicationElement.axElement
        for child in AXNodeReader.children(application) where AXNodeReader.read(child).snapshot.role == AXRoleName.menu {
            cancel(child)
            cancelled += 1
        }

        guard let pid = AXNodeReader.pid(of: application),
              let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else {
            return cancelled
        }

        let systemWide = AXUIElementCreateSystemWide()
        for info in windowList {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == Self.popupMenuWindowLayer,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else {
                continue
            }

            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(bounds.midX), Float(bounds.midY), &hit) == .success,
                  var cursor = hit
            else {
                continue
            }
            var hops = 0
            while AXNodeReader.read(cursor).snapshot.role != AXRoleName.menu, hops < 6,
                  let parent = AXNodeReader.elementAttribute(cursor, kAXParentAttribute)
            {
                cursor = parent
                hops += 1
            }
            if AXNodeReader.read(cursor).snapshot.role == AXRoleName.menu, AXNodeReader.pid(of: cursor) == pid {
                cancel(cursor)
                cancelled += 1
            }
        }
        return cancelled
    }

    // MARK: Opened window

    private struct WaitResult {
        var window: UIElement?
        var untitled = false
        var isNew = false
        /// The single new untitled window is the open-chat conversation list.
        var openChatList: OpenChatList?
        var listRowCount: Int?
    }

    /// Waits for the room's window (see `OpenedWindowRule`): a window titled for the row, or
    /// the single new window, also when it is untitled as long as it shows a chat. Team chats
    /// ("팀채팅, …"), the self chat and open chats ("오픈채팅, …") open windows titled without
    /// the room-type prefix; open chats may open one with an empty title. Some "오픈채팅, …"
    /// rows open an untitled list of 1:1 conversations instead: recognised, the wait stops at once.
    private func waitForChatWindow(
        title: String,
        windowsBefore: [AXUIElement],
        timeout: TimeInterval = 3.0
    ) -> WaitResult {
        let locator = ChatListLocator(kakao: kakao, runner: runner)
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            let windows = kakao.windows.filter { $0.identifier != ChatListLocator.mainWindowIdentifier }
            var candidates = windows.map { window in
                OpenedWindowCandidate(
                    title: window.title,
                    isNew: !windowsBefore.contains { CFEqual($0, window.axElement) }
                )
            }
            // The content check costs AX reads; only an untitled single new window needs it.
            if let index = OpenedWindowRule.untitledNewWindow(in: candidates) {
                let classified = locator.classifyWindow(windows[index])
                switch classified.kind {
                case .chat:
                    candidates[index].isChatWindow = true
                case .openChatList(let list):
                    runner.log("read: the new untitled window is an open-chat list of \(classified.rowCount ?? list.conversations.count) conversation(s)")
                    return WaitResult(openChatList: list, listRowCount: classified.rowCount)
                case .unknown:
                    candidates[index].isChatWindow = false
                }
            }
            switch OpenedWindowRule.match(rowTitle: title, candidates: candidates) {
            case .titled(let index):
                if candidates[index].isNew, !RoomTitle.windowMatchesRow(windowTitle: candidates[index].title, rowTitle: title) {
                    runner.log("read: accepting new window '\(candidates[index].title ?? "")' for row title '\(title)'")
                }
                return WaitResult(window: windows[index], isNew: candidates[index].isNew)
            case .untitled(let index):
                runner.log("read: accepting the only new window, untitled but showing a chat, for row title '\(title)'")
                return WaitResult(window: windows[index], untitled: true, isNew: true)
            case .none:
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline && !ReadInterruption.requested

        return WaitResult()
    }
}
