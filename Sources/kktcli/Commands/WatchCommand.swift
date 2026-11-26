import ArgumentParser
import Foundation
import KktcliCore

struct WatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Watch one chat, or the top of the chat list, for new messages",
        discussion: """
            kktcli watch --chat-id <chat-id> | <chat>    one chat: opened like 'read' (activity
                                                       guard, main-window policy, chat-list menu),
                                                       new messages printed as they arrive
            kktcli watch --all [--top 30] [--read]       the top chat-list rows, read only

            --all never scrolls or clicks: every --poll-interval seconds (3) it reads the top
            --top rows and prints one JSON line per change: chat_id, title, preview, time,
            unread and change (new_message, unread_changed, new_room). If KakaoTalk's main
            window is not visible it prints a status line and keeps polling. --read also opens
            each changed room (activity guard; read receipts are sent as when opening it by
            hand), prints its new messages and keeps them in the local store.

            Stops after --duration seconds, after --count events, or on Ctrl-C. A window kktcli
            opened is closed again (unless --keep-window).
            """
    )

    @Argument(help: "Name of the chat to watch (must be unique; omit with --all or --chat-id)")
    var chat: String?

    @Option(name: .long, help: "Watch the chat with this chat_id from 'kktcli chats'")
    var chatID: String?

    @Flag(name: .long, help: "Watch the top chat-list rows instead of one chat (read only, no clicks)")
    var all: Bool = false

    @Option(name: .long, help: "Rows to watch with --all")
    var top: Int = 30

    @Flag(name: .long, help: "With --all: open each changed room and print its new messages (sends read receipts)")
    var read: Bool = false

    @Option(name: .long, help: "Seconds between polls (default 3 with --all, 1 otherwise)")
    var pollInterval: Double?

    @Option(name: .long, help: "Stop after this many seconds")
    var duration: Double?

    @Option(name: .long, help: "Stop after this many events")
    var count: Int?

    @Flag(name: .long, help: "Print one JSON object per line")
    var json: Bool = false

    @Flag(name: .long, help: "Include system messages")
    var includeSystem: Bool = false

    @Flag(name: [.short, .long], help: "Keep a chat window kktcli opened")
    var keepWindow: Bool = false

    @Option(name: .long, help: "While KakaoTalk is in front, press nothing until the keyboard and mouse were idle this many seconds")
    var idleSeconds: Double = UserActivityPolicy.defaultIdleSeconds

    @Option(name: .long, help: "Wait at most this many seconds for that (0 fails at once with KAKAOTALK_IN_USE)")
    var waitForIdle: Double = UserActivityPolicy.defaultWaitSeconds

    @Flag(name: .long, help: "Allow bringing KakaoTalk to the front to reopen a hidden main window (one chat only)")
    var allowActivate: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    func validate() throws {
        if all {
            guard chat == nil, chatID == nil else { throw ValidationError("--all watches the chat list; do not name a chat.") }
            guard (1...200).contains(top) else { throw ValidationError("--top must be between 1 and 200.") }
        } else {
            guard (chat?.isEmpty == false) != (chatID?.isEmpty == false) else {
                throw ValidationError("Name one chat, or pass --chat-id, or use --all.")
            }
            guard !read else { throw ValidationError("--read is for --all.") }
        }
        if let pollInterval, pollInterval < 0.2 || pollInterval > 3600 {
            throw ValidationError("--poll-interval must be between 0.2 and 3600 seconds.")
        }
        if let count, count < 1 { throw ValidationError("--count must be at least 1.") }
        if let duration, duration <= 0 { throw ValidationError("--duration must be positive.") }
    }

    func run() throws {
        ReadInterruption.install()
        let output = WatchOutput(json: json)
        do {
            if all {
                try watchList(output)
            } else {
                try watchRoom(output)
            }
        } catch let failure as ReadFailure {
            output.status("error", details: ["code": failure.code, "message": failure.message, "hint": failure.hint ?? ""])
            throw ExitCode(failure.exitCode)
        }
    }

    // MARK: One chat

    private func watchRoom(_ output: WatchOutput) throws {
        let session = try RoomSession(traceAX: traceAX, idleSeconds: idleSeconds, waitForIdle: waitForIdle, allowActivate: allowActivate)
        let located = try chatID.map { try session.locate(chatID: $0) } ?? session.locate(name: chat ?? "")
        let opened = try session.open(located)
        defer { _ = session.close(opened, keep: keepWindow) }

        var previous = transcript(session, opened, justOpened: opened.openedByUs)
        output.status("watching", details: ["chat": opened.title, "chat_id": located.chatID ?? ""])
        let deadline = duration.map { Date().addingTimeInterval($0) }
        var events = 0
        while !ReadInterruption.requested {
            if let deadline, Date() >= deadline { break }
            Thread.sleep(forTimeInterval: pollInterval ?? 1.0)
            guard session.stillShows(opened) else {
                output.status("window_closed", details: ["chat": opened.title])
                return
            }
            let current = transcript(session, opened, justOpened: false)
            let diff = WatchDiff.newTranscriptItems(
                previous: previous.map(SendVerification.Key.init(item:)),
                current: current.map(SendVerification.Key.init(item:))
            )
            for item in current.suffix(diff.count) {
                output.message(item, chat: opened.title, chatID: located.chatID, gap: diff.gap)
                events += 1
                if let count, events >= count { return }
            }
            previous = current
        }
    }

    private func transcript(_ session: RoomSession, _ opened: RoomSession.Opened, justOpened: Bool) -> [TranscriptItem] {
        let items = session.tail(of: opened.window, limit: 30, justOpened: justOpened)
        return includeSystem ? items : items.filter { $0.kind == .message }
    }

    // MARK: The chat list

    private func watchList(_ output: WatchOutput) throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ReadFailure(code: "ACCESSIBILITY_PERMISSION_DENIED", message: "Accessibility permission is not granted to kktcli.")
        }
        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao: KakaoTalkApp
        do {
            kakao = try KakaoTalkApp(autoLaunch: false)
        } catch {
            throw ReadFailure(code: "KAKAO_NOT_RUNNING", message: "KakaoTalk is not running.", hint: "Start KakaoTalk; watch --all never launches or activates it.")
        }
        let locator = ChatListLocator(kakao: kakao, runner: runner)
        let activity = UserActivityGuard(idleSeconds: idleSeconds, waitBudget: waitForIdle, runner: runner)
        let registry = ChatIdentityRegistryStore.shared
        let deadline = duration.map { Date().addingTimeInterval($0) }
        var previous: [ChatListEntrySnapshot]?
        var lastStatus: String?
        var events = 0
        output.status("watching", details: ["rows": String(top)])

        while !ReadInterruption.requested {
            if let deadline, Date() >= deadline { break }
            guard let main = locator.mainWindow() ?? locator.confirmMainWindow(),
                  let access = locator.access(in: main) ?? locator.access(in: main, patience: ChatListLocator.mainWindowRecheckDuration)
            else {
                if lastStatus != "main_window_not_visible" {
                    let failure = MainWindowAccess(runner: runner, activity: activity, allowActivate: false)
                        .notVisible(kakao: kakao, kakaoPID: KakaoTalkInputGuard.shared.currentEvidence().kakaoPID, frontmost: false)
                    output.status("main_window_not_visible", details: failure.details)
                    lastStatus = "main_window_not_visible"
                }
                Thread.sleep(forTimeInterval: pollInterval ?? 3.0)
                continue
            }
            if lastStatus != nil {
                output.status("main_window_visible", details: [:])
                lastStatus = nil
            }

            let rows = Array(AXNodeReader.rows(of: access.table).prefix(top))
            let located = rows.indices.map { index -> LocatedChatRow in
                let summary = ChatListScanner.summarize(row: rows[index])
                return LocatedChatRow(index: index, element: rows[index], title: ChatListLocator.trimmed(summary.title), summary: summary)
            }.filter { !$0.title.isEmpty }
            let known = registry.activeChatIDs()
            let ids = registry.assignChatIDs(for: located.map(ChatListLocator.discovery))
            let current = zip(located, ids).map { row, id in
                ChatListEntrySnapshot(
                    chatID: id,
                    title: row.title,
                    preview: row.summary.preview,
                    time: row.summary.timeLabel,
                    unreadCount: row.summary.unread.count,
                    hasUnread: row.summary.unread.isUnread
                )
            }
            let rowsByID = Dictionary(zip(ids, located), uniquingKeysWith: { first, _ in first })
            let changes = WatchDiff.chatListChanges(previous: previous, current: current, knownChatIDs: known)
            previous = current
            for change in changes {
                output.change(change)
                events += 1
                if read, change.change != .unreadChanged, let row = rowsByID[change.entry.chatID] {
                    events += readChangedRoom(row, access: access, chatID: change.entry.chatID, kakao: kakao, runner: runner, activity: activity, output: output)
                }
                if let count, events >= count { return }
            }
            Thread.sleep(forTimeInterval: pollInterval ?? 3.0)
        }
    }

    /// Opens one changed room (activity guard, chat-list menu), prints the messages not in the
    /// local store yet, stores them and closes the window again. Returns the messages printed.
    private func readChangedRoom(
        _ row: LocatedChatRow,
        access: ChatListAccess,
        chatID: String,
        kakao: KakaoTalkApp,
        runner: AXActionRunner,
        activity: UserActivityGuard,
        output: WatchOutput
    ) -> Int {
        do {
            let room = try ChatRoomMenuOpener(kakao: kakao, runner: runner, activity: activity).open(row, access: access, skipUnread: false)
            defer {
                if room.isNewWindow, !keepWindow {
                    _ = ChatWindowCloser(kakao: kakao, runner: runner).close(room.window, expectedTitle: nil)
                }
            }
            let parts = StructuredTranscriptReader.waitForParts(in: room.window, timeout: 1.5)
            let items = parts.map {
                StructuredTranscriptReader(runner: runner).read(
                    $0,
                    options: TranscriptReadOptions(limit: 20, includeSystem: includeSystem, scrollback: false, scrollbackTimeout: 0)
                ).items
            } ?? []
            let fresh = WatchStore.newAndSaved(items, chatID: chatID, chat: row.title)
            for item in fresh {
                output.message(item, chat: row.title, chatID: chatID, gap: false)
            }
            return fresh.count
        } catch let failure as ReadFailure {
            output.status("read_failed", details: ["chat_id": chatID, "code": failure.code, "message": failure.message])
            return 0
        } catch {
            output.status("read_failed", details: ["chat_id": chatID, "message": "\(error)"])
            return 0
        }
    }
}

/// JSON lines (or short text lines) for `watch`.
struct WatchOutput {
    let json: Bool

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func emit(_ object: [String: AnyEncodable], text: String) {
        if json, let data = try? Self.encoder.encode(object) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } else if !json {
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
        }
    }

    func status(_ status: String, details: [String: String]) {
        emit(["event": AnyEncodable("status"), "status": AnyEncodable(status), "details": AnyEncodable(details), "detected_at": AnyEncodable(now())],
             text: "[\(status)] " + details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }

    func change(_ change: ChatListChangeEvent) {
        let entry = change.entry
        emit([
            "event": AnyEncodable("change"),
            "change": AnyEncodable(change.change.rawValue),
            "chat_id": AnyEncodable(entry.chatID),
            "title": AnyEncodable(entry.title),
            "preview": AnyEncodable(entry.preview),
            "time": AnyEncodable(entry.time),
            "unread": AnyEncodable(entry.unreadCount ?? (entry.hasUnread ? -1 : 0)),
            "detected_at": AnyEncodable(now()),
        ], text: "\(change.change.rawValue)  \(entry.title)  \(entry.time ?? "")  \(entry.preview ?? "")")
    }

    func message(_ item: TranscriptItem, chat: String, chatID: String?, gap: Bool) {
        emit([
            "event": AnyEncodable("message"),
            "chat": AnyEncodable(chat),
            "chat_id": AnyEncodable(chatID),
            "message": AnyEncodable(ReadMessageJSON(item: item)),
            "gap": AnyEncodable(gap),
            "detected_at": AnyEncodable(now()),
        ], text: "[\(chat)] \(item.time?.raw ?? "-") \(item.author ?? "?"): \(item.body)")
    }
}

/// Type-erased Encodable for the JSON lines (explicit nulls for nil optionals).
struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeValue = { encoder in
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

/// `watch --all --read`: the messages of a read that the local store does not have yet. They
/// are appended to it (the store's dedup rule keeps legitimate repeats).
enum WatchStore {
    static func newAndSaved(_ items: [TranscriptItem], chatID: String, chat: String) -> [TranscriptItem] {
        let archive = MessageArchive.shared
        let kept = items.filter { $0.kind == .message || $0.kind == .system }
        let incoming = MessageStore.records(from: kept, chatID: chatID, chat: chat, savedAt: MessageStore.timestamp(Date()))
        let existing = (try? archive.records(chatID: chatID)) ?? []
        let fresh = MessageStore.merge(existing: existing, incoming: incoming)
        _ = try? archive.append(chatID: chatID, chat: chat, items: kept)
        return incoming.indices.filter { fresh.contains(incoming[$0]) }.map { kept[$0] }
    }
}
