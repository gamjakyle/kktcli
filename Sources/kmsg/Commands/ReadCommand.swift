import ArgumentParser
import Foundation
import KmsgCore

extension ChatWindowLayoutMode: ExpressibleByArgument {}

struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read messages from a chat",
        discussion: """
            Use either:
              kmsg read <chat>
              kmsg read --chat-id <chat-id>

            An already open chat window is read in place. Otherwise the chat is found in the chat
            list and opened through its context menu (채팅방 열기) with Accessibility actions only:
            no keystrokes or clicks are posted, so KakaoTalk may stay in the background. A room
            whose chat-list row shows an unread badge is not opened, because opening it sends
            read receipts; pass --allow-unread to open it anyway (exit status 3 when refused).
            --legacy-open restores the old search/Enter based opening; it only posts input while
            KakaoTalk is the frontmost app.

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

    @Option(name: .long, help: "Read using a chat_id from 'kmsg chats'")
    var chatID: String?

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

    @Flag(name: .long, help: "Open the chat even if its chat-list row shows unread messages (sends read receipts)")
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

    @Option(name: .long, help: "Time budget in seconds for loading older messages")
    var scrollbackTimeout: Double = 4

    @Flag(name: .long, help: "Include system messages (joins, notices)")
    var includeSystem: Bool = false

    func validate() throws {
        // With --json the problem is reported as a JSON document from run().
        if !json, let problem = usageProblem() {
            throw ValidationError(problem)
        }
    }

    func run() throws {
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
        let unreadBadge: UnreadBadge

        var openedTransiently: Bool {
            method != .existingWindow
        }
    }

    private struct ReadOutcome {
        let chat: String
        let fetchedAt: Date
        let result: StructuredTranscriptResult
        let openedVia: OpenMethod
        let unreadBadge: UnreadBadge
        let windowState: String
        let windowDetail: String?
    }

    private var scrollbackEnabled: Bool {
        if noScrollback { return false }
        return scrollback || !backgroundSafe
    }

    private func usageProblem() -> String? {
        if let chatID, !chatID.isEmpty {
            if chat != nil {
                return "Chat name cannot be provided together with --chat-id."
            }
        } else if (chat ?? "").isEmpty {
            return "Chat name is required unless --chat-id is provided."
        }
        if limit < 1 {
            return "--limit must be at least 1."
        }
        if scrollback && noScrollback {
            return "--scrollback and --no-scrollback cannot be used together."
        }
        if scrollbackTimeout < 0 {
            return "--scrollback-timeout must not be negative."
        }
        return nil
    }

    private func performRead() throws -> ReadOutcome {
        if let problem = usageProblem() {
            throw ReadFailure(code: "INVALID_ARGUMENT", message: problem, exitCode: ExitCode.validationFailure.rawValue)
        }
        let target = try resolveTarget()

        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ReadFailure(
                code: "ACCESSIBILITY_PERMISSION_DENIED",
                message: "Accessibility permission is not granted to kmsg.",
                hint: "Grant it in System Settings > Privacy & Security > Accessibility (손쉬운 사용)."
            )
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        let fetchedAt = Date()
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
        let opened = try open(target, kakao: kakao, resolver: chatWindowResolver, locator: locator, runner: runner)
        runner.log("read: chat window via \(opened.method.rawValue) title='\(opened.window.title ?? "")'")

        let chatTitle = opened.window.title ?? opened.expectedTitle
        var result: StructuredTranscriptResult?
        if let parts = StructuredTranscriptReader.parts(in: opened.window) {
            result = StructuredTranscriptReader(runner: runner).read(
                parts,
                options: TranscriptReadOptions(
                    limit: limit,
                    includeSystem: includeSystem,
                    scrollback: scrollbackEnabled,
                    scrollbackTimeout: scrollbackTimeout
                )
            )
        }

        let (windowState, windowDetail) = finishWindow(opened, resolver: chatWindowResolver, target: target, runner: runner)

        guard let result else {
            var details = ["window": windowState]
            if let windowDetail { details["window_detail"] = windowDetail }
            throw ReadFailure(
                code: "TRANSCRIPT_UNAVAILABLE",
                message: "Could not locate the chat transcript in window '\(chatTitle)'.",
                hint: "Use 'kmsg inspect --window <n>' to inspect the opened chat window.",
                details: details
            )
        }

        return ReadOutcome(
            chat: chatTitle,
            fetchedAt: fetchedAt,
            result: result,
            openedVia: opened.method,
            unreadBadge: opened.unreadBadge,
            windowState: windowState,
            windowDetail: windowDetail
        )
    }

    private func resolveTarget() throws -> ReadTarget {
        if let chatID, !chatID.isEmpty {
            guard let record = ChatIdentityRegistryStore.shared.record(for: chatID) else {
                throw ReadFailure(
                    code: "UNKNOWN_CHAT_ID",
                    message: "Unknown chat_id '\(chatID)'.",
                    hint: "Run 'kmsg chats' first to refresh the local registry."
                )
            }
            return .chatID(chatID, record)
        }
        return .name(chat ?? "")
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
            return OpenedChat(window: window, method: .existingWindow, expectedTitle: window.title ?? target.exactTitle, unreadBadge: .none)
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
        let mainWindow = try locator.requireMainWindow(allowReopen: true)
        guard let access = locator.access(in: mainWindow) else {
            throw ReadFailure(
                code: "CHAT_LIST_UNAVAILABLE",
                message: "KakaoTalk's main window shows no chat list table.",
                hint: "Switch KakaoTalk's main window to the 채팅 tab and retry."
            )
        }

        let row: LocatedChatRow
        switch target {
        case .chatID(let chatID, let record):
            row = try locator.locate(chatID: chatID, record: record, in: access)
        case .name(let query):
            let (choice, rows) = locator.choose(query: query, in: access)
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
                    hint: "Use the exact chat name, or --chat-id from 'kmsg chats'."
                )
            case .none:
                if let window = locator.existingWindow(query: query) {
                    return existing(window)
                }
                throw ReadFailure(
                    code: "CHAT_NOT_IN_LIST",
                    message: "No chat-list row matches '\(query)'.",
                    hint: "Check the name with 'kmsg chats'. --legacy-open searches instead (posts keystrokes; KakaoTalk must be frontmost)."
                )
            }
        }

        let window = try ChatRoomMenuOpener(kakao: kakao, runner: runner).open(row, access: access, allowUnread: allowUnread)
        resolver.applyLayoutIfRequested(window, label: "opened chat window")
        return OpenedChat(window: window, method: .chatListMenu, expectedTitle: window.title ?? row.title, unreadBadge: row.summary.unread)
    }

    private func openLegacy(_ target: ReadTarget, resolver: ChatWindowResolver, locator: ChatListLocator) throws -> OpenedChat {
        let badge = try legacyUnreadPrecheck(target, locator: locator)
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
        return OpenedChat(
            window: resolution.window,
            method: method,
            expectedTitle: resolution.window.title ?? target.exactTitle,
            unreadBadge: badge
        )
    }

    /// The legacy path cannot re-check the row right before it opens the room, so the unread
    /// state is read from the chat list first. When it cannot be established the open is
    /// refused unless --allow-unread is given.
    private func legacyUnreadPrecheck(_ target: ReadTarget, locator: ChatListLocator) throws -> UnreadBadge {
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
            if allowUnread {
                return .none
            }
            throw ReadFailure(
                code: "UNREAD_UNVERIFIED",
                message: "'\(target.label)' was not found in the chat list, so its unread state cannot be checked before the legacy path opens it.",
                hint: "Pass --allow-unread to open it anyway.",
                exitCode: ReadFailure.refusedExitCode
            )
        }
        if row.summary.unread.isUnread, !allowUnread {
            throw ChatRoomMenuOpener.unreadRefusal(title: row.title, badge: row.summary.unread)
        }
        return row.summary.unread
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
            if !resolvedTitle.isEmpty && !resolvedTitle.localizedCaseInsensitiveContains(query) {
                runner.log("read: skipped auto-close because resolved title '\(resolvedTitle)' did not match query")
                return ("left_open", "title_does_not_match_query")
            }
        }

        let outcome = resolver.closeWindowViaCloseButton(opened.window, expectedTitle: opened.expectedTitle)
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
                    hint: "Launch KakaoTalk, or run without --background-safe to let kmsg launch it."
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
        let window: String
        let windowDetail: String?
        let unreadBadge: String?
        let rowsTotal: Int
        let rowsRead: Int
        let dateFromEarlierSeparator: Bool
        let scrollback: ScrollbackReport?

        enum CodingKeys: String, CodingKey {
            case openedVia = "opened_via"
            case window
            case windowDetail = "window_detail"
            case unreadBadge = "unread_badge"
            case rowsTotal = "rows_total"
            case rowsRead = "rows_read"
            case dateFromEarlierSeparator = "date_from_earlier_separator"
            case scrollback
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(openedVia, forKey: .openedVia)
            try container.encode(window, forKey: .window)
            try container.encode(windowDetail, forKey: .windowDetail)
            try container.encode(unreadBadge, forKey: .unreadBadge)
            try container.encode(rowsTotal, forKey: .rowsTotal)
            try container.encode(rowsRead, forKey: .rowsRead)
            try container.encode(dateFromEarlierSeparator, forKey: .dateFromEarlierSeparator)
            try container.encode(scrollback, forKey: .scrollback)
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

    private func printOutcome(_ outcome: ReadOutcome) throws {
        let items = outcome.result.items
        if json {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let payload = ReadJSONResponse(
                chat: outcome.chat,
                chatID: chatID,
                fetchedAt: formatter.string(from: outcome.fetchedAt),
                count: items.count,
                messages: items.map(ReadMessageJSON.init(item:)),
                meta: ReadMeta(
                    openedVia: outcome.openedVia.rawValue,
                    window: outcome.windowState,
                    windowDetail: outcome.windowDetail,
                    unreadBadge: outcome.unreadBadge.evidence,
                    rowsTotal: outcome.result.totalRows,
                    rowsRead: outcome.result.rowsRead,
                    dateFromEarlierSeparator: outcome.result.usedEarlierDateSeparator,
                    scrollback: outcome.result.scrollback
                )
            )
            let data = try Self.makeEncoder().encode(payload)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            return
        }

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
            print("")
        }

        if outcome.windowState == "left_open" {
            writeStderr("Note: the chat window was left open (\(outcome.windowDetail ?? "unknown reason")).\n")
        }
        if let scrollback = outcome.result.scrollback, scrollback.timedOut {
            writeStderr("Note: loading older messages stopped at the --scrollback-timeout budget.\n")
        }
    }

    private func report(_ failure: ReadFailure) {
        if json {
            let payload = ReadErrorJSON(
                code: failure.code,
                message: failure.message,
                hint: failure.hint,
                chat: chat,
                chatID: chatID,
                details: failure.details
            )
            if let data = try? Self.makeEncoder().encode(payload) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            return
        }

        print("Could not read '\(chat ?? chatID ?? "")': [\(failure.code)] \(failure.message)")
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
}
