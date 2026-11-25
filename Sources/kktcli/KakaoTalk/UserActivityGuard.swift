import CoreGraphics
import Foundation
import KktcliCore

/// Waits while the user is busy with KakaoTalk (`UserActivityPolicy`) before a press that
/// opens or brings up a KakaoTalk window, and gives up with KAKAOTALK_IN_USE, pressing nothing,
/// when the wait budget is used up. It only reads: the HID idle time (needs no permission)
/// and which app is frontmost.
final class UserActivityGuard {
    let idleSeconds: Double
    let waitBudget: Double
    let runner: AXActionRunner
    /// Seconds waited from the current budget.
    private(set) var budgetUsed: Double = 0
    /// Seconds waited in this process, over all budgets.
    private(set) var totalWaited: Double = 0
    private var announced = false

    init(idleSeconds: Double, waitBudget: Double, runner: AXActionRunner) {
        self.idleSeconds = idleSeconds
        self.waitBudget = waitBudget
        self.runner = runner
    }

    /// Each chat of a batch gets its own budget.
    func startNewBudget() {
        budgetUsed = 0
    }

    /// Seconds since the last keyboard or mouse input of any kind (kCGAnyInputEventType).
    static func secondsSinceLastInput() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    func currentState() -> UserActivityState {
        UserActivityState(
            kakaoTalkMayBeFrontmost: UserActivityPolicy.kakaoTalkMayBeFrontmost(KakaoTalkInputGuard.shared.currentEvidence()),
            secondsSinceLastInput: Self.secondsSinceLastInput()
        )
    }

    /// The re-check right before the press: may it happen now (no waiting)?
    func mayPressNow(_ press: UserActivityPress) -> Bool {
        let state = currentState()
        guard UserActivityPolicy.mayPress(press, state: state, idleSeconds: idleSeconds) else {
            runner.log("activity: \(press.rawValue) deferred right before the press (last input \(Self.format(state.secondsSinceLastInput)) s ago, KakaoTalk may be frontmost=\(state.kakaoTalkMayBeFrontmost))")
            return false
        }
        return true
    }

    /// Waits until `press` may happen. Throws KAKAOTALK_IN_USE when the budget runs out and
    /// INTERRUPTED on Ctrl-C / SIGTERM; nothing is pressed in either case.
    func waitUntilClear(_ press: UserActivityPress) throws {
        while true {
            let state = currentState()
            switch UserActivityPolicy.decide(press, state: state, idleSeconds: idleSeconds, waited: budgetUsed, budget: waitBudget) {
            case .proceed:
                return
            case .giveUp:
                throw inUseFailure(press, state: state)
            case .wait:
                if ReadInterruption.requested {
                    throw ReadFailure(
                        code: "INTERRUPTED",
                        message: "Interrupted while waiting for KakaoTalk to be idle; nothing was pressed.",
                        exitCode: ReadFailure.interruptedExitCode
                    )
                }
                if !announced {
                    announced = true
                    let note = "kktcli: KakaoTalk is in use (last input \(Self.format(state.secondsSinceLastInput)) s ago); "
                        + "waiting up to \(Self.format(waitBudget)) s until it is idle for \(Self.format(idleSeconds)) s"
                        + (press.activatesKakaoTalk ? "" : " or in the background") + ".\n"
                    FileHandle.standardError.write(Data(note.utf8))
                }
                runner.log("activity: waiting before \(press.rawValue) (last input \(Self.format(state.secondsSinceLastInput)) s ago)")
                let step = max(0.05, min(UserActivityPolicy.pollInterval, waitBudget - budgetUsed))
                Thread.sleep(forTimeInterval: step)
                budgetUsed += step
                totalWaited += step
            }
        }
    }

    private func inUseFailure(_ press: UserActivityPress, state: UserActivityState) -> ReadFailure {
        let since = Self.format(state.secondsSinceLastInput)
        let message = press.activatesKakaoTalk
            ? "The user was active \(since) s ago and this step would bring KakaoTalk to the front; nothing was pressed."
            : "KakaoTalk is in front and was used \(since) s ago; a window opened now could take the user's typing, so nothing was pressed."
        return ReadFailure(
            code: "KAKAOTALK_IN_USE",
            message: message,
            hint: "Retry when KakaoTalk is idle or in the background, or raise --wait-for-idle (now \(Self.format(waitBudget)) s).",
            exitCode: UserActivityPolicy.inUseExitCode,
            details: [
                "press": press.rawValue,
                "seconds_since_last_input": since,
                "kakao_may_be_frontmost": String(state.kakaoTalkMayBeFrontmost),
                "idle_seconds": Self.format(idleSeconds),
                "waited_ms": String(Int(budgetUsed * 1000)),
            ]
        )
    }

    static func format(_ seconds: Double) -> String {
        String(format: "%.1f", seconds)
    }
}
