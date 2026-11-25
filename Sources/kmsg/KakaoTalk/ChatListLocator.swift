import ApplicationServices.HIServices
import Foundation
import KmsgCore

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

    func existingWindow(exactTitle title: String) -> UIElement? {
        let target = ChatTextNormalizer.normalize(title)
        guard !target.isEmpty else { return nil }
        return chatWindows().first { ChatTextNormalizer.normalize($0.title ?? "") == target }
    }

    /// Best partial title match among open chat windows.
    func existingWindow(query: String) -> UIElement? {
        chatWindows()
            .compactMap { window -> (window: UIElement, score: Int)? in
                guard let title = window.title else { return nil }
                let score = ChatQueryMatcher.score(query: query, candidate: title)
                return score > 0 ? (window, score) : nil
            }
            .max { $0.score < $1.score }?
            .window
    }

    func mainWindow() -> UIElement? {
        let windows = kakao.windows
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

    /// Returns the main window, reopening it once (`open KakaoTalk.app`, as the legacy
    /// recovery did) when the app runs without one.
    func requireMainWindow(allowReopen: Bool) throws -> UIElement {
        if let main = mainWindow() {
            return main
        }
        guard allowReopen else {
            throw ReadFailure(
                code: "WINDOW_NOT_READY",
                message: "[WINDOW_NOT_READY] KakaoTalk's main window (chat list) is not open.",
                hint: "Open KakaoTalk's main window on the 채팅 tab and retry."
            )
        }

        runner.log("read: main window not exposed; reopening it via open KakaoTalk.app")
        _ = KakaoTalkApp.forceOpen(timeout: 1.0)
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if let main = mainWindow() {
                return main
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ReadFailure(
            code: "WINDOW_NOT_READY",
            message: "[WINDOW_NOT_READY] KakaoTalk's main window (chat list) did not appear.",
            hint: "Open KakaoTalk's main window on the 채팅 tab and retry."
        )
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

    /// Resolves a registry chat_id to its row. Unique names stop at the first matching title,
    /// starting at the registry's last-seen index; duplicate names are disambiguated by the
    /// registry's preview/index matching over every row with that title.
    func locate(chatID: String, record: ChatIdentityRecord, in access: ChatListAccess) throws -> LocatedChatRow {
        let registry = ChatIdentityRegistryStore.shared
        let rows = AXNodeReader.rows(of: access.table)
        let target = record.normalizedName
        let sameNameCount = registry.records(withNormalizedName: target).count
        runner.log("read: chat list rows=\(rows.count) same-name registry records=\(sameNameCount)")

        func matchingTitle(_ index: Int) -> String? {
            guard let title = title(of: rows[index]) else { return nil }
            return ChatTextNormalizer.normalize(title) == target ? title : nil
        }

        if sameNameCount <= 1 {
            var probed = Set<Int>()
            if let hint = record.lastSeenIndex {
                for index in [hint, hint - 1, hint + 1, hint - 2, hint + 2] where rows.indices.contains(index) {
                    probed.insert(index)
                    if let title = matchingTitle(index) {
                        runner.log("read: chat_id matched at registry hint index \(index) (hint \(hint))")
                        return refreshRegistry(located(index, title: title, rows: rows), chatID: chatID)
                    }
                }
            }
            for index in rows.indices where !probed.contains(index) {
                if let title = matchingTitle(index) {
                    runner.log("read: chat_id matched at row \(index) after scanning \(index + 1) rows")
                    return refreshRegistry(located(index, title: title, rows: rows), chatID: chatID)
                }
            }
            throw notInList(record.displayName, rowCount: rows.count)
        }

        var candidates: [LocatedChatRow] = []
        for index in rows.indices {
            if let title = matchingTitle(index) {
                candidates.append(located(index, title: title, rows: rows))
            }
        }
        guard !candidates.isEmpty else {
            throw notInList(record.displayName, rowCount: rows.count)
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

    /// Scans titles for a name query and stops at the first exact (normalized) match.
    func choose(query: String, in access: ChatListAccess) -> (choice: ChatQueryChoice, rows: [AXUIElement]) {
        let rows = AXNodeReader.rows(of: access.table)
        var titles: [(index: Int, title: String)] = []
        for (index, row) in rows.enumerated() {
            guard let title = title(of: row) else { continue }
            if ChatQueryMatcher.score(query: query, candidate: title) == ChatQueryMatcher.exactScore {
                runner.log("read: exact title match at row \(index) after scanning \(index + 1) of \(rows.count) rows")
                return (.match(index: index, title: title, exact: true), rows)
            }
            titles.append((index, title))
        }
        return (ChatQueryMatcher.choose(query: query, titles: titles), rows)
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
            hint: "Run 'kmsg chats' to refresh chat_ids, or check that the chat list (채팅 tab) is showing."
        )
    }
}
