import CoreGraphics
import Foundation
import KktcliCore

/// Brings KakaoTalk's main window back only when that switches neither the user's app nor
/// desktop (`MainWindowPolicy`): KakaoTalk is already frontmost, or the caller passed
/// --allow-activate. Each 카카오톡 열기 press first waits for an idle user
/// (`UserActivityGuard`) and is re-checked right before the press.
struct MainWindowAccess {
    enum ReopenOutcome {
        /// The main window was there after all (found on the patient re-check); nothing pressed.
        case alreadyVisible(UIElement)
        case pressed
        /// The menu item was unavailable or the press failed.
        case unavailable
    }

    let runner: AXActionRunner
    let activity: UserActivityGuard
    let allowActivate: Bool

    /// The main window is looked for again first (`ChatListLocator.confirmMainWindow`: a few
    /// hundred ms, longer AX timeouts), so a transient read failure never leads to a press.
    /// Then 카카오톡 열기 is pressed when the policy allows it, and only while the main window
    /// is still missing right before the press; MAIN_WINDOW_NOT_VISIBLE (nothing pressed) when
    /// the policy does not allow it.
    func reopen(kakao: KakaoTalkApp, locator: ChatListLocator) throws -> ReopenOutcome {
        if let main = locator.confirmMainWindow() {
            return .alreadyVisible(main)
        }
        let evidence = KakaoTalkInputGuard.shared.currentEvidence()
        let frontmost = FrontmostPolicy.keyboard(evidence).allowed
        guard MainWindowPolicy.decide(kakaoTalkFrontmost: frontmost, allowActivate: allowActivate) == .reopen else {
            throw notVisible(kakao: kakao, kakaoPID: evidence.kakaoPID, frontmost: frontmost)
        }
        while true {
            try activity.waitUntilClear(.showMainWindow)
            if let main = locator.mainWindow() {
                return .alreadyVisible(main)
            }
            let press = locator.pressShowMainWindowMenuItem(beforePress: {
                locator.mainWindow() == nil && activity.mayPressNow(.showMainWindow)
            })
            switch press {
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

    func notVisible(kakao: KakaoTalkApp?, kakaoPID: Int32?, frontmost: Bool) -> ReadFailure {
        var details = [
            "kakao_frontmost": String(frontmost),
            "ax_window_count": String(kakao?.windows.count ?? 0),
        ]
        if let kakaoPID {
            let counts = MainWindowPolicy.windowCounts(Self.windowServerEntries(), kakaoPID: kakaoPID)
            details["cg_layer0_window_count"] = String(counts.total)
            details["cg_layer0_offscreen_count"] = String(counts.offscreen)
        }
        runner.log("main window: not visible and not reopened (\(details))")
        return ReadFailure(
            code: "MAIN_WINDOW_NOT_VISIBLE",
            message: "KakaoTalk's main window is not visible to Accessibility and KakaoTalk is not the frontmost app, so \(MainWindowMenuItem.title) was not pressed: it would bring KakaoTalk to the front and may switch desktops.",
            hint: "The main window is closed, minimised, or on another desktop or full-screen Space. Show KakaoTalk on this desktop, or rerun with --allow-activate, which brings KakaoTalk to the front and may switch desktops.",
            details: details
        )
    }

    /// All windows the window server knows (`.optionAll`), owner, layer and on-screen state only.
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
            return WindowServerEntry(ownerPID: pid, layer: layer, isOnscreen: onscreen)
        }
    }
}
