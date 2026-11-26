import ArgumentParser
import Foundation
import KktcliCore

struct SearchCommand: ParsableCommand {
    private struct SearchResponse: Encodable {
        var results: [StoredMessage]
        var store: String

        enum CodingKeys: String, CodingKey {
            case ok
            case count
            case results
            case store
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(true, forKey: .ok)
            try container.encode(results.count, forKey: .count)
            try container.encode(results, forKey: .results)
            try container.encode(store, forKey: .store)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search saved messages in the local store (never uses KakaoTalk)",
        discussion: """
            Searches only the local message store that successful reads fill
            (~/.kktcli/messages, or $KKTCLI_STORE_DIR when set). KakaoTalk is not used,
            so only messages saved by earlier reads can be found.

            The store contains chat content in plain text on this Mac.
            'kktcli store clear' deletes it.

            <text> matches message bodies case-insensitively, also with spaces ignored
            ("안녕 하세요" finds "안녕하세요"); an empty text matches every message.
            --since and --until are inclusive: YYYY-MM-DD or YYYY-MM-DDTHH:MM.
            --author matches a name exactly or as a case-insensitive part ("(me)" is
            you). Results are newest first: by date, then time, then save order.

            Text output: one line per hit, "date time author (chat): body". With --json,
            stdout carries one document: {"ok": true, "count", "results", "store"}, or
            {"ok": false, "error": {"code", "message", "hint"}} with a non-zero exit
            status.

            Examples:
              kktcli search 안녕하세요
              kktcli search "" --author 홍길동 --since 2026-11-01 --json
              kktcli search 안녕 --chat-id <chat_id> --until 2026-11-20T18:00
            """
    )

    @Argument(help: "Text to find in message bodies (an empty string matches every message)")
    var text: String

    @Option(name: .customLong("chat-id"), help: "Only this chat (a chat_id from 'kktcli chats')")
    var chatID: String?

    @Option(name: .long, help: "Only messages on or after this day or minute: YYYY-MM-DD or YYYY-MM-DDTHH:MM")
    var since: String?

    @Option(name: .long, help: "Only messages on or before this day or minute: YYYY-MM-DD or YYYY-MM-DDTHH:MM")
    var until: String?

    @Option(name: .long, help: "Only messages whose author is this name or contains it (case-insensitive); \"(me)\" is you")
    var author: String?

    @Option(name: .shortAndLong, help: "Maximum number of results, newest first")
    var limit: Int = MessageStore.defaultSearchLimit

    @Flag(name: .long, help: "Output one JSON document")
    var json: Bool = false

    func validate() throws {
        // With --json the problem is reported as a JSON document from run().
        guard !json else { return }
        do {
            _ = try makeQuery()
        } catch let problem as StoreCommandProblem {
            throw ValidationError(problem.summary)
        }
    }

    func run() throws {
        let archive = MessageArchive.shared
        do {
            let query = try makeQuery()
            let records: [StoredMessage]
            do {
                records = try archive.records(chatID: query.chatID)
            } catch {
                throw StoreCommandProblem.storeFailed(code: "STORE_READ_FAILED", error: error, archive: archive)
            }
            if json {
                let results = MessageStore.search(records, query: query)
                try StoreOutput.printJSON(SearchResponse(results: results, store: archive.directory.path))
                return
            }
            printText(records: records, query: query, archive: archive)
        } catch let problem as StoreCommandProblem {
            StoreOutput.report(problem, json: json)
            throw ExitCode(problem.exitCode)
        }
    }

    private func printText(records: [StoredMessage], query: MessageStore.SearchQuery, archive: MessageArchive) {
        var everyHit = query
        everyHit.limit = .max
        let hits = MessageStore.search(records, query: everyHit)
        for record in hits.prefix(query.limit) {
            print(MessageStore.textLine(record))
        }
        if records.isEmpty {
            let scope = query.chatID.map { " for \($0)" } ?? ""
            StoreOutput.note("Note: no saved messages\(scope) in \(archive.directory.path); successful reads save them there.\n")
        } else if hits.isEmpty {
            StoreOutput.note("Note: no saved message matches.\n")
        } else if hits.count > query.limit {
            StoreOutput.note("Note: showing the newest \(query.limit) of \(hits.count) matches; raise --limit to see more.\n")
        }
    }

    private func makeQuery() throws -> MessageStore.SearchQuery {
        if let problem = StoreCommandProblem.chatIDProblem(chatID) {
            throw problem
        }
        let sinceBound = try Self.bound(since, option: "--since")
        let untilBound = try Self.bound(until, option: "--until")
        if MessageStore.isEmptyRange(since: sinceBound, until: untilBound) {
            throw StoreCommandProblem.invalidArgument(
                "--since \(since ?? "") is after --until \(until ?? "").",
                hint: "Swap them or widen the range."
            )
        }
        guard limit >= 1 else {
            throw StoreCommandProblem.invalidArgument(
                "--limit must be at least 1 (got \(limit)).",
                hint: "Omit it for the default of \(MessageStore.defaultSearchLimit)."
            )
        }
        return MessageStore.SearchQuery(
            text: text,
            chatID: chatID,
            since: sinceBound,
            until: untilBound,
            author: author,
            limit: limit
        )
    }

    private static func bound(_ value: String?, option: String) throws -> MessageStore.SearchBound? {
        guard let value else { return nil }
        guard let bound = MessageStore.SearchBound(value) else {
            throw StoreCommandProblem.invalidArgument(
                "Invalid \(option) '\(value)'.",
                hint: "Use YYYY-MM-DD or YYYY-MM-DDTHH:MM, e.g. 2026-11-20 or 2026-11-20T09:30."
            )
        }
        return bound
    }
}
