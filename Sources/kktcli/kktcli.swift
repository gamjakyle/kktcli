import ArgumentParser
import Foundation

/// kktcli is a fork of kmsg (https://github.com/channprj/kmsg, MIT); this is the kmsg release
/// it started from.
enum UpstreamVersion {
    static let base = "kmsg 1.260921.0"
}

extension BuildVersion {
    /// What `--version` and `-v` print, e.g. "0.1.0 (based on kmsg 1.260921.0)".
    static var display: String {
        "\(current) (based on \(UpstreamVersion.base))"
    }
}

private func invokedCommandName() -> String {
    let executable = CommandLine.arguments.first ?? "kktcli"
    let name = URL(fileURLWithPath: executable).lastPathComponent
    return name.isEmpty ? "kktcli" : name
}

@main
struct Kktcli: ParsableCommand {
    private static let commandName = invokedCommandName()

    static let configuration = CommandConfiguration(
        commandName: commandName,
        abstract: "A CLI tool for KakaoTalk on macOS",
        discussion: """
            \(commandName) uses macOS Accessibility APIs to interact with KakaoTalk.

            Before using \(commandName), make sure:
            1. KakaoTalk is installed and running
            2. Accessibility permission is granted (System Settings > Privacy & Security > Accessibility)

            Run '\(commandName) status' to check if everything is set up correctly.

            Examples:
              \(commandName) status
              \(commandName) auth login
              \(commandName) chats --json
              \(commandName) send "채팅방" "메시지"
              \(commandName) send-image "채팅방" "/path/to/image.png"
              \(commandName) watch "채팅방"
              \(commandName) watch "채팅방" --json
              \(commandName) mcp-server

            Tip:
              \(commandName) -v
            """,
        version: BuildVersion.display,
        subcommands: [
            AuthCommand.self,
            StatusCommand.self,
            InspectCommand.self,
            ChatsCommand.self,
            SendCommand.self,
            SendImageCommand.self,
            ReadCommand.self,
            WatchCommand.self,
            CacheCommand.self,
            SearchCommand.self,
            StoreCommand.self,
            MCPServerCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 1, arguments[0] == "-v" {
            print(BuildVersion.display)
            return
        }
        if ReadCommand.wantsJSONErrors(arguments) {
            runReportingArgumentErrorsAsJSON(arguments)
        }
        self.main(arguments)
    }

    /// Same as `main(_:)`, except that argument errors are printed as a JSON error document
    /// on stdout (exit status 64), because `read --json` promises JSON-only stdout.
    private static func runReportingArgumentErrorsAsJSON(_ arguments: [String]) -> Never {
        do {
            var command = try parseAsRoot(arguments)
            try command.run()
            exit()
        } catch let exitCode as ExitCode {
            exit(withError: exitCode)
        } catch {
            if exitCode(for: error) == .validationFailure {
                ReadCommand.printArgumentErrorJSON(message(for: error))
                exit(withError: ExitCode.validationFailure)
            }
            exit(withError: error)
        }
    }
}
