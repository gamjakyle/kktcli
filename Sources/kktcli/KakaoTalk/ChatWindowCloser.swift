import ApplicationServices.HIServices
import Foundation
import KktcliCore

/// Closes a KakaoTalk window by pressing its own AXCloseButton (KakaoTalk windows support no
/// AXClose) and waits until it is gone. There is deliberately no other fallback: guessing "the
/// first button in the window" could hit a banner or profile button, and Cmd-W goes to
/// whatever window is key. A window without a close button is left open and reported.
struct ChatWindowCloser {
    let kakao: KakaoTalkApp
    let runner: AXActionRunner

    /// - Parameter expectedTitle: when given, the window must still show this title; nil skips
    ///   the check (windows this command provably opened, including untitled ones).
    func close(_ window: UIElement, expectedTitle: String?) -> WindowCloseOutcome {
        if let expectedTitle {
            let currentTitle = window.title ?? ""
            guard currentTitle.trimmingCharacters(in: .whitespacesAndNewlines) == expectedTitle.trimmingCharacters(in: .whitespacesAndNewlines) else {
                runner.log("close window: title '\(currentTitle)' does not match '\(expectedTitle)'; leaving it open")
                return .titleMismatch(currentTitle)
            }
        }
        if window.identifier == ChatListLocator.mainWindowIdentifier {
            runner.log("close window: refusing to close KakaoTalk's main window")
            return .refusedMainWindow
        }

        guard let closeButton = AXNodeReader.elementAttribute(window.axElement, kAXCloseButtonAttribute) else {
            runner.log("close window: no AXCloseButton; leaving the window open")
            return .closeButtonMissing
        }

        let lookup = KakaoWindowLookup(kakao: kakao, runner: runner)
        let wasListed = lookup.isListed(window)
        let status = AXNodeReader.perform(closeButton, kAXPressAction)
        if waitForWindowClosed(window, lookup: lookup, wasListed: wasListed) {
            return .closed
        }
        if status != .success {
            runner.log("close window: AXCloseButton press failed (AXError \(status.rawValue))")
            return .pressFailed(status.rawValue)
        }
        return .stillOpen
    }

    /// Gone from kAXWindows; a window on another desktop (never listed there) is gone when its
    /// element stops answering.
    private func waitForWindowClosed(_ window: UIElement, lookup: KakaoWindowLookup, wasListed: Bool) -> Bool {
        runner.waitUntil(label: "close via AXCloseButton", timeout: 0.9, pollInterval: 0.06, evaluateAfterTimeout: false) {
            !lookup.exists(window, wasListed: wasListed)
        }
    }
}
