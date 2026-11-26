import Foundation

public struct ChatIdentityRecord: Codable, Equatable, Sendable {
    public var chatID: String
    public var displayName: String
    public var normalizedName: String
    public var lastPreviewNormalized: String?
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var lastSeenIndex: Int?
    /// Set when a scan could not tell this room apart from another one with the same name.
    /// A retired ID never points at a room again (`CHAT_ID_STALE`). Absent in schema 1.
    public var retired: Bool?
    public var retiredAt: Date?
    /// The row's time text and member count when last seen (schema 3; absent before).
    public var lastTimeLabel: String?
    public var memberCount: Int?

    public init(
        chatID: String,
        displayName: String,
        normalizedName: String,
        lastPreviewNormalized: String?,
        firstSeenAt: Date,
        lastSeenAt: Date,
        lastSeenIndex: Int?,
        retired: Bool? = nil,
        retiredAt: Date? = nil,
        lastTimeLabel: String? = nil,
        memberCount: Int? = nil
    ) {
        self.chatID = chatID
        self.displayName = displayName
        self.normalizedName = normalizedName
        self.lastPreviewNormalized = lastPreviewNormalized
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.lastSeenIndex = lastSeenIndex
        self.retired = retired
        self.retiredAt = retiredAt
        self.lastTimeLabel = lastTimeLabel
        self.memberCount = memberCount
    }

    public var isRetired: Bool {
        retired ?? false
    }

    public var identityState: IdentityRecordState {
        IdentityRecordState(
            chatID: chatID,
            normalizedName: normalizedName,
            displayName: displayName,
            preview: lastPreviewNormalized,
            timeLabel: lastTimeLabel,
            memberCount: memberCount,
            retired: isRetired
        )
    }

    /// The record after its room was seen as `row`: what the row shows replaces what was
    /// known; a preview, time or member count the row did not show keeps the old value.
    public func seen(as row: IdentityRow, at now: Date) -> ChatIdentityRecord {
        var updated = self
        updated.displayName = row.title
        updated.lastSeenAt = now
        updated.lastSeenIndex = row.listIndex
        if let preview = row.preview { updated.lastPreviewNormalized = preview }
        if let time = row.timeLabel { updated.lastTimeLabel = time }
        if let members = row.memberCount { updated.memberCount = members }
        return updated
    }
}

/// `~/.kktcli/chat-registry.json`. Schema 2 added `retired`, schema 3 `lastTimeLabel` and
/// `memberCount`; older files are read as they are and written back as schema 3.
public struct ChatIdentityRegistryDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 3
    public static let readableSchemaVersions: Set<Int> = [1, 2, 3]

    public var schemaVersion: Int
    public var records: [ChatIdentityRecord]
    public var updatedAt: Date

    public init(schemaVersion: Int = ChatIdentityRegistryDocument.schemaVersion, records: [ChatIdentityRecord] = [], updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.records = records
        self.updatedAt = updatedAt
    }

    /// The scan's assignment applied to this document (the fresh copy read under the lock):
    /// matched and held records take what their row shows, retired ones are marked, rows with
    /// a new ID become records. Records of other rooms are left exactly as they are.
    public func applying(_ result: IdentityAssignment, rows: [IdentityRow], now: Date) -> ChatIdentityRegistryDocument {
        var document = self
        for (rowIndex, recordIndex) in result.matchedRecords.enumerated() {
            guard let recordIndex else { continue }
            document.records[recordIndex] = document.records[recordIndex].seen(as: rows[rowIndex], at: now)
        }
        for held in result.heldRecords {
            document.records[held.record] = document.records[held.record].seen(as: rows[held.row], at: now)
        }
        for recordIndex in result.retiredRecords {
            document.records[recordIndex].retired = true
            document.records[recordIndex].retiredAt = now
        }
        for (rowIndex, recordIndex) in result.matchedRecords.enumerated() where recordIndex == nil && !result.rowIDs[rowIndex].isEmpty {
            let row = rows[rowIndex]
            document.records.append(ChatIdentityRecord(
                chatID: result.rowIDs[rowIndex],
                displayName: row.title,
                normalizedName: row.normalizedName,
                lastPreviewNormalized: row.preview,
                firstSeenAt: now,
                lastSeenAt: now,
                lastSeenIndex: row.listIndex,
                lastTimeLabel: row.timeLabel,
                memberCount: row.memberCount
            ))
        }
        document.schemaVersion = Self.schemaVersion
        document.updatedAt = now
        return document
    }

    /// One record refreshed with the row it was located at (a lookup never re-runs the
    /// assignment, so no other record changes). Retired or unknown IDs change nothing.
    public func refreshing(chatID: String, with row: IdentityRow, now: Date) -> ChatIdentityRegistryDocument {
        guard let index = records.firstIndex(where: { $0.chatID == chatID }), !records[index].isRetired else {
            return self
        }
        var document = self
        document.records[index] = records[index].seen(as: row, at: now)
        document.schemaVersion = Self.schemaVersion
        document.updatedAt = now
        return document
    }

    /// Whether `other` says anything this document does not: only `lastSeenAt` and `updatedAt`
    /// differ otherwise. A poll that changed nothing else is not written.
    public func differsBeyondTimestamps(from other: ChatIdentityRegistryDocument) -> Bool {
        guard schemaVersion == other.schemaVersion, records.count == other.records.count else { return true }
        for (mine, theirs) in zip(records, other.records) {
            var comparable = mine
            comparable.lastSeenAt = theirs.lastSeenAt
            if comparable != theirs { return true }
        }
        return false
    }
}

/// The registry file shared by concurrent kktcli processes (`SharedFile`): every change re-reads
/// the file under an exclusive lock and applies to that fresh copy; it is written only when
/// something besides timestamps changed. The in-process copy is only a read cache, checked
/// against the file's inode, size and modification time.
public final class ChatIdentityRegistryFile: @unchecked Sendable {
    public let fileURL: URL
    public let lockURL: URL

    private let lock = NSLock()
    private var cache: (document: ChatIdentityRegistryDocument, stamp: SharedFile.Stamp?)?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.lockURL = fileURL.deletingLastPathComponent().appendingPathComponent("chat-registry.lock")
    }

    /// The current document (cached while the file is unchanged).
    public func read() -> ChatIdentityRegistryDocument {
        lock.lock()
        defer { lock.unlock() }
        let stamp = SharedFile.stamp(fileURL)
        if let cache, cache.stamp == stamp {
            return cache.document
        }
        let loaded = SharedFile.withLock(lockURL, exclusive: false) { load() }
        cache = (loaded.document, loaded.stamp)
        return loaded.document
    }

    /// Applies `change` to the document freshly read under the exclusive lock and writes it
    /// back atomically (0600) when it changed more than timestamps. Returns what `change`
    /// returned. A file of a newer schema is never overwritten.
    @discardableResult
    public func update<T>(_ change: (inout ChatIdentityRegistryDocument) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return SharedFile.withLock(lockURL, exclusive: true) {
            var loaded = load()
            if loaded.unreadable, FileManager.default.fileExists(atPath: fileURL.path) {
                // Keep a file that cannot be decoded instead of overwriting it.
                let aside = fileURL.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: fileURL, to: aside)
                loaded.writable = true
            }
            let before = loaded.document
            var document = before
            let value = change(&document)
            guard loaded.writable else {
                // A newer kktcli's file: the change is used for this run only.
                cache = nil
                return value
            }
            guard loaded.unreadable || document.differsBeyondTimestamps(from: before) else {
                // Nothing but timestamps changed (a poll that saw the same list): not written.
                cache = (before, loaded.stamp)
                return value
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(document), (try? SharedFile.writeAtomically(data, to: fileURL)) != nil {
                cache = (document, SharedFile.stamp(fileURL))
            } else {
                cache = nil
            }
            return value
        }
    }

    private struct Loaded {
        var document: ChatIdentityRegistryDocument
        var stamp: SharedFile.Stamp?
        /// False for a file of a newer schema: kktcli must not drop what it does not know.
        var writable = true
        /// The file exists but could not be decoded.
        var unreadable = false
    }

    private func load() -> Loaded {
        let stamp = SharedFile.stamp(fileURL)
        guard stamp != nil, let data = try? Data(contentsOf: fileURL) else {
            return Loaded(document: ChatIdentityRegistryDocument(), stamp: stamp)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(ChatIdentityRegistryDocument.self, from: data) else {
            return Loaded(document: ChatIdentityRegistryDocument(), stamp: stamp, unreadable: true)
        }
        guard ChatIdentityRegistryDocument.readableSchemaVersions.contains(document.schemaVersion) else {
            // Newer: leave it alone. Older than any known schema: treat as unreadable.
            let newer = document.schemaVersion > ChatIdentityRegistryDocument.schemaVersion
            return Loaded(document: ChatIdentityRegistryDocument(), stamp: stamp, writable: !newer, unreadable: !newer)
        }
        return Loaded(document: document, stamp: stamp)
    }
}
