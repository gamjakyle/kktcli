import CryptoKit
import Foundation

/// A chat-list row as the chat_id assignment sees it.
public struct IdentityRow: Equatable, Sendable {
    public var title: String
    /// `ChatQueryMatcher.normalize(title)`: rows with the same normalized name form a group.
    public var normalizedName: String
    /// Normalized last-message preview; nil when it could not be read.
    public var preview: String?
    /// The row's time text as shown ("오후 3:10", "어제", "2024. 10. 23."), trimmed.
    public var timeLabel: String?
    public var memberCount: Int?
    public var listIndex: Int

    public init(title: String, normalizedName: String, preview: String?, timeLabel: String? = nil, memberCount: Int? = nil, listIndex: Int) {
        self.title = title
        self.normalizedName = normalizedName
        self.preview = preview
        self.timeLabel = timeLabel
        self.memberCount = memberCount
        self.listIndex = listIndex
    }

    var features: IdentityFeatures {
        IdentityFeatures(title: title, preview: preview, timeLabel: timeLabel, memberCount: memberCount)
    }
}

/// A registry record as the assignment sees it. `displayName`, `timeLabel` and `memberCount`
/// are nil for records written before they were stored (registry schema 2 and older).
public struct IdentityRecordState: Equatable, Sendable {
    public var chatID: String
    public var normalizedName: String
    public var displayName: String?
    public var preview: String?
    public var timeLabel: String?
    public var memberCount: Int?
    public var retired: Bool

    public init(
        chatID: String,
        normalizedName: String,
        displayName: String? = nil,
        preview: String?,
        timeLabel: String? = nil,
        memberCount: Int? = nil,
        retired: Bool = false
    ) {
        self.chatID = chatID
        self.normalizedName = normalizedName
        self.displayName = displayName
        self.preview = preview
        self.timeLabel = timeLabel
        self.memberCount = memberCount
        self.retired = retired
    }

    var features: IdentityFeatures {
        IdentityFeatures(title: displayName, preview: preview, timeLabel: timeLabel, memberCount: memberCount)
    }
}

/// What tells same-name rooms apart: the exact title, the normalized preview, the row's time
/// text and the member count. nil means "not known" (not read, or not stored yet).
public struct IdentityFeatures: Hashable, Sendable {
    public var title: String?
    public var preview: String?
    public var timeLabel: String?
    public var memberCount: Int?

    public init(title: String?, preview: String?, timeLabel: String? = nil, memberCount: Int? = nil) {
        self.title = title
        self.preview = preview
        self.timeLabel = timeLabel
        self.memberCount = memberCount
    }

    /// preview + time + members; nil when none of them is known.
    var compositeKey: CompositeKey? {
        let key = CompositeKey(preview: preview.nonEmpty, timeLabel: timeLabel.nonEmpty, memberCount: memberCount)
        return key.preview == nil && key.timeLabel == nil && key.memberCount == nil ? nil : key
    }

    struct CompositeKey: Hashable {
        var preview: String?
        var timeLabel: String?
        var memberCount: Int?
    }

    /// A record (`self`) could be this row: what the record knows equals the row; a time or
    /// member count the record does not have yet does not count against it.
    func recordCouldBe(_ row: IdentityFeatures) -> Bool {
        (title == nil || title == row.title)
            && preview.nonEmpty == row.preview.nonEmpty
            && (timeLabel == nil || timeLabel == row.timeLabel)
            && (memberCount == nil || memberCount == row.memberCount)
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// How the rows and the active records of one name group were matched.
public struct IdentityGroupMatch: Equatable, Sendable {
    public struct Pair: Equatable, Sendable {
        public var row: Int
        public var record: Int
    }

    public var pairs: [Pair]
    /// Rows that get a fresh ID.
    public var leftoverRows: [Int]
    /// Records neither paired nor held.
    public var leftoverRecords: [Int]
    /// Rows identical in every feature to another unpaired row of the group (or to a set of
    /// identical records): they cannot be told apart, so none of them gets an ID of its own.
    public var unassignedRows: [Int] = []
    /// Records kept as a set for such rows (`row` is one of those rows); they stay active, but
    /// point at no row (CHAT_AMBIGUOUS), so nothing is retired and reissued on every scan.
    public var heldRecords: [Pair] = []

    /// Rows are left without a record and records without a row, and they cannot be told
    /// apart: the leftover records are retired.
    public var isAmbiguous: Bool {
        (!leftoverRows.isEmpty || !unassignedRows.isEmpty) && !leftoverRecords.isEmpty
    }
}

/// The result of assigning chat_ids to one scan of the chat list.
public struct IdentityAssignment: Equatable, Sendable {
    /// Per row: the chat_id it keeps or gets; "" for a row that cannot be told apart from
    /// another same-name row (no ID of its own).
    public var rowIDs: [String]
    /// Per row: the index of the record whose ID it kept; nil for a fresh ID or none.
    public var matchedRecords: [Int?]
    /// Records retired by this scan (indices into the records passed in).
    public var retiredRecords: [Int]
    /// Records kept as a set for identical rows (`row` is one of them; indices into the rows
    /// and records passed in).
    public var heldRecords: [IdentityGroupMatch.Pair] = []
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
/// Several rooms can share a normalized name (1:1 rooms with people of the same name, open
/// chats, titles that differ only in punctuation). Within such a group a record keeps its ID,
/// in this order, only by
/// 1. its exact title: one row and one record with that exact title;
/// 2. preview + time text + member count: that key on exactly one row and one record;
/// 3. its normalized preview alone (one row and one record);
/// 4. one-to-one elimination (exactly one unmatched record and one unmatched row left).
/// Time and preview change together when a message arrives, and the time text also changes
/// as days pass, so a changed key falls through to the next step. Nothing is ever paired by
/// list position. Rows identical in every feature get no ID of their own; records that could
/// be any of them are kept as a set and resolve to CHAT_AMBIGUOUS. Other leftover records
/// are retired and the rows get fresh IDs; a retired ID is never reused, so a stale ID fails
/// instead of reaching another room.
public enum ChatIdentityAssignment {
    /// The previews-only form (no titles, times or member counts).
    public static func matchGroup(rowPreviews: [String?], recordPreviews: [String?]) -> IdentityGroupMatch {
        matchGroup(
            rows: rowPreviews.map { IdentityFeatures(title: nil, preview: $0) },
            records: recordPreviews.map { IdentityFeatures(title: nil, preview: $0) }
        )
    }

    public static func matchGroup(rows: [IdentityFeatures], records: [IdentityFeatures]) -> IdentityGroupMatch {
        var pairs: [IdentityGroupMatch.Pair] = []
        var openRows = Array(rows.indices)
        var openRecords = Array(records.indices)

        func pairUnique<Key: Hashable>(_ key: (IdentityFeatures) -> Key?) {
            let rowsByKey = Dictionary(grouping: openRows.compactMap { index in key(rows[index]).map { ($0, index) } }, by: \.0)
            let recordsByKey = Dictionary(grouping: openRecords.compactMap { index in key(records[index]).map { ($0, index) } }, by: \.0)
            for (value, rowEntries) in rowsByKey where rowEntries.count == 1 {
                guard let recordEntries = recordsByKey[value], recordEntries.count == 1 else { continue }
                pairs.append(.init(row: rowEntries[0].1, record: recordEntries[0].1))
                openRows.removeAll { $0 == rowEntries[0].1 }
                openRecords.removeAll { $0 == recordEntries[0].1 }
            }
        }
        pairUnique { $0.title.nonEmpty }
        pairUnique { $0.compositeKey }
        pairUnique { $0.preview.nonEmpty }
        if openRows.count == 1, openRecords.count == 1 {
            pairs.append(.init(row: openRows[0], record: openRecords[0]))
            openRows = []
            openRecords = []
        }

        // Rows identical in every feature cannot be told apart: none of them gets an ID of its
        // own. Records that could be such a row and no other unpaired row are kept as a set
        // (CHAT_AMBIGUOUS) instead of being retired and reissued on every scan. A single row
        // with two or more identical such records is one of an identical set whose other rows
        // this scan did not reach.
        var unassigned: [Int] = []
        var held: [IdentityGroupMatch.Pair] = []
        let classes = Dictionary(grouping: openRows) { rows[$0] }
        for (features, members) in classes.sorted(by: { $0.value.min()! < $1.value.min()! }) {
            let others = openRows.filter { !members.contains($0) }
            let candidates = openRecords.filter { record in
                records[record].recordCouldBe(features) && !others.contains { records[record].recordCouldBe(rows[$0]) }
            }
            let identicalRecords = Set(candidates.map { records[$0] }).count == 1
            guard members.count >= 2 || (candidates.count >= 2 && identicalRecords) else { continue }
            unassigned += members
            held += candidates.map { .init(row: members.min()!, record: $0) }
            openRecords.removeAll { candidates.contains($0) }
        }
        openRows.removeAll { unassigned.contains($0) }

        pairs.sort { $0.row < $1.row }
        return IdentityGroupMatch(
            pairs: pairs,
            leftoverRows: openRows.sorted(),
            leftoverRecords: openRecords.sorted(),
            unassignedRows: unassigned.sorted(),
            heldRecords: held.sorted { $0.record < $1.record }
        )
    }

    /// Assigns an ID to every row of a scan. Records not seen in this scan stay as they are
    /// (the scan may cover only part of the list); retired records never match.
    public static func assign(rows: [IdentityRow], records: [IdentityRecordState]) -> IdentityAssignment {
        var rowIDs = Array(repeating: "", count: rows.count)
        var matched = [Int?](repeating: nil, count: rows.count)
        var retired: [Int] = []
        var held: [IdentityGroupMatch.Pair] = []
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
                rows: groupRows.map { rows[$0].features },
                records: groupRecords.map { records[$0].features }
            )
            for pair in match.pairs {
                let row = groupRows[pair.row]
                let record = groupRecords[pair.record]
                rowIDs[row] = records[record].chatID
                matched[row] = record
            }
            held += match.heldRecords.map { .init(row: groupRows[$0.row], record: groupRecords[$0.record]) }
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
        return IdentityAssignment(rowIDs: rowIDs, matchedRecords: matched, retiredRecords: retired.sorted(), heldRecords: held.sorted { $0.record < $1.record })
    }

    /// Where `chatID` points among `rows` (every row whose normalized name is the record's),
    /// given all `records` of that name, with the same matching as `assign`, so an ID a scan
    /// just gave out resolves right away. Nothing is changed.
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
        let match = matchGroup(rows: groupRows.map { rows[$0].features }, records: active.map(\.features))
        guard let position = active.firstIndex(where: { $0.chatID == chatID }) else {
            return .notFound
        }
        if let pair = match.pairs.first(where: { $0.record == position }) {
            return .row(groupRows[pair.row])
        }
        if match.heldRecords.contains(where: { $0.record == position }) {
            return .ambiguous
        }
        return match.leftoverRows.isEmpty && match.unassignedRows.isEmpty ? .notFound : .ambiguous
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
