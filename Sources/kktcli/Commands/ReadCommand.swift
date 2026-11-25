import ArgumentParser
import Foundation
import KktcliCore

extension ChatWindowLayoutMode: ExpressibleByArgument {}

struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read messages from a chat",
        discussion: """
            Use either:
              kktcli read <chat>
              kktcli read --chat-id <chat-id>
              kktcli read --chat-id <a> --chat-id <b> ... | --chat-ids-file <file>

            Several chat_ids are read one after another in one run (one login check, one
            Accessibility session) and printed as one JSON document with a result per chat.

            An already open chat window is read in place. Otherwise the chat is found in the chat
            list and opened through its context menu (채팅방 열기) with Accessibility actions only:
            no keystrokes or clicks are posted, so KakaoTalk may stay in the background.
            --legacy-open restores the old search/Enter based opening; it only posts input while
            KakaoTalk is the frontmost app.

            A room whose chat-list row shows unread messages is opened like any other, exactly as
            opening it by hand, which sends read receipts to the other participants. The JSON
            meta reports the badge seen before opening (unread_before), the badge after the
            window was closed (unread_after) and whether it disappeared (marked_read).
            --skip-unread leaves such rooms unopened (UNREAD_REFUSED or UNREAD_UNVERIFIED, exit
            status 3). Apart from the last-message preview in 'kktcli chats', there is no way to
            see unread messages without marking them read. --allow-unread is deprecated and has
            no effect.

            When fewer than --limit messages are loaded, older messages are loaded by scrolling
            the transcript to the top, bounded by --scrollback-timeout (on by default, off with
            --no-scrollback, and opt-in with --scrollback under --background-safe).

            Use --background-safe to read only already exposed chat windows without launching,
            activating, logging in, searching, opening rows, resizing, or closing windows.

            When author is "(me)", the message was sent by you; author is null when the sender
            could not be established (system lines, banners). date comes from the transcript's
            date separators; time_source is "label" when the message carries its own time and
            "inferred" when it takes the time of the next message of the same run.

            With --json, stdout always carries exactly one JSON document, also on failure
            ("ok": false with an error code and a non-zero exit status).
            """
    )

    @Option(name: .customLong("chat-id"), help: "Read using a chat_id from 'kktcli chats'; repeat it to read several chats in one run")
    var chatIDs: [String] = []

    @Option(
        name: .customLong("chat-ids-file"),
        help: "Read every chat_id listed in this file, one per line (blank lines and lines starting with # are ignored)"
    )
    var chatIDsFile: String?

    @Argument(help: "Name of the chat to read from (partial match supported)")
    var chat: String?

    @Option(name: .shortAndLong, help: "Maximum number of messages to show")
    var limit: Int = 20

    @Flag(name: .long, help: "Show raw element info for debugging")
    var debug: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: [.short, .long], help: "Keep auto-opened chat window after read")
    var keepWindow: Bool = false

    @Flag(
        name: .long,
        help: "Do not activate, search, open, resize, or close KakaoTalk windows; only read already exposed matching chat windows"
    )
    var backgroundSafe: Bool = false

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Enable deep window recovery when fast window detection fails",
            visibility: .default
        )
    )
    var deepRecovery: Bool = false

    @Option(name: .long, help: "Window layout before reading: preserve, left, right, split-left, or split-right")
    var layout: ChatWindowLayoutMode = .preserve

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(
        name: .long,
        help: "Do not open a chat whose chat-list row shows unread messages (UNREAD_REFUSED, exit status 3), so no read receipts are sent"
    )
    var skipUnread: Bool = false

    @Flag(name: .long, help: "Deprecated, no effect: chats with unread messages are opened by default (see --skip-unread)")
    var allowUnread: Bool = false

    @Flag(
        name: .long,
        help: "Open chats the old way (search typing, row select + Enter, double-click); input is posted only while KakaoTalk is frontmost"
    )
    var legacyOpen: Bool = false

    @Flag(name: .long, help: "Load older messages when fewer than --limit are loaded (default unless --background-safe)")
    var scrollback: Bool = false

    @Flag(name: .long, help: "Never scroll the transcript to load older messages")
    var noScrollback: Bool = false

    @Option(name: .long, help: "Time budget in seconds for loading older messages (automatic scrollback also stops ~6.5 s after start)")
    var scrollbackTimeout: Double = 4

    static let maximumLimit = 50_000
    static let maximumScrollbackTimeout: Double = 600
    /// Automatic (not explicitly requested) scrollback must leave time for the rest of the
    /// command: the MCP server kills `read` after 8 s, which would leave the window open.
    static let automaticWorkBudget: TimeInterval = 6.5
    /// After reading, a room that showed an unread badge has its chat-list row read again;
    /// while the badge is still shown it is re-read for up to this long, because KakaoTalk may
    /// clear it a moment after the window closes.
    static let unreadRecheckDuration: TimeInterval = 1.5
    /// Without an explicit --scrollback that re-check ends this long after start, inside the
    /// MCP server's 8 s limit.
    static let automaticWorkDeadline: TimeInterval = 7.0

    @Flag(name: .long, help: "Include system messages (joins, notices)")
    var includeSystem: Bool = false

    @Flag(
        name: .long,
        help: "Fetch the full text of long messages (KakaoTalk shows only the first 500 characters): presses only each one's 전체보기 control and closes what that opens (experimental)"
    )
    var fullText: Bool = false

    func validate() throws {
        // With --json the problem is reported as a JSON document from run().
        if !json, let problem = usageProblem() {
            throw ValidationError(problem)
        }
    }

    func run() throws {
        if isBatch {
            try runBatch()
            return
        }
        var outcome: ReadOutcome?
        var failure: ReadFailure?
        // stdout must carry only the final JSON document: anything printed on the way
        // (login/unlock progress) goes to stderr.
        withStdoutRedirectedToStderr(json) {
            do {
                outcome = try performRead()
            } catch let readFailure as ReadFailure {
                failure = readFailure
            } catch {
                failure = ReadFailure(code: "READ_FAILED", message: "\(error)")
            }
        }

        if let failure {
            report(failure)
            throw ExitCode(failure.exitCode)
        }
        if let outcome {
            try printOutcome(outcome)
        }
    }

    // MARK: - Flow

    private enum ReadTarget {
        case chatID(String, ChatIdentityRecord)
        case name(String)

        var label: String {
            switch self {
            case .chatID(let chatID, let record):
                return "\(record.displayName) (\(chatID))"
            case .name(let query):
                return query
            }
        }

        var exactTitle: String {
            switch self {
            case .chatID(_, let record):
                return record.displayName
            case .name(let query):
                return query
            }
        }
    }

    private enum OpenMethod: String {
        case existingWindow = "existing_window"
        case chatListMenu = "chat_list_menu"
        case legacyChatList = "legacy_chat_list"
        case legacySearch = "legacy_search"
    }

    private struct OpenedChat {
        let window: UIElement
        let method: OpenMethod
        let expectedTitle: String
        /// The chat-list row's unread badge right before this command opened the room
        /// (.none for a window that was already open).
        let unreadBefore: UnreadBadge
        /// Chat-list row title when the room was opened from the list. It can differ from the
        /// window title ("팀채팅, X" opens a window titled "X").
        var rowTitle: String? = nil
        /// The row the room was opened from, read again after reading for `unread_after`.
        var listRow: LocatedChatRow? = nil
        var listRecovery: ChatListRecoveryReport? = nil
        var mainWindowAction: ChatListLocator.MainWindowAction? = nil
        /// The window KakaoTalk opened has no title (open chats); `expectedTitle` is then the
        /// row title without its room-type prefix and is not checked when closing.
        var windowTitleEmpty = false

        var openedTransiently: Bool {
            method != .existingWindow
        }
    }

    private struct ReadOutcome {
        let chat: String
        let fetchedAt: Date
        let result: StructuredTranscriptResult
        let openedVia: OpenMethod
        let rowTitle: String?
        let unreadBefore: UnreadBadge
        let unreadAfter: UnreadBadge?
        let markedRead: Bool?
        let windowState: String
        let windowDetail: String?
        let windowTitleEmpty: Bool
        let listRecovery: ChatListRecoveryReport?
        let mainWindow: String?
    }

    private var scrollbackEnabled: Bool {
        if noScrollback { return false }
        return scrollback || !backgroundSafe
    }

    /// Non-empty `--chat-id` values.
    private var givenChatIDs: [String] {
        chatIDs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The chat_id of a one-chat read (nil for a name or a batch).
    private var chatID: String? {
        givenChatIDs.count == 1 && chatIDsFile == nil ? givenChatIDs[0] : nil
    }

    /// Several chats: more than one --chat-id, or --chat-ids-file.
    private var isBatch: Bool {
        givenChatIDs.count > 1 || chatIDsFile != nil
    }

    private func usageProblem() -> String? {
        if !givenChatIDs.isEmpty || chatIDsFile != nil {
            if chat != nil {
                return "Chat name cannot be provided together with --chat-id or --chat-ids-file."
            }
        } else if (chat ?? "").isEmpty {
            return "Chat name is required unless --chat-id or --chat-ids-file is provided."
        }
        if limit < 1 || limit > Self.maximumLimit {
            return "--limit must be between 1 and \(Self.maximumLimit)."
        }
        if scrollback && noScrollback {
            return "--scrollback and --no-scrollback cannot be used together."
        }
        if fullText && backgroundSafe {
            return "--full-text cannot be used with --background-safe (it presses 전체보기 and closes what that opens)."
        }
        if scrollbackTimeout < 0 || scrollbackTimeout > Self.maximumScrollbackTimeout {
            return "--scrollback-timeout must be between 0 and \(Int(Self.maximumScrollbackTimeout)) seconds."
        }
        return nil
    }

    private func performRead() throws -> ReadOutcome {
        let startedAt = Date()
        try checkUsage()
        let target = try resolveTarget()
        let session = try startSession()
        return try readRoom(target, session: session, startedAt: startedAt)
    }

    private func checkUsage() throws {
        if let problem = usageProblem() {
            throw ReadFailure(code: "INVALID_ARGUMENT", message: problem, exitCode: ExitCode.validationFailure.rawValue)
        }
        if allowUnread {
            writeStderr("Note: --allow-unread is deprecated and has no effect; chats with unread messages are opened by default (--skip-unread leaves them unopened).\n")
        }
    }

    /// What one run sets up once, whether it reads one chat or several.
    private struct Session {
        let runner: AXActionRunner
        let kakao: KakaoTalkApp
        let resolver: ChatWindowResolver
        let locator: ChatListLocator
        /// How a closed main window was brought back before the login check, if it was
        /// (reported with the first chat only).
        var mainWindowAction: ChatListLocator.MainWindowAction?
    }

    private func startSession() throws -> Session {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ReadFailure(
                code: "ACCESSIBILITY_PERMISSION_DENIED",
                message: "Accessibility permission is not granted to kktcli.",
                hint: "Grant it in System Settings > Privacy & Security > Accessibility (손쉬운 사용)."
            )
        }

        let runner = AXActionRunner(traceEnabled: traceAX)

        // A closed main window is brought back with KakaoTalk's "카카오톡 열기" menu item before
        // the login check runs; otherwise that check would reopen it with `open KakaoTalk.app`
        // or activate KakaoTalk.
        var mainWindowAction: ChatListLocator.MainWindowAction?
        if !backgroundSafe, KakaoTalkApp.isRunning, let early = try? KakaoTalkApp(autoLaunch: false) {
            let earlyLocator = ChatListLocator(kakao: early, runner: runner)
            if earlyLocator.mainWindow() == nil, earlyLocator.pressShowMainWindowMenuItem(),
               earlyLocator.waitForMainWindow(timeout: 3.0) != nil
            {
                mainWindowAction = .openedViaMenuItem
            }
        }

        let kakao: KakaoTalkApp
        do {
            kakao = backgroundSafe
                ? try KakaoTalkApp(autoLaunch: false)
                : try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        } catch {
            throw Self.startupFailure(error)
        }

        let chatWindowResolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            deepRecoveryEnabled: deepRecovery,
            layoutMode: layout,
            interactionMode: backgroundSafe ? .backgroundSafe : .allowUIAutomation
        )
        let locator = ChatListLocator(kakao: kakao, runner: runner)
        // From here on Ctrl-C / SIGTERM stops the bounded loops early instead of killing the
        // process, so a window opened below is still closed and a document is still printed.
        ReadInterruption.install()
        return Session(runner: runner, kakao: kakao, resolver: chatWindowResolver, locator: locator, mainWindowAction: mainWindowAction)
    }

    /// Opens (or finds) one chat, reads it and closes what it opened. `startedAt` anchors the
    /// automatic time budget (the MCP server stops `read` after 8 s).
    private func readRoom(_ target: ReadTarget, session: Session, startedAt: Date) throws -> ReadOutcome {
        let runner = session.runner
        let kakao = session.kakao
        let chatWindowResolver = session.resolver
        let locator = session.locator
        var mainWindowAction = session.mainWindowAction
        let fetchedAt = Date()
        let opened: OpenedChat
        do {
            opened = try open(target, kakao: kakao, resolver: chatWindowResolver, locator: locator, runner: runner)
        } catch let failure as ReadFailure {
            if let mainWindowAction {
                throw failure.adding(["main_window": mainWindowAction.rawValue])
            }
            throw failure
        }
        mainWindowAction = opened.mainWindowAction ?? mainWindowAction
        runner.log("read: chat window via \(opened.method.rawValue) title='\(opened.window.title ?? "")'")

        let chatTitle = OpenedWindowRule.isUntitled(opened.window.title) ? opened.expectedTitle : (opened.window.title ?? opened.expectedTitle)
        var result: StructuredTranscriptResult?
        let parts = opened.openedTransiently
            ? StructuredTranscriptReader.waitForParts(in: opened.window, timeout: 1.5)
            : StructuredTranscriptReader.parts(in: opened.window)
        if let parts {
            var budget = scrollbackTimeout
            if !scrollback {
                budget = min(budget, max(0, Self.automaticWorkBudget - Date().timeIntervalSince(startedAt)))
            }
            result = StructuredTranscriptReader(runner: runner).read(
                parts,
                options: TranscriptReadOptions(
                    limit: limit,
                    includeSystem: includeSystem,
                    scrollback: scrollbackEnabled,
                    scrollbackTimeout: budget
                ),
                fullText: fullText ? FullTextFetcher(kakao: kakao, runner: runner) : nil
            )
        }

        let (windowState, windowDetail) = finishWindow(opened, resolver: chatWindowResolver, target: target, runner: runner)

        guard let result else {
            var details = ["window": windowState]
            if let windowDetail { details["window_detail"] = windowDetail }
            throw ReadFailure(
                code: "TRANSCRIPT_UNAVAILABLE",
                message: "Could not locate the chat transcript in window '\(chatTitle)'.",
                hint: "Use 'kktcli inspect --window <n>' to inspect the opened chat window.",
                details: details
            )
        }

        let unreadAfter = recheckUnread(opened, locator: locator, startedAt: startedAt, runner: runner)
        return ReadOutcome(
            chat: chatTitle,
            fetchedAt: fetchedAt,
            result: result,
            openedVia: opened.method,
            rowTitle: opened.rowTitle,
            unreadBefore: opened.unreadBefore,
            unreadAfter: unreadAfter,
            markedRead: UnreadReceipt.markedRead(before: opened.unreadBefore, after: unreadAfter),
            windowState: windowState,
            windowDetail: windowDetail,
            windowTitleEmpty: opened.windowTitleEmpty,
            listRecovery: opened.listRecovery,
            mainWindow: mainWindowAction?.rawValue
        )
    }

    private func resolveTarget() throws -> ReadTarget {
        if let chatID {
            return try Self.target(forChatID: chatID)
        }
        return .name(chat ?? "")
    }

    private static func target(forChatID chatID: String) throws -> ReadTarget {
        do {
            guard let record = ChatIdentityRegistryStore.shared.record(for: chatID) else {
                throw ReadFailure(
                    code: "UNKNOWN_CHAT_ID",
                    message: "Unknown chat_id '\(chatID)'.",
                    hint: "Run 'kktcli chats' first to refresh the local registry."
                )
            }
            return .chatID(chatID, record)
        }
    }

    private func open(
        _ target: ReadTarget,
        kakao: KakaoTalkApp,
        resolver: ChatWindowResolver,
        locator: ChatListLocator,
        runner: AXActionRunner
    ) throws -> OpenedChat {
        func existing(_ window: UIElement) -> OpenedChat {
            runner.log("read: found existing chat window")
            resolver.applyLayoutIfRequested(window, label: "existing chat window")
            return OpenedChat(window: window, method: .existingWindow, expectedTitle: window.title ?? target.exactTitle, unreadBefore: .none)
        }

        // 1. An already open window with exactly this title: nothing is opened.
        if let window = locator.existingWindow(exactTitle: target.exactTitle) {
            return existing(window)
        }

        if backgroundSafe {
            if case .name(let query) = target, let window = locator.existingWindow(query: query) {
                runner.log("background-safe: matched already exposed chat window")
                return existing(window)
            }
            throw ReadFailure(
                code: "BACKGROUND_SAFE_BLOCKED",
                message: "[BACKGROUND_SAFE_BLOCKED] No already exposed chat window matched '\(target.label)'. " +
                    "Background-safe mode does not activate KakaoTalk, open chat rows, search, resize, or close windows.",
                hint: "Open the chat window first, or run without --background-safe.",
                details: ["available_windows": "\(kakao.windows.count) title(s) hidden in background-safe mode"]
            )
        }

        if legacyOpen {
            if let window = locator.existingWindow(query: target.exactTitle) {
                return existing(window)
            }
            return try openLegacy(target, resolver: resolver, locator: locator)
        }

        // 2. The chat list, opened through the row's context menu.
        let (mainWindow, mainWindowAction) = try locator.requireMainWindow(allowOpenCommand: deepRecovery)
        var access = locator.access(in: mainWindow)
        var listRecovery: ChatListRecoveryReport?

        // Only when the wanted row is missing: a leftover search filter may hide it. Restores the
        // full list at most once (취소 in the search field and the top-bar 검색 toggle only).
        func recoverList(lastSeenIndex: Int?) -> Bool {
            guard listRecovery == nil else { return false }
            listRecovery = ChatListRecoverer(kakao: kakao, runner: runner).recover(
                in: mainWindow,
                table: access?.table,
                registryRowCount: ChatIdentityRegistryStore.shared.knownRowCount(),
                targetLastSeenIndex: lastSeenIndex
            )
            guard listRecovery?.restored == true else { return false }
            access = locator.access(in: mainWindow)
            return access != nil
        }
        func withRecoveryDetails(_ failure: ReadFailure) -> ReadFailure {
            var extra: [String: String] = [:]
            if let listRecovery { extra["list_recovery"] = listRecovery.summary }
            if let mainWindowAction { extra["main_window"] = mainWindowAction.rawValue }
            return failure.adding(extra)
        }

        var targetLastSeenIndex: Int?
        if case .chatID(_, let record) = target {
            targetLastSeenIndex = record.lastSeenIndex
        }
        if access == nil {
            _ = recoverList(lastSeenIndex: targetLastSeenIndex)
        }
        guard var listAccess = access else {
            throw withRecoveryDetails(ReadFailure(
                code: "CHAT_LIST_UNAVAILABLE",
                message: "KakaoTalk's main window shows no chat list table.",
                hint: "Switch KakaoTalk's main window to the 채팅 tab and retry."
            ))
        }

        let row: LocatedChatRow
        switch target {
        case .chatID(let chatID, let record):
            do {
                row = try locator.locate(chatID: chatID, record: record, in: listAccess)
            } catch let failure as ReadFailure where failure.code == "CHAT_NOT_IN_LIST" {
                guard recoverList(lastSeenIndex: record.lastSeenIndex), let recovered = access else {
                    throw withRecoveryDetails(failure)
                }
                listAccess = recovered
                do {
                    row = try locator.locate(chatID: chatID, record: record, in: listAccess)
                } catch let again as ReadFailure {
                    throw withRecoveryDetails(again)
                }
            }
        case .name(let query):
            var (choice, rows) = locator.choose(query: query, in: listAccess)
            if case .none = choice, locator.existingWindow(query: query) == nil,
               recoverList(lastSeenIndex: nil), let recovered = access
            {
                listAccess = recovered
                (choice, rows) = locator.choose(query: query, in: listAccess)
            }
            switch choice {
            case .match(let index, let title, let exact):
                // Prefer an open window over opening a room for a partial match.
                if !exact, let window = locator.existingWindow(query: query) {
                    return existing(window)
                }
                row = locator.located(index, title: title, rows: rows)
            case .ambiguous(let titles):
                if let window = locator.existingWindow(query: query) {
                    return existing(window)
                }
                throw ReadFailure(
                    code: "AMBIGUOUS_CHAT",
                    message: "'\(query)' matches several chats equally well: \(titles.prefix(8).joined(separator: ", ")).",
                    hint: "Use the exact chat name, or --chat-id from 'kktcli chats'."
                )
            case .none:
                if let window = locator.existingWindow(query: query) {
                    return existing(window)
                }
                throw withRecoveryDetails(ReadFailure(
                    code: "CHAT_NOT_IN_LIST",
                    message: "No chat-list row matches '\(query)'.",
                    hint: "Check the name with 'kktcli chats'. --legacy-open searches instead (posts keystrokes; KakaoTalk must be frontmost)."
                ))
            }
        }

        let openedRoom: ChatRoomMenuOpener.OpenedRoom
        do {
            openedRoom = try ChatRoomMenuOpener(kakao: kakao, runner: runner).open(row, access: listAccess, skipUnread: skipUnread)
        } catch let failure as ReadFailure {
            throw withRecoveryDetails(failure)
        }
        let window = openedRoom.window
        if !openedRoom.isNewWindow {
            // 채팅방 열기 only brought up a window that was already open: read it, leave it open.
            runner.log("read: the room's window was already open; it is left open")
            var existingChat = existing(window)
            existingChat.rowTitle = row.title
            existingChat.listRecovery = listRecovery
            existingChat.mainWindowAction = mainWindowAction
            return existingChat
        }
        resolver.applyLayoutIfRequested(window, label: "opened chat window")
        let roomTitle = RoomTitle.expectedWindowTitle(forRowTitle: row.title)
        return OpenedChat(
            window: window,
            method: .chatListMenu,
            expectedTitle: openedRoom.windowTitleEmpty ? roomTitle : (window.title ?? roomTitle),
            unreadBefore: openedRoom.unreadBefore,
            rowTitle: row.title,
            listRow: row,
            listRecovery: listRecovery,
            mainWindowAction: mainWindowAction,
            windowTitleEmpty: openedRoom.windowTitleEmpty
        )
    }

    private func openLegacy(_ target: ReadTarget, resolver: ChatWindowResolver, locator: ChatListLocator) throws -> OpenedChat {
        let listRow = try legacyUnreadPrecheck(target, locator: locator)
        let resolution: ChatWindowResolution
        do {
            switch target {
            case .chatID(let chatID, _):
                resolution = try resolver.resolve(chatID: chatID)
            case .name(let query):
                resolution = try resolver.resolve(query: query)
            }
        } catch {
            throw Self.legacyFailure(error)
        }

        let method: OpenMethod
        switch resolution.method {
        case .existingWindow:
            method = .existingWindow
        case .openedViaChatList:
            method = .legacyChatList
        case .openedViaSearch:
            method = .legacySearch
        }
        let openedHere = method != .existingWindow
        return OpenedChat(
            window: resolution.window,
            method: method,
            expectedTitle: resolution.window.title ?? target.exactTitle,
            unreadBefore: openedHere ? (listRow?.summary.unread ?? .none) : .none,
            listRow: openedHere ? listRow : nil
        )
    }

    /// The legacy path cannot re-check the row right before it opens the room, so the row is
    /// read from the chat list first: its badge is reported as `unread_before`, and with
    /// --skip-unread a room with a badge, or one whose row is missing, is not opened.
    private func legacyUnreadPrecheck(_ target: ReadTarget, locator: ChatListLocator) throws -> LocatedChatRow? {
        var row: LocatedChatRow?
        if let mainWindow = locator.mainWindow(), let access = locator.access(in: mainWindow) {
            switch target {
            case .chatID(let chatID, let record):
                row = try? locator.locate(chatID: chatID, record: record, in: access)
            case .name(let query):
                let (choice, rows) = locator.choose(query: query, in: access)
                if case .match(let index, let title, _) = choice {
                    row = locator.located(index, title: title, rows: rows)
                }
            }
        }

        guard let row else {
            guard skipUnread else {
                return nil
            }
            throw ReadFailure(
                code: "UNREAD_UNVERIFIED",
                message: "'\(target.label)' is missing from the chat list, so --skip-unread cannot check its unread state before the legacy path opens it.",
                hint: "Run without --skip-unread to open it (that sends read receipts if there are unread messages).",
                exitCode: ReadFailure.refusedExitCode
            )
        }
        if row.summary.unread.isUnread, skipUnread {
            throw ChatRoomMenuOpener.unreadRefusal(title: row.title, badge: row.summary.unread)
        }
        return row
    }

    /// Reads the room's chat-list row again after the window was closed (with --keep-window,
    /// after reading) and returns the unread badge it shows then. Done only when this command
    /// opened the room and its row showed a badge (or could not be read completely) before;
    /// while a badge is still shown the row is re-read until `unreadRecheckDuration` passes.
    /// nil when not checked or when the row could not be identified again.
    private func recheckUnread(_ opened: OpenedChat, locator: ChatListLocator, startedAt: Date, runner: AXActionRunner) -> UnreadBadge? {
        guard opened.openedTransiently, opened.unreadBefore.isUnread, let row = opened.listRow,
              !ReadInterruption.requested
        else {
            return nil
        }
        var deadline = Date().addingTimeInterval(Self.unreadRecheckDuration)
        if !scrollback {
            deadline = min(deadline, startedAt.addingTimeInterval(Self.automaticWorkDeadline))
        }
        var latest: UnreadBadge?
        var checks = 0
        while true {
            checks += 1
            if let badge = locator.currentUnreadBadge(of: row) {
                latest = badge
                if !badge.isUnread {
                    break
                }
            }
            if Date() >= deadline || ReadInterruption.requested {
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        let after = latest.map { $0.evidence ?? "none" } ?? "row not found"
        runner.log("read: unread badge before='\(opened.unreadBefore.evidence ?? "none")' after='\(after)' (\(checks) check(s))")
        return latest
    }

    /// Closes a window this command opened, via its AXCloseButton only.
    private func finishWindow(
        _ opened: OpenedChat,
        resolver: ChatWindowResolver,
        target: ReadTarget,
        runner: AXActionRunner
    ) -> (state: String, detail: String?) {
        guard opened.openedTransiently else {
            return ("untouched", nil)
        }
        if keepWindow {
            runner.log("read: auto-opened chat window kept by --keep-window")
            return ("kept_open", nil)
        }
        if opened.window.identifier == ChatListLocator.mainWindowIdentifier {
            return ("left_open", "refused_main_window")
        }
        if opened.method == .legacySearch, case .name(let query) = target {
            let resolvedTitle = opened.window.title ?? ""
            if !resolvedTitle.isEmpty && !resolvedTitle.localizedCaseInsensitiveContains(query)
                && !RoomTitle.windowMatchesRow(windowTitle: resolvedTitle, rowTitle: query)
            {
                runner.log("read: skipped auto-close because resolved title '\(resolvedTitle)' did not match query")
                return ("left_open", "title_does_not_match_query")
            }
        }

        // A window opened through the chat-list menu appeared after this command's own press and
        // did not exist before, so it is closed whatever its title is now (open chats may have
        // none). Windows from the legacy paths must still show the title they were opened with.
        let outcome = resolver.closeWindowViaCloseButton(
            opened.window,
            expectedTitle: opened.method == .chatListMenu ? nil : opened.expectedTitle
        )
        if outcome == .closed {
            runner.log("read: auto-opened chat window closed")
            return ("closed", nil)
        }
        runner.log("read: auto-opened chat window left open (\(outcome.code))")
        return ("left_open", outcome.code)
    }

    // MARK: - Errors

    private static func startupFailure(_ error: Error) -> ReadFailure {
        if let kakaoError = error as? KakaoTalkError {
            switch kakaoError {
            case .appNotRunning:
                return ReadFailure(
                    code: "KAKAO_NOT_RUNNING",
                    message: kakaoError.description,
                    hint: "Launch KakaoTalk, or run without --background-safe to let kktcli launch it."
                )
            case .launchFailed:
                return ReadFailure(code: "KAKAO_LAUNCH_FAILED", message: kakaoError.description)
            default:
                return ReadFailure(code: "KAKAO_UNAVAILABLE", message: kakaoError.description)
            }
        }
        if let authError = error as? AuthenticationError {
            return ReadFailure(code: "KAKAO_AUTH_FAILED", message: authError.errorDescription ?? "\(authError)")
        }
        return ReadFailure(code: "KAKAO_UNAVAILABLE", message: "\(error)")
    }

    private static func legacyFailure(_ error: Error) -> ReadFailure {
        let text = "\(error)"
        for code in ["NOT_FRONTMOST", "SEARCH_MISS", "WINDOW_NOT_READY", "FOCUS_FAIL", "INPUT_NOT_REFLECTED"] where text.contains(code) {
            return ReadFailure(code: code, message: text)
        }
        return ReadFailure(code: "LEGACY_OPEN_FAILED", message: text)
    }

    // MARK: - Output

    private struct ReadMeta: Encodable {
        let openedVia: String
        let rowTitle: String?
        let mainWindow: String?
        let listRecovery: ChatListRecoveryReport?
        let window: String
        let windowDetail: String?
        let windowTitleEmpty: Bool
        let unreadBefore: String?
        let unreadAfter: String?
        let markedRead: Bool?
        let rowsTotal: Int
        let rowsRead: Int
        let dateFromEarlierSeparator: Bool
        let scrollback: ScrollbackReport?
        let interrupted: Bool
        let truncatedMessages: Int
        let fullText: FullTextFetcher.Report?

        enum CodingKeys: String, CodingKey {
            case openedVia = "opened_via"
            case rowTitle = "row_title"
            case mainWindow = "main_window"
            case listRecovery = "list_recovery"
            case window
            case windowDetail = "window_detail"
            case windowTitleEmpty = "window_title_empty"
            case unreadBefore = "unread_before"
            case unreadAfter = "unread_after"
            case markedRead = "marked_read"
            case rowsTotal = "rows_total"
            case rowsRead = "rows_read"
            case dateFromEarlierSeparator = "date_from_earlier_separator"
            case scrollback
            case interrupted
            case truncatedMessages = "truncated_messages"
            case fullText = "full_text"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(openedVia, forKey: .openedVia)
            try container.encode(rowTitle, forKey: .rowTitle)
            try container.encode(mainWindow, forKey: .mainWindow)
            try container.encode(listRecovery, forKey: .listRecovery)
            try container.encode(window, forKey: .window)
            try container.encode(windowDetail, forKey: .windowDetail)
            try container.encode(windowTitleEmpty, forKey: .windowTitleEmpty)
            try container.encode(unreadBefore, forKey: .unreadBefore)
            try container.encode(unreadAfter, forKey: .unreadAfter)
            try container.encode(markedRead, forKey: .markedRead)
            try container.encode(rowsTotal, forKey: .rowsTotal)
            try container.encode(rowsRead, forKey: .rowsRead)
            try container.encode(dateFromEarlierSeparator, forKey: .dateFromEarlierSeparator)
            try container.encode(scrollback, forKey: .scrollback)
            try container.encode(interrupted, forKey: .interrupted)
            try container.encode(truncatedMessages, forKey: .truncatedMessages)
            try container.encode(fullText, forKey: .fullText)
        }
    }

    private struct ReadJSONResponse: Encodable {
        let chat: String
        let chatID: String?
        let fetchedAt: String
        let count: Int
        let messages: [ReadMessageJSON]
        let meta: ReadMeta

        enum CodingKeys: String, CodingKey {
            case ok
            case chat
            case chatID = "chat_id"
            case fetchedAt = "fetched_at"
            case count
            case messages
            case meta
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(true, forKey: .ok)
            try container.encode(chat, forKey: .chat)
            try container.encode(chatID, forKey: .chatID)
            try container.encode(fetchedAt, forKey: .fetchedAt)
            try container.encode(count, forKey: .count)
            try container.encode(messages, forKey: .messages)
            try container.encode(meta, forKey: .meta)
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func printOutcome(_ outcome: ReadOutcome) throws {
        if json {
            let data = try Self.makeEncoder().encode(jsonResponse(outcome, chatID: chatID))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            return
        }
        printText(outcome)
    }

    private func jsonResponse(_ outcome: ReadOutcome, chatID: String?) -> ReadJSONResponse {
        let items = outcome.result.items
        return ReadJSONResponse(
                chat: outcome.chat,
                chatID: chatID,
                fetchedAt: Self.timestamp(outcome.fetchedAt),
                count: items.count,
                messages: items.map(ReadMessageJSON.init(item:)),
                meta: ReadMeta(
                    openedVia: outcome.openedVia.rawValue,
                    rowTitle: outcome.rowTitle,
                    mainWindow: outcome.mainWindow,
                    listRecovery: outcome.listRecovery,
                    window: outcome.windowState,
                    windowDetail: outcome.windowDetail,
                    windowTitleEmpty: outcome.windowTitleEmpty,
                    unreadBefore: UnreadReceipt.evidence(outcome.unreadBefore),
                    unreadAfter: UnreadReceipt.evidence(outcome.unreadAfter),
                    markedRead: outcome.markedRead,
                    rowsTotal: outcome.result.totalRows,
                    rowsRead: outcome.result.rowsRead,
                    dateFromEarlierSeparator: outcome.result.usedEarlierDateSeparator,
                    scrollback: outcome.result.scrollback,
                    interrupted: outcome.result.interrupted,
                    truncatedMessages: items.filter(\.truncated).count,
                    fullText: outcome.result.fullText
                )
            )
    }

    private func printText(_ outcome: ReadOutcome) {
        let items = outcome.result.items
        print("Reading messages from: \(outcome.chat)\n")
        print("Recent messages (\(items.count)):\n")
        for (index, item) in items.enumerated() {
            let author = item.author ?? (item.kind == .system ? "(system)" : "(unknown)")
            if debug {
                print(
                    "[\(index + 1)] kind=\(item.kind.rawValue) side=\(item.side.rawValue) author=\(author) " +
                        "date=\(item.date ?? "-") time=\(item.time?.hhmm ?? "-") source=\(item.timeSource?.rawValue ?? "-") " +
                        "unread=\(item.unreadCount.map(String.init) ?? "-") body=\(item.body)"
                )
                continue
            }

            var when = [item.date, item.time?.raw].compactMap { $0 }.joined(separator: " ")
            if when.isEmpty {
                when = "unknown"
            }
            if item.timeSource == .inferred {
                when += " (inferred)"
            }
            print("[\(index + 1)] author: \(author)")
            print("    time: \(when)")
            print("    body: \(item.body)")
            if item.truncated {
                print("    note: truncated; KakaoTalk shows only the first \(LongMessage.visibleLimit) characters (--full-text fetches the rest)")
            }
            print("")
        }

        if let note = Self.unreadNote(before: outcome.unreadBefore, after: outcome.unreadAfter, markedRead: outcome.markedRead) {
            writeStderr(note)
        }
        if outcome.windowState == "left_open" {
            writeStderr("Note: the chat window was left open (\(outcome.windowDetail ?? "unknown reason")).\n")
        }
        if let mainWindow = outcome.mainWindow {
            writeStderr("Note: KakaoTalk's main window was closed and was reopened (\(mainWindow)).\n")
        }
        if let listRecovery = outcome.listRecovery {
            writeStderr("Note: chat-list recovery: \(listRecovery.summary).\n")
        }
        if let scrollback = outcome.result.scrollback, scrollback.timedOut {
            writeStderr("Note: loading older messages stopped at the --scrollback-timeout budget.\n")
        }
        if outcome.result.interrupted {
            writeStderr("Note: interrupted; the messages above are what had been read.\n")
        }
        let truncated = items.filter(\.truncated).count
        if truncated > 0 {
            writeStderr("Note: \(truncated) long message(s) are cut at \(LongMessage.visibleLimit) characters" + (fullText ? "; their full text could not be fetched.\n" : "; --full-text fetches the full text.\n"))
        }
        if let report = outcome.result.fullText, !report.leftOpen.isEmpty {
            writeStderr("Note: full-text view(s) left open: \(report.leftOpen.joined(separator: ", ")).\n")
        }
    }

    /// Text-mode note for a room that showed unread messages before it was opened.
    private static func unreadNote(before: UnreadBadge, after: UnreadBadge?, markedRead: Bool?) -> String? {
        guard let badge = UnreadReceipt.evidence(before) else { return nil }
        if before == .unknown(ChatRowAnalyzer.incompleteReadEvidence) {
            return "Note: the room's chat-list row could not be read completely before it was opened, so it may have had unread messages; opening sends read receipts for those like opening it by hand.\n"
        }
        let afterwards: String
        switch markedRead {
        case true?:
            afterwards = "afterwards the chat-list badge was gone (marked read)"
        case false?:
            afterwards = "afterwards the chat-list badge was still shown (\(UnreadReceipt.evidence(after) ?? "badge"))"
        case nil:
            afterwards = "whether that cleared the chat-list badge could not be checked"
        }
        return "Note: the room's chat-list row showed unread messages (\(badge)) and was opened, which sends read receipts like opening it by hand; \(afterwards).\n"
    }

    // MARK: - Argument errors as JSON

    /// `kktcli read ... --json` promises one JSON document on stdout even when the arguments
    /// themselves do not parse (see `Kktcli.main`).
    static func wantsJSONErrors(_ arguments: [String]) -> Bool {
        arguments.first == "read" && arguments.contains("--json")
    }

    static func printArgumentErrorJSON(_ message: String) {
        let payload = ReadErrorJSON(
            code: "INVALID_ARGUMENT",
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            hint: "Run 'kktcli read --help'.",
            chat: nil,
            chatID: nil
        )
        if let data = try? makeEncoder().encode(payload) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    private func report(_ failure: ReadFailure) {
        if json {
            if let data = try? Self.makeEncoder().encode(Self.errorJSON(failure, chat: chat, chatID: chatID)) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            return
        }
        Self.printFailureText(failure, label: chat ?? chatID ?? "")
    }

    private static func errorJSON(_ failure: ReadFailure, chat: String?, chatID: String?) -> ReadErrorJSON {
        ReadErrorJSON(
            code: failure.code,
            message: failure.message,
            hint: failure.hint,
            chat: chat,
            chatID: chatID,
            details: failure.details
        )
    }

    private static func printFailureText(_ failure: ReadFailure, label: String) {
        print("Could not read '\(label)': [\(failure.code)] \(failure.message)")
        if let hint = failure.hint {
            print("Hint: \(hint)")
        }
        for (key, value) in failure.details.sorted(by: { $0.key < $1.key }) {
            print("  \(key): \(value)")
        }
    }

    private func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    // MARK: - Several chats in one run

    /// One chat's result in a batch: the document a single read prints.
    private enum BatchEntry: Encodable {
        case success(ReadJSONResponse)
        case failure(ReadErrorJSON)

        var ok: Bool {
            if case .success = self { return true }
            return false
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .success(let document):
                try document.encode(to: encoder)
            case .failure(let document):
                try document.encode(to: encoder)
            }
        }
    }

    private struct BatchJSONResponse: Encodable {
        let fetchedAt: String
        let results: [BatchEntry]
        let elapsedMs: Int
        let interrupted: Bool

        enum CodingKeys: String, CodingKey {
            case ok
            case count
            case fetchedAt = "fetched_at"
            case results
            case meta
        }

        enum MetaKeys: String, CodingKey {
            case chats
            case succeeded
            case failed
            case elapsedMs = "elapsed_ms"
            case interrupted
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let succeeded = results.filter(\.ok).count
            try container.encode(succeeded == results.count, forKey: .ok)
            try container.encode(results.count, forKey: .count)
            try container.encode(fetchedAt, forKey: .fetchedAt)
            try container.encode(results, forKey: .results)
            var meta = container.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
            try meta.encode(results.count, forKey: .chats)
            try meta.encode(succeeded, forKey: .succeeded)
            try meta.encode(results.count - succeeded, forKey: .failed)
            try meta.encode(elapsedMs, forKey: .elapsedMs)
            try meta.encode(interrupted, forKey: .interrupted)
        }
    }

    /// --chat-id values, then the lines of --chat-ids-file, without duplicates.
    private func batchChatIDs() throws -> [String] {
        var ids = givenChatIDs.map { $0.trimmingCharacters(in: .whitespaces) }
        if let chatIDsFile {
            let text: String
            do {
                text = try String(contentsOfFile: (chatIDsFile as NSString).expandingTildeInPath, encoding: .utf8)
            } catch {
                throw ReadFailure(
                    code: "INVALID_ARGUMENT",
                    message: "Could not read --chat-ids-file '\(chatIDsFile)': \(error.localizedDescription)",
                    exitCode: ExitCode.validationFailure.rawValue
                )
            }
            ids += text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else {
            throw ReadFailure(code: "INVALID_ARGUMENT", message: "No chat_id was given.", exitCode: ExitCode.validationFailure.rawValue)
        }
        return unique
    }

    /// Reads each chat in turn with one session (one permission and login check, one AX setup).
    /// A failing chat does not stop the others; every chat gets a result. Exit status: 0 when
    /// all succeeded, 130 when interrupted, otherwise 1.
    private func runBatch() throws {
        let batchStart = Date()
        var entries: [(id: String, outcome: Result<ReadOutcome, ReadFailure>)] = []
        var fatal: ReadFailure?

        withStdoutRedirectedToStderr(json) {
            do {
                try checkUsage()
                let ids = try batchChatIDs()
                var session = try startSession()
                for id in ids {
                    if ReadInterruption.requested {
                        entries.append((id, .failure(ReadFailure(
                            code: "INTERRUPTED",
                            message: "Stopped before this chat was read.",
                            exitCode: ReadFailure.interruptedExitCode
                        ))))
                        continue
                    }
                    do {
                        let target = try Self.target(forChatID: id)
                        session.runner.log("read: batch chat \(entries.count + 1)/\(ids.count) \(id)")
                        entries.append((id, .success(try readRoom(target, session: session, startedAt: Date()))))
                    } catch let failure as ReadFailure {
                        entries.append((id, .failure(failure)))
                    } catch {
                        entries.append((id, .failure(ReadFailure(code: "READ_FAILED", message: "\(error)"))))
                    }
                    session.mainWindowAction = nil
                }
            } catch let failure as ReadFailure {
                fatal = failure
            } catch {
                fatal = ReadFailure(code: "READ_FAILED", message: "\(error)")
            }
        }

        if let fatal {
            report(fatal)
            throw ExitCode(fatal.exitCode)
        }

        let interrupted = ReadInterruption.requested
        if json {
            let results: [BatchEntry] = entries.map { entry in
                switch entry.outcome {
                case .success(let outcome):
                    return .success(jsonResponse(outcome, chatID: entry.id))
                case .failure(let failure):
                    let record = ChatIdentityRegistryStore.shared.record(for: entry.id)
                    return .failure(Self.errorJSON(failure, chat: record?.displayName, chatID: entry.id))
                }
            }
            let payload = BatchJSONResponse(
                fetchedAt: Self.timestamp(batchStart),
                results: results,
                elapsedMs: Int(Date().timeIntervalSince(batchStart) * 1000),
                interrupted: interrupted
            )
            let data = try Self.makeEncoder().encode(payload)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } else {
            for (position, entry) in entries.enumerated() {
                print("=== [\(position + 1)/\(entries.count)] \(entry.id) ===")
                switch entry.outcome {
                case .success(let outcome):
                    printText(outcome)
                case .failure(let failure):
                    let record = ChatIdentityRegistryStore.shared.record(for: entry.id)
                    Self.printFailureText(failure, label: record?.displayName ?? entry.id)
                    print("")
                }
            }
        }

        let failed = entries.filter { if case .failure = $0.outcome { return true } else { return false } }.count
        if interrupted {
            throw ExitCode(ReadFailure.interruptedExitCode)
        }
        if failed > 0 {
            throw ExitCode(1)
        }
    }
}
