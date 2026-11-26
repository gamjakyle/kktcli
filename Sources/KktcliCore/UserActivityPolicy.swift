import Foundation

/// A press that opens or brings up a KakaoTalk window, which may become the key window and
/// take the user's keystrokes (Enter would send them to the wrong room).
public enum UserActivityPress: String, Sendable {
    /// AXShowMenu on a chat-list row and its 채팅방 열기 item.
    case openChatRoom
    /// A long message's 전체보기 control (opens a window).
    case seeAll
    /// 카카오톡 열기 (or `open KakaoTalk.app`): activates KakaoTalk whatever app is in front.
    case showMainWindow
    /// The next chat of a batch.
    case nextChat
    /// 취소 / 검색 in the main window while restoring a filtered chat list.
    case listRecovery
    /// The old search / Enter based opening (`--legacy-open`).
    case legacyOpen

    /// The press activates KakaoTalk itself, so it needs an idle user even when another app is
    /// in front.
    public var activatesKakaoTalk: Bool {
        self == .showMainWindow
    }
}

public struct UserActivityState: Equatable, Sendable {
    /// KakaoTalk is, or may be, the frontmost app (unknown counts as "may be").
    public var kakaoTalkMayBeFrontmost: Bool
    /// Seconds since the last keyboard or mouse input (HID system state, any input type).
    public var secondsSinceLastInput: Double

    public init(kakaoTalkMayBeFrontmost: Bool, secondsSinceLastInput: Double) {
        self.kakaoTalkMayBeFrontmost = kakaoTalkMayBeFrontmost
        self.secondsSinceLastInput = secondsSinceLastInput
    }
}

public enum UserActivityDecision: Equatable, Sendable {
    case proceed
    case wait
    case giveUp
}

/// Do not open or bring up a KakaoTalk window while the user is busy with KakaoTalk.
///
/// When KakaoTalk is in front, a window opened by 채팅방 열기 or 전체보기 becomes key: whatever
/// the user is typing goes into that room, and Enter would send it there. When KakaoTalk is in
/// the background, opening rooms leaves it there. So a press waits while KakaoTalk may be
/// frontmost and the last input was less than `idleSeconds` ago; 카카오톡 열기 activates
/// KakaoTalk and therefore always waits for an idle user.
public enum UserActivityPolicy {
    public static let defaultIdleSeconds: Double = 10
    public static let defaultWaitSeconds: Double = 30
    public static let maximumSeconds: Double = 600
    public static let pollInterval: Double = 0.5
    /// Exit status for KAKAOTALK_IN_USE (EX_TEMPFAIL: try again later).
    public static let inUseExitCode: Int32 = KktcliExitStatus.inUse

    public static func mayPress(_ press: UserActivityPress, state: UserActivityState, idleSeconds: Double) -> Bool {
        let idle = state.secondsSinceLastInput >= idleSeconds
        if press.activatesKakaoTalk {
            return idle
        }
        return !state.kakaoTalkMayBeFrontmost || idle
    }

    /// `waited`: seconds already spent waiting from the budget; `budget`: the most to wait
    /// (0 gives up at once).
    public static func decide(
        _ press: UserActivityPress,
        state: UserActivityState,
        idleSeconds: Double,
        waited: Double,
        budget: Double
    ) -> UserActivityDecision {
        if mayPress(press, state: state, idleSeconds: idleSeconds) {
            return .proceed
        }
        return waited < budget ? .wait : .giveUp
    }

    /// Conservative for this guard: any positive sign, or no information at all, counts as
    /// "KakaoTalk may be frontmost".
    public static func kakaoTalkMayBeFrontmost(_ evidence: FrontmostEvidence) -> Bool {
        guard let kakaoPID = evidence.kakaoPID else { return false }
        if evidence.focusedApplicationPID == kakaoPID || evidence.kakaoReportsFrontmost == true {
            return true
        }
        if evidence.focusedApplicationPID != nil || evidence.kakaoReportsFrontmost == false {
            return false
        }
        return true
    }
}

/// One entry of `CGWindowListCopyWindowInfo` (no window names: those need Screen Recording).
public struct WindowServerEntry: Equatable, Sendable {
    public var ownerPID: Int32
    public var layer: Int
    public var isOnscreen: Bool

    public init(ownerPID: Int32, layer: Int, isOnscreen: Bool) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.isOnscreen = isOnscreen
    }
}

/// What to do when KakaoTalk's main window is not visible through Accessibility.
///
/// That happens when it is closed or minimised, and also when it sits on another desktop or
/// full-screen Space: Accessibility then reports no KakaoTalk windows at all, while the window
/// server still lists them as off screen. 카카오톡 열기 activates KakaoTalk and may switch the
/// user's desktop, so it is pressed only when KakaoTalk is already frontmost (no app switch)
/// or the caller allowed activation.
public enum MainWindowPolicy {
    public enum Decision: Equatable, Sendable {
        case reopen
        case refuse
    }

    public static func decide(kakaoTalkFrontmost: Bool, allowActivate: Bool) -> Decision {
        kakaoTalkFrontmost || allowActivate ? .reopen : .refuse
    }

    /// KakaoTalk's normal-level (layer 0) windows: all of them, and those not on screen. The
    /// counts cannot tell a closed-but-retained window from one on another Space.
    public static func windowCounts(_ entries: [WindowServerEntry], kakaoPID: Int32) -> (total: Int, offscreen: Int) {
        let windows = entries.filter { $0.ownerPID == kakaoPID && $0.layer == 0 }
        return (windows.count, windows.filter { !$0.isOnscreen }.count)
    }
}
