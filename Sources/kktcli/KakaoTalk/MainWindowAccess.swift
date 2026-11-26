import CoreGraphics
import Foundation
import KktcliCore

/// Gets hold of KakaoTalk's main window without switching the user's app or desktop
/// (`MainWindowLookup`):
///
/// 1. kAXWindows, looked at again for a moment (a busy KakaoTalk can fail one read);
/// 2. the window by element id when it is on another desktop or Space (read-only);
/// 3. when the window server shows no main window at all (it is closed), KakaoTalk's own
///    창 > 채팅 (⌘2) menu item, which opens it on the current desktop without activating
///    KakaoTalk; guarded like 채팅방 열기 (`UserActivityGuard`, re-checked right before);
/// 4. 카카오톡 열기, which activates KakaoTalk, only with --allow-activate (then
///    `open KakaoTalk.app` with --deep-recovery);
/// 5. otherwise MAIN_WINDOW_NOT_VISIBLE, with what each step saw.
struct MainWindowAccess {
    let runner: AXActionRunner
    let activity: UserActivityGuard
    let allowActivate: Bool

    func resolve(locator: ChatListLocator, allowOpenCommand: Bool) throws -> (window: UIElement, action: ChatListLocator.MainWindowAction?) {
        let lookup = locator.windowLookup
        if let main = locator.mainWindow() {
            return (main, lookup.isListed(main) ? nil : .otherDesktop)
        }
        // A transient read failure must never lead to a press.
        if let main = locator.confirmMainWindow() {
            return (main, nil)
        }

        var scan: KakaoWindowLookup.ScanResult?
        if KakaoWindowLookup.scanAvailable {
            let result = lookup.scanForMainWindow()
            scan = result
            if let main = result.mainWindow {
                return (main.element, .otherDesktop)
            }
        }

        let windowServer = lookup.windowServerCheck(knownWindows: scan?.otherWindows.map(\.element) ?? [])
        let steps = MainWindowLookup.fallbacks(
            windowServerShowsNoMainWindow: windowServer?.showsNoMainWindow ?? false,
            allowActivate: allowActivate
        )
        var pressed: [String] = []
        for step in steps {
            switch step {
            case .windowMenu:
                switch try pressWindowMenu(locator: locator) {
                case .alreadyVisible(let main):
                    return (main, nil)
                case .pressed:
                    pressed.append("창 > \(ChatTabMenu.title)")
                    if let main = locator.waitForMainWindow(timeout: 3.0) {
                        return (main, .openedViaWindowMenu)
                    }
                case .unavailable:
                    break
                }
            case .showMainWindowItem:
                switch try pressShowMainWindowItem(locator: locator) {
                case .alreadyVisible(let main):
                    return (main, nil)
                case .pressed:
                    pressed.append(MainWindowMenuItem.title)
                    if let main = locator.waitForMainWindow(timeout: 3.0) {
                        return (main, .openedViaMenuItem)
                    }
                case .unavailable:
                    break
                }
                if allowOpenCommand {
                    runner.log("main window: still missing; reopening it via open KakaoTalk.app")
                    try forceOpen()
                    pressed.append("open KakaoTalk.app")
                    if let main = locator.waitForMainWindow(timeout: 3.0) {
                        return (main, .openedViaOpenCommand)
                    }
                }
            case .notVisible:
                if !pressed.isEmpty {
                    throw ReadFailure(
                        code: "WINDOW_NOT_READY",
                        message: "[WINDOW_NOT_READY] KakaoTalk's main window did not appear after \(pressed.joined(separator: ", ")).",
                        hint: "Open KakaoTalk's main window on the 채팅 tab and retry.",
                        details: ["pressed": pressed.joined(separator: ", ")]
                    )
                }
                throw notVisible(kakao: locator.kakao, lookup: lookup, scan: scan, windowServer: windowServer)
            case .accessibilityWindows, .elementIDScan:
                break
            }
        }
        throw notVisible(kakao: locator.kakao, lookup: lookup, scan: scan, windowServer: windowServer)
    }

    enum PressOutcome {
        /// The main window was there after all; nothing was pressed.
        case alreadyVisible(UIElement)
        case pressed
        /// The menu item was unavailable or the press failed.
        case unavailable
    }

    /// 창 > 채팅 with the main window closed: waits like 채팅방 열기 (it opens a window that may
    /// become key, but does not activate KakaoTalk) and re-checks right before the press that
    /// the main window is still missing.
    private func pressWindowMenu(locator: ChatListLocator) throws -> PressOutcome {
        while true {
            try activity.waitUntilClear(.reopenViaWindowMenu)
            if let main = locator.mainWindow() {
                return .alreadyVisible(main)
            }
            switch locator.pressChatTabMenuItem(beforePress: {
                locator.mainWindow() == nil && activity.mayPressNow(.reopenViaWindowMenu)
            }) {
            case .pressed:
                return .pressed
            case .unavailable:
                return .unavailable
            case .deferred:
                continue
            }
        }
    }

    /// 카카오톡 열기 (activates KakaoTalk; --allow-activate only): waits for an idle user and is
    /// re-checked right before the press.
    private func pressShowMainWindowItem(locator: ChatListLocator) throws -> PressOutcome {
        while true {
            try activity.waitUntilClear(.showMainWindow)
            if let main = locator.mainWindow() {
                return .alreadyVisible(main)
            }
            switch locator.pressShowMainWindowMenuItem(beforePress: {
                locator.mainWindow() == nil && activity.mayPressNow(.showMainWindow)
            }) {
            case .pressed:
                return .pressed
            case .unavailable:
                return .unavailable
            case .deferred:
                continue
            }
        }
    }

    /// `open KakaoTalk.app` (--deep-recovery) activates KakaoTalk too: same idle wait and re-check.
    func forceOpen() throws {
        while true {
            try activity.waitUntilClear(.showMainWindow)
            if activity.mayPressNow(.showMainWindow) {
                _ = KakaoTalkApp.forceOpen(timeout: 1.0)
                return
            }
        }
    }

    func notVisible(
        kakao: KakaoTalkApp?,
        lookup: KakaoWindowLookup? = nil,
        scan: KakaoWindowLookup.ScanResult? = nil,
        windowServer: KakaoWindowLookup.WindowServerCheck? = nil
    ) -> ReadFailure {
        let evidence = KakaoTalkInputGuard.shared.currentEvidence()
        var details = [
            "kakao_frontmost": String(FrontmostPolicy.keyboard(evidence).allowed),
            "ax_window_count": String(kakao?.windows.count ?? 0),
            "element_id_scan": KakaoWindowLookup.scanAvailable ? (scan?.summary ?? "not run") : "unavailable",
        ]
        if let kakaoPID = evidence.kakaoPID {
            let counts = MainWindowPolicy.windowCounts(Self.windowServerEntries(), kakaoPID: kakaoPID)
            details["cg_layer0_window_count"] = String(counts.total)
            details["cg_layer0_offscreen_count"] = String(counts.offscreen)
        }
        if let windowServer {
            details["cg_unaccounted_window_count"] = String(windowServer.unaccounted)
        }
        runner.log("main window: not found and not opened (\(details))")
        let found = scan == nil
            ? "KakaoTalk's main window is not visible to Accessibility (closed, minimised, or on another desktop or Space; windows there cannot be looked up by id on this system)"
            : "KakaoTalk's main window was not found on this or another desktop"
        return ReadFailure(
            code: "MAIN_WINDOW_NOT_VISIBLE",
            message: "\(found), and the window server shows a KakaoTalk window kktcli cannot reach, so nothing was pressed: 창 > 채팅 is used only when the main window is closed, and 카카오톡 열기 would bring KakaoTalk to the front and may switch desktops.",
            hint: "Show KakaoTalk's main window, or rerun with --allow-activate, which brings KakaoTalk to the front and may switch desktops.",
            details: details
        )
    }

    /// All windows the window server knows (`.optionAll`): owner, layer, on-screen state and
    /// bounds only (names would need Screen Recording).
    static func windowServerEntries() -> [WindowServerEntry] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
            else {
                return nil
            }
            let onscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let frame = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return WindowServerEntry(ownerPID: pid, layer: layer, isOnscreen: onscreen, frame: frame)
        }
    }
}
