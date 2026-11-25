import Foundation

@main
struct VersionGenTool {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            throw ToolError.usage
        }

        let versionFilePath = args[1]
        let outputFilePath = args[2]

        let rawVersion = try String(contentsOfFile: versionFilePath, encoding: .utf8)
        guard let firstLine = rawVersion.split(whereSeparator: \.isNewline).first else {
            throw ToolError.invalidVersion("VERSION file is empty")
        }

        let version = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw ToolError.invalidVersion("VERSION file is empty")
        }

        guard isValidReleaseVersion(version) else {
            throw ToolError.invalidVersion("VERSION must be MAJOR.MINOR.PATCH without leading zeros (e.g. 0.1.0)")
        }

        let generated = """
        import Foundation

        enum BuildVersion {
            static let current = "\(escapeForSwiftLiteral(version))"
        }
        """

        let outputURL = URL(fileURLWithPath: outputFilePath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try generated.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// Semantic version core: MAJOR.MINOR.PATCH, ASCII digits, no leading zeros.
    private static func isValidReleaseVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }

        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            return part == "0" || part.first != "0"
        }
    }

    private static func escapeForSwiftLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum ToolError: LocalizedError {
    case usage
    case invalidVersion(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: VersionGenTool <VERSION file> <output swift file>"
        case .invalidVersion(let message):
            return message
        }
    }
}
