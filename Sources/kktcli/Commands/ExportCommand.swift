import ArgumentParser
import Foundation
import KktcliCore

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write kept messages as readable Markdown, JSON or CSV (reads only the local store)",
        discussion: """
            Reads only the local message store (~/.kktcli/messages; see 'kktcli store'), never
            KakaoTalk. The store holds chat content in plain text on this Mac.

            Markdown (default): '# room', '## YYYY-MM-DD (요일)', '- HH:MM 이름: 본문'; long
            messages as kept, attachments as [사진] or [파일: name], links kept.
            CSV is UTF-8 with a byte-order mark so Excel on the Mac shows Korean.
            """
    )

    @Option(name: .customLong("chat-id"), help: "Only this chat (repeatable; output follows this order)")
    var chatIDs: [String] = []

    @Option(name: .long, help: "From this date (YYYY-MM-DD or YYYY-MM-DDTHH:MM, inclusive)")
    var since: String?

    @Option(name: .long, help: "Until this date (inclusive)")
    var until: String?

    @Option(name: .long, help: "Only messages whose author contains this")
    var author: String?

    @Option(name: .long, help: "Only messages whose body contains this (also matched without spaces)")
    var grep: String?

    @Option(name: .long, help: "md, json or csv")
    var format: String = "md"

    @Option(name: .long, help: "Write to this file instead of stdout")
    var out: String?

    func validate() throws {
        guard ExportFormatter.Format(rawValue: format) != nil else {
            throw ValidationError("--format must be md, json or csv.")
        }
    }

    func run() throws {
        let archive = MessageArchive.shared
        let records = try chatIDs.isEmpty ? archive.records(chatID: nil) : chatIDs.flatMap { try archive.records(chatID: $0) }
        let messages = records.map(ExportMessage.init(stored:))
        let selected = ExportFormatter.select(messages, filter: ExportFilter(chatIDs: chatIDs, since: since, until: until, author: author, grep: grep))
        let text = try ExportFormatter.render(selected, format: ExportFormatter.Format(rawValue: format) ?? .md)
        if let out {
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            try Data(text.utf8).write(to: url, options: .atomic)
            FileHandle.standardError.write(Data("Wrote \(selected.count) message(s) to \(url.path)\n".utf8))
        } else {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }
}
