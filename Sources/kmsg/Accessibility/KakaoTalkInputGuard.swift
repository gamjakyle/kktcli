import AppKit
import ApplicationServices.HIServices
import Foundation
import KmsgCore

/// Gate in front of every CGEvent kmsg posts to the HID tap.
///
/// Keyboard events go to whichever app is frontmost and clicks to whatever window is under
/// the pointer. When kmsg runs from a background process, `NSRunningApplication.activate`
/// can report success without bringing KakaoTalk forward, so keystrokes (including search
/// text and passwords) could land in another app. Every post is therefore preceded by a
/// live check; when KakaoTalk is not verifiably frontmost the event is not posted.
final class KakaoTalkInputGuard: @unchecked Sendable {
    static let shared = KakaoTalkInputGuard()

    private let lock = NSLock()
    private var blocked = 0
    private var lastReason: String?
    private var warned = false

    /// Number of events refused so far in this process.
    var blockedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }

    var lastBlockReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastReason
    }

    /// True when KakaoTalk is frontmost right now (same check the guard uses).
    func isKakaoTalkFrontmost() -> Bool {
        FrontmostPolicy.keyboard(currentEvidence()).allowed
    }

    /// Call immediately before posting a keyboard event.
    func permitKeyboardEvent(_ label: String) -> Bool {
        let verdict = FrontmostPolicy.keyboard(currentEvidence())
        if !verdict.allowed {
            recordBlock(label: label, reason: verdict.reason)
        }
        return verdict.allowed
    }

    /// Call immediately before posting a mouse event at `point` (screen coordinates).
    func permitPointerEvent(_ label: String, at point: CGPoint) -> Bool {
        let verdict = FrontmostPolicy.pointer(currentEvidence(), pointOwnerPID: ownerPID(at: point))
        if !verdict.allowed {
            recordBlock(label: label, reason: verdict.reason)
        }
        return verdict.allowed
    }

    func currentEvidence() -> FrontmostEvidence {
        let kakaoPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: KakaoTalkApp.bundleIdentifier)
            .first?
            .processIdentifier

        var focusedPID: Int32?
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedApplicationAttribute as CFString,
            &focusedValue
        ) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        {
            var pid: pid_t = 0
            if AXUIElementGetPid(focusedValue as! AXUIElement, &pid) == .success {
                focusedPID = pid
            }
        }

        var reportsFrontmost: Bool?
        if let kakaoPID {
            let application = AXUIElementCreateApplication(kakaoPID)
            AXUIElementSetMessagingTimeout(application, 0.5)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFrontmostAttribute as CFString, &value) == .success,
               let value,
               CFGetTypeID(value) == CFBooleanGetTypeID()
            {
                reportsFrontmost = CFBooleanGetValue((value as! CFBoolean))
            }
        }

        return FrontmostEvidence(
            kakaoPID: kakaoPID,
            focusedApplicationPID: focusedPID,
            kakaoReportsFrontmost: reportsFrontmost
        )
    }

    private func ownerPID(at point: CGPoint) -> Int32? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element
        else {
            return nil
        }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private func recordBlock(label: String, reason: String) {
        lock.lock()
        blocked += 1
        lastReason = reason
        let shouldWarn = !warned
        warned = true
        lock.unlock()

        if shouldWarn {
            let message = "kmsg: refused to post \(label): \(reason). Bring KakaoTalk to the front and retry.\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }
}
