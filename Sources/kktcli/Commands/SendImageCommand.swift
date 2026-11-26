import AppKit
import ArgumentParser
import Foundation
import KktcliCore

struct SendImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-image",
        abstract: "Send one image to one chat (off unless enabled; preview first)",
        discussion: """
            kktcli send-image <chat> <image> [--preview]
            kktcli send-image --chat-id <chat-id> <image> [--preview]

            Like 'send': off unless 'kktcli config set send on' (SEND_DISABLED, exit status 9);
            --preview always works and shows the room, its last messages and the file. Pasting
            needs KakaoTalk in front, so it is brought to the front only for the paste; the
            clipboard is saved before the image is put on it and restored afterwards, and the app
            that was in front before is brought back.
            """
    )

    @Option(name: .long, help: "Send using a chat_id from 'kktcli chats'")
    var chatID: String?

    @Argument(help: "Chat name, or the image path when --chat-id is used")
    var firstValue: String

    @Argument(help: "Path to the image file when a chat name is given")
    var secondValue: String?

    @Flag(name: .long, help: "Send nothing; show who it goes to and the file")
    var preview: Bool = false

    @Flag(name: .long, help: "Print one JSON document")
    var json: Bool = false

    @Flag(name: [.short, .long], help: "Keep the chat window open if kktcli opened it")
    var keepWindow: Bool = false

    @Option(name: .long, help: "While KakaoTalk is in front, press nothing until the keyboard and mouse were idle this many seconds")
    var idleSeconds: Double = UserActivityPolicy.defaultIdleSeconds

    @Option(name: .long, help: "Wait at most this many seconds for that (0 fails at once with KAKAOTALK_IN_USE)")
    var waitForIdle: Double = UserActivityPolicy.defaultWaitSeconds

    @Flag(name: .long, help: "Allow reopening a hidden main window (brings KakaoTalk to the front)")
    var allowActivate: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    private var imagePath: String { (chatID == nil ? secondValue : firstValue) ?? "" }

    func validate() throws {
        if chatID != nil, secondValue != nil {
            throw ValidationError("A chat name cannot be given together with --chat-id.")
        }
        if chatID == nil, secondValue == nil {
            throw ValidationError("The image path is required.")
        }
    }

    func run() throws {
        let report = withStdoutRedirectedToStderr(json) { () -> SendReport in
            if !preview {
                do {
                    try ConfigStore.requireSendEnabled()
                } catch let failure as ReadFailure {
                    return SendOutput.failureReport(failure, mode: "send")
                } catch {
                    return SendOutput.failureReport(ReadFailure(code: "SEND_FAILED", message: "\(error)"), mode: "send")
                }
            }
            return perform()
        }
        SendOutput.print(report, json: json)
        if let code = SendOutput.exitCode(report) {
            throw ExitCode(code)
        }
    }

    private func perform() -> SendReport {
        var report = SendReport(mode: preview ? "preview" : "send")
        let url = URL(fileURLWithPath: (imagePath as NSString).expandingTildeInPath)
        guard let image = NSImage(contentsOf: url) else {
            report.error = .init(code: "INVALID_ARGUMENT", message: "Not a readable image: \(url.path)", hint: nil)
            report.details["exit_status"] = String(KktcliExitStatus.usage)
            return report
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let fileLabel = "\(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
        report.file = fileLabel

        var session: RoomSession?
        var opened: RoomSession.Opened?
        do {
            let room = try RoomSession(traceAX: traceAX, idleSeconds: idleSeconds, waitForIdle: waitForIdle, allowActivate: allowActivate)
            session = room
            let located = try chatID.map { try room.locate(chatID: $0) } ?? room.locate(name: firstValue)
            let window = try room.open(located)
            opened = window
            let tail = room.tail(of: window.window, limit: 3, justOpened: window.openedByUs)
            let method = "chat_list_menu + paste (KakaoTalk brought to the front for it) + sheet 전송"
            let summary = SendPreview(
                title: located.row.title,
                memberCount: located.row.summary.memberCount,
                chatID: located.chatID,
                listPreview: located.row.summary.preview,
                listTime: located.row.summary.timeLabel,
                lastMessages: tail.suffix(3).map(SendContextMessage.init(item:)),
                sameNameRows: located.sameNameRows,
                text: "[이미지] \(fileLabel)",
                method: method
            )
            report.preview = summary
            report.method = method
            if preview {
                report.ok = true
                report.window = room.close(window, keep: keepWindow)
                return report
            }

            try room.requireOnThisDesktop(window)
            guard room.stillShows(window) else {
                throw MessageSender.failure("SEND_TARGET_CHANGED", "The chat window closed or changed; nothing was sent.")
            }
            let now = room.tail(of: window.window, limit: 3, justOpened: false)
            let verified = try ImagePaster(session: room).paste(image, into: window, tailBefore: now)
            report.ok = true
            report.sent = true
            report.bubbleVerified = verified
            report.window = room.close(window, keep: keepWindow)
            return report
        } catch let failure as ReadFailure {
            if let session, let opened {
                report.window = session.close(opened, keep: keepWindow)
            }
            report.error = .init(code: failure.code, message: failure.message, hint: failure.hint)
            report.details = failure.details
            report.details["exit_status"] = String(failure.exitCode)
            return report
        } catch {
            report.error = .init(code: "SEND_FAILED", message: "\(error)", hint: nil)
            return report
        }
    }
}

/// Pastes an image into an open chat window and presses the confirmation sheet's 전송. The
/// clipboard is saved first and restored afterwards; KakaoTalk is brought to the front only for
/// the paste (Cmd-V goes through `KakaoTalkInputGuard`), then the previous app comes back.
struct ImagePaster {
    let session: RoomSession

    func paste(_ image: NSImage, into opened: RoomSession.Opened, tailBefore: [TranscriptItem]) throws -> Bool {
        let runner = session.runner
        let pasteboard = NSPasteboard.general
        let saved = Self.save(pasteboard)
        let previous = KakaoTalkInputGuard.shared.currentEvidence().focusedApplicationPID
            .flatMap { NSRunningApplication(processIdentifier: $0) }
        defer {
            Self.restore(saved, to: pasteboard)
            runner.log("send-image: clipboard restored (\(saved.count) item(s))")
            if let previous, previous.bundleIdentifier != KakaoTalkApp.bundleIdentifier {
                previous.activate(options: [])
            }
        }

        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        session.kakao.activate()
        _ = AXNodeReader.perform(opened.window.axElement, kAXRaiseAction)
        let deadline = Date().addingTimeInterval(1.5)
        while !KakaoTalkInputGuard.shared.isKakaoTalkFrontmost(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard runner.pressPaste() else {
            throw MessageSender.failure("NOT_FRONTMOST", "KakaoTalk could not be verified in front, so nothing was pasted or sent.")
        }

        if let sheet = waitForSheet(in: opened.window) {
            guard let button = AXNodeReader.firstDescendant(of: sheet, maxNodes: 200, where: {
                SendButtonSafety.isSendButton(role: $0.snapshot.role, title: $0.snapshot.title, description: $0.snapshot.desc)
            })?.element else {
                _ = AXNodeReader.perform(sheet, kAXCancelAction)
                throw MessageSender.failure("SEND_BUTTON_UNAVAILABLE", "The image sheet has no 전송 button; it was cancelled and nothing was sent.")
            }
            let status = AXNodeReader.perform(button, kAXPressAction)
            runner.log("send-image: pressed the sheet's 전송 status=\(status.rawValue)")
        } else {
            runner.log("send-image: no confirmation sheet appeared after the paste")
        }

        let verifyDeadline = Date().addingTimeInterval(4.0)
        repeat {
            Thread.sleep(forTimeInterval: 0.3)
            if SendVerification.imageSent(before: tailBefore, after: session.tail(of: opened.window, limit: 6, justOpened: false)) {
                return true
            }
        } while Date() < verifyDeadline
        throw MessageSender.failure(
            "SEND_UNVERIFIED",
            "No new outgoing image bubble was found. Check the room before doing anything else, and do not send it again.",
            details: ["probably_sent": "unknown"]
        )
    }

    private func waitForSheet(in window: UIElement) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(2.0)
        repeat {
            if let sheet = AXNodeReader.children(window.axElement).first(where: { AXNodeReader.read($0).snapshot.role == "AXSheet" }) {
                return sheet
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    /// Every item and type on the pasteboard, as data.
    static func save(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { types[type] = data }
            }
            return types
        }
    }

    static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
