import CryptoKit
import Foundation

/// A chat-list row as the chat_id assignment sees it.
public struct IdentityRow: Equatable, Sendable {
    public var title: String
    /// `ChatQueryMatcher.normalize(title)`: rows with the same normalized name form a group.
    public var normalizedName: String
    /// Normalized last-message preview; nil when it could not be read.
    public var preview: String?
    public var listIndex: Int

    public init(title: String, normalizedName: String, preview: String?, listIndex: Int) {
        self.title = title
        self.normalizedName = normalizedName
        self.preview = preview
        self.listIndex = listIndex
    }
}

/// A registry record as the assignment sees it.
public struct IdentityRecordState: Equatable, Sendable {
    public var chatID: String
    public var normalizedName: String
    public var preview: String?
    public var retired: Bool

    public init(chatID: String, normalizedName: String, preview: String?, retired: Bool = false) {
        self.chatID = chatID
        self.normalizedName = normalizedName
        self.preview = preview
        self.retired = retired
    }
}

/// How the rows and the active records of one name group were matched.
public struct IdentityGroupMatch: Equatable, Sendable {
    public struct Pair: Equatable, Sendable {
        public var row: Int
        public var record: Int
    }

    public var pairs: [Pair]
    public var leftoverRows: [Int]
    public var leftoverRecords: [Int]

    /// Rows and records are both left over and cannot be told apart.
    public var isAmbiguous: Bool {
        !leftoverRows.isEmpty && !leftoverRecords.isEmpty
    }
}

/// The result of assigning chat_ids to one scan of the chat list.
public struct IdentityAssignment: Equatable, Sendable {
    /// Per row: the chat_id it keeps or gets.
    public var rowIDs: [String]
    /// Per row: the index of the record whose ID it kept; nil for a fresh ID.
    public var matchedRecords: [Int?]
    /// Records retired by this scan (indices into the records passed in).
    public var retiredRecords: [Int]
}

/// What a stored chat_id points at in the current chat list.
public enum IdentityResolution: Equatable, Sendable {
    /// Index of the row (into the rows passed in).
    case row(Int)
    /// The ID was retired earlier; it never points at a room again.
    case stale
    /// Same-name rows and records are left over and cannot be told apart.
    case ambiguous
    /// No row with that name is in the list, or its room is not among them.
    case notFound
}

/// Synthetic chat_ids for chat-list rows (KakaoTalk exposes no room id).
///
/// Several rooms can share a name (1:1 rooms with people of the same name, open chats).
/// Within such a name group a record keeps its ID only by
/// - an exact normalized preview match (one row and one record with that preview), or
/// - one-to-one elimination (exactly one unmatched record and one unmatched row left).
/// Nothing is ever paired by list position. When rows and records are left over otherwise,
/// the leftover records are retired and the rows get fresh IDs; a retired ID is never
/// reused, so a stale ID fails instead of reaching another room.
public enum ChatIdentityAssignment {
    public static func matchGroup(rowPreviews: [String?], recordPreviews: [String?]) -> IdentityGroupMatch {
        var rowsByPreview: [String: [Int]] = [:]
        for (index, preview) in rowPreviews.enumerated() {
            if let preview, !preview.isEmpty { rowsByPreview[preview, default: []].append(index) }
        }
        var recordsByPreview: [String: [Int]] = [:]
        for (index, preview) in recordPreviews.enumerated() {
            if let preview, !preview.isEmpty { recordsByPreview[preview, default: []].append(index) }
        }

        var pairs: [IdentityGroupMatch.Pair] = []
        for (preview, rows) in rowsByPreview where rows.count == 1 {
            if let records = recordsByPreview[preview], records.count == 1 {
                pairs.append(.init(row: rows[0], record: records[0]))
            }
        }
        var leftoverRows = rowPreviews.indices.filter { row in !pairs.contains { $0.row == row } }
        var leftoverRecords = recordPreviews.indices.filter { record in !pairs.contains { $0.record == record } }
        if leftoverRows.count == 1, leftoverRecords.count == 1 {
            pairs.append(.init(row: leftoverRows[0], record: leftoverRecords[0]))
            leftoverRows = []
            leftoverRecords = []
        }
        pairs.sort { $0.row < $1.row }
        return IdentityGroupMatch(pairs: pairs, leftoverRows: leftoverRows, leftoverRecords: leftoverRecords)
    }

    /// Assigns an ID to every row of a scan. Records not seen in this scan stay as they are
    /// (the scan may cover only part of the list); retired records never match.
    public static func assign(rows: [IdentityRow], records: [IdentityRecordState]) -> IdentityAssignment {
        var rowIDs = Array(repeating: "", count: rows.count)
        var matched = [Int?](repeating: nil, count: rows.count)
        var retired: [Int] = []
        var taken = Set(records.map(\.chatID))

        let groups = Dictionary(grouping: rows.indices) { rows[$0].normalizedName }
        let orderedNames = groups.keys.sorted { lhs, rhs in
            let left = groups[lhs]!.map { rows[$0].listIndex }.min() ?? 0
            let right = groups[rhs]!.map { rows[$0].listIndex }.min() ?? 0
            return left == right ? lhs < rhs : left < right
        }
        for name in orderedNames {
            let groupRows = groups[name]!.sorted { rows[$0].listIndex < rows[$1].listIndex }
            let groupRecords = records.indices.filter { records[$0].normalizedName == name && !records[$0].retired }
            let match = matchGroup(
                rowPreviews: groupRows.map { rows[$0].preview },
                recordPreviews: groupRecords.map { records[$0].preview }
            )
            for pair in match.pairs {
                let row = groupRows[pair.row]
                let record = groupRecords[pair.record]
                rowIDs[row] = records[record].chatID
                matched[row] = record
            }
            if match.isAmbiguous {
                retired += match.leftoverRecords.map { groupRecords[$0] }
            }
            for leftover in match.leftoverRows {
                let row = groupRows[leftover]
                let id = freshID(normalizedName: name, taken: taken)
                taken.insert(id)
                rowIDs[row] = id
            }
        }
        return IdentityAssignment(rowIDs: rowIDs, matchedRecords: matched, retiredRecords: retired.sorted())
    }

    /// Where `chatID` points among `rows` (every row whose normalized name is the record's),
    /// given all `records` of that name. Nothing is changed.
    public static func resolve(chatID: String, rows: [IdentityRow], records: [IdentityRecordState]) -> IdentityResolution {
        guard let target = records.first(where: { $0.chatID == chatID }) else {
            return .notFound
        }
        if target.retired {
            return .stale
        }
        let active = records.filter { !$0.retired && $0.normalizedName == target.normalizedName }
        let groupRows = rows.indices.filter { rows[$0].normalizedName == target.normalizedName }
        guard !groupRows.isEmpty else {
            return .notFound
        }
        let match = matchGroup(
            rowPreviews: groupRows.map { rows[$0].preview },
            recordPreviews: active.map(\.preview)
        )
        guard let position = active.firstIndex(where: { $0.chatID == chatID }) else {
            return .notFound
        }
        if let pair = match.pairs.first(where: { $0.record == position }) {
            return .row(groupRows[pair.row])
        }
        return match.leftoverRows.isEmpty ? .notFound : .ambiguous
    }

    /// `chat_<first 6 bytes of SHA-256(normalized name)>`, then `_2`, `_3`, … skipping every
    /// ID in `taken` (retired ones included).
    public static func freshID(normalizedName: String, taken: Set<String>) -> String {
        let digest = SHA256.hash(data: Data(normalizedName.utf8))
        let base = "chat_" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        if !taken.contains(base) {
            return base
        }
        var suffix = 2
        while taken.contains("\(base)_\(suffix)") {
            suffix += 1
        }
        return "\(base)_\(suffix)"
    }
}
