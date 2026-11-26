import Foundation
import Testing
@testable import KktcliCore

@Suite("read --all-history: meta.history")
struct HistoryStatusTests {
    private func evaluate(top: Bool = false, attempted: Bool = true, stalled: Bool = false, timedOut: Bool = false, returned: Int = 10, limit: Int = 50_000) -> HistoryStatus {
        HistoryStatus.evaluate(reachedTop: top, scrollbackAttempted: attempted, stalled: stalled, timedOut: timedOut, returned: returned, limit: limit, dates: ["2026-11-03", nil, "2026-11-01", "2026-11-20"])
    }

    @Test("Only the top of the local history counts as complete")
    func stops() {
        #expect(evaluate(top: true) == HistoryStatus(complete: true, stopped: .top, earliestDate: "2026-11-01"))
        #expect(evaluate(top: true, attempted: false).stopped == .top)
        #expect(evaluate(stalled: true).stopped == .stalled)
        #expect(evaluate(timedOut: true).stopped == .timeout)
        #expect(evaluate(timedOut: true, returned: 50_000).stopped == .timeout)
        #expect(evaluate(returned: 20, limit: 20).stopped == .limit)
        #expect(evaluate(attempted: false, returned: 20, limit: 20).stopped == .limit)
        #expect(evaluate(attempted: false, returned: 5, limit: 20).stopped == .notAttempted)
        #expect(!evaluate(stalled: true).complete)
    }

    @Test("JSON keys and values")
    func json() throws {
        let data = try JSONEncoder().encode(HistoryStatus(complete: false, stopped: .notAttempted, earliestDate: nil))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["stopped"] as? String == "not_attempted")
        #expect(object?["earliest_date"] is NSNull)
        #expect(object?["complete"] as? Bool == false)
    }
}
