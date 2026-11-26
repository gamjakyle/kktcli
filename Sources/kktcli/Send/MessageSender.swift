import AppKit
import ApplicationServices.HIServices
import Foundation
import KktcliCore

/// Puts the text into the open chat window's input (`_NS:51`) with AXValue, checks
/// it, and presses the window's own "전송" button (`SendButtonSafety`) once; then checks that
/// a new outgoing bubble with that text appears. Nothing else is pressed. When the button
/// stays missing or disabled the input is cleared again and nothing is sent, unless
/// `allowActivate` permits the Enter fallback (KakaoTalk is brought to the front, Enter goes
/// through `KakaoTalkInputGuard`, and the previously frontmost app is brought back).
struct MessageSender {
    struct Outcome {
        var bubbleVerified: Bool
        var method: String
    }

    let session: RoomSession
    let allowActivate: Bool

    private var runner: AXActionRunner { session.runner }

    func send(_ text: String, in opened: RoomSession.Opened, tailBefore: [TranscriptItem]) throws -> Outcome {
        guard let input = findInput(in: opened.window) else {
            throw Self.failure("SEND_INPUT_UNAVAILABLE", "The chat window has no message input (_NS:51); nothing was sent.")
        }
        let draft = currentValue(input)
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Self.failure("SEND_INPUT_NOT_EMPTY", "The room's input box holds unsent text; it was left as it is and nothing was sent.", hint: "Send or clear that draft in KakaoTalk first.")
        }

        guard setValue(text, on: input) else {
            let cleared = clear(input)
            throw Self.failure("SEND_INPUT_REJECTED", "The text could not be put into the input box; nothing was sent.", details: ["input_cleared": String(cleared)])
        }

        guard let button = waitForEnabledSendButton(in: opened.window) else {
            if allowActivate {
                return try enterFallback(text, input: input, opened: opened, tailBefore: tailBefore)
            }
            let cleared = clear(input)
            throw Self.failure(
                "SEND_BUTTON_UNAVAILABLE",
                "The room's 전송 button is missing or stayed disabled after the text was set; the input was cleared and nothing was sent.",
                hint: "--allow-activate permits an Enter fallback, which brings KakaoTalk to the front.",
                details: ["input_cleared": String(cleared)]
            )
        }

        // Re-verified right before the press: the same window still shows the same room, the
        // input still holds exactly the text and the button is still the enabled 전송 button.
        let node = AXNodeReader.read(button).snapshot
        guard session.stillShows(opened),
              SendText.exact(currentValue(input)) == text,
              SendButtonSafety.isSendButton(role: node.role, title: node.title, description: node.desc),
              AXNodeReader.boolAttribute(button, kAXEnabledAttribute) == true
        else {
            let cleared = clear(input)
            throw Self.failure("SEND_UNVERIFIED", "The input or the 전송 button changed right before the press; the input was cleared and nothing was sent.", details: ["input_cleared": String(cleared)])
        }
        AXNodeReader.setMessagingTimeout(button, seconds: 2.0)
        let status = AXNodeReader.perform(button, kAXPressAction)
        runner.log("send: pressed 전송 status=\(status.rawValue)")
        return try verify(text, input: input, opened: opened, tailBefore: tailBefore, method: "chat_list_menu + AXValue + 전송 button")
    }

    // MARK: Input and button

    private func findInput(in window: UIElement) -> AXUIElement? {
        AXNodeReader.firstDescendant(of: window.axElement, maxNodes: 600) {
            $0.snapshot.role == AXRoleName.textArea && $0.snapshot.identifier == ChatListLocator.messageInputIdentifier
        }?.element
    }

    private func findSendButton(in window: UIElement) -> AXUIElement? {
        AXNodeReader.firstDescendant(of: window.axElement, maxNodes: 600) {
            SendButtonSafety.isSendButton(role: $0.snapshot.role, title: $0.snapshot.title, description: $0.snapshot.desc)
        }?.element
    }

    private func waitForEnabledSendButton(in window: UIElement) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            if let button = findSendButton(in: window), AXNodeReader.boolAttribute(button, kAXEnabledAttribute) == true {
                return button
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        runner.log("send: 전송 button missing or disabled")
        return nil
    }

    private func currentValue(_ input: AXUIElement) -> String {
        AXNodeReader.read(input).snapshot.value ?? ""
    }

    private func setValue(_ text: String, on input: AXUIElement) -> Bool {
        let status = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, text as CFString)
        runner.log("send: set input AXValue status=\(status.rawValue)")
        let deadline = Date().addingTimeInterval(0.8)
        repeat {
            if SendText.exact(currentValue(input)) == text {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    /// Leaves no text behind; true when the input is empty afterwards.
    @discardableResult
    private func clear(_ input: AXUIElement) -> Bool {
        _ = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, "" as CFString)
        Thread.sleep(forTimeInterval: 0.1)
        let empty = currentValue(input).isEmpty
        runner.log("send: input cleared=\(empty)")
        return empty
    }

    // MARK: Verification

    private func verify(_ text: String, input: AXUIElement, opened: RoomSession.Opened, tailBefore: [TranscriptItem], method: String) throws -> Outcome {
        let deadline = Date().addingTimeInterval(3.0)
        repeat {
            Thread.sleep(forTimeInterval: 0.25)
            let now = session.tail(of: opened.window, limit: 6, justOpened: false)
            if SendVerification.bubbleSent(text: text, before: tailBefore, after: now) {
                return Outcome(bubbleVerified: true, method: method)
            }
        } while Date() < deadline

        let stillThere = SendText.exact(currentValue(input)) == text
        if stillThere {
            let cleared = clear(input)
            throw Self.failure("SEND_UNVERIFIED", "No new bubble with the text appeared and the text was still in the input box, so it was not sent; the input was cleared.", details: ["input_cleared": String(cleared), "probably_sent": "false"])
        }
        throw Self.failure(
            "SEND_UNVERIFIED",
            "KakaoTalk took the text from the input box, but no new outgoing bubble with exactly this text was found. It was probably sent: check the room before doing anything else, and do not send it again.",
            details: ["probably_sent": "true"]
        )
    }

    // MARK: Enter fallback (--allow-activate only)

    private func enterFallback(_ text: String, input: AXUIElement, opened: RoomSession.Opened, tailBefore: [TranscriptItem]) throws -> Outcome {
        runner.log("send: 전송 button unavailable; Enter fallback (--allow-activate)")
        let previous = KakaoTalkInputGuard.shared.currentEvidence().focusedApplicationPID
            .flatMap { NSRunningApplication(processIdentifier: $0) }
        defer {
            if let previous, previous.bundleIdentifier != KakaoTalkApp.bundleIdentifier {
                previous.activate(options: [])
            }
        }
        session.kakao.activate()
        _ = AXNodeReader.perform(opened.window.axElement, kAXRaiseAction)
        _ = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let deadline = Date().addingTimeInterval(1.5)
        while !KakaoTalkInputGuard.shared.isKakaoTalkFrontmost(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard SendText.exact(currentValue(input)) == text, runner.pressEnterKey() else {
            let cleared = clear(input)
            throw Self.failure("SEND_BUTTON_UNAVAILABLE", "KakaoTalk could not be verified in front for the Enter fallback; the input was cleared and nothing was sent.", details: ["input_cleared": String(cleared)])
        }
        return try verify(text, input: input, opened: opened, tailBefore: tailBefore, method: "chat_list_menu + AXValue + Enter (--allow-activate)")
    }

    static func failure(_ code: String, _ message: String, hint: String? = nil, details: [String: String] = [:]) -> ReadFailure {
        ReadFailure(code: code, message: message, hint: hint, exitCode: KktcliExitStatus.sendUnverified, details: details)
    }
}
