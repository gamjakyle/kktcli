import ApplicationServices.HIServices
import CoreGraphics
import Foundation
import KmsgCore

/// What chat-list recovery did; printed as `meta.list_recovery` by `read`.
struct ChatListRecoveryReport: Encodable {
    /// "visible_search", "hidden_search", or "hidden_search_without_query".
    var state: String
    /// Buttons pressed, in order ("취소" = clear inside the search field, "검색" = top-bar toggle).
    var pressed: [String] = []
    var clearedQuery: String?
    var rowsBefore: Int
    var rowsAfter: Int
    /// "restored", "no_filter_found", or "failed: <reason>".
    var outcome: String

    var restored: Bool {
        outcome == "restored"
    }

    var summary: String {
        "\(state); pressed [\(pressed.joined(separator: ", "))]; rows \(rowsBefore)->\(rowsAfter); \(outcome)"
    }

    enum CodingKeys: String, CodingKey {
        case state
        case pressed
        case clearedQuery = "cleared_query"
        case rowsBefore = "rows_before"
        case rowsAfter = "rows_after"
        case outcome
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(pressed, forKey: .pressed)
        try container.encode(clearedQuery, forKey: .clearedQuery)
        try container.encode(rowsBefore, forKey: .rowsBefore)
        try container.encode(rowsAfter, forKey: .rowsAfter)
        try container.encode(outcome, forKey: .outcome)
    }
}

/// Restores KakaoTalk's full chat list when a leftover search filter hides the wanted row.
///
/// Called only after the row was not found. It presses nothing but two verified buttons, both
/// with AXPress: "취소" inside the search field (AXTextField subrole AXSearchField), which
/// clears the query, and the "검색" toggle that is a direct child of the main window. It never
/// types, never sends Enter, and never presses the "검색" button inside the search field.
struct ChatListRecoverer {
    private static let pressTimeout: Float = 2.0

    let kakao: KakaoTalkApp
    let runner: AXActionRunner

    func recover(
        in mainWindow: UIElement,
        table: AXUIElement?,
        registryRowCount: Int?,
        targetLastSeenIndex: Int?
    ) -> ChatListRecoveryReport? {
        let rowsBefore = table.map { AXNodeReader.rowCount(of: $0) } ?? 0
        let controls = readControls(in: mainWindow)
        let plan = ChatListRecovery.plan(ChatListObservation(
            rowCount: rowsBefore,
            searchFieldVisible: controls.searchFieldVisible,
            searchText: controls.searchText,
            hasClearButton: controls.clearButton != nil,
            hasSearchToggle: controls.toggle != nil,
            registryRowCount: registryRowCount,
            targetLastSeenIndex: targetLastSeenIndex
        ))
        runner.log("read: list recovery rows=\(rowsBefore) field visible=\(controls.searchFieldVisible) plan=\(plan)")

        var report = ChatListRecoveryReport(state: "", rowsBefore: rowsBefore, rowsAfter: rowsBefore, outcome: "")
        let steps: [ChatListRecoveryStep]
        switch plan {
        case .none(let reason):
            runner.log("read: list recovery not attempted: \(reason)")
            return nil
        case .leaveVisibleSearch(let planned):
            report.state = "visible_search"
            if planned.contains(.pressClear) {
                report.clearedQuery = controls.searchText
            }
            steps = planned
        case .revealHiddenSearch:
            report.state = "hidden_search"
            guard press(.pressSearchToggle, in: mainWindow, report: &report) else {
                return finish(report, outcome: "failed: the 검색 toggle could not be pressed", in: mainWindow)
            }
            guard waitForSearchField(visible: true, in: mainWindow) else {
                // The toggle is symmetric: pressing it once more returns the list to the state
                // it was found in.
                let restored = press(.pressSearchToggle, in: mainWindow, report: &report)
                return finish(
                    report,
                    outcome: "failed: the 검색 toggle did not show a search field" + (restored ? " (pressed again to restore)" : ""),
                    in: mainWindow
                )
            }
            let revealed = readControls(in: mainWindow)
            steps = ChatListRecovery.stepsAfterReveal(searchText: revealed.searchText, hasClearButton: revealed.clearButton != nil)
            if steps.contains(.pressClear) {
                report.clearedQuery = revealed.searchText
            } else {
                report.state = "hidden_search_without_query"
            }
        }

        for step in steps {
            guard press(step, in: mainWindow, report: &report) else {
                return finish(report, outcome: "failed: \(step.rawValue) could not be pressed", in: mainWindow)
            }
            switch step {
            case .pressClear:
                if !waitForEmptySearchText(in: mainWindow) {
                    runner.log("read: list recovery: the search text did not clear")
                }
            case .pressSearchToggle:
                if !waitForSearchField(visible: false, in: mainWindow) {
                    return finish(report, outcome: "failed: search mode did not turn off", in: mainWindow)
                }
            }
        }

        let outcome = report.state == "hidden_search_without_query" ? "no_filter_found" : "restored"
        return finish(report, outcome: outcome, in: mainWindow)
    }

    // MARK: Controls

    private struct Controls {
        var searchFieldVisible = false
        var searchText: String?
        var clearButton: AXUIElement?
        var toggle: AXUIElement?
    }

    /// Re-read before every press, so only currently verified elements are ever pressed.
    private func readControls(in mainWindow: UIElement) -> Controls {
        var controls = Controls()
        let window = AXNodeReader.read(mainWindow.axElement)

        for child in window.children {
            let node = AXNodeReader.read(child, depth: 1).snapshot
            if ChatListControls.isSearchToggle(node, isDirectChildOfMainWindow: true) {
                controls.toggle = child
                break
            }
        }

        var fields: [AXLiveNode] = []
        var queue = window.children
        var index = 0
        while index < queue.count, index < 200 {
            let node = AXNodeReader.read(queue[index])
            index += 1
            if ChatListControls.isSearchField(node.snapshot) {
                fields.append(node)
                continue
            }
            // The chat list itself never holds the search field; skip its rows.
            if node.snapshot.role == AXRoleName.table {
                continue
            }
            queue.append(contentsOf: node.children)
        }

        guard let field = fields.first(where: { $0.snapshot.identifier == ChatListControls.searchFieldIdentifier }) ?? fields.first else {
            return controls
        }
        controls.searchFieldVisible = field.snapshot.frame.map { $0.width > 1 && $0.height > 1 } ?? false
        controls.searchText = field.snapshot.value

        search: for child in field.children {
            let node = AXNodeReader.read(child)
            if ChatListControls.isClearButton(node.snapshot, insideSearchField: true) {
                controls.clearButton = child
                break
            }
            for grandchild in node.children
            where ChatListControls.isClearButton(AXNodeReader.read(grandchild).snapshot, insideSearchField: true) {
                controls.clearButton = grandchild
                break search
            }
        }
        return controls
    }

    private func press(_ step: ChatListRecoveryStep, in mainWindow: UIElement, report: inout ChatListRecoveryReport) -> Bool {
        let controls = readControls(in: mainWindow)
        let target: AXUIElement?
        switch step {
        case .pressClear:
            target = controls.clearButton
        case .pressSearchToggle:
            target = controls.toggle
        }
        guard let target else {
            runner.log("read: list recovery: \(step.rawValue) is not available")
            return false
        }
        AXNodeReader.setMessagingTimeout(target, seconds: Self.pressTimeout)
        let status = AXNodeReader.perform(target, kAXPressAction)
        report.pressed.append(step.rawValue)
        runner.log("read: list recovery pressed \(step.rawValue) status=\(status.rawValue)")
        // A timeout can still mean the press happened; the waits below decide.
        return status == .success || status == .cannotComplete
    }

    // MARK: Waits

    private func waitForSearchField(visible: Bool, in mainWindow: UIElement, timeout: TimeInterval = 1.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if readControls(in: mainWindow).searchFieldVisible == visible {
                return true
            }
            Thread.sleep(forTimeInterval: 0.08)
        } while Date() < deadline && !ReadInterruption.requested
        return readControls(in: mainWindow).searchFieldVisible == visible
    }

    private func waitForEmptySearchText(in mainWindow: UIElement, timeout: TimeInterval = 1.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let text = readControls(in: mainWindow).searchText ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.08)
        } while Date() < deadline && !ReadInterruption.requested
        return false
    }

    /// Row count of a freshly located list once it has held still briefly (the table element
    /// may be replaced when search mode changes).
    private func settledRowCount(in mainWindow: UIElement, timeout: TimeInterval = 2.0) -> Int {
        let locator = ChatListLocator(kakao: kakao, runner: runner)
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1
        var stableSince: Date?
        while Date() < deadline, !ReadInterruption.requested {
            let count = locator.access(in: mainWindow).map { AXNodeReader.rowCount(of: $0.table) } ?? 0
            if count == last, count > 0 {
                let since = stableSince ?? Date()
                stableSince = since
                if Date().timeIntervalSince(since) >= 0.3 {
                    return count
                }
            } else {
                last = count
                stableSince = nil
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return max(last, 0)
    }

    private func finish(_ report: ChatListRecoveryReport, outcome: String, in mainWindow: UIElement) -> ChatListRecoveryReport {
        var finished = report
        finished.outcome = outcome
        finished.rowsAfter = settledRowCount(in: mainWindow)
        runner.log("read: list recovery \(finished.summary)")
        return finished
    }
}
