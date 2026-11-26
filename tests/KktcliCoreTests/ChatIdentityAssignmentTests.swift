import Testing
@testable import KktcliCore

@Suite("chat_id assignment between same-name rooms")
struct ChatIdentityAssignmentTests {
    private let name = "홍길동"

    private func row(_ preview: String?, at index: Int) -> IdentityRow {
        IdentityRow(title: name, normalizedName: name, preview: preview, listIndex: index)
    }

    private func record(_ id: String, _ preview: String?, retired: Bool = false) -> IdentityRecordState {
        IdentityRecordState(chatID: id, normalizedName: name, preview: preview, retired: retired)
    }

    @Test("Reported swap: both previews changed and the rooms moved; nobody gets the other's ID")
    func swapReproduction() {
        // Record A was last seen with preview "안녕" at row 3, B with "ㅇㅇ" at row 10.
        let records = [record("chat_a", "안녕"), record("chat_b", "ㅇㅇ")]
        // Now B's room shows "ㅋㅋ" at row 0 and A's room "내일봐" at row 1.
        let rows = [row("ㅋㅋ", at: 0), row("내일봐", at: 1)]
        let result = ChatIdentityAssignment.assign(rows: rows, records: records)
        #expect(!result.rowIDs.contains("chat_a"))
        #expect(!result.rowIDs.contains("chat_b"))
        #expect(result.retiredRecords == [0, 1])
        #expect(Set(result.rowIDs).count == 2)
        #expect(result.matchedRecords == [nil, nil])
        // Both old IDs are now stale.
        let afterwards = [record("chat_a", "안녕", retired: true), record("chat_b", "ㅇㅇ", retired: true)]
        #expect(ChatIdentityAssignment.resolve(chatID: "chat_a", rows: rows, records: afterwards) == .stale)
    }

    @Test("Reported new room: a new same-name room does not take A's ID")
    func newRoomReproduction() {
        let records = [record("chat_a", "안녕"), record("chat_b", "ㅇㅇ")]
        // New room C at row 0, A with a changed preview at row 5, B unchanged at row 11.
        let rows = [row("처음뵙겠습니다", at: 0), row("내일봐", at: 5), row("ㅇㅇ", at: 11)]
        let result = ChatIdentityAssignment.assign(rows: rows, records: records)
        #expect(result.rowIDs[2] == "chat_b")
        #expect(result.matchedRecords[2] == 1)
        #expect(!result.rowIDs.contains("chat_a"))
        #expect(result.retiredRecords == [0])
        #expect(result.rowIDs[0] != result.rowIDs[1])
    }

    @Test("Exact preview match keeps IDs, also when the rooms moved")
    func previewMatch() {
        let records = [record("chat_a", "안녕"), record("chat_b", "ㅇㅇ")]
        let rows = [row("ㅇㅇ", at: 0), row("안녕", at: 1)]
        let result = ChatIdentityAssignment.assign(rows: rows, records: records)
        #expect(result.rowIDs == ["chat_b", "chat_a"])
        #expect(result.retiredRecords.isEmpty)
    }

    @Test("One record and one row left: elimination keeps the ID")
    func elimination() {
        let records = [record("chat_a", "안녕"), record("chat_b", "ㅇㅇ")]
        let rows = [row("새 메시지", at: 0), row("ㅇㅇ", at: 4)]
        let result = ChatIdentityAssignment.assign(rows: rows, records: records)
        #expect(result.rowIDs == ["chat_a", "chat_b"])
        let single = ChatIdentityAssignment.assign(rows: [row("바뀜", at: 7)], records: [record("chat_a", "안녕")])
        #expect(single.rowIDs == ["chat_a"])
    }

    @Test("Identical rows and records: no row gets an ID, the IDs are kept as a set, nothing retired")
    func duplicatePreviews() {
        let records = [record("chat_a", "ㅇㅇ"), record("chat_b", "ㅇㅇ")]
        let rows = [row("ㅇㅇ", at: 0), row("ㅇㅇ", at: 1)]
        let result = ChatIdentityAssignment.assign(rows: rows, records: records)
        #expect(result.retiredRecords.isEmpty)
        #expect(result.rowIDs == ["", ""])
        #expect(result.heldRecords.map(\.record) == [0, 1])
        #expect(ChatIdentityAssignment.resolve(chatID: "chat_a", rows: rows, records: records) == .ambiguous)
    }

    @Test("Records not seen in a partial scan stay; nothing is retired without leftover rows")
    func partialScan() {
        let records = [record("chat_a", "안녕"), record("chat_b", "ㅇㅇ")]
        let result = ChatIdentityAssignment.assign(rows: [row("안녕", at: 2)], records: records)
        #expect(result.rowIDs == ["chat_a"])
        #expect(result.retiredRecords.isEmpty)
    }

    @Test("Retired IDs are never reused and never matched")
    func retiredNeverReused() {
        let base = ChatIdentityAssignment.freshID(normalizedName: name, taken: [])
        let records = [record(base, "안녕", retired: true)]
        let result = ChatIdentityAssignment.assign(rows: [row("안녕", at: 0)], records: records)
        #expect(result.rowIDs[0] != base)
        #expect(result.rowIDs[0] == base + "_2")
        #expect(result.retiredRecords.isEmpty)
        #expect(ChatIdentityAssignment.freshID(normalizedName: name, taken: [base, base + "_2"]) == base + "_3")
    }

    @Test("Resolving one ID: unique row, stale, ambiguous, not in the list")
    func resolveTarget() {
        let records = [record("chat_a", "안녕"), record("chat_b", "ㅇㅇ")]
        #expect(ChatIdentityAssignment.resolve(chatID: "chat_a", rows: [row("ㅇㅇ", at: 0), row("안녕", at: 1)], records: records) == .row(1))
        #expect(ChatIdentityAssignment.resolve(chatID: "chat_a", rows: [row("ㅇㅇ", at: 0), row("바뀜", at: 1)], records: records) == .row(1))
        #expect(ChatIdentityAssignment.resolve(chatID: "chat_a", rows: [row("ㅋㅋ", at: 0), row("바뀜", at: 1)], records: records) == .ambiguous)
        #expect(ChatIdentityAssignment.resolve(chatID: "chat_a", rows: [row("ㅇㅇ", at: 0)], records: records) == .notFound)
        #expect(ChatIdentityAssignment.resolve(chatID: "chat_a", rows: [], records: records) == .notFound)
        #expect(ChatIdentityAssignment.resolve(chatID: "chat_x", rows: [row("ㅇㅇ", at: 0)], records: records) == .notFound)
        let retired = [record("chat_a", "안녕", retired: true)]
        #expect(ChatIdentityAssignment.resolve(chatID: "chat_a", rows: [row("안녕", at: 0)], records: retired) == .stale)
    }

    @Test("Different names never interfere; fresh IDs follow the list order")
    func groupsAndOrder() {
        let rows = [
            IdentityRow(title: "테스트방", normalizedName: "테스트방", preview: "a", listIndex: 0),
            IdentityRow(title: name, normalizedName: name, preview: "b", listIndex: 1),
            IdentityRow(title: name, normalizedName: name, preview: "c", listIndex: 2),
        ]
        let result = ChatIdentityAssignment.assign(rows: rows, records: [])
        let base = ChatIdentityAssignment.freshID(normalizedName: name, taken: [])
        #expect(result.rowIDs[1] == base)
        #expect(result.rowIDs[2] == base + "_2")
        #expect(result.rowIDs[0] == ChatIdentityAssignment.freshID(normalizedName: "테스트방", taken: []))
    }
}
