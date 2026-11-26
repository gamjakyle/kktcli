import AppKit
import Foundation
import KktcliCore

/// The native confirmation for `send` and `send-image`: the only way to approve a send.
///
/// 취소 is the default button (Return) and Esc cancels too. 보내기 has no key equivalent,
/// cannot take keyboard focus, is enabled only after `SendDialogPolicy.enableDelay`, and counts
/// only for a real left mouse click inside it (seen by a local event monitor; an AXPress or a
/// key press reaches the action without such a click and is ignored). The dialog cancels by
/// itself after `SendDialogPolicy.timeout`.
final class SendConfirmationDialog: NSObject {
    enum Outcome: Equatable {
        case send
        case cancel
        case timedOut
        case unavailable(String)
    }

    struct Content {
        var heading: String
        var context: String
        var text: String
        var checks: [String]
    }

    private var panel: ConfirmationPanel?
    private var sendButton: NSButton?
    private var shownAt = Date()
    private var outcome: Outcome = .cancel
    private var timers: [Timer] = []
    private var monitor: Any?
    private var lastMouseUpInSend: (timestamp: TimeInterval, number: Int)?
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func run(_ content: Content) -> Outcome {
        guard Thread.isMainThread else {
            return .unavailable("the dialog must run on the main thread")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = makePanel(content)
        self.panel = panel

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            if let self, let button = self.sendButton, event.window === button.window {
                let point = button.convert(event.locationInWindow, from: nil)
                if button.bounds.contains(point) {
                    self.lastMouseUpInSend = (event.timestamp, event.eventNumber)
                }
            }
            return event
        }

        app.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        shownAt = Date()
        schedule(after: SendDialogPolicy.enableDelay) { [weak self] in
            self?.sendButton?.isEnabled = true
        }
        schedule(after: SendDialogPolicy.timeout) { [weak self] in
            self?.finish(SendDialogPolicy.decide(.timeout, elapsed: SendDialogPolicy.timeout))
        }
        app.runModal(for: panel)

        timers.forEach { $0.invalidate() }
        timers = []
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        panel.orderOut(nil)
        self.panel = nil
        return outcome
    }

    private func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        timers.append(timer)
    }

    private func finish(_ decision: SendDialogPolicy.Decision) {
        switch decision {
        case .ignore:
            return
        case .send:
            outcome = .send
        case .cancel:
            outcome = .cancel
        case .timedOut:
            outcome = .timedOut
        }
        NSApplication.shared.stopModal()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        finish(SendDialogPolicy.decide(.cancelButton, elapsed: Date().timeIntervalSince(shownAt)))
    }

    @objc private func sendPressed(_ sender: Any?) {
        let event = NSApplication.shared.currentEvent
        var realClick = false
        if let event, event.type == .leftMouseUp, let recorded = lastMouseUpInSend {
            realClick = recorded.number == event.eventNumber && recorded.timestamp == event.timestamp
        }
        let decision = SendDialogPolicy.decide(.sendButton(mouseEvent: realClick), elapsed: Date().timeIntervalSince(shownAt))
        if decision == .ignore {
            log("send: 보내기 activation ignored (real mouse click: \(realClick))")
            NSSound.beep()
        }
        finish(decision)
    }

    private func makePanel(_ content: Content) -> ConfirmationPanel {
        let width: CGFloat = 520
        let panel = ConfirmationPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 460),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "kktcli · 보내기 확인"
        panel.level = .modalPanel
        panel.onCancel = { [weak self] in
            self?.finish(SendDialogPolicy.decide(.escapeKey, elapsed: Date().timeIntervalSince(self?.shownAt ?? Date())))
        }

        let heading = NSTextField(wrappingLabelWithString: content.heading)
        heading.font = .boldSystemFont(ofSize: 14)
        let context = NSTextField(wrappingLabelWithString: content.context)
        context.font = .systemFont(ofSize: 12)
        context.textColor = .secondaryLabelColor

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 40, height: 160))
        textView.string = content.text
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width - 40, height: 160))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let checks = NSTextField(wrappingLabelWithString: content.checks.map { "⚠︎ " + $0 }.joined(separator: "\n"))
        checks.font = .systemFont(ofSize: 12)
        checks.textColor = .systemOrange

        let cancel = NSButton(title: "취소", target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\r"
        let send = NSButton(title: "보내기", target: self, action: #selector(sendPressed(_:)))
        send.keyEquivalent = ""
        send.isEnabled = false
        send.refusesFirstResponder = true
        sendButton = send

        let buttons = NSStackView(views: [send, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [heading, context, scroll, checks, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: width - 40),
            scroll.heightAnchor.constraint(equalToConstant: 160),
            heading.widthAnchor.constraint(lessThanOrEqualToConstant: width - 40),
            context.widthAnchor.constraint(lessThanOrEqualToConstant: width - 40),
            checks.widthAnchor.constraint(lessThanOrEqualToConstant: width - 40),
        ])
        panel.initialFirstResponder = cancel
        return panel
    }
}

/// Esc (cancelOperation) cancels.
final class ConfirmationPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
