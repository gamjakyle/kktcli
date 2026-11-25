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
            Reads the chat list of KakaoTalk's main window with Accessibility reads only.

            If the main window is not visible (closed, minimised, or on another desktop or
            full-screen Space) and KakaoTalk is not in front, it is not reopened, because that
            would bring KakaoTalk to the front and may switch the user's desktop:
            MAIN_WINDOW_NOT_VISIBLE, unless --allow-activate is given. Reopening waits while
            the user is busy (KAKAOTALK_IN_USE after --wait-for-idle seconds, exit status 75).
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

    @Flag(name: [.short, .long], help: "Keep auto-opened chat window after chats")
    var keepWindow: Bool = false

    @Option(name: .long, help: "While KakaoTalk is in front, press nothing until the keyboard and mouse were idle this many seconds")
    var idleSeconds: Double = UserActivityPolicy.defaultIdleSeconds

    @Option(name: .long, help: "Wait at most this many seconds for that (0 fails at once with KAKAOTALK_IN_USE)")
    var waitForIdle: Double = UserActivityPolicy.defaultWaitSeconds

    @Flag(
        name: .long,
        help: "Allow bringing KakaoTalk to the front (카카오톡 열기) when its main window is not visible; may switch desktops"
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

        // A main window that Accessibility does not show is dealt with before the login check,
        // which would otherwise activate KakaoTalk: "카카오톡 열기" only when that switches no
        // app or desktop (KakaoTalk in front) or --allow-activate, else MAIN_WINDOW_NOT_VISIBLE.
        if KakaoTalkApp.isRunning, let early = try? KakaoTalkApp(autoLaunch: false) {
            let earlyLocator = ChatListLocator(kakao: early, runner: runner)
            if earlyLocator.mainWindow() == nil,
               case .pressed = try mainWindowAccess.reopen(kakao: early, locator: earlyLocator),
               earlyLocator.waitForMainWindow(timeout: 3.0) != nil
            {
                FileHandle.standardError.write(Data("Note: KakaoTalk's main window was reopened (\(MainWindowMenuItem.title)).\n".utf8))
            }
        }

        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let chatWindowResolver = ChatWindowResolver(kakao: kakao, runner: runner)
        let windowsBefore = kakao.windows

        // Prefer the chat list window ("카카오톡") over any conversation window
        let mainWindow: UIElement
        let autoOpenedWindow: Bool
        if let chatListWindow = kakao.chatListWindow {
            mainWindow = chatListWindow
            autoOpenedWindow = false
            runner.log("chats: using chatListWindow title='\(chatListWindow.title ?? "")'")
        } else if let fallback = try activatingFallback(kakao: kakao, access: mainWindowAccess, runner: runner) {
            mainWindow = fallback
            autoOpenedWindow = !windowsBefore.contains(where: { existing in
                CFEqual(existing.axElement, fallback.axElement)
            })
            runner.log("chats: fallback to ensureMainWindow")
        } else {
            throw ReadFailure(
                code: "WINDOW_NOT_READY",
                message: "Could not find a usable KakaoTalk window.",
                hint: "Open KakaoTalk's main window on the 채팅 tab and retry."
            )
        }

        defer {
            if autoOpenedWindow && keepWindow {
                runner.log("chats: keep-window enabled; auto-opened window will be kept")
            } else if autoOpenedWindow {
                if chatWindowResolver.closeWindow(mainWindow) {
                    runner.log("chats: auto-opened window closed")
                } else {
                    runner.log("chats: failed to close auto-opened window")
                }
            }
        }

        runner.log("chats: usable window ready")
        let scanner = ChatListScanner()
        let snapshots = scanner.scan(in: mainWindow, limit: limit, trace: { message in
            runner.log(message)
        })

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

    /// The old fallback (activate, relaunch, `open KakaoTalk.app`) brings KakaoTalk to the
    /// front, so it runs only as `MainWindowPolicy` allows and after the user-activity wait.
    private func activatingFallback(kakao: KakaoTalkApp, access: MainWindowAccess, runner: AXActionRunner) throws -> UIElement? {
        // A transient read failure must not lead to activating KakaoTalk.
        if let main = ChatListLocator(kakao: kakao, runner: runner).confirmMainWindow() {
            return main
        }
        let evidence = KakaoTalkInputGuard.shared.currentEvidence()
        let frontmost = FrontmostPolicy.keyboard(evidence).allowed
        guard MainWindowPolicy.decide(kakaoTalkFrontmost: frontmost, allowActivate: allowActivate) == .reopen else {
            throw access.notVisible(kakao: kakao, kakaoPID: evidence.kakaoPID, frontmost: frontmost)
        }
        try access.activity.waitUntilClear(.showMainWindow)
        return kakao.ensureMainWindow(timeout: 5.0, trace: { message in
            runner.log(message)
        })
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
