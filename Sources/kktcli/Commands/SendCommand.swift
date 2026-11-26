import ArgumentParser
import Foundation
import KktcliCore

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send one message to one chat, after you confirm it in a dialog",
        discussion: """
            kktcli send --chat-id <chat-id> <message> [--preview]
            kktcli send <chat> <message> [--preview]

            --preview (alias --dry-run) sends nothing. It opens the room the way 'read' does and
            prints who the message goes to (title, kind, member count, chat_id, chat-list preview
            and time), the last 3 messages, a warning when other rooms share the name, the exact
            text with its line and character counts, and how it would be sent.

            Without --preview the same room is opened and a macOS confirmation dialog shows the
            room, its last messages and the full text. 취소 is the default (Return and Esc
            cancel); 보내기 counts only for a real mouse click after 1 s; the dialog cancels by
            itself after 120 s (SEND_CANCELLED, exit status 7). No option skips the dialog.
            After 보내기 the room is checked again, the text is put into the input box, the
            room's own 전송 button is pressed once and the new bubble is verified (other
            failures: exit status 8). One message per run; there is no batch send.
            """
    )

    @Option(name: .long, help: "Send using a chat_id from 'kktcli chats'")
    var chatID: String?

    @Argument(help: "Chat name, or the message when --chat-id is used")
    var firstValue: String?

    @Argument(help: "The message when a chat name is given")
    var secondValue: String?

    @Flag(name: .long, help: "Send nothing; show who it goes to, the last messages and the exact text")
    var preview: Bool = false

    @Flag(name: .customLong("dry-run"), help: "Same as --preview")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Print one JSON document")
    var json: Bool = false

    @Flag(name: [.short, .long], help: "Keep the chat window open if kktcli opened it")
    var keepWindow: Bool = false

    @Option(name: .long, help: "While KakaoTalk is in front, press nothing until the keyboard and mouse were idle this many seconds")
    var idleSeconds: Double = UserActivityPolicy.defaultIdleSeconds

    @Option(name: .long, help: "Wait at most this many seconds for that (0 fails at once with KAKAOTALK_IN_USE)")
    var waitForIdle: Double = UserActivityPolicy.defaultWaitSeconds

    @Flag(name: .long, help: "Allow bringing KakaoTalk to the front: to reopen a hidden main window, and for the Enter fallback when the 전송 button is unavailable")
    var allowActivate: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    private var isPreview: Bool { preview || dryRun }

    private var message: String {
        (chatID == nil ? secondValue : firstValue) ?? ""
    }

    func validate() throws {
        if let chatID, !chatID.isEmpty {
            guard let firstValue, !firstValue.isEmpty else { throw ValidationError("The message is required.") }
            guard secondValue == nil else { throw ValidationError("A chat name cannot be given together with --chat-id.") }
        } else {
            guard let firstValue, !firstValue.isEmpty else { throw ValidationError("The chat name is required.") }
            guard let secondValue, !secondValue.isEmpty else { throw ValidationError("The message is required.") }
        }
        guard !SendText.exact(message).isEmpty else { throw ValidationError("The message is empty.") }
        for (name, value) in [("--idle-seconds", idleSeconds), ("--wait-for-idle", waitForIdle)]
            where value < 0 || value > UserActivityPolicy.maximumSeconds
        {
            throw ValidationError("\(name) must be between 0 and \(Int(UserActivityPolicy.maximumSeconds)).")
        }
    }

    func run() throws {
        let report = withStdoutRedirectedToStderr(json) { perform(SendText.exact(message)) }
        SendOutput.print(report, json: json)
        if let code = SendOutput.exitCode(report) {
            throw ExitCode(code)
        }
    }

    private func perform(_ text: String) -> SendReport {
        var report = SendReport(mode: isPreview ? "preview" : "send")
        var session: RoomSession?
        var opened: RoomSession.Opened?
        do {
            let room = try RoomSession(traceAX: traceAX, idleSeconds: idleSeconds, waitForIdle: waitForIdle, allowActivate: allowActivate)
            session = room
            let located = try chatID.map { try room.locate(chatID: $0) } ?? room.locate(name: firstValue ?? "")
            let window = try room.open(located)
            opened = window
            let tail = room.tail(of: window.window, limit: 3, justOpened: window.openedByUs)
            let method = "chat_list_menu + AXValue + 전송 button"
            let preview = SendPreview(
                title: located.row.title,
                memberCount: located.row.summary.memberCount,
                chatID: located.chatID,
                listPreview: located.row.summary.preview,
                listTime: located.row.summary.timeLabel,
                lastMessages: tail.suffix(3).map(SendContextMessage.init(item:)),
                sameNameRows: located.sameNameRows,
                text: text,
                method: method
            )
            report.preview = preview
            report.method = method

            if isPreview {
                report.ok = true
                report.window = room.close(window, keep: keepWindow)
                return report
            }

            let dialog = SendConfirmationDialog(log: { room.runner.log($0) })
            let outcome = dialog.run(SendOutput.dialogContent(preview))
            guard outcome == .send else {
                report.cancelled = true
                report.window = room.close(window, keep: keepWindow)
                let reason: String
                switch outcome {
                case .timedOut: reason = "timed out after \(Int(SendDialogPolicy.timeout)) s"
                case .unavailable(let why): reason = "the dialog could not be shown (\(why))"
                default: reason = "cancelled"
                }
                report.error = .init(code: "SEND_CANCELLED", message: "Not sent: \(reason).", hint: nil)
                return report
            }

            // The same window, the same room, and nothing new since the dialog was shown.
            guard room.stillShows(window) else {
                throw MessageSender.failure("SEND_TARGET_CHANGED", "The chat window closed or changed while the dialog was open; nothing was sent.")
            }
            let now = room.tail(of: window.window, limit: 3, justOpened: false)
            switch SendVerification.compareTail(before: tail.suffix(3).map(SendVerification.Key.init(item:)), now: now.suffix(3).map(SendVerification.Key.init(item:))) {
            case .same:
                break
            case .grown(let newer):
                throw MessageSender.failure("SEND_CONTEXT_CHANGED", "\(newer) new message(s) arrived while the dialog was open; nothing was sent.", hint: "Run the preview again to see them.")
            case .different:
                throw MessageSender.failure("SEND_TARGET_CHANGED", "The room's last messages no longer match what the dialog showed; nothing was sent.")
            }

            let sent = try MessageSender(session: room, allowActivate: allowActivate).send(text, in: window, tailBefore: now)
            report.ok = true
            report.sent = true
            report.bubbleVerified = sent.bubbleVerified
            report.method = sent.method
            report.window = room.close(window, keep: keepWindow)
            return report
        } catch let failure as ReadFailure {
            if let session, let opened {
                report.window = session.close(opened, keep: keepWindow)
            }
            report.error = .init(code: failure.code, message: failure.message, hint: failure.hint)
            report.details = failure.details
            report.details["exit_status"] = String(failure.exitCode)
            if failure.details["probably_sent"] == "true" {
                report.sent = true
            }
            return report
        } catch {
            report.error = .init(code: "SEND_FAILED", message: "\(error)", hint: nil)
            return report
        }
    }
}

/// Shared output of `send` and `send-image`.
enum SendOutput {
    static func dialogContent(_ preview: SendPreview) -> SendConfirmationDialog.Content {
        let members = preview.memberCount.map { ", \($0)명" } ?? ""
        var context = ["방: \(preview.title) (\(preview.kind.rawValue)\(members))" + (preview.chatID.map { " · \($0)" } ?? "")]
        if !preview.lastMessages.isEmpty {
            context.append("최근 메시지:")
            context += preview.lastMessages.map { "  \($0.time ?? "-") \($0.author ?? "?"): \($0.body.replacingOccurrences(of: "\n", with: " "))" }
        }
        return .init(
            heading: "이 메시지를 \(preview.title)에 보낼까요? (\(preview.lines)줄, \(preview.characters)자)",
            context: context.joined(separator: "\n"),
            text: preview.text,
            checks: preview.checks
        )
    }

    static func exitCode(_ report: SendReport) -> Int32? {
        guard let error = report.error else { return nil }
        if error.code == "SEND_CANCELLED" { return KktcliExitStatus.sendCancelled }
        return Int32(report.details["exit_status"] ?? "") ?? 1
    }

    static func print(_ report: SendReport, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var clean = report
            clean.details.removeValue(forKey: "exit_status")
            if let data = try? encoder.encode(clean) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            return
        }
        if let preview = report.preview {
            Swift.print(preview.humanText)
        }
        if let file = report.file {
            Swift.print("File:    \(file)")
        }
        if let error = report.error {
            Swift.print(error.code == "SEND_CANCELLED" ? "Not sent: \(error.message)" : "Could not send: [\(error.code)] \(error.message)")
            if let hint = error.hint { Swift.print("Hint: \(hint)") }
        } else if report.mode == "preview" {
            Swift.print("Preview only: nothing was sent.")
        } else {
            Swift.print(report.bubbleVerified ? "Sent (the new bubble was verified)." : "Sent.")
        }
    }
}
