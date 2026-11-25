import ApplicationServices.HIServices
import CoreGraphics
import Foundation
import KmsgCore

struct TranscriptAXParts {
    let window: AXUIElement
    let scrollArea: AXUIElement
    let table: AXUIElement
    let scrollFrame: CGRect?
}

struct TranscriptReadOptions {
    var limit: Int
    var includeSystem: Bool
    var scrollback: Bool
    var scrollbackTimeout: TimeInterval
}

struct ScrollbackReport: Encodable {
    var attempted = false
    var rowsBefore = 0
    var rowsAfter = 0
    /// Row count stopped growing (top of the locally loaded history).
    var stalled = false
    var timedOut = false
    /// "지난 대화 보기" or the history authentication notice sits at the top. Never pressed.
    var reachedHistoryTop = false
    var unavailable: String?
    var elapsedMs = 0
    var restoredToBottom = false

    enum CodingKeys: String, CodingKey {
        case attempted
        case rowsBefore = "rows_before"
        case rowsAfter = "rows_after"
        case stalled
        case timedOut = "timed_out"
        case reachedHistoryTop = "reached_history_top"
        case unavailable
        case elapsedMs = "elapsed_ms"
        case restoredToBottom = "restored_to_bottom"
    }
}

struct StructuredTranscriptResult {
    /// The newest `limit` output items, oldest first.
    let items: [TranscriptItem]
    let totalRows: Int
    let rowsRead: Int
    let scrollback: ScrollbackReport?
    /// The first item's date came from a separator above the rows that were parsed.
    let usedEarlierDateSeparator: Bool
}

/// Reads a chat window's transcript table row by row (batched AX reads) and parses it with
/// `TranscriptParser`. Rows are read from the newest end backwards until `limit` messages and
/// their context (a date separator and the sender name of continuation rows) are covered.
/// Older history is loaded by setting the transcript scroll bar to 0 and polling the row count.
struct StructuredTranscriptReader {
    private static let rowFlattenDepth = 8
    private static let rowFlattenBudget = 120
    private static let stallTimeout: TimeInterval = 1.2
    private static let dateProbeRowLimit = 5_000
    private static let dateProbeTimeout: TimeInterval = 2.5

    let runner: AXActionRunner

    /// The window's own AXScrollArea `_NS:32` holding an AXTable; otherwise the tallest scroll
    /// area inside the window frame that holds a table, list or outline.
    static func parts(in window: UIElement) -> TranscriptAXParts? {
        let windowNode = AXNodeReader.read(window.axElement)
        for child in windowNode.children {
            let node = AXNodeReader.read(child, depth: 1)
            guard node.snapshot.role == AXRoleName.scrollArea,
                  node.snapshot.identifier == ChatListLocator.transcriptScrollAreaIdentifier
            else {
                continue
            }
            if let table = node.children.first(where: { AXNodeReader.read($0).snapshot.role == AXRoleName.table }) {
                return TranscriptAXParts(window: window.axElement, scrollArea: child, table: table, scrollFrame: node.snapshot.frame)
            }
        }

        guard let windowFrame = windowNode.snapshot.frame else { return nil }
        var best: (scrollArea: AXUIElement, table: AXUIElement, frame: CGRect)?
        var queue = windowNode.children
        var index = 0
        while index < queue.count, index < 200 {
            let element = queue[index]
            index += 1
            let node = AXNodeReader.read(element)
            if node.snapshot.role == AXRoleName.scrollArea,
               let frame = node.snapshot.frame,
               windowFrame.insetBy(dx: -4, dy: -4).contains(frame)
            {
                for child in node.children {
                    let role = AXNodeReader.read(child).snapshot.role
                    guard role == AXRoleName.table || role == "AXList" || role == "AXOutline" else { continue }
                    if best == nil || frame.height > best!.frame.height {
                        best = (element, child, frame)
                    }
                }
                continue
            }
            queue.append(contentsOf: node.children)
        }
        guard let best else { return nil }
        return TranscriptAXParts(window: window.axElement, scrollArea: best.scrollArea, table: best.table, scrollFrame: best.frame)
    }

    func read(_ parts: TranscriptAXParts, options: TranscriptReadOptions) -> StructuredTranscriptResult {
        var tail = readTail(parts, options: options)
        var report: ScrollbackReport?
        var scrollBarToRestore: (element: AXUIElement, original: Double)?

        if options.scrollback, tail.selected.count < options.limit {
            var scrollReport = ScrollbackReport(attempted: true, rowsBefore: tail.totalRows, rowsAfter: tail.totalRows)
            let started = Date()
            let deadline = started.addingTimeInterval(max(0, options.scrollbackTimeout))

            if tail.start == 0, TranscriptSelection.reachedHistoryTop(tail.items) {
                scrollReport.reachedHistoryTop = true
            } else if let scrollBar = AXNodeReader.elementAttribute(parts.scrollArea, kAXVerticalScrollBarAttribute),
                      AXNodeReader.isSettable(scrollBar, kAXValueAttribute)
            {
                if let original = AXNodeReader.doubleValue(scrollBar) {
                    scrollBarToRestore = (scrollBar, original)
                }
                while tail.selected.count < options.limit {
                    if Date() >= deadline {
                        scrollReport.timedOut = true
                        break
                    }
                    let target = ScrollbackMath.targetRowCount(
                        currentRows: tail.totalRows,
                        missingMessages: options.limit - tail.selected.count
                    )
                    let step = loadOlderRows(table: parts.table, scrollBar: scrollBar, targetRowCount: target, deadline: deadline)
                    runner.log("read: scrollback rows \(step.rowsBefore) -> \(step.rowsAfter) (target \(target))")
                    scrollReport.rowsAfter = step.rowsAfter
                    let previousTotal = tail.totalRows
                    if step.rowsAfter != previousTotal {
                        tail = readTail(parts, options: options)
                    }
                    if step.stalled {
                        scrollReport.stalled = true
                        break
                    }
                    if step.timedOut {
                        scrollReport.timedOut = true
                        break
                    }
                    if tail.totalRows <= previousTotal {
                        // Nothing new although the step reported progress; do not spin.
                        scrollReport.stalled = true
                        break
                    }
                }
                if tail.start == 0, TranscriptSelection.reachedHistoryTop(tail.items) {
                    scrollReport.reachedHistoryTop = true
                }
            } else {
                scrollReport.unavailable = "the transcript scroll bar is missing or not settable"
            }
            scrollReport.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            report = scrollReport
        }

        var selected = tail.selected
        var usedEarlierSeparator = false
        if TranscriptSelection.missingContext(selected).date, tail.start > 0,
           let date = probeDateSeparator(rows: tail.rowElements, before: tail.start)
        {
            let parsed = TranscriptParser.parse(
                tail.rows,
                options: TranscriptParseOptions(transcriptFrame: parts.scrollFrame, initialDate: date)
            )
            selected = TranscriptSelection.lastItems(parsed, limit: options.limit, includeSystem: options.includeSystem)
            usedEarlierSeparator = true
        }

        // Rows are read before restoring: scrolling back down may unload older rows.
        if let scrollBarToRestore, scrollBarToRestore.original >= 0.98 {
            let status = AXNodeReader.setNumber(scrollBarToRestore.element, kAXValueAttribute, 1.0)
            report?.restoredToBottom = status == .success
        }

        return StructuredTranscriptResult(
            items: selected,
            totalRows: tail.totalRows,
            rowsRead: tail.rows.count,
            scrollback: report,
            usedEarlierDateSeparator: usedEarlierSeparator
        )
    }

    // MARK: Tail reading

    private struct TailRead {
        let rowElements: [AXUIElement]
        let totalRows: Int
        /// Index of the first row that was read.
        let start: Int
        let rows: [TranscriptRow]
        let items: [TranscriptItem]
        let selected: [TranscriptItem]
    }

    private func readTail(_ parts: TranscriptAXParts, options: TranscriptReadOptions) -> TailRead {
        let rowElements = AXNodeReader.rows(of: parts.table)
        let parseOptions = TranscriptParseOptions(transcriptFrame: parts.scrollFrame)
        let contextRowCap = max(400, options.limit * 3 + 200)

        var start = rowElements.count
        var rows: [TranscriptRow] = []
        var items: [TranscriptItem] = []
        var selected: [TranscriptItem] = []
        var chunk = max(40, options.limit * 2)

        while start > 0 {
            let newStart = max(0, start - chunk)
            let fresh = rowElements[newStart..<start].map { element in
                TranscriptRow(nodes: AXNodeReader.flatten(element, maxDepth: Self.rowFlattenDepth, budget: Self.rowFlattenBudget))
            }
            rows.insert(contentsOf: fresh, at: 0)
            start = newStart

            items = TranscriptParser.parse(rows, options: parseOptions)
            selected = TranscriptSelection.lastItems(items, limit: options.limit, includeSystem: options.includeSystem)
            if selected.count >= options.limit {
                let missing = TranscriptSelection.missingContext(selected)
                if !missing.date && !missing.author {
                    break
                }
                if rows.count >= contextRowCap {
                    runner.log("read: context row cap reached (date missing=\(missing.date), author missing=\(missing.author))")
                    break
                }
            }
            chunk = min(chunk * 2, 400)
        }

        runner.log("read: transcript rows total=\(rowElements.count) read=\(rows.count) items=\(items.count) selected=\(selected.count)")
        return TailRead(rowElements: rowElements, totalRows: rowElements.count, start: start, rows: rows, items: items, selected: selected)
    }

    /// Walks rows above `end` (cheap reads) for the nearest date separator.
    private func probeDateSeparator(rows: [AXUIElement], before end: Int) -> String? {
        let deadline = Date().addingTimeInterval(Self.dateProbeTimeout)
        var index = end - 1
        var scanned = 0
        while index >= 0, scanned < Self.dateProbeRowLimit, Date() < deadline {
            if let cell = AXNodeReader.children(rows[index]).first,
               AXNodeReader.count(cell, kAXChildrenAttribute) == 1,
               let only = AXNodeReader.children(cell).first
            {
                let node = AXNodeReader.read(only).snapshot
                if node.role == AXRoleName.button, let date = KakaoText.dateSeparator(node.label) {
                    runner.log("read: date separator \(date) found \(end - index) rows above the parsed rows")
                    return date
                }
            }
            index -= 1
            scanned += 1
        }
        return nil
    }

    // MARK: Scrollback

    private struct ScrollStep {
        var rowsBefore: Int
        var rowsAfter: Int
        var stalled: Bool
        var timedOut: Bool
    }

    /// Sets the transcript scroll bar to 0 (top) and polls the row count until it reaches
    /// `targetRowCount`, stops growing, or the deadline passes.
    private func loadOlderRows(table: AXUIElement, scrollBar: AXUIElement, targetRowCount: Int, deadline: Date) -> ScrollStep {
        let before = AXNodeReader.rowCount(of: table)
        var count = before
        var nudged = false

        while count < targetRowCount {
            if Date() >= deadline {
                return ScrollStep(rowsBefore: before, rowsAfter: count, stalled: false, timedOut: true)
            }
            if (AXNodeReader.doubleValue(scrollBar) ?? 1) > 0.0005 {
                AXNodeReader.setNumber(scrollBar, kAXValueAttribute, 0)
            }
            if let grown = waitForRowGrowth(table, from: count, until: min(deadline, Date().addingTimeInterval(Self.stallTimeout))) {
                count = grown
                nudged = false
                continue
            }
            if Date() >= deadline {
                return ScrollStep(rowsBefore: before, rowsAfter: count, stalled: false, timedOut: true)
            }
            guard !nudged else {
                return ScrollStep(rowsBefore: before, rowsAfter: count, stalled: true, timedOut: false)
            }
            // KakaoTalk may already sit at the top after the previous batch; step away and back
            // so the next batch is requested.
            nudged = true
            AXNodeReader.setNumber(scrollBar, kAXValueAttribute, 0.05)
            Thread.sleep(forTimeInterval: 0.05)
            AXNodeReader.setNumber(scrollBar, kAXValueAttribute, 0)
        }
        return ScrollStep(rowsBefore: before, rowsAfter: count, stalled: false, timedOut: false)
    }

    private func waitForRowGrowth(_ table: AXUIElement, from count: Int, until deadline: Date) -> Int? {
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.08)
            let current = AXNodeReader.rowCount(of: table)
            guard current > count else { continue }
            // Let the batch settle.
            var settled = current
            for _ in 0..<5 {
                Thread.sleep(forTimeInterval: 0.06)
                let next = AXNodeReader.rowCount(of: table)
                guard next > settled else { break }
                settled = next
            }
            return settled
        }
        return nil
    }
}
