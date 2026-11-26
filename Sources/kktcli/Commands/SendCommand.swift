import ArgumentParser
import Foundation
import KktcliCore

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send one message to one chat (off unless enabled; preview first)",
        discussion: """
            kktcli send --chat-id <chat-id> <message> [--preview]
            kktcli send <chat> <message> [--preview]

            Sending is off by default: 'kktcli config set send on' enables it. While it is off,
            everything but --preview fails with SEND_DISABLED (exit status 9).

            --preview (alias --dry-run) sends nothing, also while sending is off. It opens the room
            the way 'read' does and prints who the message goes to (title, kind, member count,
            chat_id, chat-list preview and time), the last 3 messages, a warning when other rooms
            share the name, the exact text with its line and character counts, and how it would
            be sent.

            Without --preview the same room is opened, the text is put into the input box, the
            room is checked again right before the room's own 전송 button is pressed once, and the
            new bubble is verified (failures: exit status 8). One message per run; there is no
            batch send.
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

    @Flag(name: .long, help: "Allow bringing KakaoTalk to the front: 카카오톡 열기 when the main window cannot be found or opened otherwise, and the Enter fallback when the 전송 button is unavailable")
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
        let report = withStdoutRedirectedToStderr(json) { () -> SendReport in
            if !isPreview {
                do {
                    try ConfigStore.requireSendEnabled()
                } catch let failure as ReadFailure {
                    return SendOutput.failureReport(failure, mode: "send")
                } catch {
                    return SendOutput.failureReport(ReadFailure(code: "SEND_FAILED", message: "\(error)"), mode: "send")
                }
            }
            return perform(SendText.exact(message))
        }
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

            try room.requireOnThisDesktop(window)
            let now = room.tail(of: window.window, limit: 3, justOpened: false)
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
    static func failureReport(_ failure: ReadFailure, mode: String) -> SendReport {
        var report = SendReport(mode: mode)
        report.error = .init(code: failure.code, message: failure.message, hint: failure.hint)
        report.details = failure.details
        report.details["exit_status"] = String(failure.exitCode)
        return report
    }

    static func exitCode(_ report: SendReport) -> Int32? {
        guard report.error != nil else { return nil }
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
            Swift.print("Could not send: [\(error.code)] \(error.message)")
            if let hint = error.hint { Swift.print("Hint: \(hint)") }
        } else if report.mode == "preview" {
            Swift.print("Preview only: nothing was sent.")
        } else {
            Swift.print(report.bubbleVerified ? "Sent (the new bubble was verified)." : "Sent.")
        }
    }
}
