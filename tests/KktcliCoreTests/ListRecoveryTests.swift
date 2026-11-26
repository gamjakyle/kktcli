import Testing
@testable import KktcliCore

@Suite("Chat-list recovery: when to recover and what may be pressed")
struct ListRecoveryTests {
    private func observation(
        rows: Int,
        visible: Bool = false,
        text: String? = nil,
        clear: Bool = false,
        toggle: Bool = true,
        registryRows: Int? = nil,
        lastSeen: Int? = nil
    ) -> ChatListObservation {
        ChatListObservation(
            rowCount: rows,
            searchFieldVisible: visible,
            searchText: text,
            hasClearButton: clear,
            hasSearchToggle: toggle,
            registryRowCount: registryRows,
            targetLastSeenIndex: lastSeen
        )
    }

    @Test("Visible search with a query: 취소, then the top-bar 검색 toggle")
    func visibleSearchWithQuery() {
        #expect(ChatListRecovery.plan(observation(rows: 1, visible: true, text: "모임", clear: true))
            == .leaveVisibleSearch([.pressClear, .pressSearchToggle]))
    }

    @Test("Visible search without text (empty list): only the toggle")
    func visibleSearchEmpty() {
        #expect(ChatListRecovery.plan(observation(rows: 0, visible: true, text: "", clear: false))
            == .leaveVisibleSearch([.pressSearchToggle]))
    }

    @Test("Visible search with text but no 취소 button: no recovery")
    func visibleSearchWithoutClear() {
        guard case .none = ChatListRecovery.plan(observation(rows: 1, visible: true, text: "모임", clear: false)) else {
            Issue.record("expected no recovery")
            return
        }
    }

    @Test("No top-bar toggle: no recovery at all")
    func noToggle() {
        guard case .none = ChatListRecovery.plan(observation(rows: 0, visible: true, text: "x", clear: true, toggle: false)) else {
            Issue.record("expected no recovery")
            return
        }
    }

    @Test("Hidden filter is suspected for empty, short, or shrunken lists")
    func hiddenFilterSuspicion() {
        #expect(ChatListRecovery.plan(observation(rows: 0)) == .revealHiddenSearch)
        #expect(ChatListRecovery.plan(observation(rows: 1)) == .revealHiddenSearch)
        #expect(ChatListRecovery.plan(observation(rows: 60, lastSeen: 75)) == .revealHiddenSearch)
        #expect(ChatListRecovery.plan(observation(rows: 60, registryRows: 182)) == .revealHiddenSearch)
    }

    @Test("A long list that matches what the registry saw is left alone")
    func fullListNotTouched() {
        guard case .none = ChatListRecovery.plan(observation(rows: 182, registryRows: 182, lastSeen: 40)) else {
            Issue.record("expected no recovery")
            return
        }
        guard case .none = ChatListRecovery.plan(observation(rows: 120, registryRows: 125)) else {
            Issue.record("expected no recovery")
            return
        }
    }

    @Test("After revealing the field: clear an old query, otherwise only toggle back")
    func afterReveal() {
        #expect(ChatListRecovery.stepsAfterReveal(searchText: "모임", hasClearButton: true) == [.pressClear, .pressSearchToggle])
        #expect(ChatListRecovery.stepsAfterReveal(searchText: "", hasClearButton: true) == [.pressSearchToggle])
        #expect(ChatListRecovery.stepsAfterReveal(searchText: "모임", hasClearButton: false) == [.pressSearchToggle])
        #expect(ChatListRecovery.stepsAfterReveal(searchText: nil, hasClearButton: false) == [.pressSearchToggle])
    }

    @Test("Only 취소 inside the search field and the top-bar 검색 toggle qualify")
    func allowedControls() {
        let clear = AXNodeSnapshot(role: "AXButton", desc: "취소")
        let search = AXNodeSnapshot(role: "AXButton", desc: "검색")
        #expect(ChatListControls.isClearButton(clear, insideSearchField: true))
        #expect(!ChatListControls.isClearButton(clear, insideSearchField: false))
        #expect(!ChatListControls.isClearButton(search, insideSearchField: true))
        #expect(ChatListControls.isSearchToggle(search, isDirectChildOfMainWindow: true))
        // The "검색" button inside the search field is not the toggle.
        #expect(!ChatListControls.isSearchToggle(search, isDirectChildOfMainWindow: false))
        #expect(!ChatListControls.isSearchToggle(AXNodeSnapshot(role: "AXButton", desc: "검색 "), isDirectChildOfMainWindow: true))
        #expect(!ChatListControls.isSearchToggle(AXNodeSnapshot(role: "AXMenuItem", desc: "검색"), isDirectChildOfMainWindow: true))
        #expect(!ChatListControls.isSearchToggle(AXNodeSnapshot(role: "AXButton", title: "검색"), isDirectChildOfMainWindow: true))

        let field = AXNodeSnapshot(role: "AXTextField", subrole: "AXSearchField", identifier: "_NS:20", value: "모임")
        #expect(ChatListControls.isSearchField(field))
        #expect(!ChatListControls.isSearchField(AXNodeSnapshot(role: "AXTextField", value: "메시지")))
        #expect(!ChatListControls.isSearchField(AXNodeSnapshot(role: "AXTextArea", subrole: "AXSearchField")))
    }

    @Test("Only the 카카오톡 열기 / showFirstWindow: menu item reopens the main window")
    func mainWindowMenuItem() {
        #expect(MainWindowMenuItem.isShowMainWindowItem(AXNodeSnapshot(role: "AXMenuItem", identifier: "showFirstWindow:", title: "카카오톡 열기")))
        #expect(!MainWindowMenuItem.isShowMainWindowItem(AXNodeSnapshot(role: "AXMenuItem", identifier: "showFirstWindow:", title: "카카오톡 종료")))
        #expect(!MainWindowMenuItem.isShowMainWindowItem(AXNodeSnapshot(role: "AXMenuItem", identifier: "terminate:", title: "카카오톡 열기")))
        #expect(!MainWindowMenuItem.isShowMainWindowItem(AXNodeSnapshot(role: "AXButton", identifier: "showFirstWindow:", title: "카카오톡 열기")))
    }

    @Test("Nothing is pressed on a table that is not verified as the chat list")
    func unverifiedTable() {
        let visible = ChatListObservation(rowCount: 0, searchFieldVisible: true, searchText: "홍길동", hasClearButton: true, hasSearchToggle: true, tableVerified: false)
        #expect(ChatListRecovery.plan(visible) == .none(reason: "the table is not verified as the chat list"))
        let hidden = ChatListObservation(rowCount: 3, searchFieldVisible: false, searchText: nil, hasClearButton: false, hasSearchToggle: true, registryRowCount: 180, tableVerified: false)
        #expect(ChatListRecovery.plan(hidden) == .none(reason: "the table is not verified as the chat list"))
        var verified = hidden
        verified.tableVerified = true
        #expect(ChatListRecovery.plan(verified) == .revealHiddenSearch)
    }
}
