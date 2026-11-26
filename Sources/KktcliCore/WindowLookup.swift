import CoreGraphics
import Foundation

// MARK: - Elements by id (windows on other desktops)

/// The 20-byte token `_AXUIElementCreateWithRemoteToken` takes: pid (Int32), 0 (Int32),
/// 0x636f636f (Int32) and the element id (UInt64), little-endian.
///
/// That private HIServices function (resolved at run time, never linked) turns an element id
/// into an AXUIElement. It is the technique AltTab uses: Accessibility's kAXWindows lists only
/// the windows on the current desktop or Space, but a window elsewhere still answers by id.
/// Live (2026-11-26, KakaoTalk 26.10.0): the main window on another desktop was found as the
/// AXWindow identified "Main Window" at id 1601 (later 1666), and its table was readable.
public enum AXRemoteToken {
    public static let length = 20
    public static let marker: Int32 = 0x636f_636f

    public static func bytes(pid: Int32, elementID: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        append(pid)
        append(Int32(0))
        append(marker)
        append(elementID)
        return bytes
    }

    /// The pid and element id of a token, or nil when it is not one.
    public static func parse(_ bytes: [UInt8]) -> (pid: Int32, elementID: UInt64)? {
        guard bytes.count == length else { return nil }
        func read(_ offset: Int, _ size: Int) -> UInt64 {
            (0..<size).reduce(UInt64(0)) { value, index in value | UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
        }
        guard read(4, 4) == 0, Int32(truncatingIfNeeded: read(8, 4)) == marker else { return nil }
        return (Int32(truncatingIfNeeded: read(0, 4)), read(12, 8))
    }
}

/// Which element ids to try, in which order, when looking for the main window by id.
///
/// Ids grow while KakaoTalk runs (a reopened main window got a higher id), so the scan goes
/// upward in chunks and stops at the first match. A miss over 0..<200 000 took about 1.9 s.
public enum RemoteElementScan {
    public static let chunkSize: UInt64 = 5_000
    public static let span: UInt64 = 200_000

    /// Without a cached id: 0 upward for `span` ids. With one: that id first, then upward from
    /// it for `span` ids, then the `span` ids below it. Every range is at most `chunk` long.
    public static func ranges(cachedID: UInt64?, span: UInt64 = span, chunk: UInt64 = chunkSize) -> [Range<UInt64>] {
        let chunk = max(chunk, 1)
        var result: [Range<UInt64>] = []
        func split(_ range: Range<UInt64>) {
            var lower = range.lowerBound
            while lower < range.upperBound {
                let upper = min(lower + chunk, range.upperBound)
                result.append(lower..<upper)
                lower = upper
            }
        }
        guard let cachedID, cachedID < UInt64.max - span - 1 else {
            split(0..<span)
            return result
        }
        result.append(cachedID..<(cachedID + 1))
        split((cachedID + 1)..<(cachedID + 1 + span))
        split((cachedID > span ? cachedID - span : 0)..<cachedID)
        return result
    }
}

/// `~/.kktcli/main-window-id.json`: the main window's element id for one KakaoTalk process.
public struct AXElementCache: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var pid: Int32
    public var mainWindowElementID: UInt64
    public var updatedAt: Date

    public init(pid: Int32, mainWindowElementID: UInt64, updatedAt: Date = Date()) {
        self.schemaVersion = Self.schemaVersion
        self.pid = pid
        self.mainWindowElementID = mainWindowElementID
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case pid
        case mainWindowElementID = "main_window_element_id"
        case updatedAt = "updated_at"
    }

    /// The cached id, only for the same KakaoTalk process (ids start over with a new one).
    public func mainWindowElementID(forPID pid: Int32) -> UInt64? {
        schemaVersion == Self.schemaVersion && self.pid == pid ? mainWindowElementID : nil
    }

    public static func decode(_ data: Data?) -> AXElementCache? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AXElementCache.self, from: data)
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }
}

// MARK: - Finding the main window

/// How kktcli gets hold of KakaoTalk's main window when kAXWindows does not list it.
///
/// kAXWindows is empty for a main window on another desktop or full-screen Space, and also for
/// a closed one. In order: the window by element id (other desktop; read-only); when the
/// window server shows no main window at all (closed), KakaoTalk's own 창 > 채팅 menu item,
/// which opens it on the current desktop without activating KakaoTalk (live 2026-11-26);
/// 카카오톡 열기, which activates KakaoTalk, only with --allow-activate; otherwise
/// MAIN_WINDOW_NOT_VISIBLE.
public enum MainWindowLookup {
    public enum Step: String, Equatable, Sendable {
        /// kAXWindows, looked at again for a moment (a busy KakaoTalk can fail one read).
        case accessibilityWindows = "accessibility_windows"
        /// The main window by element id (`AXRemoteToken`); skipped when the symbol is missing.
        case elementIDScan = "element_id_scan"
        /// 창 > 채팅 (⌘2): opens a closed main window on this desktop, no activation.
        case windowMenu = "window_menu"
        /// 카카오톡 열기: activates KakaoTalk; only with --allow-activate.
        case showMainWindowItem = "show_main_window_item"
        /// MAIN_WINDOW_NOT_VISIBLE (or WINDOW_NOT_READY after a press that showed nothing).
        case notVisible = "not_visible"
    }

    public static func order(scanAvailable: Bool, windowServerShowsNoMainWindow: Bool, allowActivate: Bool) -> [Step] {
        [.accessibilityWindows]
            + (scanAvailable ? [.elementIDScan] : [])
            + fallbacks(windowServerShowsNoMainWindow: windowServerShowsNoMainWindow, allowActivate: allowActivate)
    }

    /// What follows when neither kAXWindows nor the id scan found the main window.
    public static func fallbacks(windowServerShowsNoMainWindow: Bool, allowActivate: Bool) -> [Step] {
        (windowServerShowsNoMainWindow ? [.windowMenu] : [])
            + (allowActivate ? [.showMainWindowItem] : [])
            + [.notVisible]
    }

    /// Smallest window side that could be KakaoTalk's main window.
    public static let minimumMainWindowSide: CGFloat = 200
    /// How far a window-server frame may differ from an Accessibility frame and still match.
    public static let frameTolerance: CGFloat = 2

    /// KakaoTalk's normal-level windows the window server knows (on any desktop) that are big
    /// enough to be the main window and match none of the windows Accessibility can reach
    /// (`knownFrames`). The window server gives no window names without Screen Recording, so
    /// any of these may be the main window somewhere kktcli cannot see; a window without a
    /// frame counts as unaccounted.
    public static func unaccountedWindows(_ entries: [WindowServerEntry], kakaoPID: Int32, knownFrames: [CGRect]) -> [WindowServerEntry] {
        entries.filter { entry in
            guard entry.ownerPID == kakaoPID, entry.layer == 0 else { return false }
            guard let frame = entry.frame else { return true }
            guard frame.width >= minimumMainWindowSide, frame.height >= minimumMainWindowSide else { return false }
            return !knownFrames.contains { matches($0, frame) }
        }
    }

    /// True when the window server shows no window that could be the main window: it is closed.
    public static func windowServerShowsNoMainWindow(_ entries: [WindowServerEntry], kakaoPID: Int32, knownFrames: [CGRect]) -> Bool {
        unaccountedWindows(entries, kakaoPID: kakaoPID, knownFrames: knownFrames).isEmpty
    }

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance && abs(a.height - b.height) <= frameTolerance
    }
}

// MARK: - Which tab the main window shows

public enum MainWindowTab: String, Equatable, Sendable {
    case chats
    case friends
    case unknown
}

/// KakaoTalk 26.10 main window (live 2026-11-26). 채팅 tab: AXScrollArea `_NS:101` > AXTable
/// `_NS:63`, plus an AXButton described "채팅방 추가". 친구 tab: AXScrollArea `_NS:93` > AXOutline
/// `_NS:8`. Tab buttons: AXButtons identified "friends", "chatrooms", "more". The `_NS`
/// identifiers are hints only; the chat list is verified by role and row structure.
public enum MainWindowLayout {
    public static let outlineRole = "AXOutline"
    public static let chatListScrollAreaIdentifier = "_NS:101"
    public static let chatListTableIdentifier = "_NS:63"
    public static let friendsScrollAreaIdentifier = "_NS:93"
    public static let friendsOutlineIdentifier = "_NS:8"
    public static let addChatRoomLabel = "채팅방 추가"
    public static let tabButtonIdentifiers: Set<String> = ["friends", "chatrooms", "more"]
    public static let chatroomsButtonIdentifier = "chatrooms"

    /// Only an AXTable can be the chat list; the 친구 tab's AXOutline never is.
    public static func isChatListContainer(role: String) -> Bool {
        role == AXRoleName.table
    }

    /// The tab the window's nodes show: 친구 when there is an outline and no "채팅방 추가"
    /// button, 채팅 when there is a table and that button and no outline, otherwise unknown.
    public static func classifyTab(_ nodes: [AXNodeSnapshot]) -> MainWindowTab {
        let outline = nodes.contains { $0.role == outlineRole }
        let table = nodes.contains { $0.role == AXRoleName.table }
        let addChatRoom = nodes.contains { $0.role == AXRoleName.button && $0.label.kktTrimmed == addChatRoomLabel }
        if outline && !addChatRoom {
            return .friends
        }
        if table && addChatRoom && !outline {
            return .chats
        }
        return .unknown
    }

    /// The top-level "chatrooms" tab button (second choice to switch tabs, after 창 > 채팅).
    /// "friends" and "more" are never pressed.
    public static func isChatroomsButton(role: String, identifier: String) -> Bool {
        role == AXRoleName.button && identifier == chatroomsButtonIdentifier
    }
}
