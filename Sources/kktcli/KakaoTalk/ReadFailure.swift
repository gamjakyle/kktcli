import Darwin
import Foundation

/// A `read` failure with a stable machine-readable code. `kktcli read --json` prints it as
/// `{"ok": false, "error": {...}}` and exits with `exitCode`.
struct ReadFailure: Error, CustomStringConvertible {
    /// Exit status for refusals (unread room, unverifiable unread state).
    static let refusedExitCode: Int32 = 3
    /// Ctrl-C / SIGTERM (128 + SIGINT).
    static let interruptedExitCode: Int32 = 130

    var code: String
    var message: String
    var hint: String?
    var exitCode: Int32 = 1
    var details: [String: String] = [:]

    init(code: String, message: String, hint: String? = nil, exitCode: Int32 = 1, details: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.hint = hint
        self.exitCode = exitCode
        self.details = details
    }

    var description: String {
        "[\(code)] \(message)"
    }

    func adding(_ extra: [String: String]) -> ReadFailure {
        var copy = self
        copy.details.merge(extra) { _, new in new }
        return copy
    }
}

/// Runs `body` with file descriptor 1 pointed at stderr, so progress lines printed by shared
/// helpers (login, unlock) cannot corrupt the single JSON document `read --json` writes.
func withStdoutRedirectedToStderr<T>(_ enabled: Bool, _ body: () throws -> T) rethrows -> T {
    guard enabled else { return try body() }
    fflush(stdout)
    let savedStdout = dup(STDOUT_FILENO)
    guard savedStdout >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
        if savedStdout >= 0 { close(savedStdout) }
        return try body()
    }
    defer {
        fflush(stdout)
        dup2(savedStdout, STDOUT_FILENO)
        close(savedStdout)
    }
    return try body()
}

nonisolated(unsafe) private var readInterruptedFlag: sig_atomic_t = 0

/// SIGINT/SIGTERM during `read` (Ctrl-C, or the MCP server's timeout) stop the bounded loops
/// early so the command can still close the window it opened and print its document.
enum ReadInterruption {
    static func install() {
        readInterruptedFlag = 0
        signal(SIGINT) { _ in
            readInterruptedFlag = 1
        }
        signal(SIGTERM) { _ in
            readInterruptedFlag = 1
        }
    }

    static var requested: Bool {
        readInterruptedFlag != 0
    }

    static func check(_ stage: String) throws {
        guard requested else { return }
        throw ReadFailure(code: "INTERRUPTED", message: "Interrupted \(stage).", exitCode: ReadFailure.interruptedExitCode)
    }
}
