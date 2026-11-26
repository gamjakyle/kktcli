import ArgumentParser
import Foundation
import KktcliCore

struct ChatsCommand: ParsableCommand {
    private struct ChatsJSONResponse: Codable {
        var ok = true
        let count: Int
        let chats: [ChatListEntry]
    }

    static let configuration = CommandConfiguration(
        commandName: "chats",
        abstract: "List chat rooms",
        discussion: """
            Reads the chat list of KakaoTalk's main window with Accessibility reads
            only, after checking that it is the chat list (another tab is switched
            with 창 > 채팅, ⌘2).

            The main window is found wherever it is: on another desktop or Space it
            is read in place (looked up by element id; nothing is pressed). A closed
            main window is opened with KakaoTalk's 창 > 채팅 menu item, which does not
            bring KakaoTalk to the front. 카카오톡 열기, which does, is used only with
            --allow-activate; otherwise MAIN_WINDOW_NOT_VISIBLE. Presses wait while
            the user is busy (KAKAOTALK_IN_USE after --wait-for-idle seconds, exit
            status 75).
            """
    )

    @Flag(name: .shortAndLong, help: "Show detailed information")
    var verbose: Bool = false

    @Option(name: .shortAndLong, help: "Maximum number of chats to show")
    var limit: Int = 20

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: [.short, .long], help: "No effect (kept for compatibility); a main window opened with 창 > 채팅 is left open")
    var keepWindow: Bool = false

    @Option(name: .long, help: "While KakaoTalk is in front, press nothing until the keyboard and mouse were idle this many seconds")
    var idleSeconds: Double = UserActivityPolicy.defaultIdleSeconds

    @Option(name: .long, help: "Wait at most this many seconds for that (0 fails at once with KAKAOTALK_IN_USE)")
    var waitForIdle: Double = UserActivityPolicy.defaultWaitSeconds

    @Flag(
        name: .long,
        help: "Allow bringing KakaoTalk to the front (카카오톡 열기) when its main window cannot be found or opened otherwise; may switch desktops"
    )
    var allowActivate: Bool = false

    func run() throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }
        var chats: [ChatListEntry]?
        var failure: ReadFailure?
        var otherError: Error?
        // With --json, stdout carries only the final document (login progress goes to stderr).
        withStdoutRedirectedToStderr(json) {
            do {
                chats = try listChats()
            } catch let readFailure as ReadFailure {
                failure = readFailure
            } catch {
                otherError = error
            }
        }
        if let failure {
            report(failure)
            throw ExitCode(failure.exitCode)
        }
        if let otherError {
            throw otherError
        }
        guard let chats else { return }
        if json {
            try printChatsAsJSON(chats)
            return
        }
        printText(chats)
    }

    private func listChats() throws -> [ChatListEntry]? {
        for (name, value) in [("--idle-seconds", idleSeconds), ("--wait-for-idle", waitForIdle)]
            where value < 0 || value > UserActivityPolicy.maximumSeconds
        {
            throw ReadFailure(
                code: "INVALID_ARGUMENT",
                message: "\(name) must be between 0 and \(Int(UserActivityPolicy.maximumSeconds)).",
                exitCode: ExitCode.validationFailure.rawValue
            )
        }
        let runner = AXActionRunner(traceEnabled: traceAX)
        let activity = UserActivityGuard(idleSeconds: idleSeconds, waitBudget: waitForIdle, runner: runner)
        let mainWindowAccess = MainWindowAccess(runner: runner, activity: activity, allowActivate: allowActivate)

        // The main window is looked for before the login check, which would otherwise activate
        // KakaoTalk or run `open KakaoTalk.app` when kAXWindows lists none (`MainWindowAccess`:
        // another desktop by element id, 창 > 채팅 for a closed one, 카카오톡 열기 only with
        // --allow-activate, else MAIN_WINDOW_NOT_VISIBLE). Found on another desktop, KakaoTalk
        // is logged in and the login check (which would activate it) is skipped.
        var earlyAction: ChatListLocator.MainWindowAction?
        if KakaoTalkApp.isRunning, let early = try? KakaoTalkApp(autoLaunch: false) {
            earlyAction = try mainWindowAccess.resolve(locator: ChatListLocator(kakao: early, runner: runner), allowOpenCommand: false).action
        }
        let kakao = earlyAction == .otherDesktop
            ? try KakaoTalkApp(autoLaunch: false)
            : try AuthBootstrap.requireAuthenticated(traceAX: traceAX)

        let locator = ChatListLocator(kakao: kakao, runner: runner)
        let (mainWindow, action) = try locator.requireMainWindow(allowOpenCommand: false, access: mainWindowAccess)
        // Only the verified chat list is read and recorded: another tab (e.g. 친구) is switched
        // away from with 창 > 채팅, or nothing is written and CHAT_LIST_UNAVAILABLE is reported.
        let verified = try locator.verifiedAccess(in: mainWindow, activity: activity)
        let actions = [earlyAction, action, verified.switched ? .switchedToChatTab : nil]
        if let report = ChatListLocator.MainWindowAction.report(actions) {
            FileHandle.standardError.write(Data("Note: KakaoTalk's main window: \(report).\n".utf8))
        }
        runner.log("chats: verified chat list ready")
        let snapshots = ChatListScanner().scan(table: verified.access.table, limit: limit, trace: { message in
            runner.log(message)
        })
        let verification = ChatListCheck.verify(snapshots.compactMap(\.summary))
        if case .notChatList = verification {
            throw ChatListLocator.notChatList(verification, switched: false)
        }

        if snapshots.isEmpty {
            runner.log("chats: no chat items found after traversal")
            if json {
                return []
            }
            print("No chat list found.")
            print("\nTip: Make sure you're on the 'Chats' (채팅) tab in KakaoTalk.")
            print("Use 'kktcli inspect' to explore the UI structure.")
            return nil
        }

        let registry = ChatIdentityRegistryStore.shared
        let assignedIDs = registry.assignChatIDs(for: snapshots.map(\.discovery))
        return zip(snapshots, assignedIDs).map { snapshot, chatID in
            ChatListEntry(
                title: snapshot.discovery.title,
                chatID: chatID.isEmpty ? nil : chatID,
                lastMessage: snapshot.discovery.lastMessage,
                hasUnread: snapshot.discovery.unread.isUnread,
                unreadCount: snapshot.discovery.unread.count
            )
        }
    }

    private func printText(_ chats: [ChatListEntry]) {
        print("Searching for chat list in KakaoTalk...\n")
        print("Found \(chats.count) chat(s):\n")

        for (index, chat) in chats.enumerated() {
            let unreadMarker: String
            if let unreadCount = chat.unreadCount {
                unreadMarker = "  (unread \(unreadCount))"
            } else if chat.hasUnread {
                unreadMarker = "  (unread)"
            } else {
                unreadMarker = ""
            }
            print("[\(index + 1)] \(chat.title)\(unreadMarker)")
            print("    chat_id: \(chat.chatID ?? "unavailable")")
            if verbose, let msg = chat.lastMessage {
                print("    └─ \(msg)")
            }
        }
    }

    private func report(_ failure: ReadFailure) {
        if json {
            let payload = ReadErrorJSON(
                code: failure.code,
                message: failure.message,
                hint: failure.hint,
                chat: nil,
                chatID: nil,
                details: failure.details
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(payload) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            return
        }
        print("Could not list chats: [\(failure.code)] \(failure.message)")
        if let hint = failure.hint {
            print("Hint: \(hint)")
        }
        for (key, value) in failure.details.sorted(by: { $0.key < $1.key }) {
            print("  \(key): \(value)")
        }
    }

    private func printChatsAsJSON(_ chats: [ChatListEntry]) throws {
        let response = ChatsJSONResponse(count: chats.count, chats: chats)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }
}
