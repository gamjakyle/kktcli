import Foundation

/// `~/.config/kktcli/config.json` (`kktcli config get|set`). Sending is off unless the user
/// turned it on.
public struct KktcliConfig: Codable, Equatable, Sendable {
    /// `send` and `send-image` (except `--preview`) and the MCP send tools work only when on.
    public var send: Bool

    public static let defaults = KktcliConfig(send: false)
    public static let keys = ["send"]

    public init(send: Bool) {
        self.send = send
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        send = try container.decodeIfPresent(Bool.self, forKey: .send) ?? Self.defaults.send
    }

    /// The file's content, or the defaults when it is missing, empty or unreadable.
    public static func decode(_ data: Data?) -> KktcliConfig {
        guard let data, !data.isEmpty, let config = try? JSONDecoder().decode(KktcliConfig.self, from: data) else {
            return defaults
        }
        return config
    }

    public enum ValueError: Error, Equatable, CustomStringConvertible {
        case unknownKey(String)
        case invalidValue(key: String, value: String)

        public var description: String {
            switch self {
            case .unknownKey(let key):
                return "Unknown setting '\(key)'. Settings: \(KktcliConfig.keys.joined(separator: ", "))."
            case .invalidValue(let key, let value):
                return "'\(value)' is not a value for \(key); use on or off."
            }
        }
    }

    public func value(of key: String) throws -> String {
        guard key == "send" else { throw ValueError.unknownKey(key) }
        return send ? "on" : "off"
    }

    public func setting(_ key: String, to value: String) throws -> KktcliConfig {
        guard key == "send" else { throw ValueError.unknownKey(key) }
        var config = self
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on": config.send = true
        case "off": config.send = false
        default: throw ValueError.invalidValue(key: key, value: value)
        }
        return config
    }
}
