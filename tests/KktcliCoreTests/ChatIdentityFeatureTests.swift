import Testing
@testable import KktcliCore

/// Same-name rooms that previews alone cannot tell apart (placeholder titles; the live cases
/// were a pair of team chats whose titles differ only in punctuation, and a pair of rooms with
/// the same name and empty previews).
@Suite("chat_id assignment with titles, times and member counts")
struct ChatIdentityFeatureTests {
    /// What the registry does with an assignment: matched and held records take the row's
    /// features, retired ones are marked, new IDs become records.
    private func apply(_ result: IdentityAssignment, rows: [IdentityRow], records: [IdentityRecordState]) -> [IdentityRecordState] {
        var updated = records
        func refresh(_ index: Int, from row: IdentityRow) {
            updated[index].displayName = row.title
            if let preview = row.preview { updated[index].preview = preview }
            if let time = row.timeLabel { updated[index].timeLabel = time }
            if let members = row.memberCount { updated[index].memberCount = members }
        }
        for (rowIndex, recordIndex) in result.matchedRecords.enumerated() {
            if let recordIndex { refresh(recordIndex, from: rows[rowIndex]) }
        }
        for held in result.heldRecords {
            refresh(held.record, from: rows[held.row])
        }
        for index in result.retiredRecords {
            updated[index].retired = true
        }
        for (rowIndex, recordIndex) in result.matchedRecords.enumerated() where recordIndex == nil && !result.rowIDs[rowIndex].isEmpty {
            let row = rows[rowIndex]
            updated.append(IdentityRecordState(
                chatID: result.rowIDs[rowIndex],
                normalizedName: row.normalizedName,
                displayName: row.title,
                preview: row.preview,
                timeLabel: row.timeLabel,
                memberCount: row.memberCount
            ))
        }
        return updated
    }

    // Group A: titles that differ only in punctuation, the same preview, different times and
    // member counts.
    private let teamName = "팀채팅테스트방"
    private func teamRows(offset: Int = 0) -> [IdentityRow] {
        [
            IdentityRow(title: "팀채팅, 테스트방", normalizedName: teamName, preview: "같은첫메시지", timeLabel: "2025. 12. 30.", memberCount: 2, listIndex: 3 + offset),
            IdentityRow(title: "팀채팅, 테스트방!", normalizedName: teamName, preview: "같은첫메시지", timeLabel: "2024. 10. 23.", memberCount: 3, listIndex: 9 + offset),
        ]
    }

    @Test("Group A: the exact title pairs records left by the old churn; nothing is retired")
    func punctuationTitlesWithOldRecords() {
        // Records as the previous version left them: fresh IDs with titles, no time or members.
        let records = [
            IdentityRecordState(chatID: "chat_t_5", normalizedName: teamName, displayName: "팀채팅, 테스트방", preview: "같은첫메시지"),
            IdentityRecordState(chatID: "chat_t_6", normalizedName: teamName, displayName: "팀채팅, 테스트방!", preview: "같은첫메시지"),
            IdentityRecordState(chatID: "chat_t_4", normalizedName: teamName, displayName: "팀채팅, 테스트방", preview: "같은첫메시지", retired: true),
        ]
        let rows = teamRows()
        let result = ChatIdentityAssignment.assign(rows: rows, records: records)
        #expect(result.rowIDs == ["chat_t_5", "chat_t_6"])
        #expect(result.retiredRecords.isEmpty)
        // Stable: the next scan (rooms moved) keeps the same IDs.
        let next = ChatIdentityAssignment.assign(rows: teamRows(offset: 5), records: apply(result, rows: rows, records: records))
        #expect(next.rowIDs == ["chat_t_5", "chat_t_6"])
        #expect(next.retiredRecords.isEmpty)
    }

    @Test("Group A from scratch: chats, then read --chat-id resolves each ID to its own row")
    func punctuationTitlesChatsThenRead() {
        let rows = teamRows()
        let first = ChatIdentityAssignment.assign(rows: rows, records: [])
        #expect(first.rowIDs.allSatisfy { !$0.isEmpty })
        #expect(Set(first.rowIDs).count == 2)
        let records = apply(first, rows: rows, records: [])
        for (index, id) in first.rowIDs.enumerated() {
            #expect(ChatIdentityAssignment.resolve(chatID: id, rows: rows, records: records) == .row(index))
        }
        let again = ChatIdentityAssignment.assign(rows: rows, records: records)
        #expect(again.rowIDs == first.rowIDs)
        #expect(again.retiredRecords.isEmpty)
    }

    @Test("Same exact title and preview: time and member count pair, also right after chats")
    func compositeKey() {
        let rows = [
            IdentityRow(title: "홍길동", normalizedName: "홍길동", preview: nil, timeLabel: "2025. 3. 1.", memberCount: 2, listIndex: 0),
            IdentityRow(title: "홍길동", normalizedName: "홍길동", preview: nil, timeLabel: "2024. 7. 9.", memberCount: 2, listIndex: 4),
        ]
        // Records the old version left: same title, no preview, no time or members. They could
        // be either row, so they are retired once and the rows get IDs with their features.
        let old = [
            IdentityRecordState(chatID: "chat_h_5", normalizedName: "홍길동", displayName: "홍길동", preview: nil),
            IdentityRecordState(chatID: "chat_h_6", normalizedName: "홍길동", displayName: "홍길동", preview: nil),
        ]
        let first = ChatIdentityAssignment.assign(rows: rows, records: old)
        #expect(first.retiredRecords == [0, 1])
        #expect(first.rowIDs.allSatisfy { !$0.isEmpty && !$0.hasSuffix("_5") && !$0.hasSuffix("_6") })
        let records = apply(first, rows: rows, records: old)
        for (index, id) in first.rowIDs.enumerated() {
            #expect(ChatIdentityAssignment.resolve(chatID: id, rows: rows, records: records) == .row(index))
        }
        let again = ChatIdentityAssignment.assign(rows: [rows[1], rows[0]].enumerated().map { index, row in
            var moved = row
            moved.listIndex = index
            return moved
        }, records: records)
        #expect(again.rowIDs == [first.rowIDs[1], first.rowIDs[0]])
        #expect(again.retiredRecords.isEmpty)
    }

    @Test("A changed time falls through to the preview; preview and time changed falls to elimination or retirement")
    func changedKeys() {
        let records = [
            IdentityRecordState(chatID: "chat_a", normalizedName: "홍길동", displayName: "홍길동", preview: "안녕", timeLabel: "오후 3:10", memberCount: 2),
            IdentityRecordState(chatID: "chat_b", normalizedName: "홍길동", displayName: "홍길동", preview: "ㅇㅇ", timeLabel: "오후 1:00", memberCount: 2),
        ]
        // The day passed: "오후 3:10" became "어제"; the previews still tell them apart.
        let dayLater = [
            IdentityRow(title: "홍길동", normalizedName: "홍길동", preview: "ㅇㅇ", timeLabel: "어제", memberCount: 2, listIndex: 0),
            IdentityRow(title: "홍길동", normalizedName: "홍길동", preview: "안녕", timeLabel: "어제", memberCount: 2, listIndex: 1),
        ]
        #expect(ChatIdentityAssignment.assign(rows: dayLater, records: records).rowIDs == ["chat_b", "chat_a"])
        // Both got new messages: nothing pairs, the old IDs are retired (never swapped).
        let bothNew = [
            IdentityRow(title: "홍길동", normalizedName: "홍길동", preview: "ㅋㅋ", timeLabel: "오후 4:00", memberCount: 2, listIndex: 0),
            IdentityRow(title: "홍길동", normalizedName: "홍길동", preview: "내일봐", timeLabel: "오후 4:01", memberCount: 2, listIndex: 1),
        ]
        let result = ChatIdentityAssignment.assign(rows: bothNew, records: records)
        #expect(result.retiredRecords == [0, 1])
        #expect(!result.rowIDs.contains("chat_a") && !result.rowIDs.contains("chat_b"))
        // Only one got a new message: the other pairs by its key, the new one by elimination.
        let oneNew = [
            IdentityRow(title: "홍길동", normalizedName: "홍길동", preview: "ㅋㅋ", timeLabel: "오후 4:00", memberCount: 2, listIndex: 0),
            IdentityRow(title: "홍길동", normalizedName: "홍길동", preview: "ㅇㅇ", timeLabel: "오후 1:00", memberCount: 2, listIndex: 1),
        ]
        #expect(ChatIdentityAssignment.assign(rows: oneNew, records: records).rowIDs == ["chat_a", "chat_b"])
    }

    // Group B: same title, empty previews, identical in every feature.
    private func identicalRows(_ indices: [Int]) -> [IdentityRow] {
        indices.map { IdentityRow(title: "홍길동", normalizedName: "홍길동", preview: nil, timeLabel: "2023. 5. 2.", memberCount: 2, listIndex: $0) }
    }

    @Test("Group B: rows identical in every feature keep the existing IDs as a set; read is CHAT_AMBIGUOUS; no churn")
    func identicalRowsKeepTheSet() {
        let old = [
            IdentityRecordState(chatID: "chat_h_5", normalizedName: "홍길동", displayName: "홍길동", preview: nil),
            IdentityRecordState(chatID: "chat_h_6", normalizedName: "홍길동", displayName: "홍길동", preview: nil),
        ]
        let rows = identicalRows([2, 7])
        let first = ChatIdentityAssignment.assign(rows: rows, records: old)
        #expect(first.rowIDs == ["", ""])
        #expect(first.retiredRecords.isEmpty)
        #expect(first.heldRecords.map(\.record) == [0, 1])
        let records = apply(first, rows: rows, records: old)
        #expect(records.allSatisfy { $0.timeLabel == "2023. 5. 2." && $0.memberCount == 2 && !$0.retired })
        for id in ["chat_h_5", "chat_h_6"] {
            #expect(ChatIdentityAssignment.resolve(chatID: id, rows: rows, records: records) == .ambiguous)
        }
        // Scan after scan: same IDs, nothing retired, nothing new.
        let again = ChatIdentityAssignment.assign(rows: identicalRows([0, 1]), records: records)
        #expect(again.rowIDs == ["", ""])
        #expect(again.retiredRecords.isEmpty)
        #expect(apply(again, rows: identicalRows([0, 1]), records: records).count == 2)
        // A partial scan that reaches only one of them does not retire the set either.
        let partial = ChatIdentityAssignment.assign(rows: identicalRows([0]), records: records)
        #expect(partial.rowIDs == [""])
        #expect(partial.retiredRecords.isEmpty)
    }

    @Test("Group B from scratch: identical rows get no IDs and no records; a later difference gives them IDs")
    func identicalRowsFromScratch() {
        let rows = identicalRows([0, 1])
        let first = ChatIdentityAssignment.assign(rows: rows, records: [])
        #expect(first.rowIDs == ["", ""])
        #expect(apply(first, rows: rows, records: []).isEmpty)
        // One of them gets a message: now they differ and both get IDs that resolve.
        var changed = rows
        changed[0].preview = "새 메시지"
        changed[0].timeLabel = "오후 2:00"
        let second = ChatIdentityAssignment.assign(rows: changed, records: [])
        #expect(second.rowIDs.allSatisfy { !$0.isEmpty })
        let records = apply(second, rows: changed, records: [])
        for (index, id) in second.rowIDs.enumerated() {
            #expect(ChatIdentityAssignment.resolve(chatID: id, rows: changed, records: records) == .row(index))
        }
    }

    @Test("Records that could be either of two different rows are not held for one of them")
    func wildcardRecordsAreNotHeld() {
        let rows = [
            IdentityRow(title: "홍길동", normalizedName: "홍길동", preview: "같은말", timeLabel: "2025. 1. 1.", memberCount: 2, listIndex: 0),
            IdentityRow(title: "홍길동", normalizedName: "홍길동", preview: "같은말", timeLabel: "2024. 1. 1.", memberCount: 3, listIndex: 1),
        ]
        let old = [
            IdentityRecordState(chatID: "chat_a", normalizedName: "홍길동", displayName: "홍길동", preview: "같은말"),
            IdentityRecordState(chatID: "chat_b", normalizedName: "홍길동", displayName: "홍길동", preview: "같은말"),
        ]
        let result = ChatIdentityAssignment.assign(rows: rows, records: old)
        #expect(result.heldRecords.isEmpty)
        #expect(result.retiredRecords == [0, 1])
        #expect(result.rowIDs.allSatisfy { !$0.isEmpty })
    }

    @Test("A unique exact title wins over everything else; a shared one does not pair")
    func exactTitle() {
        let rows = [
            IdentityRow(title: "테스트방", normalizedName: "테스트방", preview: "x", listIndex: 0),
            IdentityRow(title: "테스트 방", normalizedName: "테스트방", preview: "y", listIndex: 1),
        ]
        let records = [
            IdentityRecordState(chatID: "chat_spaced", normalizedName: "테스트방", displayName: "테스트 방", preview: "x"),
            IdentityRecordState(chatID: "chat_plain", normalizedName: "테스트방", displayName: "테스트방", preview: "y"),
        ]
        // Titles beat swapped previews.
        #expect(ChatIdentityAssignment.assign(rows: rows, records: records).rowIDs == ["chat_plain", "chat_spaced"])
        let shared = [
            IdentityRecordState(chatID: "chat_1", normalizedName: "테스트방", displayName: "테스트방", preview: "x"),
            IdentityRecordState(chatID: "chat_2", normalizedName: "테스트방", displayName: "테스트방", preview: "y"),
        ]
        let sameTitles = rows.map { row -> IdentityRow in
            var copy = row
            copy.title = "테스트방"
            return copy
        }
        #expect(ChatIdentityAssignment.assign(rows: sameTitles, records: shared).rowIDs == ["chat_1", "chat_2"])
    }
}
