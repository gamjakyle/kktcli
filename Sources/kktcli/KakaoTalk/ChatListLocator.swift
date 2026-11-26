import ApplicationServices.HIServices
import Foundation
import KktcliCore

/// The main window's chat-list table.
struct ChatListAccess {
    let window: UIElement
    let table: AXUIElement
    /// The table's enclosing scroll area (its frame is the visible part of the list).
    let scrollArea: AXUIElement?
}

struct LocatedChatRow {
    let index: Int
    let element: AXUIElement
    let title: String
    let summary: ChatRowSummary
}

/// Finds chat windows and chat-list rows for `read` using Accessibility reads only.
///
/// Row lookup reads one title label per row and stops at the first match, checks the
/// registry's last-seen index first for `--chat-id`, and never posts input events.
struct ChatListLocator {
    static let mainWindowIdentifier = "Main Window"
    static let transcriptScrollAreaIdentifier = "_NS:32"
    static let messageInputIdentifier = "_NS:51"

    let kakao: KakaoTalkApp
    let runner: AXActionRunner

    // MARK: Windows

    func isMainWindow(_ window: UIElement) -> Bool {
        window.identifier == Self.mainWindowIdentifier
    }

    /// Open chat windows (the main window is never a chat window).
    func chatWindows() -> [UIElement] {
        kakao.windows.filter { window in
            (window.role ?? kAXWindowRole) == kAXWindowRole && !isMainWindow(window)
        }
    }

    /// Open chat windows that have a title. Untitled windows (open chats on KakaoTalk 26.10)
    /// are never matched by title; only `ChatRoomMenuOpener` may accept one, as the single
    /// new window that appeared after its own press.
    func titledChatWindows() -> [UIElement] {
        chatWindows().filter { !OpenedWindowRule.isUntitled($0.title) }
    }

    /// An open chat window titled exactly `title`; failing that, the only window whose
    /// normalized title (no spaces, punctuation or symbols) matches.
    func existingWindow(exactTitle title: String) -> UIElement? {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let windows = titledChatWindows()
        if let exact = windows.first(where: { Self.trimmed($0.title) == wanted }) {
            return exact
        }
        // A team-chat / self-chat row title carries a room-type prefix its window title lacks.
        let byRowTitle = windows.filter { RoomTitle.windowMatchesRow(windowTitle: $0.title, rowTitle: wanted) }
        if byRowTitle.count == 1 {
            return byRowTitle[0]
        }
        let target = ChatTextNormalizer.normalize(RoomTitle.expectedWindowTitle(forRowTitle: wanted))
        guard !target.isEmpty else { return nil }
        let normalizedMatches = windows.filter { ChatTextNormalizer.normalize($0.title ?? "") == target }
        return normalizedMatches.count == 1 ? normalizedMatches[0] : nil
    }

    static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best partial title match among open chat windows (titled ones only).
    func existingWindow(query: String) -> UIElement? {
        titledChatWindows()
            .compactMap { window -> (window: UIElement, score: Int)? in
                guard let title = window.title else { return nil }
                let score = ChatQueryMatcher.score(query: query, candidate: title)
                return score > 0 ? (window, score) : nil
            }
            .max { $0.score < $1.score }?
            .window
    }

    var windowLookup: KakaoWindowLookup {
        KakaoWindowLookup(kakao: kakao, runner: runner)
    }

    /// The main window: from kAXWindows (this desktop), else the one found by element id on
    /// another desktop earlier (or cached for this KakaoTalk process). Never scans; the full
    /// lookup, which may scan and press, is `MainWindowAccess.resolve`.
    func mainWindow() -> UIElement? {
        mainWindow(among: kakao.windows) ?? windowLookup.knownOffDesktopMainWindow()?.element
    }

    /// Read-only lookup: `mainWindow()`, the patient re-check, then the element-id scan. Never
    /// presses (for `watch --all`). `offDesktop` is true when kAXWindows does not list it.
    func findMainWindow(scan: Bool) -> (window: UIElement, offDesktop: Bool)? {
        if let main = mainWindow() ?? confirmMainWindow() {
            return (main, !windowLookup.isListed(main))
        }
        guard scan, KakaoWindowLookup.scanAvailable, let found = windowLookup.scanForMainWindow().mainWindow else {
            return nil
        }
        return (found.element, true)
    }

    private func mainWindow(among windows: [UIElement]) -> UIElement? {
        if let main = windows.first(where: { $0.identifier == Self.mainWindowIdentifier }) {
            return main
        }
        // Other KakaoTalk builds: a window without a transcript that carries the chat list.
        return windows.first { window in
            guard !hasTranscript(window) else { return false }
            if window.title == "카카오톡" {
                return true
            }
            return !window.findAll(where: { $0.identifier == "chatrooms" }, limit: 1, maxNodes: 160).isEmpty
        }
    }

    /// How long a missing main window is looked for again before 카카오톡 열기 may be pressed.
    static let mainWindowRecheckDuration: TimeInterval = 0.6
    /// AX messaging timeout for that re-check (the process default is 0.25 s).
    private static let patientMessagingTimeout: Float = 1.0

    /// The main window, looked for again for up to `duration` with a longer AX messaging
    /// timeout on the application and on each window. Right after a KakaoTalk window closes,
    /// KakaoTalk may not answer within the 0.25 s default, and a failed read looks exactly like
    /// a missing main window. Nil only when it stays missing; the trace then says what
    /// Accessibility reported.
    func confirmMainWindow(within duration: TimeInterval = ChatListLocator.mainWindowRecheckDuration) -> UIElement? {
        let started = Date()
        let deadline = started.addingTimeInterval(duration)
        AXNodeReader.setMessagingTimeout(kakao.applicationElement.axElement, seconds: Self.patientMessagingTimeout)
        var attempts = 0
        repeat {
            attempts += 1
            let windows = kakao.windows
            for window in windows {
                AXNodeReader.setMessagingTimeout(window.axElement, seconds: Self.patientMessagingTimeout)
            }
            if let main = mainWindow(among: windows) {
                runner.log("main window: found again after \(Int(Date().timeIntervalSince(started) * 1000)) ms (attempt \(attempts)); \(MainWindowMenuItem.title) not needed")
                return main
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline && !ReadInterruption.requested
        runner.log("main window: still missing after \(Int(Date().timeIntervalSince(started) * 1000)) ms (\(attempts) attempts); \(windowDiagnostics())")
        return nil
    }

    /// What Accessibility reports about KakaoTalk's windows (trace only).
    func windowDiagnostics() -> String {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(kakao.applicationElement.axElement, kAXWindowsAttribute as CFString, &value)
        let windows = (value as? [AXUIElement]) ?? []
        let described = windows.prefix(10).map { element -> String in
            AXNodeReader.setMessagingTimeout(element, seconds: Self.patientMessagingTimeout)
            let snapshot = AXNodeReader.read(element).snapshot
            return "\(snapshot.role)/\(snapshot.identifier.isEmpty ? "-" : snapshot.identifier)/'\(snapshot.title ?? "")'" + (snapshot.readFailed ? " (read failed)" : "")
        }
        return "AXWindows status=\(status.rawValue) count=\(windows.count) [\(described.joined(separator: ", "))]"
    }

    /// The chat-list table of `window`, looked for again for up to `duration` (a busy KakaoTalk
    /// can fail a single read right after another window closed).
    func access(in window: UIElement, patience duration: TimeInterval) -> ChatListAccess? {
        let deadline = Date().addingTimeInterval(duration)
        AXNodeReader.setMessagingTimeout(window.axElement, seconds: Self.patientMessagingTimeout)
        repeat {
            if let access = access(in: window) {
                return access
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline && !ReadInterruption.requested
        runner.log("main window: chat list table still missing after \(Int(duration * 1000)) ms")
        return nil
    }

    /// What kktcli did to get the main window, for `meta.main_window` (several are joined
    /// with "," in the order they happened, e.g. "other_desktop,switched_to_chat_tab").
    enum MainWindowAction: String {
        /// Found by element id on another desktop or Space; nothing pressed.
        case otherDesktop = "other_desktop"
        /// A closed main window opened with 창 > 채팅 (no activation).
        case openedViaWindowMenu = "opened_via_window_menu"
        case openedViaMenuItem = "opened_via_menu_item"
        case openedViaOpenCommand = "opened_via_open_command"
        case switchedToChatTab = "switched_to_chat_tab"

        static func report(_ actions: [MainWindowAction?]) -> String? {
            var values: [String] = []
            for value in actions.compactMap({ $0?.rawValue }) where !values.contains(value) {
                values.append(value)
            }
            return values.isEmpty ? nil : values.joined(separator: ",")
        }
    }

    /// The main window, wherever it is (`MainWindowAccess.resolve`); `open KakaoTalk.app`,
    /// which activates KakaoTalk, only as a last resort with `allowOpenCommand` (--deep-recovery).
    func requireMainWindow(allowOpenCommand: Bool, access: MainWindowAccess) throws -> (window: UIElement, action: MainWindowAction?) {
        try access.resolve(locator: self, allowOpenCommand: allowOpenCommand)
    }

    enum MainWindowPress {
        case pressed
        /// The item was not found (or the press failed).
        case unavailable
        /// `beforePress` said no right before the press; nothing was pressed.
        case deferred
    }

    /// Presses KakaoTalk's menu item "카카오톡 열기" (identifier `showFirstWindow:`) and nothing
    /// else. The item is looked up below the application element (its menu-extra and menu bar,
    /// not inside windows) and re-verified right before the AXPress, together with
    /// `beforePress` (the user-activity re-check). Callers go through `MainWindowAccess`.
    func pressShowMainWindowMenuItem(beforePress: () -> Bool) -> MainWindowPress {
        let application = kakao.applicationElement.axElement
        var roots: [AXUIElement] = []
        if let extras = AXNodeReader.elementAttribute(application, kAXExtrasMenuBarAttribute) {
            roots.append(extras)
        }
        roots += AXNodeReader.children(application).filter { AXNodeReader.read($0).snapshot.role != AXRoleName.window }

        for root in roots {
            guard let item = AXNodeReader.firstDescendant(of: root, maxNodes: 400, where: {
                MainWindowMenuItem.isShowMainWindowItem($0.snapshot)
            }) else {
                continue
            }
            AXNodeReader.setMessagingTimeout(item.element, seconds: 2.0)
            guard MainWindowMenuItem.isShowMainWindowItem(AXNodeReader.read(item.element).snapshot) else {
                continue
            }
            guard beforePress() else {
                return .deferred
            }
            let status = AXNodeReader.perform(item.element, kAXPressAction)
            runner.log("read: pressed \(MainWindowMenuItem.title) (\(MainWindowMenuItem.identifier)) status=\(status.rawValue)")
            return status == .success || status == .cannotComplete ? .pressed : .unavailable
        }
        runner.log("read: \(MainWindowMenuItem.title) menu item unavailable")
        return .unavailable
    }

    /// Waits for the window identified "Main Window".
    func waitForMainWindow(timeout: TimeInterval) -> UIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let main = kakao.windows.first(where: { $0.identifier == Self.mainWindowIdentifier }) {
                return main
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline && !ReadInterruption.requested
        return nil
    }

    // MARK: Chat list verification and the 채팅 tab

    /// What the main window's tab, the table's role and its first rows say about the table
    /// (`ChatListCheck.verify(containerRole:tab:summaries:)`). Reads only.
    func verify(_ access: ChatListAccess?, in window: UIElement) -> ChatListVerification {
        let tab = MainWindowLayout.classifyTab(AXNodeReader.flatten(window.axElement, maxDepth: 4, budget: 300))
        let role = access.map { AXNodeReader.read($0.table).snapshot.role }
        let rows = access.map { Array(AXNodeReader.rows(of: $0.table).prefix(ChatListCheck.sampleSize)) } ?? []
        let verification = ChatListCheck.verify(containerRole: role, tab: tab, summaries: rows.map { ChatListScanner.summarize(row: $0) })
        runner.log("chat list: tab \(tab.rawValue), verification \(verification)")
        return verification
    }

    enum ChatTabPress {
        case pressed
        case unavailable
        case deferred
    }

    /// Presses KakaoTalk's 창 menu item "채팅" (⌘2) and nothing else: found only below the 창
    /// menu of the application's menu bar, re-verified (title, ⌘ character) right before the
    /// AXPress together with `beforePress`.
    func pressChatTabMenuItem(beforePress: () -> Bool) -> ChatTabPress {
        let application = kakao.applicationElement.axElement
        guard let menuBar = AXNodeReader.elementAttribute(application, kAXMenuBarAttribute) else {
            runner.log("chat tab: no menu bar")
            return .unavailable
        }
        let windowMenus = AXNodeReader.children(menuBar).filter { element in
            ChatTabMenu.windowMenuTitles.contains((AXNodeReader.read(element).snapshot.title ?? "").trimmingCharacters(in: .whitespaces))
        }
        func isItem(_ element: AXUIElement) -> Bool {
            let node = AXNodeReader.read(element).snapshot
            let commandCharacter = AXNodeReader.attribute(element, kAXMenuItemCmdCharAttribute) as? String
            return ChatTabMenu.isChatTabItem(role: node.role, title: node.title, commandCharacter: commandCharacter)
        }
        for menu in windowMenus {
            guard let item = AXNodeReader.firstDescendant(of: menu, maxNodes: 200, where: { isItem($0.element) })?.element else {
                continue
            }
            AXNodeReader.setMessagingTimeout(item, seconds: 2.0)
            guard isItem(item), beforePress() else {
                return .deferred
            }
            let status = AXNodeReader.perform(item, kAXPressAction)
            runner.log("chat tab: pressed 창 > \(ChatTabMenu.title) (⌘\(ChatTabMenu.commandCharacter)) status=\(status.rawValue)")
            return status == .success || status == .cannotComplete ? .pressed : .unavailable
        }
        runner.log("chat tab: the 창 menu item \(ChatTabMenu.title) (⌘\(ChatTabMenu.commandCharacter)) was not found")
        return .unavailable
    }

    /// Second choice to switch tabs, only when the 창 menu item is unavailable (untested live):
    /// the main window's top-level "chatrooms" tab button and nothing else, re-verified right
    /// before the AXPress together with `beforePress`.
    func pressChatroomsButton(in mainWindow: UIElement, beforePress: () -> Bool) -> ChatTabPress {
        func isButton(_ element: AXUIElement) -> Bool {
            let node = AXNodeReader.read(element).snapshot
            return MainWindowLayout.isChatroomsButton(role: node.role, identifier: node.identifier)
        }
        guard let button = AXNodeReader.firstDescendant(of: mainWindow.axElement, maxNodes: 300, where: {
            MainWindowLayout.isChatroomsButton(role: $0.snapshot.role, identifier: $0.snapshot.identifier)
        })?.element else {
            runner.log("chat tab: no \(MainWindowLayout.chatroomsButtonIdentifier) button either")
            return .unavailable
        }
        AXNodeReader.setMessagingTimeout(button, seconds: 2.0)
        guard isButton(button), beforePress() else {
            return .deferred
        }
        let status = AXNodeReader.perform(button, kAXPressAction)
        runner.log("chat tab: pressed the \(MainWindowLayout.chatroomsButtonIdentifier) button status=\(status.rawValue)")
        return status == .success || status == .cannotComplete ? .pressed : .unavailable
    }

    /// The main window's chat list, verified (`ChatListCheck`). When the window shows another
    /// tab and `activity` is given, KakaoTalk's 창 > 채팅 is pressed once (after the
    /// user-activity guard; the "chatrooms" tab button only when that menu item is unavailable)
    /// and the chat table is awaited for up to 2 s. Throws CHAT_LIST_UNAVAILABLE (nothing read,
    /// nothing written) when it stays unverified.
    func verifiedAccess(in mainWindow: UIElement, activity: UserActivityGuard?) throws -> (access: ChatListAccess, switched: Bool, verified: Bool) {
        var access = self.access(in: mainWindow) ?? self.access(in: mainWindow, patience: Self.mainWindowRecheckDuration)
        var verification = verify(access, in: mainWindow)
        var switched = false
        while true {
            switch ChatTabMenu.decide(verification, mayPress: activity != nil, alreadySwitched: switched) {
            case .useTable:
                if let access {
                    return (access, switched, verification.isChatList)
                }
                throw Self.notChatList(verification, switched: switched)
            case .notChatTab:
                throw Self.notChatList(verification, switched: switched)
            case .switchTab:
                guard let activity else { throw Self.notChatList(verification, switched: switched) }
                var press = ChatTabPress.deferred
                while press == .deferred {
                    try activity.waitUntilClear(.switchToChatTab)
                    press = pressChatTabMenuItem(beforePress: { activity.mayPressNow(.switchToChatTab) })
                }
                if press == .unavailable {
                    press = .deferred
                    while press == .deferred {
                        try activity.waitUntilClear(.switchToChatTab)
                        press = pressChatroomsButton(in: mainWindow, beforePress: { activity.mayPressNow(.switchToChatTab) })
                    }
                }
                switched = true
                guard press == .pressed else { throw Self.notChatList(verification, switched: false) }
                let deadline = Date().addingTimeInterval(2.0)
                repeat {
                    Thread.sleep(forTimeInterval: 0.2)
                    access = self.access(in: mainWindow)
                    verification = verify(access, in: mainWindow)
                } while !verification.isChatList && Date() < deadline && !ReadInterruption.requested
            }
        }
    }

    static func notChatList(_ verification: ChatListVerification, switched: Bool) -> ReadFailure {
        var details = ["chat_list": "\(verification)"]
        if switched { details["main_window"] = MainWindowAction.switchedToChatTab.rawValue }
        return ReadFailure(
            code: "CHAT_LIST_UNAVAILABLE",
            message: switched
                ? "KakaoTalk's main window still does not show the chat list after 창 > 채팅 was pressed; nothing was read or recorded."
                : "KakaoTalk's main window does not show the chat list (another tab, e.g. 친구); nothing was read or recorded.",
            hint: "Switch KakaoTalk's main window to the 채팅 tab (⌘2) and retry (or unlock KakaoTalk if it is locked).",
            details: details
        )
    }

    /// What the window shows (`KakaoWindowClassifier`): a chat, the open-chat conversation
    /// list, or something unknown. Reads only; each direct child is flattened on its own budget
    /// so a long transcript cannot hide the others. `rowCount` is the open-chat list table's
    /// row count when that is what the window shows.
    func classifyWindow(_ window: UIElement) -> (kind: KakaoWindowKind, rowCount: Int?) {
        let windowNode = AXNodeReader.read(window.axElement)
        var nodes = [windowNode.snapshot]
        for child in windowNode.children {
            nodes += AXNodeReader.flatten(child, maxDepth: 4, budget: 300).map { snapshot in
                var shifted = snapshot
                shifted.depth += 1
                return shifted
            }
        }
        let kind = KakaoWindowClassifier.classify(nodes)
        guard case .openChatList = kind else {
            return (kind, nil)
        }
        let table = windowNode.children
            .first { AXNodeReader.read($0).snapshot.identifier == KakaoWindowClassifier.openChatListScrollAreaIdentifier }
            .flatMap { scrollArea in
                AXNodeReader.children(scrollArea).first {
                    AXNodeReader.read($0).snapshot.identifier == KakaoWindowClassifier.openChatListTableIdentifier
                }
            }
        return (kind, table.map { AXNodeReader.rowCount(of: $0) })
    }

    func hasTranscript(_ window: UIElement) -> Bool {
        AXNodeReader.children(window.axElement).contains { child in
            let node = AXNodeReader.read(child).snapshot
            return node.role == AXRoleName.scrollArea && node.identifier == Self.transcriptScrollAreaIdentifier
        }
    }

    // MARK: Chat list

    func access(in window: UIElement) -> ChatListAccess? {
        // Only an AXTable can be the chat list (the 친구 tab's list is an AXOutline).
        guard let table = AXNodeReader.firstDescendant(of: window.axElement, maxNodes: 300, where: {
            MainWindowLayout.isChatListContainer(role: $0.snapshot.role)
        }) else {
            return nil
        }
        let parent = AXNodeReader.elementAttribute(table.element, kAXParentAttribute)
        let scrollArea = parent.flatMap { element in
            AXNodeReader.read(element).snapshot.role == AXRoleName.scrollArea ? element : nil
        }
        return ChatListAccess(window: window, table: table.element, scrollArea: scrollArea)
    }

    /// The row's `_NS:40` title, read with three batched calls; falls back to a full row read.
    func title(of row: AXUIElement) -> String? {
        for cell in AXNodeReader.read(row).children.prefix(2) {
            for child in AXNodeReader.read(cell, depth: 1).children {
                let node = AXNodeReader.read(child, depth: 2).snapshot
                if node.identifier == ChatRowAnalyzer.titleIdentifier {
                    let title = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return title.isEmpty ? nil : title
                }
            }
        }
        return ChatListScanner.summarize(row: row).title
    }

    func located(_ index: Int, title: String, rows: [AXUIElement]) -> LocatedChatRow {
        LocatedChatRow(index: index, element: rows[index], title: title, summary: ChatListScanner.summarize(row: rows[index]))
    }

    /// Resolves a registry chat_id to its row (`ChatIdentityAssignment.resolve`).
    ///
    /// A retired ID fails with CHAT_ID_STALE. Fast path for reads (`requireUnique` false and
    /// the name unique in the registry): rows with the exact registered title are checked from
    /// the registry's last-seen index, and the first whose preview still matches is taken; with
    /// a changed preview it is taken only when it is the only row with that exact title.
    /// Otherwise (and always with `requireUnique`, used before sending) every row with the same
    /// normalized name is collected and the record must match exactly one of them by preview or
    /// by one-to-one elimination; never by position. Left-over same-name rooms that cannot be
    /// told apart fail with CHAT_AMBIGUOUS and list the candidates. The located record is then
    /// updated by chat_id; the assignment is not re-run.
    func locate(chatID: String, record: ChatIdentityRecord, in access: ChatListAccess, requireUnique: Bool = false) throws -> LocatedChatRow {
        if record.isRetired {
            throw Self.staleChatID(chatID, record: record)
        }
        let registry = ChatIdentityRegistryStore.shared
        let rows = AXNodeReader.rows(of: access.table)
        let exactName = Self.trimmed(record.displayName)
        let target = record.normalizedName
        let sameNameCount = registry.records(withNormalizedName: target).count
        runner.log("read: chat list rows=\(rows.count) same-name registry records=\(sameNameCount) unique=\(requireUnique)")

        var titleCache: [Int: String?] = [:]
        func titleAt(_ index: Int) -> String? {
            if let cached = titleCache[index] {
                return cached
            }
            let title = title(of: rows[index])
            titleCache[index] = title
            return title
        }

        if !requireUnique, sameNameCount <= 1 {
            var order: [Int] = []
            if let hint = record.lastSeenIndex {
                order = [hint, hint - 1, hint + 1, hint - 2, hint + 2].filter { rows.indices.contains($0) }
            }
            let hinted = Set(order)
            order += rows.indices.filter { !hinted.contains($0) }

            var exactRows: [LocatedChatRow] = []
            for (scanned, index) in order.enumerated() {
                try ReadInterruption.check("while scanning the chat list")
                guard titleAt(index) == exactName else { continue }
                let row = located(index, title: exactName, rows: rows)
                if previewMatches(row, record: record) {
                    runner.log("read: chat_id matched row \(index) after \(scanned + 1) title reads (hint \(record.lastSeenIndex.map(String.init) ?? "none"))")
                    return refreshRegistry(row, chatID: chatID)
                }
                exactRows.append(row)
            }
            if exactRows.count == 1 {
                runner.log("read: chat_id matched the only row titled exactly '\(exactName)' (preview changed)")
                return refreshRegistry(exactRows[0], chatID: chatID)
            }
        }

        var candidates: [LocatedChatRow] = []
        for index in rows.indices {
            try ReadInterruption.check("while scanning the chat list")
            guard let title = titleAt(index), ChatTextNormalizer.normalize(title) == target else { continue }
            candidates.append(located(index, title: title, rows: rows))
        }
        guard !candidates.isEmpty else {
            throw notInList(record.displayName, rowCount: rows.count)
        }
        let discoveries = candidates.map(Self.discovery)
        switch registry.resolution(of: chatID, among: discoveries) {
        case .row(let position):
            runner.log("read: chat_id matched row \(candidates[position].index) among \(candidates.count) same-name row(s)")
            return refreshRegistry(candidates[position], chatID: chatID)
        case .stale:
            throw Self.staleChatID(chatID, record: record)
        case .ambiguous:
            throw Self.ambiguousChatID(chatID, record: record, candidates: candidates)
        case .notFound:
            throw notInList(record.displayName, rowCount: rows.count)
        }
    }

    static func discovery(_ row: LocatedChatRow) -> ChatListDiscovery {
        ChatListDiscovery(
            title: row.title,
            lastMessage: row.summary.preview,
            listIndex: row.index,
            unread: row.summary.unread,
            timeLabel: row.summary.timeLabel,
            memberCount: row.summary.memberCount
        )
    }

    static func staleChatID(_ chatID: String, record: ChatIdentityRecord) -> ReadFailure {
        ReadFailure(
            code: "CHAT_ID_STALE",
            message: "chat_id '\(chatID)' ('\(record.displayName)') was retired: a chat-list scan could not tell its room apart from another room with the same name, so it no longer points at any room.",
            hint: "Run 'kktcli chats' and use the room's current chat_id.",
            exitCode: KktcliExitStatus.staleChatID
        )
    }

    static func ambiguousChatID(_ chatID: String, record: ChatIdentityRecord, candidates: [LocatedChatRow]) -> ReadFailure {
        let lines = candidates.map { row -> String in
            let summary = row.summary
            let members = summary.memberCount.map { "\($0) members" } ?? "members unknown"
            return "\(row.title) | \(summary.preview ?? "-") | \(summary.timeLabel ?? "-") | \(members)"
        }
        return ReadFailure(
            code: "CHAT_AMBIGUOUS",
            message: "chat_id '\(chatID)' cannot be told apart among \(candidates.count) rooms named '\(record.displayName)'; nothing was opened.",
            hint: "Run 'kktcli chats' for fresh chat_ids and pick the room by its preview and time.",
            exitCode: KktcliExitStatus.ambiguousChatID,
            details: ["candidates": lines.joined(separator: "\n"), "candidate_count": String(candidates.count)]
        )
    }

    /// Scans titles for a name query and stops at the first row titled exactly `query`.
    /// Without one, a single normalized match wins, several are ambiguous, then fuzzy matching.
    func choose(query: String, in access: ChatListAccess) -> (choice: ChatQueryChoice, rows: [AXUIElement]) {
        let rows = AXNodeReader.rows(of: access.table)
        let wanted = Self.trimmed(query)
        var titles: [(index: Int, title: String)] = []
        for (index, row) in rows.enumerated() {
            if ReadInterruption.requested {
                break
            }
            guard let title = title(of: row) else { continue }
            // The query may also be the window title of a "팀채팅, …" row.
            if title == wanted || RoomTitle.windowMatchesRow(windowTitle: wanted, rowTitle: title) {
                runner.log("read: exact title match at row \(index) after scanning \(index + 1) of \(rows.count) rows")
                return (.match(index: index, title: title, exact: true), rows)
            }
            titles.append((index, title))
        }
        return (ChatQueryMatcher.choose(query: query, titles: titles), rows)
    }

    /// The unread badge the chat list shows now for the room `row` was located as, or nil when
    /// that row cannot be identified again. Reads only: the same row element first, then the
    /// rows at and next to its old index (the list shifts when other rooms get messages). A row
    /// counts only with exactly the same title, and a neighbour only when it is the only one.
    func currentUnreadBadge(of row: LocatedChatRow) -> UnreadBadge? {
        let wanted = Self.trimmed(row.title)
        let sameElement = ChatListScanner.summarize(row: row.element)
        if Self.trimmed(sameElement.title) == wanted {
            return sameElement.unread
        }
        guard let main = mainWindow(), let access = access(in: main) else { return nil }
        let rows = AXNodeReader.rows(of: access.table)
        let matches = [row.index, row.index - 1, row.index + 1, row.index - 2, row.index + 2]
            .filter { rows.indices.contains($0) && title(of: rows[$0]) == wanted }
        guard matches.count == 1 else { return nil }
        let summary = ChatListScanner.summarize(row: rows[matches[0]])
        return Self.trimmed(summary.title) == wanted ? summary.unread : nil
    }

    private func previewMatches(_ row: LocatedChatRow, record: ChatIdentityRecord) -> Bool {
        guard let registered = record.lastPreviewNormalized, !registered.isEmpty else { return true }
        return ChatTextNormalizer.normalize(row.summary.preview ?? "") == registered
    }

    /// Updates the located record by chat_id; never re-runs the assignment.
    private func refreshRegistry(_ row: LocatedChatRow, chatID: String) -> LocatedChatRow {
        ChatIdentityRegistryStore.shared.refresh(chatID: chatID, with: Self.discovery(row))
        return row
    }

    private func notInList(_ name: String, rowCount: Int) -> ReadFailure {
        ReadFailure(
            code: "CHAT_NOT_IN_LIST",
            message: "No chat-list row is titled '\(name)' (\(rowCount) rows checked).",
            hint: "Run 'kktcli chats' to refresh chat_ids, or check that the chat list (채팅 tab) is showing."
        )
    }
}
