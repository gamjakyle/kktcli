import CoreGraphics
import Foundation
import Testing
@testable import KktcliCore

@Suite("Main window on any desktop: element-id tokens, scan order, lookup order, tabs")
struct WindowLookupTests {
    // MARK: Token layout

    @Test("Token: pid, 0, 0x636f636f, element id; 20 bytes, little-endian")
    func tokenLayout() {
        let bytes = AXRemoteToken.bytes(pid: 0x0102_0304, elementID: 0x1122_3344_5566_7788)
        #expect(bytes.count == 20)
        #expect(Array(bytes[0..<4]) == [0x04, 0x03, 0x02, 0x01])
        #expect(Array(bytes[4..<8]) == [0, 0, 0, 0])
        #expect(Array(bytes[8..<12]) == [0x6f, 0x63, 0x6f, 0x63])
        #expect(Array(bytes[12..<20]) == [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])

        let parsed = AXRemoteToken.parse(AXRemoteToken.bytes(pid: 4321, elementID: 1666))
        #expect(parsed?.pid == 4321)
        #expect(parsed?.elementID == 1666)
        #expect(AXRemoteToken.parse(Array(bytes[0..<19])) == nil)
        var wrongMarker = bytes
        wrongMarker[8] = 0
        #expect(AXRemoteToken.parse(wrongMarker) == nil)
        var nonZero = bytes
        nonZero[5] = 1
        #expect(AXRemoteToken.parse(nonZero) == nil)
    }

    // MARK: Scan order

    private func covered(_ ranges: [Range<UInt64>]) -> Set<UInt64> {
        Set(ranges.flatMap { Array($0) })
    }

    @Test("Without a cache: 0 upward in chunks up to the span")
    func scanWithoutCache() {
        let ranges = RemoteElementScan.ranges(cachedID: nil, span: 12, chunk: 5)
        #expect(ranges == [0..<5, 5..<10, 10..<12])
        let full = RemoteElementScan.ranges(cachedID: nil)
        #expect(full.first == 0..<5_000)
        #expect(full.last == 195_000..<200_000)
        #expect(full.count == 40)
        #expect(full.allSatisfy { $0.count <= Int(RemoteElementScan.chunkSize) })
    }

    @Test("With a cache: that id first, then upward from it, then the ids just below it")
    func scanWithCache() {
        let ranges = RemoteElementScan.ranges(cachedID: 20, span: 10, chunk: 4)
        #expect(ranges.first == 20..<21)
        #expect(ranges[1] == 21..<25)
        #expect(ranges.contains(29..<31))
        #expect(ranges.last == 18..<20)
        #expect(covered(ranges) == Set(10..<31))
        // Upward comes before anything below the cached id.
        let firstBelow = ranges.firstIndex { $0.lowerBound < 20 }!
        #expect(ranges[..<firstBelow].allSatisfy { $0.lowerBound >= 20 })

        let small = RemoteElementScan.ranges(cachedID: 3, span: 10, chunk: 100)
        #expect(small == [3..<4, 4..<14, 0..<3])
        let overflow = RemoteElementScan.ranges(cachedID: UInt64.max - 2, span: 10, chunk: 100)
        #expect(overflow == [0..<10])
    }

    @Test("Cache: only for the same KakaoTalk process; snake_case keys round-trip")
    func cache() throws {
        let cache = AXElementCache(pid: 4321, mainWindowElementID: 1666, updatedAt: Date(timeIntervalSince1970: 0))
        #expect(cache.mainWindowElementID(forPID: 4321) == 1666)
        #expect(cache.mainWindowElementID(forPID: 4322) == nil)
        let data = try #require(cache.encoded())
        let text = String(decoding: data, as: UTF8.self)
        for key in ["\"schema_version\"", "\"pid\"", "\"main_window_element_id\"", "\"updated_at\""] {
            #expect(text.contains(key))
        }
        #expect(AXElementCache.decode(data) == cache)
        #expect(AXElementCache.decode(Data("not json".utf8)) == nil)
        #expect(AXElementCache.decode(nil) == nil)
    }

    // MARK: Lookup order

    @Test("Order: kAXWindows, id scan, 창 > 채팅 only when closed, 카카오톡 열기 only with --allow-activate")
    func lookupOrder() {
        #expect(MainWindowLookup.order(scanAvailable: true, windowServerShowsNoMainWindow: true, allowActivate: false)
            == [.accessibilityWindows, .elementIDScan, .windowMenu, .notVisible])
        #expect(MainWindowLookup.order(scanAvailable: true, windowServerShowsNoMainWindow: false, allowActivate: false)
            == [.accessibilityWindows, .elementIDScan, .notVisible])
        #expect(MainWindowLookup.order(scanAvailable: false, windowServerShowsNoMainWindow: true, allowActivate: true)
            == [.accessibilityWindows, .windowMenu, .showMainWindowItem, .notVisible])
        #expect(MainWindowLookup.order(scanAvailable: false, windowServerShowsNoMainWindow: false, allowActivate: true)
            == [.accessibilityWindows, .showMainWindowItem, .notVisible])
        for scan in [false, true] {
            for closed in [false, true] {
                for allow in [false, true] {
                    let steps = MainWindowLookup.order(scanAvailable: scan, windowServerShowsNoMainWindow: closed, allowActivate: allow)
                    #expect(steps.contains(.showMainWindowItem) == allow)
                    #expect(steps.contains(.windowMenu) == closed)
                    #expect(steps.last == .notVisible)
                    if let menu = steps.firstIndex(of: .windowMenu), let activate = steps.firstIndex(of: .showMainWindowItem) {
                        #expect(menu < activate)
                    }
                }
            }
        }
    }

    @Test("Window server: closed when no main-sized KakaoTalk window is left unaccounted for")
    func windowServer() {
        let main = CGRect(x: 100, y: 80, width: 420, height: 640)
        let chat = CGRect(x: 600, y: 80, width: 380, height: 560)
        let entries = [
            WindowServerEntry(ownerPID: 100, layer: 0, isOnscreen: true, frame: chat),
            WindowServerEntry(ownerPID: 100, layer: 0, isOnscreen: false, frame: main),
            WindowServerEntry(ownerPID: 100, layer: 0, isOnscreen: false, frame: CGRect(x: 0, y: 0, width: 40, height: 30)),
            WindowServerEntry(ownerPID: 100, layer: 25, isOnscreen: true, frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
            WindowServerEntry(ownerPID: 200, layer: 0, isOnscreen: false, frame: CGRect(x: 0, y: 0, width: 800, height: 800)),
        ]
        // Only the chat window is reachable: the off-screen main-sized window may be the main window.
        #expect(MainWindowLookup.unaccountedWindows(entries, kakaoPID: 100, knownFrames: [chat]).map(\.frame) == [main])
        #expect(!MainWindowLookup.windowServerShowsNoMainWindow(entries, kakaoPID: 100, knownFrames: [chat]))
        // Reached by id too (within 2 pt): nothing left, so the main window is closed.
        let nearlyMain = main.offsetBy(dx: 1.5, dy: -1)
        #expect(MainWindowLookup.windowServerShowsNoMainWindow(entries, kakaoPID: 100, knownFrames: [chat, nearlyMain]))
        #expect(!MainWindowLookup.windowServerShowsNoMainWindow(entries, kakaoPID: 100, knownFrames: [chat, main.offsetBy(dx: 3, dy: 0)]))
        // No windows at all: closed. A window without bounds is never assumed away.
        #expect(MainWindowLookup.windowServerShowsNoMainWindow([], kakaoPID: 100, knownFrames: []))
        #expect(!MainWindowLookup.windowServerShowsNoMainWindow([WindowServerEntry(ownerPID: 100, layer: 0, isOnscreen: false)], kakaoPID: 100, knownFrames: []))
    }

    // MARK: Tabs and the table

    private func chatTab() -> [AXNodeSnapshot] {
        [
            AXNodeSnapshot(role: "AXWindow", identifier: "Main Window"),
            AXNodeSnapshot(role: "AXButton", identifier: "friends", depth: 1),
            AXNodeSnapshot(role: "AXButton", identifier: "chatrooms", depth: 1),
            AXNodeSnapshot(role: "AXButton", identifier: "more", depth: 1),
            AXNodeSnapshot(role: "AXButton", desc: "채팅방 추가", depth: 1),
            AXNodeSnapshot(role: "AXScrollArea", identifier: "_NS:101", depth: 1),
            AXNodeSnapshot(role: "AXTable", identifier: "_NS:63", depth: 2),
        ]
    }

    private func friendsTab() -> [AXNodeSnapshot] {
        [
            AXNodeSnapshot(role: "AXWindow", identifier: "Main Window"),
            AXNodeSnapshot(role: "AXButton", identifier: "friends", depth: 1),
            AXNodeSnapshot(role: "AXButton", identifier: "chatrooms", depth: 1),
            AXNodeSnapshot(role: "AXScrollArea", identifier: "_NS:93", depth: 1),
            AXNodeSnapshot(role: "AXOutline", identifier: "_NS:8", depth: 2),
        ]
    }

    @Test("Tabs: 채팅 has a table and 채팅방 추가, 친구 an outline; identifiers are only hints")
    func tabs() {
        #expect(MainWindowLayout.classifyTab(chatTab()) == .chats)
        #expect(MainWindowLayout.classifyTab(friendsTab()) == .friends)
        // Other identifiers, same structure.
        let renamed = chatTab().map { node -> AXNodeSnapshot in
            var copy = node
            if copy.identifier.hasPrefix("_NS:") { copy.identifier = "_NS:999" }
            return copy
        }
        #expect(MainWindowLayout.classifyTab(renamed) == .chats)
        #expect(MainWindowLayout.classifyTab(chatTab().filter { $0.desc != "채팅방 추가" }) == .unknown)
        #expect(MainWindowLayout.classifyTab([]) == .unknown)
    }

    @Test("Only an AXTable on a window not showing 친구 can be the chat list, then the rows decide")
    func tableVerification() {
        let chatRows = (0..<12).map { _ in
            ChatRowSummary(title: "테스트방", titleSource: .titleLabel, memberCount: nil, timeLabel: "오후 3:10", isPinned: false, preview: "안녕하세요", unread: .none)
        }
        #expect(MainWindowLayout.isChatListContainer(role: "AXTable"))
        #expect(!MainWindowLayout.isChatListContainer(role: "AXOutline"))
        #expect(!MainWindowLayout.isChatListContainer(role: "AXList"))
        #expect(ChatListCheck.verify(containerRole: "AXTable", tab: .chats, summaries: chatRows) == .chatList)
        #expect(ChatListCheck.verify(containerRole: "AXTable", tab: .unknown, summaries: chatRows) == .chatList)
        #expect(ChatListCheck.verify(containerRole: "AXTable", tab: .friends, summaries: chatRows) == .otherTab(.friends))
        #expect(ChatListCheck.verify(containerRole: "AXOutline", tab: .unknown, summaries: chatRows) == .wrongContainer(role: "AXOutline"))
        #expect(ChatListCheck.verify(containerRole: nil, tab: .unknown, summaries: []) == .noTable)
        #expect(ChatListCheck.verify(containerRole: nil, tab: .friends, summaries: []) == .otherTab(.friends))
        #expect(ChatTabMenu.decide(.otherTab(.friends), mayPress: true, alreadySwitched: false) == .switchTab)
        #expect(ChatTabMenu.decide(.wrongContainer(role: "AXOutline"), mayPress: true, alreadySwitched: true) == .notChatTab)
    }

    @Test("Second choice for the tab: the chatrooms button only, never friends or more")
    func chatroomsButton() {
        #expect(MainWindowLayout.isChatroomsButton(role: "AXButton", identifier: "chatrooms"))
        #expect(!MainWindowLayout.isChatroomsButton(role: "AXButton", identifier: "friends"))
        #expect(!MainWindowLayout.isChatroomsButton(role: "AXButton", identifier: "more"))
        #expect(!MainWindowLayout.isChatroomsButton(role: "AXMenuItem", identifier: "chatrooms"))
        #expect(MainWindowLayout.tabButtonIdentifiers == ["friends", "chatrooms", "more"])
    }

    @Test("창 > 채팅 for a closed main window is guarded like 채팅방 열기 (no activation)")
    func windowMenuGuard() {
        #expect(!UserActivityPress.reopenViaWindowMenu.activatesKakaoTalk)
        let busyInFront = UserActivityState(kakaoTalkMayBeFrontmost: true, secondsSinceLastInput: 1)
        let busyElsewhere = UserActivityState(kakaoTalkMayBeFrontmost: false, secondsSinceLastInput: 1)
        for press in [UserActivityPress.reopenViaWindowMenu, .openChatRoom] {
            #expect(!UserActivityPolicy.mayPress(press, state: busyInFront, idleSeconds: 10))
            #expect(UserActivityPolicy.mayPress(press, state: busyElsewhere, idleSeconds: 10))
        }
        // 카카오톡 열기 activates KakaoTalk, so it waits for an idle user even then.
        #expect(!UserActivityPolicy.mayPress(.showMainWindow, state: busyElsewhere, idleSeconds: 10))
    }
}
