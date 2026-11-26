import Foundation
import KktcliCore

struct ChatIdentityRecord: Codable {
    var chatID: String
    var displayName: String
    var normalizedName: String
    var lastPreviewNormalized: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var lastSeenIndex: Int?
    /// Set when a scan could not tell this room apart from another one with the same name.
    /// A retired ID never points at a room again (`CHAT_ID_STALE`). Absent in schema 1.
    var retired: Bool?
    var retiredAt: Date?
    /// The row's time text and member count when last seen (schema 3; absent before).
    var lastTimeLabel: String?
    var memberCount: Int?

    var isRetired: Bool {
        retired ?? false
    }
}

private struct ChatIdentityRegistryDocument: Codable {
    var schemaVersion: Int
    var records: [ChatIdentityRecord]
    var updatedAt: Date
}

/// `~/.kktcli/chat-registry.json`: synthetic chat_ids (see `ChatIdentityAssignment`).
///
/// Schema 2 added `retired`, schema 3 `lastTimeLabel` and `memberCount`. Older files are read
/// as they are (records without those fields; nothing retired) and written back as schema 3
/// on the next change.
final class ChatIdentityRegistryStore: @unchecked Sendable {
    static let shared = ChatIdentityRegistryStore()
    static let schemaVersion = 3
    static let readableSchemaVersions: Set<Int> = [1, 2, 3]

    let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedDocument: ChatIdentityRegistryDocument?

    init(fileURL: URL = ChatIdentityRegistryStore.defaultURL()) {
        self.fileURL = fileURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Assigns an ID to every row of a chat-list scan (`ChatIdentityAssignment.assign`):
    /// matched records are updated, records held for identical rows refreshed (they keep
    /// their IDs but point at no row), ambiguous leftovers retired, new rows recorded. A row
    /// that cannot be told apart from another same-name row gets "" (no ID).
    func assignChatIDs(for discoveries: [ChatListDiscovery]) -> [String] {
        var document = loadDocument()
        let now = Date()
        let rows = discoveries.map(Self.identityRow)
        let result = ChatIdentityAssignment.assign(rows: rows, records: document.records.map(Self.identityState))

        for (rowIndex, recordIndex) in result.matchedRecords.enumerated() {
            guard let recordIndex else { continue }
            document.records[recordIndex] = updatedRecord(document.records[recordIndex], with: discoveries[rowIndex], now: now)
        }
        for held in result.heldRecords {
            document.records[held.record] = updatedRecord(document.records[held.record], with: discoveries[held.row], now: now)
        }
        for recordIndex in result.retiredRecords {
            document.records[recordIndex].retired = true
            document.records[recordIndex].retiredAt = now
        }
        for (rowIndex, recordIndex) in result.matchedRecords.enumerated() where recordIndex == nil && !result.rowIDs[rowIndex].isEmpty {
            document.records.append(ChatIdentityRecord(
                chatID: result.rowIDs[rowIndex],
                displayName: discoveries[rowIndex].title,
                normalizedName: rows[rowIndex].normalizedName,
                lastPreviewNormalized: rows[rowIndex].preview,
                firstSeenAt: now,
                lastSeenAt: now,
                lastSeenIndex: discoveries[rowIndex].listIndex,
                lastTimeLabel: rows[rowIndex].timeLabel,
                memberCount: rows[rowIndex].memberCount
            ))
        }

        document.schemaVersion = Self.schemaVersion
        document.updatedAt = now
        cachedDocument = document
        try? persist(document)
        return result.rowIDs
    }

    /// Where `chatID` points among `discoveries` (every row with that name). Changes nothing.
    func resolution(of chatID: String, among discoveries: [ChatListDiscovery]) -> IdentityResolution {
        let document = loadDocument()
        guard let record = document.records.first(where: { $0.chatID == chatID }) else {
            return .notFound
        }
        let group = document.records.filter { $0.normalizedName == record.normalizedName }
        return ChatIdentityAssignment.resolve(
            chatID: chatID,
            rows: discoveries.map(Self.identityRow),
            records: group.map(Self.identityState)
        )
    }

    /// Updates the record of `chatID` with the row it was located at. Never re-runs the
    /// assignment, so no other record changes.
    func refresh(chatID: String, with discovery: ChatListDiscovery) {
        var document = loadDocument()
        guard let index = document.records.firstIndex(where: { $0.chatID == chatID }), !document.records[index].isRetired else {
            return
        }
        let now = Date()
        document.records[index] = updatedRecord(document.records[index], with: discovery, now: now)
        document.schemaVersion = Self.schemaVersion
        document.updatedAt = now
        cachedDocument = document
        try? persist(document)
    }

    static func identityRow(_ discovery: ChatListDiscovery) -> IdentityRow {
        IdentityRow(
            title: discovery.title,
            normalizedName: ChatTextNormalizer.normalize(discovery.title),
            preview: normalizePreview(discovery.lastMessage),
            timeLabel: normalizeTime(discovery.timeLabel),
            memberCount: discovery.memberCount,
            listIndex: discovery.listIndex
        )
    }

    static func identityState(_ record: ChatIdentityRecord) -> IdentityRecordState {
        IdentityRecordState(
            chatID: record.chatID,
            normalizedName: record.normalizedName,
            displayName: record.displayName,
            preview: record.lastPreviewNormalized,
            timeLabel: record.lastTimeLabel,
            memberCount: record.memberCount,
            retired: record.isRetired
        )
    }

    /// Every chat_id that is not retired.
    func activeChatIDs() -> Set<String> {
        Set(loadDocument().records.filter { !$0.isRetired }.map(\.chatID))
    }

    func record(for chatID: String) -> ChatIdentityRecord? {
        let document = loadDocument()
        return document.records.first(where: { $0.chatID == chatID })
    }

    /// Records of that name that are not retired.
    func records(withNormalizedName normalizedName: String) -> [ChatIdentityRecord] {
        loadDocument().records.filter { $0.normalizedName == normalizedName && !$0.isRetired }
    }

    /// Rows earlier chat-list scans have seen (highest last-seen index + 1), if any.
    func knownRowCount() -> Int? {
        loadDocument().records.compactMap(\.lastSeenIndex).max().map { $0 + 1 }
    }

    private func updatedRecord(_ record: ChatIdentityRecord, with discovery: ChatListDiscovery, now: Date) -> ChatIdentityRecord {
        var updated = record
        updated.displayName = discovery.title
        updated.lastSeenAt = now
        updated.lastSeenIndex = discovery.listIndex
        if let preview = Self.normalizePreview(discovery.lastMessage) {
            updated.lastPreviewNormalized = preview
        }
        if let time = Self.normalizeTime(discovery.timeLabel) {
            updated.lastTimeLabel = time
        }
        if let members = discovery.memberCount {
            updated.memberCount = members
        }
        return updated
    }

    static func normalizeTime(_ time: String?) -> String? {
        guard let time = time?.trimmingCharacters(in: .whitespacesAndNewlines), !time.isEmpty else { return nil }
        return time
    }

    static func normalizePreview(_ preview: String?) -> String? {
        guard let preview else { return nil }
        let normalized = ChatTextNormalizer.normalize(preview)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    private func loadDocument(forceReload: Bool = false) -> ChatIdentityRegistryDocument {
        if !forceReload, let cachedDocument {
            return cachedDocument
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let document = emptyDocument()
            cachedDocument = document
            return document
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let document = try decoder.decode(ChatIdentityRegistryDocument.self, from: data)
            guard Self.readableSchemaVersions.contains(document.schemaVersion) else {
                let reset = emptyDocument()
                cachedDocument = reset
                return reset
            }
            cachedDocument = document
            return document
        } catch {
            let reset = emptyDocument()
            cachedDocument = reset
            return reset
        }
    }

    private func persist(_ document: ChatIdentityRegistryDocument) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }

    private func emptyDocument() -> ChatIdentityRegistryDocument {
        ChatIdentityRegistryDocument(
            schemaVersion: Self.schemaVersion,
            records: [],
            updatedAt: Date()
        )
    }

    private static func defaultURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".kktcli", isDirectory: true)
            .appendingPathComponent("chat-registry.json")
    }
}
