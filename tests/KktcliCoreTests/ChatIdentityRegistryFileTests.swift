import Dispatch
import Foundation
import Testing
@testable import KktcliCore

@Suite("chat-registry.json shared by concurrent kktcli processes")
struct ChatIdentityRegistryFileTests {
    private func temporaryRegistry() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kktcli-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("chat-registry.json")
    }

    private func row(_ title: String, preview: String? = nil, at index: Int = 0) -> IdentityRow {
        IdentityRow(title: title, normalizedName: title, preview: preview, listIndex: index)
    }

    /// What `ChatIdentityRegistryStore.assignChatIDs` does with one scan.
    @discardableResult
    private func scan(_ rows: [IdentityRow], into file: ChatIdentityRegistryFile) -> [String] {
        file.update { document in
            let result = ChatIdentityAssignment.assign(rows: rows, records: document.records.map(\.identityState))
            document = document.applying(result, rows: rows, now: Date())
            return result.rowIDs
        }
    }

    private func onDisk(_ url: URL) throws -> ChatIdentityRegistryDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatIdentityRegistryDocument.self, from: Data(contentsOf: url))
    }

    @Test("Merge: a scan applies to the fresh document and leaves other rooms' records as they are")
    func mergeKeepsOtherRecords() {
        let now = Date(timeIntervalSince1970: 1_000)
        let other = ChatIdentityRecord(chatID: "chat_other", displayName: "테스트방", normalizedName: "테스트방", lastPreviewNormalized: "x", firstSeenAt: now, lastSeenAt: now, lastSeenIndex: 4)
        let fresh = ChatIdentityRegistryDocument(schemaVersion: 2, records: [other], updatedAt: now)
        let rows = [row("홍길동", preview: "안녕", at: 0)]
        let result = ChatIdentityAssignment.assign(rows: rows, records: fresh.records.map(\.identityState))
        let merged = fresh.applying(result, rows: rows, now: now.addingTimeInterval(5))
        #expect(merged.records.first == other)
        #expect(merged.records.count == 2)
        #expect(merged.records[1].chatID == result.rowIDs[0])
        #expect(merged.schemaVersion == ChatIdentityRegistryDocument.schemaVersion)
        // Refreshing one ID touches only that record.
        let refreshed = merged.refreshing(chatID: result.rowIDs[0], with: row("홍길동", preview: "ㅇㅇ", at: 2), now: now.addingTimeInterval(9))
        #expect(refreshed.records[0] == other)
        #expect(refreshed.records[1].lastPreviewNormalized == "ㅇㅇ")
        #expect(refreshed.records[1].lastSeenIndex == 2)
        #expect(merged.refreshing(chatID: "chat_unknown", with: rows[0], now: now) == merged)
    }

    @Test("Only timestamps changed: not a change worth writing")
    func timestampOnlyChanges() {
        let now = Date(timeIntervalSince1970: 1_000)
        let record = ChatIdentityRecord(chatID: "chat_a", displayName: "테스트방", normalizedName: "테스트방", lastPreviewNormalized: "x", firstSeenAt: now, lastSeenAt: now, lastSeenIndex: 0)
        let document = ChatIdentityRegistryDocument(records: [record], updatedAt: now)
        var later = document
        later.updatedAt = now.addingTimeInterval(60)
        later.records[0].lastSeenAt = now.addingTimeInterval(60)
        #expect(!later.differsBeyondTimestamps(from: document))
        var moved = later
        moved.records[0].lastSeenIndex = 3
        #expect(moved.differsBeyondTimestamps(from: document))
        var added = document
        added.records.append(record)
        #expect(added.differsBeyondTimestamps(from: document))
    }

    @Test("Reported loss: a long-running process with a stale copy no longer overwrites another's records")
    func staleProcessDoesNotOverwrite() throws {
        let url = try temporaryRegistry()
        let watch = ChatIdentityRegistryFile(fileURL: url)   // e.g. watch --all, started first
        let chats = ChatIdentityRegistryFile(fileURL: url)   // e.g. chats, run meanwhile
        scan([row("테스트방", preview: "a")], into: watch)
        _ = watch.read()                                     // the watch now holds a cached copy
        let fresh = scan([row("홍길동", preview: "b", at: 1)], into: chats)
        // The watch's next poll sees a new message in its room, so it writes.
        scan([row("테스트방", preview: "a2")], into: watch)
        let records = try onDisk(url).records
        #expect(Set(records.map(\.chatID)).contains(fresh[0]))
        #expect(records.count == 2)
        #expect(records.contains { $0.lastPreviewNormalized == "a2" })
        // And its reads see the other process's record (cache checked against the file).
        #expect(watch.read().records.contains { $0.chatID == fresh[0] })
    }

    @Test("Two writers at the same time (separate instances on two threads): no record is lost")
    func concurrentWriters() throws {
        let url = try temporaryRegistry()
        let perWriter = 40
        DispatchQueue.concurrentPerform(iterations: 2) { writer in
            let file = ChatIdentityRegistryFile(fileURL: url)
            for index in 0..<perWriter {
                scan([row("방\(writer)-\(index)", preview: "p\(index)")], into: file)
                _ = file.read()
            }
        }
        let records = try onDisk(url).records
        #expect(records.count == 2 * perWriter)
        #expect(Set(records.map(\.chatID)).count == 2 * perWriter)
        #expect(records.allSatisfy { !$0.isRetired })
    }

    @Test("An unchanged scan does not rewrite the file; written files are 0600 with a lock file next to them")
    func writesOnlyChanges() throws {
        let url = try temporaryRegistry()
        let file = ChatIdentityRegistryFile(fileURL: url)
        let rows = [row("테스트방", preview: "a"), row("홍길동", preview: "b", at: 1)]
        let first = scan(rows, into: file)
        let stamp = SharedFile.stamp(url)
        #expect(stamp != nil)
        Thread.sleep(forTimeInterval: 0.02)
        #expect(scan(rows, into: file) == first)
        #expect(SharedFile.stamp(url) == stamp)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("chat-registry.lock").path))
        // No temp files are left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("A newer schema is never overwritten; an unreadable file is kept aside, not overwritten")
    func foreignFiles() throws {
        let url = try temporaryRegistry()
        let newer = Data(#"{"schemaVersion": 99, "records": [], "updatedAt": "2026-01-01T00:00:00Z"}"#.utf8)
        try newer.write(to: url)
        let file = ChatIdentityRegistryFile(fileURL: url)
        let ids = scan([row("테스트방")], into: file)
        #expect(!ids[0].isEmpty)
        #expect(try Data(contentsOf: url) == newer)

        let broken = try temporaryRegistry()
        try Data("{ not json".utf8).write(to: broken)
        scan([row("테스트방")], into: ChatIdentityRegistryFile(fileURL: broken))
        #expect(try onDisk(broken).records.count == 1)
        let aside = try FileManager.default.contentsOfDirectory(atPath: broken.deletingLastPathComponent().path).filter { $0.contains(".unreadable-") }
        #expect(aside.count == 1)
    }
}
