import CoreGraphics
import Foundation

/// What is known about the frontmost application right before an input event is posted.
public struct FrontmostEvidence: Equatable, Sendable {
    /// KakaoTalk's process id, nil when it is not running.
    public var kakaoPID: Int32?
    /// The system-wide focused application (AXFocusedApplication), nil when unavailable.
    public var focusedApplicationPID: Int32?
    /// KakaoTalk's own AXFrontmost attribute, nil when it could not be read.
    public var kakaoReportsFrontmost: Bool?

    public init(kakaoPID: Int32?, focusedApplicationPID: Int32?, kakaoReportsFrontmost: Bool?) {
        self.kakaoPID = kakaoPID
        self.focusedApplicationPID = focusedApplicationPID
        self.kakaoReportsFrontmost = kakaoReportsFrontmost
    }
}

public struct InputVerdict: Equatable, Sendable {
    public var allowed: Bool
    public var reason: String

    public init(allowed: Bool, reason: String) {
        self.allowed = allowed
        self.reason = reason
    }
}

/// Keyboard and mouse events posted to the HID tap go to whatever app is frontmost (or under
/// the pointer), not to KakaoTalk. Posting is allowed only when KakaoTalk is verifiably in front;
/// anything unverifiable is refused.
public enum FrontmostPolicy {
    public static func keyboard(_ evidence: FrontmostEvidence) -> InputVerdict {
        guard let kakaoPID = evidence.kakaoPID else {
            return InputVerdict(allowed: false, reason: "KakaoTalk is not running")
        }
        guard let frontmost = evidence.kakaoReportsFrontmost else {
            return InputVerdict(allowed: false, reason: "could not read KakaoTalk's AXFrontmost")
        }
        guard frontmost else {
            return InputVerdict(allowed: false, reason: "KakaoTalk is not the frontmost app")
        }
        if let focused = evidence.focusedApplicationPID, focused != kakaoPID {
            return InputVerdict(allowed: false, reason: "focused application pid \(focused) is not KakaoTalk (\(kakaoPID))")
        }
        return InputVerdict(allowed: true, reason: "KakaoTalk is frontmost")
    }

    /// Mouse clicks additionally require that KakaoTalk owns the element under the point.
    public static func pointer(_ evidence: FrontmostEvidence, pointOwnerPID: Int32?) -> InputVerdict {
        let keyboardVerdict = keyboard(evidence)
        guard keyboardVerdict.allowed else { return keyboardVerdict }
        guard let owner = pointOwnerPID else {
            return InputVerdict(allowed: false, reason: "no accessible element under the click point")
        }
        guard owner == evidence.kakaoPID else {
            return InputVerdict(allowed: false, reason: "click point belongs to pid \(owner), not KakaoTalk")
        }
        return InputVerdict(allowed: true, reason: "KakaoTalk is frontmost and owns the click point")
    }
}

/// Context-menu items that must never be pressed, whatever the caller asked for.
/// Mirrors `refuseIfBlocked` from the reference tool.
public enum MenuItemSafety {
    public static let openChatRoomIdentifier = "openChatRoom:"
    public static let openChatRoomTitle = "채팅방 열기"

    static let blockedTitles: Set<String> = [
        "모두 읽음 처리", "읽음 처리", "로그아웃", "종료", "KakaoTalk 종료", "종료 및 윈도우 유지", "잠금모드",
        "나가기", "채팅방 나가기", "삭제", "전송", "보내기", "잠자기", "재시동", "재시동…", "시스템 종료", "시스템 종료…",
        "잠금 화면", "카카오톡 강제 종료", "강제 종료...", "모든 채팅창 닫기", "지난 대화 보기", "인증하기", "보이스톡", "페이스톡",
    ]
    static let blockedIdentifiers: Set<String> = [
        "readAllNewMessages", "logout:", "logout", "terminate:", "terminate", "lock:",
        "markAsRead:", "leaveChatRoom:", "callVoiceTalk:", "callFaceTalk:",
    ]
    static let blockedFragments = ["읽음", "나가기", "로그아웃", "종료", "차단", "신고"]

    public static func isBlocked(title: String?, description: String?, identifier: String?) -> Bool {
        let title = title ?? ""
        let description = description ?? ""
        let identifier = identifier ?? ""
        if blockedTitles.contains(title) || blockedTitles.contains(description) || blockedIdentifiers.contains(identifier) {
            return true
        }
        return blockedFragments.contains { title.contains($0) || description.contains($0) }
    }

    /// The only item `read` may press.
    public static func isOpenChatRoomItem(title: String?, identifier: String?) -> Bool {
        identifier == openChatRoomIdentifier && title == openChatRoomTitle
    }
}

public enum ListScrollMath {
    public static func isRowVisible(rowFrame: CGRect, visibleFrame: CGRect, tolerance: CGFloat = 1) -> Bool {
        guard rowFrame.height > 0 else { return false }
        return rowFrame.minY >= visibleFrame.minY - tolerance && rowFrame.maxY <= visibleFrame.maxY + tolerance
    }

    /// Vertical scroll-bar value (0 = top, 1 = bottom) that centers `rowFrame` in the visible area.
    public static func scrollValueCentering(rowFrame: CGRect, tableFrame: CGRect, visibleFrame: CGRect) -> Double {
        let offset = rowFrame.minY - tableFrame.minY
        let maxScroll = max(1, tableFrame.height - visibleFrame.height)
        let value = (offset - visibleFrame.height / 2 + rowFrame.height / 2) / maxScroll
        return Double(max(0, min(1, value)))
    }
}

public enum ScrollbackMath {
    /// Row count to aim for when `missingMessages` more messages are wanted. Rows include date
    /// separators and system lines, so ask for a little more than one row per message.
    public static func targetRowCount(currentRows: Int, missingMessages: Int) -> Int {
        guard missingMessages > 0 else { return currentRows }
        return currentRows + Int((Double(missingMessages) * 1.25).rounded(.up)) + 8
    }
}
