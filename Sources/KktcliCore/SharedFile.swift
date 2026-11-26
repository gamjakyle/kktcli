import Darwin
import Foundation

/// A small file several kktcli processes read and write at the same time (a long `watch`, an
/// MCP server, a `read` started next to them). The only file I/O in this module.
///
/// Every change takes an exclusive `flock` on a sibling `.lock` file, re-reads the file, applies
/// the change to that fresh copy and replaces the file atomically (a 0600 temp file in the same
/// directory, then rename), so no process writes back a stale copy over another one's change.
/// Readers take a shared lock. Locks are per open file description, so they also order threads
/// of one process that each open the lock file.
public enum SharedFile {
    /// Identity and version of the file on disk: a rename gives a new inode, a rewrite a new
    /// size or modification time. Used to invalidate in-process read caches.
    public struct Stamp: Equatable, Sendable {
        public var device: Int64
        public var inode: UInt64
        public var size: Int64
        public var modifiedSeconds: Int
        public var modifiedNanoseconds: Int
    }

    public static func stamp(_ url: URL) -> Stamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Stamp(
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec)
        )
    }

    /// Runs `body` holding an exclusive (or shared) `flock` on `lockURL`, created 0600 in a 0700
    /// directory if missing. If the lock file cannot be opened, `body` runs without it.
    public static func withLock<T>(_ lockURL: URL, exclusive: Bool, _ body: () throws -> T) rethrows -> T {
        let directory = lockURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return try body()
        }
        defer { close(descriptor) }
        while flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) != 0 {
            guard errno == EINTR else { return try body() }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Writes `data` to a new temp file (mode `mode`) next to `url`, flushes it and renames it
    /// over `url`; a reader sees the old file or the new one, never a partial one.
    public static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temp.path])
        }
        var failed = false
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failed = true
                    return
                }
                offset += written
            }
        }
        if !failed {
            fchmod(descriptor, mode)
            failed = fsync(descriptor) != 0
        }
        close(descriptor)
        guard !failed, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
