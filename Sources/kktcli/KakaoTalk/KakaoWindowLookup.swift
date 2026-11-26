import ApplicationServices.HIServices
import CoreGraphics
import Foundation
import KktcliCore

/// Every KakaoTalk window kktcli can reach, wherever it is. Read-only: nothing here presses.
///
/// kAXWindows lists only the windows on the current desktop or Space. A window on another
/// desktop (or full-screen Space) is reached by element id (`RemoteAXElement`): the main
/// window's id is looked for upward in chunks, stops at the first match and is cached in
/// `~/.kktcli/ax-cache.json` for the same KakaoTalk process. When the symbol is unavailable,
/// only kAXWindows is used, as before.
///
/// New sources of windows go into `reachableWindows(remote:)` and `scanForMainWindow()`; the
/// order in which they are tried for the main window is `MainWindowLookup`.
struct KakaoWindowLookup {
    struct RemoteWindow {
        let element: UIElement
        let elementID: UInt64
    }

    struct ScanResult {
        var mainWindow: RemoteWindow?
        /// Every other AXWindow seen on the way (all of them in range after a miss).
        var otherWindows: [RemoteWindow] = []
        var scannedIDs: UInt64 = 0
        var elapsedMs = 0
        var timedOut = false
        var cachedIDTried = false

        var summary: String {
            if let mainWindow {
                return "found id \(mainWindow.elementID) after \(scannedIDs) ids in \(elapsedMs) ms"
            }
            return (timedOut ? "timed out" : "missed") + " after \(scannedIDs) ids in \(elapsedMs) ms (\(otherWindows.count) other windows)"
        }
    }

    /// Wall-clock budget for one main-window scan (a miss over 200 000 ids took about 1.9 s).
    static let scanBudget: TimeInterval = 4.0
    /// Ids above the main window looked at for windows opened on another desktop.
    static let newWindowSpan: UInt64 = 20_000
    /// Wall-clock budget for that.
    static let newWindowBudget: TimeInterval = 1.0

    let kakao: KakaoTalkApp
    let runner: AXActionRunner

    static var scanAvailable: Bool {
        RemoteAXElement.isAvailable
    }

    var pid: pid_t? {
        AXNodeReader.pid(of: kakao.applicationElement.axElement)
    }

    // MARK: Main window

    /// The main window found by id earlier in this process (still answering, same id), or the
    /// cached id of this KakaoTalk process: at most a few reads, never a scan.
    func knownOffDesktopMainWindow() -> RemoteWindow? {
        guard Self.scanAvailable, let pid else { return nil }
        if let remembered = Self.memo.get(pid: pid), isMainWindow(remembered.element.axElement) {
            return remembered
        }
        guard let cachedID = Self.loadCache()?.mainWindowElementID(forPID: pid),
              let element = RemoteAXElement.element(pid: pid, elementID: cachedID),
              isMainWindow(element)
        else {
            return nil
        }
        let window = RemoteWindow(element: UIElement(element), elementID: cachedID)
        Self.memo.set(window, pid: pid)
        return window
    }

    /// Looks for the main window by id: the cached id first, then upward in chunks
    /// (`RemoteElementScan`), stopping at the first match, within `scanBudget`.
    func scanForMainWindow() -> ScanResult {
        var result = ScanResult()
        guard Self.scanAvailable, let pid else { return result }
        let started = Date()
        let cachedID = Self.loadCache()?.mainWindowElementID(forPID: pid)
        result.cachedIDTried = cachedID != nil
        let deadline = started.addingTimeInterval(Self.scanBudget)
        scan: for range in RemoteElementScan.ranges(cachedID: cachedID) {
            if Date() >= deadline || ReadInterruption.requested {
                result.timedOut = Date() >= deadline
                break
            }
            for id in range {
                // A busy KakaoTalk can make single reads wait for the messaging timeout.
                if id & 0xFF == 0, Date() >= deadline {
                    result.timedOut = true
                    break scan
                }
                result.scannedIDs += 1
                guard let element = RemoteAXElement.element(pid: pid, elementID: id), isWindow(element) else { continue }
                let window = RemoteWindow(element: UIElement(element), elementID: id)
                if isMainWindow(element) {
                    result.mainWindow = window
                    break scan
                }
                result.otherWindows.append(window)
            }
        }
        result.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        if let main = result.mainWindow {
            Self.memo.set(main, pid: pid)
            Self.saveCache(AXElementCache(pid: pid, mainWindowElementID: main.elementID))
        }
        runner.log("main window: element-id scan \(result.summary)")
        return result
    }

    // MARK: Other windows

    /// kAXWindows, plus, with `offDesktop`, the app's focused and main window (they may be on
    /// another desktop) and, with `scanIDs` too, the windows by id just above the main window's
    /// id (a room opened from an off-desktop main window may open on KakaoTalk's desktop;
    /// about 0.2 s, so pollers do it only now and then). Deduplicated.
    func reachableWindows(offDesktop: Bool, scanIDs: Bool) -> [UIElement] {
        var windows = kakao.windows
        guard offDesktop else { return windows }
        func add(_ candidate: UIElement?) {
            guard let candidate, isWindow(candidate.axElement),
                  !windows.contains(where: { CFEqual($0.axElement, candidate.axElement) })
            else { return }
            windows.append(candidate)
        }
        add(kakao.focusedWindow)
        add(kakao.mainWindow)
        if scanIDs, Self.scanAvailable, let pid, let floor = Self.memo.get(pid: pid)?.elementID {
            let upper = floor + Self.newWindowSpan
            let deadline = Date().addingTimeInterval(Self.newWindowBudget)
            for id in floor..<upper {
                if id & 0xFF == 0, Date() >= deadline {
                    runner.log("windows: element-id scan above \(floor) stopped at \(id) (time budget)")
                    break
                }
                guard let element = RemoteAXElement.element(pid: pid, elementID: id), isWindow(element) else { continue }
                add(UIElement(element))
            }
        }
        return windows
    }

    /// The window still exists: listed in kAXWindows, or (off-desktop) still answering by id.
    func exists(_ window: UIElement, wasListed: Bool) -> Bool {
        if kakao.windows.contains(where: { CFEqual($0.axElement, window.axElement) }) {
            return true
        }
        return wasListed ? false : RemoteAXElement.isAlive(window.axElement)
    }

    func isListed(_ window: UIElement) -> Bool {
        kakao.windows.contains { CFEqual($0.axElement, window.axElement) }
    }

    // MARK: Window server

    struct WindowServerCheck {
        let showsNoMainWindow: Bool
        let unaccounted: Int
        let layer0: Int
    }

    /// Does the window server show a window that could be the main window, beyond those
    /// Accessibility reaches (kAXWindows plus `knownWindows`)? None means it is closed.
    func windowServerCheck(knownWindows: [UIElement]) -> WindowServerCheck? {
        guard let pid else { return nil }
        let entries = MainWindowAccess.windowServerEntries()
        let frames = (kakao.windows + knownWindows).compactMap(\.frame)
        let unaccounted = MainWindowLookup.unaccountedWindows(entries, kakaoPID: pid, knownFrames: frames)
        let layer0 = MainWindowPolicy.windowCounts(entries, kakaoPID: pid).total
        runner.log("main window: window server layer-0 windows=\(layer0) unaccounted=\(unaccounted.count) known AX frames=\(frames.count)")
        return WindowServerCheck(showsNoMainWindow: unaccounted.isEmpty, unaccounted: unaccounted.count, layer0: layer0)
    }

    // MARK: Element checks

    private func isWindow(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return false }
        return (value as? String) == AXRoleName.window
    }

    private func isMainWindow(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) == .success else { return false }
        return (value as? String) == ChatListLocator.mainWindowIdentifier && isWindow(element)
    }

    // MARK: Cache

    /// The main window found by id in this process.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        private var window: RemoteWindow?

        func get(pid: pid_t) -> RemoteWindow? {
            lock.lock()
            defer { lock.unlock() }
            return self.pid == pid ? window : nil
        }

        func set(_ window: RemoteWindow, pid: pid_t) {
            lock.lock()
            defer { lock.unlock() }
            self.pid = pid
            self.window = window
        }
    }

    private static let memo = Memo()

    static func cacheURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kktcli", isDirectory: true)
            .appendingPathComponent("ax-cache.json")
    }

    private static func loadCache() -> AXElementCache? {
        AXElementCache.decode(try? Data(contentsOf: cacheURL()))
    }

    private static func saveCache(_ cache: AXElementCache) {
        guard let data = cache.encoded() else { return }
        let url = cacheURL()
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
