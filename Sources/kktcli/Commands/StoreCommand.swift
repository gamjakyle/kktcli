import ArgumentParser
import Foundation
import KktcliCore

struct StoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "store",
        abstract: "Manage the local message store that successful reads fill",
        discussion: """
            Successful reads save the messages they read to the local message store,
            one JSON-lines file per chat: ~/.kktcli/messages/<chat_id>.jsonl, or
            $KKTCLI_STORE_DIR/<chat_id>.jsonl when KKTCLI_STORE_DIR is set. The
            directory has mode 0700 and every file 0600.

            The store contains chat content in plain text on this Mac. Anything running
            as your user account (backups, sync tools, other programs) can read it.

            'kktcli search' searches it and 'kktcli store clear' deletes it; neither
            uses KakaoTalk.
            """,
        subcommands: [StoreClearCommand.self]
    )
}

struct StoreClearCommand: ParsableCommand {
    private struct ClearResponse: Encodable {
        var removed: [String]
        var store: String

        enum CodingKeys: String, CodingKey {
            case ok
            case removed
            case chatIDs = "chat_ids"
            case store
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(true, forKey: .ok)
            try container.encode(removed.count, forKey: .removed)
            try container.encode(removed, forKey: .chatIDs)
            try container.encode(store, forKey: .store)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Delete saved messages (every chat, or one with --chat-id)",
        discussion: """
            The store contains chat content in plain text on this Mac; this deletes it.
            Only <chat_id>.jsonl files in the store directory (~/.kktcli/messages or
            $KKTCLI_STORE_DIR) are removed; other files and the directory itself stay.
            KakaoTalk is not used. Later reads save messages again unless run with
            --no-save.
            """
    )

    @Option(name: .customLong("chat-id"), help: "Delete only this chat's saved messages (a chat_id from 'kktcli chats')")
    var chatID: String?

    @Flag(name: .long, help: "Output one JSON document")
    var json: Bool = false

    func validate() throws {
        // With --json the problem is reported as a JSON document from run().
        if !json, let problem = StoreCommandProblem.chatIDProblem(chatID) {
            throw ValidationError(problem.summary)
        }
    }

    func run() throws {
        let archive = MessageArchive.shared
        do {
            if let problem = StoreCommandProblem.chatIDProblem(chatID) {
                throw problem
            }
            let removed: [String]
            do {
                removed = try archive.clearChats(chatID: chatID)
            } catch {
                throw StoreCommandProblem.storeFailed(code: "STORE_CLEAR_FAILED", error: error, archive: archive)
            }
            if json {
                try StoreOutput.printJSON(ClearResponse(removed: removed, store: archive.directory.path))
                return
            }
            let directory = archive.directory.path
            guard !removed.isEmpty else {
                print("No saved messages\(chatID.map { " for \($0)" } ?? "") in \(directory).")
                return
            }
            for id in removed {
                print("Removed \((try? archive.fileURL(chatID: id).path) ?? id)")
            }
            print("Removed the saved messages of \(removed.count) chat(s) from \(directory).")
        } catch let problem as StoreCommandProblem {
            StoreOutput.report(problem, json: json)
            throw ExitCode(problem.exitCode)
        }
    }
}

// MARK: - Output shared by `search` and `store`

/// A failed `search` or `store` command. With --json it is printed on stdout as
/// {"ok": false, "error": {"code", "message", "hint"}}, otherwise on stderr; the exit status
/// is non-zero either way.
struct StoreCommandProblem: Error {
    var code: String
    var message: String
    var hint: String?
    var exitCode: Int32

    var summary: String {
        [message, hint].compactMap { $0 }.joined(separator: " ")
    }

    static func invalidArgument(_ message: String, hint: String?) -> StoreCommandProblem {
        StoreCommandProblem(code: "INVALID_ARGUMENT", message: message, hint: hint, exitCode: ExitCode.validationFailure.rawValue)
    }

    static func chatIDProblem(_ chatID: String?) -> StoreCommandProblem? {
        guard let chatID, !MessageStore.isValidChatID(chatID) else { return nil }
        return invalidArgument(
            "Invalid --chat-id '\(chatID)': only letters, digits, '_' and '-' are allowed.",
            hint: "Use a chat_id from 'kktcli chats --json'."
        )
    }

    static func storeFailed(code: String, error: Error, archive: MessageArchive) -> StoreCommandProblem {
        StoreCommandProblem(
            code: code,
            message: "\(error)",
            hint: "Check \(archive.directory.path), or set \(MessageArchive.environmentVariable) to use another directory.",
            exitCode: 1
        )
    }
}

enum StoreOutput {
    private struct ErrorResponse: Encodable {
        var problem: StoreCommandProblem

        enum CodingKeys: String, CodingKey {
            case ok
            case error
        }

        enum ErrorKeys: String, CodingKey {
            case code
            case message
            case hint
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(false, forKey: .ok)
            var error = container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
            try error.encode(problem.code, forKey: .code)
            try error.encode(problem.message, forKey: .message)
            try error.encode(problem.hint, forKey: .hint)
        }
    }

    /// One pretty-printed JSON document with sorted keys on stdout.
    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func report(_ problem: StoreCommandProblem, json: Bool) {
        if json, (try? printJSON(ErrorResponse(problem: problem))) != nil {
            return
        }
        var text = "Error: \(problem.message)\n"
        if let hint = problem.hint {
            text += "Hint: \(hint)\n"
        }
        note(text)
    }

    /// Text for people on stderr, after what was printed on stdout so far.
    static func note(_ text: String) {
        fflush(stdout)
        FileHandle.standardError.write(Data(text.utf8))
    }
}
