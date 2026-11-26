import Testing
@testable import KktcliCore

@Suite("User-activity guard and main-window policy")
struct UserActivityPolicyTests {
    private func state(front: Bool, idle: Double) -> UserActivityState {
        UserActivityState(kakaoTalkMayBeFrontmost: front, secondsSinceLastInput: idle)
    }

    @Test("While KakaoTalk is in front and in use, presses that open windows wait")
    func frontAndBusy() {
        for press in [UserActivityPress.openChatRoom, .seeAll, .nextChat, .listRecovery, .legacyOpen] {
            #expect(!UserActivityPolicy.mayPress(press, state: state(front: true, idle: 2), idleSeconds: 10))
            #expect(UserActivityPolicy.mayPress(press, state: state(front: true, idle: 10), idleSeconds: 10))
            // KakaoTalk in the background: a new window stays there, so no wait.
            #expect(UserActivityPolicy.mayPress(press, state: state(front: false, idle: 0), idleSeconds: 10))
        }
    }

    @Test("카카오톡 열기 activates KakaoTalk, so it needs an idle user whatever is in front")
    func showMainWindowNeedsIdle() {
        #expect(UserActivityPress.showMainWindow.activatesKakaoTalk)
        #expect(!UserActivityPolicy.mayPress(.showMainWindow, state: state(front: false, idle: 3), idleSeconds: 10))
        #expect(!UserActivityPolicy.mayPress(.showMainWindow, state: state(front: true, idle: 3), idleSeconds: 10))
        #expect(UserActivityPolicy.mayPress(.showMainWindow, state: state(front: false, idle: 12), idleSeconds: 10))
    }

    @Test("Waiting stops at the budget; a budget of 0 gives up at once")
    func budget() {
        let busy = state(front: true, idle: 1)
        #expect(UserActivityPolicy.decide(.openChatRoom, state: busy, idleSeconds: 10, waited: 0, budget: 30) == .wait)
        #expect(UserActivityPolicy.decide(.openChatRoom, state: busy, idleSeconds: 10, waited: 29.5, budget: 30) == .wait)
        #expect(UserActivityPolicy.decide(.openChatRoom, state: busy, idleSeconds: 10, waited: 30, budget: 30) == .giveUp)
        #expect(UserActivityPolicy.decide(.openChatRoom, state: busy, idleSeconds: 10, waited: 0, budget: 0) == .giveUp)
        #expect(UserActivityPolicy.decide(.openChatRoom, state: state(front: false, idle: 1), idleSeconds: 10, waited: 0, budget: 0) == .proceed)
        #expect(UserActivityPolicy.defaultIdleSeconds == 10)
        #expect(UserActivityPolicy.defaultWaitSeconds == 30)
        #expect(UserActivityPolicy.inUseExitCode == 75)
    }

    @Test("Unknown counts as maybe in front; any positive sign wins")
    func mayBeFrontmost() {
        let kakao: Int32 = 100
        #expect(!UserActivityPolicy.kakaoTalkMayBeFrontmost(FrontmostEvidence(kakaoPID: nil, focusedApplicationPID: kakao, kakaoReportsFrontmost: true)))
        #expect(UserActivityPolicy.kakaoTalkMayBeFrontmost(FrontmostEvidence(kakaoPID: kakao, focusedApplicationPID: kakao, kakaoReportsFrontmost: nil)))
        #expect(UserActivityPolicy.kakaoTalkMayBeFrontmost(FrontmostEvidence(kakaoPID: kakao, focusedApplicationPID: 7, kakaoReportsFrontmost: true)))
        #expect(!UserActivityPolicy.kakaoTalkMayBeFrontmost(FrontmostEvidence(kakaoPID: kakao, focusedApplicationPID: 7, kakaoReportsFrontmost: nil)))
        #expect(!UserActivityPolicy.kakaoTalkMayBeFrontmost(FrontmostEvidence(kakaoPID: kakao, focusedApplicationPID: nil, kakaoReportsFrontmost: false)))
        #expect(UserActivityPolicy.kakaoTalkMayBeFrontmost(FrontmostEvidence(kakaoPID: kakao, focusedApplicationPID: nil, kakaoReportsFrontmost: nil)))
    }

    @Test("Window-server counts: KakaoTalk's layer-0 windows, total and off screen")
    func windowCounts() {
        let entries = [
            WindowServerEntry(ownerPID: 100, layer: 0, isOnscreen: false),
            WindowServerEntry(ownerPID: 100, layer: 0, isOnscreen: false),
            WindowServerEntry(ownerPID: 100, layer: 0, isOnscreen: true),
            WindowServerEntry(ownerPID: 100, layer: 25, isOnscreen: true),  // status item
            WindowServerEntry(ownerPID: 200, layer: 0, isOnscreen: false),
        ]
        let counts = MainWindowPolicy.windowCounts(entries, kakaoPID: 100)
        #expect(counts.total == 3)
        #expect(counts.offscreen == 2)
    }
}
