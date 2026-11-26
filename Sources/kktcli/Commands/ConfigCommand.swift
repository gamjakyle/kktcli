import ArgumentParser
import Darwin
import Foundation
import KktcliCore

/// `~/.config/kktcli/config.json` (directory 0700, file 0600). `KKTCLI_CONFIG_DIR` overrides the
/// directory (tests use a temporary one).
enum ConfigStore {
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["KKTCLI_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return AuthPaths.configDirectoryURL
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static func load() -> KktcliConfig {
        KktcliConfig.decode(try? Data(contentsOf: fileURL))
    }

    static func save(_ config: KktcliConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
        chmod(fileURL.path, 0o600)
    }

    /// SEND_DISABLED (nothing touched) unless sending was turned on.
    static func requireSendEnabled() throws {
        guard load().send else {
            throw ReadFailure(
                code: "SEND_DISABLED",
                message: "Sending is off in kktcli, so nothing was sent.",
                hint: "Only if you want kktcli to send: kktcli config set send on",
                exitCode: KktcliExitStatus.sendDisabled
            )
        }
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change kktcli settings (~/.config/kktcli/config.json)",
        discussion: """
            kktcli config get send
            kktcli config set send on|off

            send (default off): while off, 'send' and 'send-image' refuse to send (SEND_DISABLED;
            --preview still works) and the MCP server does not offer its send tools.
            """,
        subcommands: [Get.self, Set.self]
    )

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a setting")

        @Argument(help: "Setting name (send)")
        var key: String

        @Flag(name: .long, help: "Print one JSON document")
        var json: Bool = false

        func run() throws {
            do {
                ConfigCommand.output(key: key, value: try ConfigStore.load().value(of: key), json: json)
            } catch let error as KktcliConfig.ValueError {
                throw ValidationError(error.description)
            }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a setting")

        @Argument(help: "Setting name (send)")
        var key: String

        @Argument(help: "on or off")
        var value: String

        @Flag(name: .long, help: "Print one JSON document")
        var json: Bool = false

        func run() throws {
            do {
                let config = try ConfigStore.load().setting(key, to: value)
                try ConfigStore.save(config)
                ConfigCommand.output(key: key, value: try config.value(of: key), json: json)
            } catch let error as KktcliConfig.ValueError {
                throw ValidationError(error.description)
            }
        }
    }

    static func output(key: String, value: String, json: Bool) {
        if json {
            print(#"{"key":"\#(key)","ok":true,"value":"\#(value)"}"#)
        } else {
            print("\(key) \(value)")
        }
    }
}
