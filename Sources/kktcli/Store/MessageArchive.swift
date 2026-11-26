import Darwin
import Foundation
import KktcliCore

/// The local message store: one JSON-lines file per chat, `<chat_id>.jsonl`, in
/// `~/.kktcli/messages`, or in `$KKTCLI_STORE_DIR` when that is set (tests use a temporary
/// directory).
///
/// The files hold chat content in plain text. The directory is created with mode 0700 and
/// every file with 0600; wider modes are narrowed whenever something is saved. chat_ids are
/// validated before any path is built, so nothing is written outside the directory. Nothing
/// here touches KakaoTalk.
struct MessageArchive: Sendable {
    static let environmentVariable = "KKTCLI_STORE_DIR"
    /// Below the home directory.
    static let defaultRelativePath = ".kktcli/messages"
    static let directoryMode: mode_t = 0o700
    static let fileMode: mode_t = 0o600

    /// The store this process uses (`KKTCLI_STORE_DIR` or `~/.kktcli/messages`).
    static var shared: MessageArchive {
        MessageArchive()
    }

    let directory: URL

    init(directory: URL = MessageArchive.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            // `standardized` only removes "." and ".." segments; the path stays as given.
            return URL(fileURLWithPath: expanded, isDirectory: true).absoluteURL.standardized
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(defaultRelativePath, isDirectory: true)
    }

    // MARK: API

    /// Saves the messages and system lines of one successful read (control rows are skipped)
    /// to the chat's file and returns how many records were new. Records already stored
    /// with the same date, time, author, body and occurrence are not added again (see
    /// `MessageStore.merge`). The whole read-merge-append runs under an exclusive lock on
    /// the file, so concurrent appends to one chat cannot interleave.
    @discardableResult
    func append(chatID: String, chat: String, items: [TranscriptItem], savedAt: Date = Date()) throws -> Int {
        let url = try fileURL(chatID: chatID)
        let incoming = MessageStore.records(
            from: items,
            chatID: chatID,
            chat: chat,
            savedAt: MessageStore.timestamp(savedAt)
        )
        guard !incoming.isEmpty else { return 0 }

        try prepareDirectory()
        guard let descriptor = try openLocked(url, forWriting: true) else {
            throw MessageArchiveError.system(operation: "open", path: url.path, code: ENOENT)
        }
        defer { close(descriptor) }
        try restrictFileMode(descriptor, path: url.path)

        let content = try readAll(descriptor, path: url.path)
        let added = MessageStore.merge(existing: MessageStore.decodeLines(content).records, incoming: incoming)
        guard !added.isEmpty else { return 0 }

        var data = Data()
        if let last = content.last, last != 0x0A {
            // An earlier write was cut short: start on a fresh line so this record stays whole.
            data.append(0x0A)
        }
        data.append(try MessageStore.encodeLines(added))
        try writeAll(descriptor, data, path: url.path)
        return added.count
    }

    /// The saved records of one chat, or of every chat (files in chat_id order), each in file
    /// order. A missing store or file means no records. Never creates anything.
    func records(chatID: String?) throws -> [StoredMessage] {
        if let chatID {
            return try records(in: fileURL(chatID: chatID))
        }
        var records: [StoredMessage] = []
        for id in try storedChatIDs() {
            records.append(contentsOf: try self.records(in: fileURL(chatID: id)))
        }
        return records
    }

    /// Deletes the file of one chat, or every `<chat_id>.jsonl` in the store (other files are
    /// left alone), and returns how many files were removed.
    @discardableResult
    func clear(chatID: String?) throws -> Int {
        try clearChats(chatID: chatID).count
    }

    /// Like `clear(chatID:)`, returning the chat_ids whose files were removed.
    func clearChats(chatID: String?) throws -> [String] {
        let ids: [String]
        if let chatID {
            _ = try fileURL(chatID: chatID)
            ids = [chatID]
        } else {
            ids = try storedChatIDs()
        }
        var removed: [String] = []
        for id in ids {
            if try removeFile(fileURL(chatID: id)) {
                removed.append(id)
            }
        }
        return removed
    }

    /// chat_ids that have a store file, sorted.
    func storedChatIDs() throws -> [String] {
        let path = directory.path
        var info = stat()
        guard stat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return [] }
            throw MessageArchiveError.system(operation: "stat", path: path, code: code)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw MessageArchiveError.notADirectory(path)
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            throw MessageArchiveError.listFailed(path: path, reason: error.localizedDescription)
        }
        return names.compactMap { name -> String? in
            guard let id = MessageStore.chatID(fromFileName: name) else { return nil }
            var entry = stat()
            guard lstat(directory.appendingPathComponent(name).path, &entry) == 0, (entry.st_mode & S_IFMT) == S_IFREG else {
                return nil
            }
            return id
        }
        .sorted()
    }

    /// `<directory>/<chat_id>.jsonl`; throws for a chat_id that is not `[A-Za-z0-9_-]+`.
    func fileURL(chatID: String) throws -> URL {
        guard let name = MessageStore.fileName(chatID: chatID) else {
            throw MessageArchiveError.invalidChatID(chatID)
        }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: Files

    private func records(in url: URL) throws -> [StoredMessage] {
        guard let descriptor = try openLocked(url, forWriting: false) else { return [] }
        defer { close(descriptor) }
        return MessageStore.decodeLines(try readAll(descriptor, path: url.path)).records
    }

    /// Creates the directory (0700) when missing; narrows an existing one that group or
    /// others can access to 0700.
    private func prepareDirectory() throws {
        let path = directory.path
        var info = stat()
        if stat(path, &info) != 0 {
            let code = errno
            guard code == ENOENT else {
                throw MessageArchiveError.system(operation: "stat", path: path, code: code)
            }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Int(Self.directoryMode))]
                )
            } catch {
                throw MessageArchiveError.createFailed(path: path, reason: error.localizedDescription)
            }
            guard stat(path, &info) == 0 else {
                throw MessageArchiveError.system(operation: "stat", path: path, code: errno)
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw MessageArchiveError.notADirectory(path)
        }
        if info.st_mode & 0o077 != 0, chmod(path, Self.directoryMode) != 0 {
            throw MessageArchiveError.system(operation: "chmod", path: path, code: errno)
        }
    }

    /// Narrows a store file that group or others can access to 0600.
    private func restrictFileMode(_ descriptor: Int32, path: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw MessageArchiveError.system(operation: "stat", path: path, code: errno)
        }
        if info.st_mode & 0o077 != 0, fchmod(descriptor, Self.fileMode) != 0 {
            throw MessageArchiveError.system(operation: "chmod", path: path, code: errno)
        }
    }

    /// Opens the file (created with 0600 when writing; symbolic links are refused) and takes
    /// a lock on it: exclusive for writing, shared for reading. When the file was removed or
    /// replaced while waiting for the lock (`store clear`), the current file is opened
    /// instead. Returns nil only when reading a file that does not exist.
    private func openLocked(_ url: URL, forWriting: Bool) throws -> Int32? {
        let path = url.path
        let access = forWriting ? (O_RDWR | O_CREAT | O_APPEND) : O_RDONLY
        for _ in 0..<8 {
            let descriptor = open(path, access | O_CLOEXEC | O_NOFOLLOW, Self.fileMode)
            if descriptor < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == ENOENT, !forWriting { return nil }
                if code == ELOOP { throw MessageArchiveError.notARegularFile(path) }
                throw MessageArchiveError.system(operation: "open", path: path, code: code)
            }
            var locked = flock(descriptor, forWriting ? LOCK_EX : LOCK_SH) == 0
            while !locked, errno == EINTR {
                locked = flock(descriptor, forWriting ? LOCK_EX : LOCK_SH) == 0
            }
            guard locked else {
                let code = errno
                close(descriptor)
                throw MessageArchiveError.system(operation: "lock", path: path, code: code)
            }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else {
                let code = errno
                close(descriptor)
                throw MessageArchiveError.system(operation: "stat", path: path, code: code)
            }
            guard (opened.st_mode & S_IFMT) == S_IFREG else {
                close(descriptor)
                throw MessageArchiveError.notARegularFile(path)
            }
            var current = stat()
            if lstat(path, &current) == 0, current.st_dev == opened.st_dev, current.st_ino == opened.st_ino {
                return descriptor
            }
            close(descriptor)
        }
        throw MessageArchiveError.system(operation: "lock", path: path, code: EAGAIN)
    }

    /// Removes a store file once no append is running on it. False when there was none.
    private func removeFile(_ url: URL) throws -> Bool {
        let path = url.path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor >= 0 {
            while flock(descriptor, LOCK_EX) != 0, errno == EINTR {}
        }
        defer {
            if descriptor >= 0 { close(descriptor) }
        }
        if unlink(path) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw MessageArchiveError.system(operation: "remove", path: path, code: code)
    }

    private func readAll(_ descriptor: Int32, path: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw MessageArchiveError.system(operation: "read", path: path, code: errno)
            }
        }
    }

    private func writeAll(_ descriptor: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, base + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw MessageArchiveError.system(operation: "write", path: path, code: written < 0 ? errno : EIO)
                }
            }
        }
    }
}

enum MessageArchiveError: Error, CustomStringConvertible {
    case invalidChatID(String)
    case notADirectory(String)
    case notARegularFile(String)
    case createFailed(path: String, reason: String)
    case listFailed(path: String, reason: String)
    case system(operation: String, path: String, code: Int32)

    var description: String {
        switch self {
        case .invalidChatID(let chatID):
            return "Invalid chat_id '\(chatID)': only letters, digits, '_' and '-' are allowed."
        case .notADirectory(let path):
            return "\(path) is not a directory."
        case .notARegularFile(let path):
            return "\(path) is not a regular file."
        case .createFailed(let path, let reason):
            return "Could not create \(path): \(reason)"
        case .listFailed(let path, let reason):
            return "Could not list \(path): \(reason)"
        case .system(let operation, let path, let code):
            return "Could not \(operation) \(path): \(String(cString: strerror(code)))"
        }
    }
}
