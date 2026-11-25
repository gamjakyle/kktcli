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

    func mainWindow() -> UIElement? {
        mainWindow(among: kakao.windows)
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

    /// Returns the main window, reopening it once (`open KakaoTalk.app`, as the legacy
    /// recovery did) when the app runs without one.
    enum MainWindowAction: String {
        case openedViaMenuItem = "opened_via_menu_item"
        case openedViaOpenCommand = "opened_via_open_command"
    }

    /// Returns the main window. A missing one is brought back by pressing KakaoTalk's
    /// "카카오톡 열기" menu item (`showFirstWindow:`) only as `access` allows (KakaoTalk already
    /// frontmost, or --allow-activate; idle user); `open KakaoTalk.app`, which activates
    /// KakaoTalk, is only used as a last resort when `allowOpenCommand` (--deep-recovery).
    func requireMainWindow(allowOpenCommand: Bool, access: MainWindowAccess) throws -> (window: UIElement, action: MainWindowAction?) {
        if let main = mainWindow() {
            return (main, nil)
        }
        let pressed: Bool
        switch try access.reopen(kakao: kakao, locator: self) {
        case .alreadyVisible(let main):
            return (main, nil)
        case .pressed:
            if let main = waitForMainWindow(timeout: 3.0) {
                return (main, .openedViaMenuItem)
            }
            pressed = true
        case .unavailable:
            pressed = false
        }
        guard allowOpenCommand else {
            throw ReadFailure(
                code: "WINDOW_NOT_READY",
                message: pressed
                    ? "[WINDOW_NOT_READY] KakaoTalk's main window did not appear after pressing \(MainWindowMenuItem.title)."
                    : "[WINDOW_NOT_READY] KakaoTalk's main window (chat list) is not open and the \(MainWindowMenuItem.title) menu item was unavailable.",
                hint: "Open KakaoTalk's main window on the 채팅 tab and retry, or pass --deep-recovery to reopen it with open KakaoTalk.app (activates KakaoTalk)."
            )
        }

        runner.log("read: main window still missing; reopening it via open KakaoTalk.app")
        try access.forceOpen()
        if let main = waitForMainWindow(timeout: 3.0) {
            return (main, .openedViaOpenCommand)
        }
        throw ReadFailure(
            code: "WINDOW_NOT_READY",
            message: "[WINDOW_NOT_READY] KakaoTalk's main window (chat list) did not appear.",
            hint: "Open KakaoTalk's main window on the 채팅 tab and retry."
        )
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
        guard let table = AXNodeReader.firstDescendant(of: window.axElement, maxNodes: 300, where: {
            $0.snapshot.role == AXRoleName.table
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

    /// Resolves a registry chat_id to its row.
    ///
    /// Fast path (the name is unique in the registry): rows are checked for the exact registered
    /// title starting at the registry's last-seen index, and the first one whose preview still
    /// matches the registered preview (or that has none registered) is taken without reading
    /// the rest of the list. A changed preview keeps scanning titles, so a newer room with the
    /// same name is not mistaken for the registered one. Otherwise every row with the same
    /// normalized name is collected and the registry's preview/position matching decides.
    func locate(chatID: String, record: ChatIdentityRecord, in access: ChatListAccess) throws -> LocatedChatRow {
        let registry = ChatIdentityRegistryStore.shared
        let rows = AXNodeReader.rows(of: access.table)
        let exactName = Self.trimmed(record.displayName)
        let target = record.normalizedName
        let sameNameCount = registry.records(withNormalizedName: target).count
        runner.log("read: chat list rows=\(rows.count) same-name registry records=\(sameNameCount)")

        var titleCache: [Int: String?] = [:]
        func titleAt(_ index: Int) -> String? {
            if let cached = titleCache[index] {
                return cached
            }
            let title = title(of: rows[index])
            titleCache[index] = title
            return title
        }

        if sameNameCount <= 1 {
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
        if candidates.count == 1, sameNameCount <= 1 {
            return refreshRegistry(candidates[0], chatID: chatID)
        }
        let discoveries = candidates.map {
            ChatListDiscovery(title: $0.title, lastMessage: $0.summary.preview, listIndex: $0.index, unread: $0.summary.unread)
        }
        let assigned = registry.assignChatIDs(for: discoveries)
        guard let position = assigned.firstIndex(of: chatID) else {
            throw notInList(record.displayName, rowCount: rows.count)
        }
        runner.log("read: chat_id matched duplicate-title row \(candidates[position].index)")
        return candidates[position]
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

    private func refreshRegistry(_ row: LocatedChatRow, chatID: String) -> LocatedChatRow {
        let discovery = ChatListDiscovery(title: row.title, lastMessage: row.summary.preview, listIndex: row.index, unread: row.summary.unread)
        let assigned = ChatIdentityRegistryStore.shared.assignChatIDs(for: [discovery])
        if assigned.first != chatID {
            runner.log("read: registry assigned '\(assigned.first ?? "")' to the matched row (expected \(chatID))")
        }
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
