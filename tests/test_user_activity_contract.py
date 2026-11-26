import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources"
GUARD = SOURCES / "kktcli" / "KakaoTalk" / "UserActivityGuard.swift"
ACCESS = SOURCES / "kktcli" / "KakaoTalk" / "MainWindowAccess.swift"
OPENER = SOURCES / "kktcli" / "KakaoTalk" / "ChatRoomMenuOpener.swift"
FETCHER = SOURCES / "kktcli" / "KakaoTalk" / "FullTextFetcher.swift"
LOCATOR = SOURCES / "kktcli" / "KakaoTalk" / "ChatListLocator.swift"
READ_COMMAND = SOURCES / "kktcli" / "Commands" / "ReadCommand.swift"
CHATS_COMMAND = SOURCES / "kktcli" / "Commands" / "ChatsCommand.swift"
MCP_SERVER = SOURCES / "kktcli" / "Commands" / "MCPServerCommand.swift"
MCP_MAPPING = SOURCES / "KktcliCore" / "MCPMapping.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class UserActivityContractTests(unittest.TestCase):
    def test_idle_time_comes_from_the_hid_state_without_permission(self) -> None:
        guard = read(GUARD)
        self.assertIn("CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)", guard)
        self.assertIn('code: "KAKAOTALK_IN_USE"', guard)
        self.assertIn("exitCode: UserActivityPolicy.inUseExitCode", guard)

    def test_window_opening_presses_wait_and_are_rechecked_right_before(self) -> None:
        opener = read(OPENER)
        self.assertIn("try activity.waitUntilClear(.openChatRoom)", opener)
        recheck = opener.index("guard activity.mayPressNow(.openChatRoom) else {")
        press = opener.index("AXNodeReader.perform(item.element, kAXPressAction)")
        self.assertLess(recheck, press)
        self.assertLess(opener.index("try activity.waitUntilClear(.openChatRoom)"), opener.index('AXNodeReader.perform(cell, "AXShowMenu")'))

        fetcher = read(FETCHER)
        self.assertIn("try activity.waitUntilClear(.seeAll)", fetcher)
        self.assertLess(fetcher.index("guard activity.mayPressNow(.seeAll) else {"), fetcher.index("target.control, kAXPressAction"))

        locator = read(LOCATOR)
        body = locator[locator.index("func pressShowMainWindowMenuItem(beforePress: () -> Bool) -> MainWindowPress {"):]
        self.assertLess(body.index("guard beforePress() else {"), body.index("AXNodeReader.perform(item.element, kAXPressAction)"))

    def test_main_window_lookup_order_and_presses(self) -> None:
        access = read(ACCESS)
        body = access[access.index("func resolve(locator: ChatListLocator, allowOpenCommand: Bool)"):access.index("enum PressOutcome")]
        # kAXWindows (and the remembered off-desktop window), the patient re-check, the
        # element-id scan, then the fallbacks MainWindowLookup allows.
        order = [
            "if let main = locator.mainWindow() {",
            "if let main = locator.confirmMainWindow() {",
            "lookup.scanForMainWindow()",
            "lookup.windowServerCheck(knownWindows:",
            "MainWindowLookup.fallbacks(",
        ]
        positions = [body.index(text) for text in order]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("allowActivate: allowActivate", body)
        self.assertLess(body.index("case .windowMenu:"), body.index("case .showMainWindowItem:"))
        self.assertIn("return (main.element, .otherDesktop)", body)
        self.assertIn("return (main, .openedViaWindowMenu)", body)
        # 창 > 채팅 is guarded like 채팅방 열기 and re-checked right before the press.
        self.assertIn("try activity.waitUntilClear(.reopenViaWindowMenu)", access)
        self.assertIn("locator.mainWindow() == nil && activity.mayPressNow(.reopenViaWindowMenu)", access)
        self.assertIn("try activity.waitUntilClear(.showMainWindow)", access)
        self.assertIn("locator.mainWindow() == nil && activity.mayPressNow(.showMainWindow)", access)
        self.assertIn('code: "MAIN_WINDOW_NOT_VISIBLE"', access)
        for key in ("kakao_frontmost", "ax_window_count", "cg_layer0_window_count", "cg_layer0_offscreen_count", "element_id_scan", "cg_unaccounted_window_count"):
            self.assertIn(f'"{key}"', access)
        self.assertIn("CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)", access)
        self.assertNotIn("MainWindowPolicy.decide(", access)
        # 카카오톡 열기 is only pressed through MainWindowAccess; every command looks the main
        # window up through it before the login check, and skips that check (which activates
        # KakaoTalk) only for a main window found on another desktop.
        for path in (READ_COMMAND, CHATS_COMMAND):
            source = read(path)
            self.assertNotIn("pressShowMainWindowMenuItem(", source)
            self.assertIn("Access.resolve(locator: ChatListLocator(kakao: early, runner: runner), allowOpenCommand: false)", source)
            self.assertLess(source.index("allowOpenCommand: false)"), source.index("AuthBootstrap.requireAuthenticated("))
        self.assertIn("backgroundSafe || mainWindowAction == .otherDesktop", read(READ_COMMAND))
        self.assertIn("earlyAction == .otherDesktop", read(CHATS_COMMAND))
        self.assertIn("try access.resolve(locator: self, allowOpenCommand: allowOpenCommand)", read(LOCATOR))

    def test_windows_on_other_desktops_are_found_by_element_id(self) -> None:
        remote = read(SOURCES / "kktcli" / "Accessibility" / "RemoteAXElement.swift")
        self.assertIn('static let symbolName = "_AXUIElementCreateWithRemoteToken"', remote)
        self.assertIn("dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbolName)", remote)
        self.assertIn("AXRemoteToken.bytes(pid: pid, elementID: elementID)", remote)
        all_sources = "\n".join(path.read_text(encoding="utf-8") for path in SOURCES.rglob("*.swift"))
        # A missing symbol must not stop kktcli from launching: never linked by name.
        self.assertNotIn("@_silgen_name", all_sources)
        lookup = read(SOURCES / "kktcli" / "KakaoTalk" / "KakaoWindowLookup.swift")
        self.assertIn("RemoteElementScan.ranges(cachedID: cachedID)", lookup)
        self.assertIn("break scan", lookup)
        # Its own file: ax-cache.json is the AX path cache's.
        self.assertIn('.appendingPathComponent("main-window-id.json")', lookup)
        self.assertNotIn('"ax-cache.json"', lookup)
        self.assertIn("mainWindowElementID(forPID: pid)", lookup)
        # The lookup only reads.
        for forbidden in ("perform(", "setNumber(", "kAXPressAction", "activate("):
            self.assertNotIn(forbidden, lookup)
        # Windows that a press opens are looked for there too, and closed by their close button.
        opener = read(OPENER)
        self.assertIn("lookup.reachableWindows(offDesktop: offDesktop, scanIDs: offDesktop)", opener)
        self.assertIn("lookup.reachableWindows(offDesktop: offDesktop, scanIDs: scanIDs)", opener)
        closer = read(SOURCES / "kktcli" / "KakaoTalk" / "ChatWindowCloser.swift")
        self.assertIn("!lookup.exists(window, wasListed: wasListed)", closer)
        self.assertIn("lookup.reachableWindows(offDesktop: offDesktop, scanIDs: scanIDs)", read(FETCHER))

    def test_a_real_send_never_goes_to_a_window_on_another_desktop(self) -> None:
        session = read(SOURCES / "kktcli" / "Send" / "RoomSession.swift")
        self.assertIn("func requireOnThisDesktop(_ opened: Opened) throws {", session)
        send = read(SOURCES / "kktcli" / "Commands" / "SendCommand.swift")
        self.assertLess(send.index("if isPreview {"), send.index("try room.requireOnThisDesktop(window)"))
        self.assertLess(send.index("try room.requireOnThisDesktop(window)"), send.index("MessageSender(session: room"))
        image = read(SOURCES / "kktcli" / "Commands" / "SendImageCommand.swift")
        self.assertLess(image.index("try room.requireOnThisDesktop(window)"), image.index("ImagePaster(session: room)"))

    def test_options_meta_and_batch(self) -> None:
        for path in (READ_COMMAND, CHATS_COMMAND):
            source = read(path)
            self.assertIn("var idleSeconds: Double = UserActivityPolicy.defaultIdleSeconds", source)
            self.assertIn("var waitForIdle: Double = UserActivityPolicy.defaultWaitSeconds", source)
            self.assertIn("var allowActivate: Bool = false", source)
        command = read(READ_COMMAND)
        self.assertIn('case waitedForUserMs = "waited_for_user_ms"', command)
        self.assertIn("try session.activity.waitUntilClear(.nextChat)", command)
        self.assertIn("throw ExitCode(UserActivityPolicy.inUseExitCode)", command)
        self.assertIn("var ok = true", read(CHATS_COMMAND))

    def test_mcp_exposes_the_options(self) -> None:
        server = read(MCP_SERVER)
        for option in ('"idle_seconds"', '"wait_for_idle"', '"allow_activate"'):
            self.assertIn(option, server)
        mapping = read(MCP_MAPPING)
        for flag in ('"--idle-seconds"', '"--wait-for-idle"', '"--allow-activate"'):
            self.assertIn(flag, mapping)


class OpenChatListContractTests(unittest.TestCase):
    def test_the_list_window_is_recognised_closed_and_reported(self) -> None:
        opener = read(OPENER)
        self.assertIn("case .openChatList(let list):", opener)
        self.assertIn('code: "OPEN_CHAT_LIST"', opener)
        self.assertIn("exitCode: notAChatExitCode", opener)
        self.assertIn('details["conversation_count"]', opener)
        # Closed with its own close button (no title check), before the error is thrown.
        failure = opener.index("throw Self.openChatListFailure(row: row, list: list, rowCount: opened.listRowCount")
        self.assertLess(opener.index("var details = closeWindowsOpenedByThePress(windowsBefore: windowsBefore, offDesktop: offDesktop)"), failure)
        self.assertIn('details["opened"] = "true"', opener)

    def test_empty_list_preview_is_a_shortcut_that_presses_nothing(self) -> None:
        opener = read(OPENER)
        body = opener[opener.index("func open(_ row: LocatedChatRow, access: ChatListAccess, skipUnread: Bool) throws -> OpenedRoom {"):]
        shortcut = body.index("KakaoWindowClassifier.isEmptyOpenChatListRow(title: row.title, preview: row.summary.preview)")
        self.assertLess(shortcut, body.index("try activity.waitUntilClear(.openChatRoom)"))
        self.assertIn('details: ["opened": "false"]', body)

    def test_a_missing_main_window_is_looked_for_again_before_any_reopen(self) -> None:
        access = read(ACCESS)
        confirm = access.index("if let main = locator.confirmMainWindow() {")
        self.assertLess(confirm, access.index("lookup.scanForMainWindow()"))
        self.assertLess(confirm, access.index("try pressWindowMenu(locator: locator)"))
        self.assertLess(confirm, access.index("try pressShowMainWindowItem(locator: locator)"))
        self.assertIn("case .alreadyVisible(let main):", access)
        locator = read(LOCATOR)
        self.assertIn("func confirmMainWindow(within duration: TimeInterval = ChatListLocator.mainWindowRecheckDuration) -> UIElement? {", locator)
        self.assertIn("self.access(in: mainWindow, patience: Self.mainWindowRecheckDuration)", locator)
        # watch --all looks it up read-only (no presses).
        self.assertIn("func findMainWindow(scan: Bool) -> (window: UIElement, offDesktop: Bool)? {", locator)

    def test_classification_only_reads(self) -> None:
        locator = read(LOCATOR)
        body = locator[locator.index("func classifyWindow(_ window: UIElement)"):locator.index("func hasTranscript(")]
        self.assertNotIn("perform(", body)
        self.assertNotIn("setNumber(", body)


if __name__ == "__main__":
    unittest.main()
