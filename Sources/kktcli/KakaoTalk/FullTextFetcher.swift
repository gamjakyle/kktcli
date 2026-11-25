import ApplicationServices.HIServices
import CoreGraphics
import Foundation
import KktcliCore

/// `read --full-text`: reads the full text of a long message (see `LongMessage`) by pressing
/// that message's 전체보기 control, reading what the press opens and closing exactly that.
///
/// The only elements pressed are
/// - the row's see-all control, re-identified from the row's cut text and re-verified right
///   before the press (`LongMessage.isSeeAllControl`: labelled "전체보기", or the unlabeled
///   button right below the cut text, as observed on 26.10.0), and
/// - afterwards the close button of the one window that appeared after that press, or
///   AXCancel on a sheet or popover that appeared after it.
///
/// What the press opens has not been observed yet. A new window, a sheet, a popover and the
/// bubble expanding in place are handled; anything without a recognisable full text is closed
/// again and the cut text is kept (`truncated: true`).
struct FullTextFetcher {
    struct Report: Encodable {
        struct Failure: Encodable {
            let messageIndex: Int
            let reason: String

            enum CodingKeys: String, CodingKey {
                case messageIndex = "message_index"
                case reason
            }
        }

        /// Truncated messages among the returned ones.
        var requested = 0
        var fetched = 0
        var failures: [Failure] = []
        /// Windows or overlays opened by a press that could not be closed again.
        var leftOpen: [String] = []

        enum CodingKeys: String, CodingKey {
            case requested
            case fetched
            case failures
            case leftOpen = "left_open"
        }
    }

    enum Outcome {
        case fetched(String, leftOpen: String?)
        case failed(String)
    }

    /// At most this many presses per read.
    static let maximumFetches = 20
    private static let openTimeout: TimeInterval = 2.5
    private static let fillTimeout: TimeInterval = 1.5
    private static let overlayRoles: Set<String> = ["AXSheet", "AXPopover"]
    private static let textRoles: Set<String> = [AXRoleName.textArea, AXRoleName.staticText, "AXTextField"]

    let kakao: KakaoTalkApp
    let runner: AXActionRunner

    func fetch(row: AXUIElement, cutText: String, parts: TranscriptAXParts) -> Outcome {
        guard let target = locate(in: row, cutText: cutText) else {
            return .failed("the row no longer shows this cut message")
        }
        let scroll = reveal(target.control, parts: parts)
        defer { restore(scroll) }

        let application = kakao.applicationElement.axElement
        let windowsBefore = kakao.windows.map(\.axElement)
        let overlaysBefore = overlays(of: parts.window) + overlays(of: application)

        // Re-verified right before the press: the same cut text and the same control.
        guard !ReadInterruption.requested else {
            return .failed("interrupted before the press")
        }
        guard let again = locate(in: row, cutText: cutText), CFEqual(again.control, target.control) else {
            return .failed("the row changed before the press; nothing was pressed")
        }
        AXNodeReader.setMessagingTimeout(target.control, seconds: 2.0)
        let status = AXNodeReader.perform(target.control, kAXPressAction)
        runner.log("read: pressed 전체보기 status=\(status.rawValue)")

        // Not cut short by an interruption: whatever the press opens must be closed again.
        let deadline = Date().addingTimeInterval(Self.openTimeout)
        repeat {
            let newWindows = kakao.windows.filter { window in
                window.identifier != ChatListLocator.mainWindowIdentifier
                    && !windowsBefore.contains { CFEqual($0, window.axElement) }
            }
            if !newWindows.isEmpty {
                return readAndClose(newWindows, cutText: cutText)
            }
            let newOverlays = (overlays(of: parts.window) + overlays(of: application)).filter { overlay in
                !overlaysBefore.contains { CFEqual($0, overlay) }
            }
            if let overlay = newOverlays.first {
                return readAndCancel(overlay, cutText: cutText)
            }
            if let value = AXNodeReader.read(target.textArea).snapshot.value, value != cutText,
               LongMessage.isFullText(value, of: cutText)
            {
                runner.log("read: the long message expanded in place")
                return .fetched(value, leftOpen: nil)
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return .failed("nothing opened after pressing 전체보기 (AXPress status \(status.rawValue))")
    }

    // MARK: Row

    /// The bubble text area showing exactly `cutText` and its see-all control, among the row
    /// cell's children (the parser's depth 2).
    private func locate(in row: AXUIElement, cutText: String) -> (textArea: AXUIElement, control: AXUIElement)? {
        guard let cell = AXNodeReader.children(row).first else { return nil }
        let children = AXNodeReader.children(cell).map { AXNodeReader.read($0, depth: 2) }
        let snapshots = children.map(\.snapshot)
        guard let textIndex = snapshots.firstIndex(where: { $0.role == AXRoleName.textArea && $0.text == cutText }),
              let controlIndex = LongMessage.seeAllControl(for: textIndex, in: snapshots)
        else {
            return nil
        }
        return (children[textIndex].element, children[controlIndex].element)
    }

    private struct ScrollState {
        let scrollBar: AXUIElement
        let original: Double
    }

    /// Scrolls the transcript (scroll-bar value) so the control is visible; nil when it already is
    /// or the transcript cannot be scrolled.
    private func reveal(_ control: AXUIElement, parts: TranscriptAXParts) -> ScrollState? {
        guard let visible = AXNodeReader.frame(parts.scrollArea) ?? parts.scrollFrame,
              let frame = AXNodeReader.frame(control),
              !ListScrollMath.isRowVisible(rowFrame: frame, visibleFrame: visible),
              let scrollBar = AXNodeReader.elementAttribute(parts.scrollArea, kAXVerticalScrollBarAttribute),
              let original = AXNodeReader.doubleValue(scrollBar),
              let tableFrame = AXNodeReader.frame(parts.table)
        else {
            return nil
        }
        let target = ListScrollMath.scrollValueCentering(rowFrame: frame, tableFrame: tableFrame, visibleFrame: visible)
        AXNodeReader.setNumber(scrollBar, kAXValueAttribute, target)
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.03)
            if let moved = AXNodeReader.frame(control), ListScrollMath.isRowVisible(rowFrame: moved, visibleFrame: visible) {
                break
            }
        }
        return ScrollState(scrollBar: scrollBar, original: original)
    }

    private func restore(_ state: ScrollState?) {
        guard let state else { return }
        AXNodeReader.setNumber(state.scrollBar, kAXValueAttribute, state.original)
    }

    // MARK: What the press opened

    private func overlays(of element: AXUIElement) -> [AXUIElement] {
        AXNodeReader.children(element).filter { Self.overlayRoles.contains(AXNodeReader.read($0).snapshot.role) }
    }

    /// The longest text in `root` that is the full text of `cutText`, waiting briefly for a
    /// just-opened view to fill.
    private func waitForFullText(in root: AXUIElement, cutText: String) -> String? {
        let deadline = Date().addingTimeInterval(Self.fillTimeout)
        repeat {
            let text = AXNodeReader.flatten(root, maxDepth: 14, budget: 900)
                .filter { Self.textRoles.contains($0.role) }
                .map(\.text)
                .filter { LongMessage.isFullText($0, of: cutText) }
                .max { $0.count < $1.count }
            if let text {
                return text
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    private func readAndClose(_ windows: [UIElement], cutText: String) -> Outcome {
        let text = windows.count == 1 ? waitForFullText(in: windows[0].axElement, cutText: cutText) : nil
        let labels = windows.map { OpenedWindowRule.label($0.title) }
        let closer = ChatWindowCloser(kakao: kakao, runner: runner)
        var leftOpen: [String] = []
        for (window, label) in zip(windows, labels) {
            let outcome = closer.close(window, expectedTitle: nil)
            runner.log("read: full-text window '\(label)': \(outcome.code)")
            if outcome != .closed {
                leftOpen.append("\(label) (\(outcome.code))")
            }
        }
        let leftOpenNote = leftOpen.isEmpty ? nil : leftOpen.joined(separator: ", ")
        if windows.count > 1 {
            return .failed("several windows opened (\(labels.joined(separator: ", "))); closed" + (leftOpenNote.map { " except \($0)" } ?? ""))
        }
        guard let text else {
            return .failed("the window that opened ('\(labels[0])') shows no recognisable full text; closed" + (leftOpenNote.map { " except \($0)" } ?? ""))
        }
        return .fetched(text, leftOpen: leftOpenNote)
    }

    private func readAndCancel(_ overlay: AXUIElement, cutText: String) -> Outcome {
        let role = AXNodeReader.read(overlay).snapshot.role
        let text = waitForFullText(in: overlay, cutText: cutText)
        let status = AXNodeReader.perform(overlay, kAXCancelAction)
        var gone = false
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.06)
            let snapshot = AXNodeReader.read(overlay).snapshot
            if snapshot.readFailed || snapshot.role.isEmpty {
                gone = true
                break
            }
        }
        runner.log("read: full-text \(role) cancelled status=\(status.rawValue) gone=\(gone)")
        let leftOpenNote = gone ? nil : "\(role) (AXCancel status \(status.rawValue))"
        guard let text else {
            return .failed("the \(role) that opened shows no recognisable full text; cancelled" + (leftOpenNote.map { ", but left open: \($0)" } ?? ""))
        }
        return .fetched(text, leftOpen: leftOpenNote)
    }
}
