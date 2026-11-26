import Foundation
import KktcliCore

/// `~/.kktcli/chat-registry.json`: synthetic chat_ids (see `ChatIdentityAssignment`), shared by
/// concurrent kktcli processes through `ChatIdentityRegistryFile`. Every change re-reads the
/// file under an exclusive lock on `~/.kktcli/chat-registry.lock` and applies to that fresh
/// copy, so a long-running `watch`, MCP server or batch read never writes back a stale copy
/// over what another process recorded. A scan that changed nothing but timestamps writes
/// nothing.
final class ChatIdentityRegistryStore: @unchecked Sendable {
    static let shared = ChatIdentityRegistryStore()
    static let schemaVersion = ChatIdentityRegistryDocument.schemaVersion

    let file: ChatIdentityRegistryFile

    var fileURL: URL {
        file.fileURL
    }

    init(fileURL: URL = ChatIdentityRegistryStore.defaultURL()) {
        self.file = ChatIdentityRegistryFile(fileURL: fileURL)
    }

    /// Assigns an ID to every row of a chat-list scan (`ChatIdentityAssignment.assign`) against
    /// the registry as it is on disk now: matched records are updated, records held for
    /// identical rows refreshed (they keep their IDs but point at no row), ambiguous leftovers
    /// retired, new rows recorded. A row that cannot be told apart from another same-name row
    /// gets "" (no ID).
    func assignChatIDs(for discoveries: [ChatListDiscovery]) -> [String] {
        let rows = discoveries.map(Self.identityRow)
        return file.update { document in
            let result = ChatIdentityAssignment.assign(rows: rows, records: document.records.map(\.identityState))
            document = document.applying(result, rows: rows, now: Date())
            return result.rowIDs
        }
    }

    /// Where `chatID` points among `discoveries` (every row with that name). Changes nothing.
    func resolution(of chatID: String, among discoveries: [ChatListDiscovery]) -> IdentityResolution {
        let document = file.read()
        guard let record = document.records.first(where: { $0.chatID == chatID }) else {
            return .notFound
        }
        let group = document.records.filter { $0.normalizedName == record.normalizedName }
        return ChatIdentityAssignment.resolve(
            chatID: chatID,
            rows: discoveries.map(Self.identityRow),
            records: group.map(\.identityState)
        )
    }

    /// Updates the record of `chatID` with the row it was located at. Never re-runs the
    /// assignment, so no other record changes.
    func refresh(chatID: String, with discovery: ChatListDiscovery) {
        let row = Self.identityRow(discovery)
        file.update { document in
            document = document.refreshing(chatID: chatID, with: row, now: Date())
        }
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

    /// Every chat_id that is not retired.
    func activeChatIDs() -> Set<String> {
        Set(file.read().records.filter { !$0.isRetired }.map(\.chatID))
    }

    func record(for chatID: String) -> ChatIdentityRecord? {
        file.read().records.first(where: { $0.chatID == chatID })
    }

    /// Records of that name that are not retired.
    func records(withNormalizedName normalizedName: String) -> [ChatIdentityRecord] {
        file.read().records.filter { $0.normalizedName == normalizedName && !$0.isRetired }
    }

    /// Rows earlier chat-list scans have seen (highest last-seen index + 1), if any.
    func knownRowCount() -> Int? {
        file.read().records.compactMap(\.lastSeenIndex).max().map { $0 + 1 }
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

    private static func defaultURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".kktcli", isDirectory: true)
            .appendingPathComponent("chat-registry.json")
    }
}
