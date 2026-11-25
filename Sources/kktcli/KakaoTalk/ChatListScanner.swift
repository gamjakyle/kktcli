import ApplicationServices.HIServices
import Foundation
import KktcliCore

enum ChatTextNormalizer {
    static func normalize(_ text: String) -> String {
        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(lowered.unicodeScalars.count)

        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            scalars.append(scalar)
        }

        return String(scalars)
    }

    static func isTimeLikeValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        if parts.count == 2,
           parts[0].count <= 2, parts[1].count == 2,
           parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber)
        {
            return true
        }

        if trimmed.hasSuffix("일") || trimmed == "어제" || trimmed == "그저께" {
            return true
        }

        return false
    }

    static func isUnreadCountLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0.isNumber || $0 == "+" || $0 == "," }
    }
}

struct ChatListDiscovery {
    let title: String
    let lastMessage: String?
    let listIndex: Int
    var unread: UnreadBadge = .none
}

struct ChatListEntry: Codable, Equatable {
    let title: String
    let chatID: String?
    let lastMessage: String?
    /// True when the row shows an unread badge (or something that may be one).
    /// `kktcli read` refuses to open such rooms unless `--allow-unread` is given.
    var hasUnread: Bool = false
    var unreadCount: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case chatID = "chat_id"
        case lastMessage = "last_message"
        case hasUnread = "has_unread"
        case unreadCount = "unread_count"
    }
}

struct ChatListSnapshotItem {
    let element: UIElement
    let discovery: ChatListDiscovery
}

/// Reads chat-list rows by element identifier (see `ChatRowAnalyzer`).
///
/// Earlier versions cached a per-row "title path" in the AX path cache. Every row shares the
/// same root fingerprint ("AXRow||8x1"), so a path learned on an unread row pointed every row
/// at the `_NS:138` badge and unread rooms were listed as "안읽음 N". Rows are now read
/// directly with batched attribute reads and the title always comes from `_NS:40`.
struct ChatListScanner {
    static let rowFlattenDepth = 6
    static let rowFlattenBudget = 80

    func scan(in window: UIElement, limit: Int, trace: ((String) -> Void)? = nil) -> [ChatListSnapshotItem] {
        guard let container = resolveChatListContainer(in: window, trace: trace) else {
            trace?("chats: chat list container unavailable")
            return []
        }

        let rows = collectChatItems(from: container, limit: limit)
        guard !rows.isEmpty else {
            trace?("chats: chat list container found but no rows/items resolved")
            return []
        }

        var snapshots: [ChatListSnapshotItem] = []
        snapshots.reserveCapacity(rows.count)

        for (index, row) in rows.enumerated() {
            let summary = Self.summarize(row: row.axElement)
            if summary.titleSource != .titleLabel {
                trace?("chats: row[\(index)] title source=\(summary.titleSource.rawValue)")
            }
            let discovery = ChatListDiscovery(
                title: summary.title ?? "(Unknown Chat)",
                lastMessage: summary.preview,
                listIndex: index,
                unread: summary.unread
            )
            snapshots.append(ChatListSnapshotItem(element: row, discovery: discovery))
        }

        trace?("chats: resolved rows=\(snapshots.count)")
        return snapshots
    }

    static func summarize(row: AXUIElement) -> ChatRowSummary {
        ChatRowAnalyzer.summarize(AXNodeReader.flatten(row, maxDepth: rowFlattenDepth, budget: rowFlattenBudget))
    }

    func warmup(in window: UIElement, trace: ((String) -> Void)? = nil) -> [AXPathSlot] {
        // Row titles and previews are read by identifier now, so only the container path is cached.
        guard resolveChatListContainer(in: window, trace: trace) != nil else {
            return []
        }
        return [.chatListContainer]
    }

    private func resolveChatListContainer(in window: UIElement, trace: ((String) -> Void)? = nil) -> UIElement? {
        if let cached = AXPathCacheStore.shared.resolve(
            slot: .chatListContainer,
            root: window,
            validate: isLikelyChatListContainer,
            trace: trace
        ) {
            trace?("chats: container fast path hit")
            return cached
        }

        trace?("chats: container fast path miss, scanning")
        let tables = window.findAll(role: kAXTableRole, limit: 1, maxNodes: 220)
        let outlines = window.findAll(role: kAXOutlineRole, limit: 1, maxNodes: 220)
        let lists = window.findAll(role: kAXListRole, limit: 1, maxNodes: 220)
        let container = tables.first ?? outlines.first ?? lists.first

        if let container {
            AXPathCacheStore.shared.remember(slot: .chatListContainer, root: window, element: container, trace: trace)
        }

        return container
    }

    private func isLikelyChatListContainer(_ element: UIElement) -> Bool {
        switch element.role {
        case kAXTableRole, kAXOutlineRole, kAXListRole:
            return true
        default:
            return false
        }
    }

    private func collectChatItems(from container: UIElement, limit: Int) -> [UIElement] {
        let role = container.role ?? ""

        if role == kAXListRole {
            let children = Array(container.children.prefix(limit))
            return deduplicateElements(children)
        }

        let directRows = container.children.filter { $0.role == kAXRowRole }
        if !directRows.isEmpty {
            return Array(deduplicateElements(directRows).prefix(limit))
        }

        let discoveredRows = container.findAll(role: kAXRowRole, limit: limit, maxNodes: max(80, limit * 8))
        return deduplicateElements(discoveredRows)
    }

    private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(elements.count)

        for element in elements {
            if unique.contains(where: { existing in
                CFEqual(existing.axElement, element.axElement)
            }) {
                continue
            }
            unique.append(element)
        }

        return unique
    }
}
