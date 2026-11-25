import ApplicationServices.HIServices
import CoreGraphics
import Foundation
import KmsgCore

/// Opens a chat-list row through its context menu using Accessibility actions only:
/// scroll the list (scroll-bar AXValue) until the row is visible, AXShowMenu on the row's
/// cell, then AXPress on the single item identified as `openChatRoom:` / "채팅방 열기".
/// No keyboard or mouse events are posted, so KakaoTalk may stay in the background.
///
/// The row is re-verified (title unchanged, no unread badge) before scrolling, before the
/// menu is shown and right before the press. Any other outcome cancels the menu (AXCancel);
/// nothing else is ever pressed.
struct ChatRoomMenuOpener {
    /// AX messaging timeout for AXShowMenu / AXPress / AXCancel (the process default is 0.25 s).
    private static let menuMessagingTimeout: Float = 2.0
    /// AX messaging timeout for reading menu elements while the menu is tracking.
    private static let menuReadTimeout: Float = 1.0
    private static let popupMenuWindowLayer = 101

    let kakao: KakaoTalkApp
    let runner: AXActionRunner

    func open(_ row: LocatedChatRow, access: ChatListAccess, allowUnread: Bool) throws -> UIElement {
        try ensureListIsShowing(access)
        try verify(row, allowUnread: allowUnread, stage: "before scrolling the list")

        let scrollState = try revealRow(row, access: access)
        defer { restoreListScroll(scrollState) }

        try verify(row, allowUnread: allowUnread, stage: "before showing the context menu")

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

        do {
            try ReadInterruption.check("before pressing \(MenuItemSafety.openChatRoomTitle)")
            try verify(row, allowUnread: allowUnread, stage: "right before pressing \(MenuItemSafety.openChatRoomTitle)")
        } catch {
            cancel(menu)
            throw error
        }

        AXNodeReader.setMessagingTimeout(item.element, seconds: Self.menuMessagingTimeout)
        let pressStatus = AXNodeReader.perform(item.element, kAXPressAction)
        runner.log("read: pressed \(MenuItemSafety.openChatRoomIdentifier) status=\(pressStatus.rawValue)")

        let opened = waitForChatWindow(title: row.title, windowsBefore: windowsBefore)
        if let window = opened.window {
            return window
        }

        if menuIsOpen(on: cell) {
            cancel(menu)
        }
        var details: [String: String] = [:]
        if !opened.newWindowTitles.isEmpty {
            // Left open on purpose: it cannot be proven that this command opened them.
            details["unexpected_new_windows"] = opened.newWindowTitles.joined(separator: ", ")
        }
        throw ReadFailure(
            code: "CHAT_WINDOW_NOT_OPENED",
            message: "No chat window titled '\(row.title)' appeared after pressing \(MenuItemSafety.openChatRoomTitle) (AXPress status \(pressStatus.rawValue)).",
            hint: "Retry, or check KakaoTalk for a dialog.",
            details: details
        )
    }

    // MARK: Verification

    private func verify(_ row: LocatedChatRow, allowUnread: Bool, stage: String) throws {
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
        if summary.unread.isUnread, !allowUnread {
            throw Self.unreadRefusal(title: row.title, badge: summary.unread)
        }
    }

    static func unreadRefusal(title: String, badge: UnreadBadge) -> ReadFailure {
        if badge == .unknown(ChatRowAnalyzer.incompleteReadEvidence) {
            return ReadFailure(
                code: "UNREAD_UNVERIFIED",
                message: "'\(title)': the chat-list row could not be read completely, so an unread badge cannot be ruled out; opening it could send read receipts.",
                hint: "Retry, or pass --allow-unread to open it anyway.",
                exitCode: ReadFailure.refusedExitCode
            )
        }
        return ReadFailure(
            code: "UNREAD_REFUSED",
            message: "'\(title)' shows unread messages (\(badge.evidence ?? "badge")); opening it would send read receipts.",
            hint: "Pass --allow-unread to open it anyway.",
            exitCode: ReadFailure.refusedExitCode,
            details: ["unread_badge": badge.evidence ?? ""]
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

    private func waitForChatWindow(
        title: String,
        windowsBefore: [AXUIElement],
        timeout: TimeInterval = 3.0
    ) -> (window: UIElement?, newWindowTitles: [String]) {
        // Team chats ("팀채팅, …") and the self chat ("나와의 채팅, …") open a window titled
        // without that room-type prefix, so compare against the expected window title.
        let target = ChatTextNormalizer.normalize(RoomTitle.expectedWindowTitle(forRowTitle: title))
        let deadline = Date().addingTimeInterval(timeout)
        var newWindows: [UIElement] = []

        repeat {
            let windows = kakao.windows.filter { $0.identifier != ChatListLocator.mainWindowIdentifier }
            if let match = windows.first(where: { RoomTitle.windowMatchesRow(windowTitle: $0.title, rowTitle: title) }) {
                return (match, [])
            }
            newWindows = windows.filter { window in
                !windowsBefore.contains { CFEqual($0, window.axElement) }
            }
            // A single window that appeared after the press is the room that was just opened when
            // its title differs only by an unlisted room-type label, spacing or punctuation.
            if newWindows.count == 1, let window = newWindows.first,
               RoomTitle.openedWindowMatchesRow(windowTitle: window.title, rowTitle: title)
                || ChatTextNormalizer.normalize(window.title ?? "") == target
            {
                runner.log("read: accepting new window '\(window.title ?? "")' for row title '\(title)'")
                return (window, [])
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline && !ReadInterruption.requested

        return (nil, newWindows.map { $0.title ?? "(untitled)" })
    }
}
