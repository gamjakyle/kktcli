import Foundation

/// `meta.history` of `read`: how far back the messages go and why reading stopped.
///
/// KakaoTalk keeps only part of a room's history locally; older messages sit behind
/// "지난 대화 보기", which needs the user's own authentication and is never pressed by kktcli.
/// `complete` therefore means "everything KakaoTalk has locally", reached when the top of the
/// transcript shows that control (or the authentication notice).
public struct HistoryStatus: Codable, Equatable, Sendable {
    public enum Stop: String, Codable, Sendable {
        /// The top of the local history (지난 대화 보기 / authentication notice) is loaded.
        case top
        /// Scrolling up loaded no more rows (KakaoTalk's local limit).
        case stalled
        /// The scrollback time budget ran out.
        case timeout
        /// `--limit` messages were returned; older ones were not looked for.
        case limit
        /// No scrollback (`--no-scrollback`, `--background-safe`).
        case notAttempted = "not_attempted"
    }

    public var complete: Bool
    public var stopped: Stop
    /// The oldest date among the returned messages.
    public var earliestDate: String?

    enum CodingKeys: String, CodingKey {
        case complete
        case stopped
        case earliestDate = "earliest_date"
    }

    public init(complete: Bool, stopped: Stop, earliestDate: String?) {
        self.complete = complete
        self.stopped = stopped
        self.earliestDate = earliestDate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(complete, forKey: .complete)
        try container.encode(stopped, forKey: .stopped)
        try container.encode(earliestDate, forKey: .earliestDate)
    }

    public static func evaluate(
        reachedTop: Bool,
        scrollbackAttempted: Bool,
        stalled: Bool,
        timedOut: Bool,
        returned: Int,
        limit: Int,
        dates: [String?]
    ) -> HistoryStatus {
        let earliest = dates.compactMap { $0 }.min()
        let stop: Stop
        if reachedTop {
            stop = .top
        } else if !scrollbackAttempted {
            stop = returned >= limit ? .limit : .notAttempted
        } else if timedOut {
            stop = .timeout
        } else if stalled {
            stop = .stalled
        } else {
            stop = returned >= limit ? .limit : .stalled
        }
        return HistoryStatus(complete: stop == .top, stopped: stop, earliestDate: earliest)
    }
}
