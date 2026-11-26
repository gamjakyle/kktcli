import ApplicationServices.HIServices
import Darwin
import Foundation
import KktcliCore

/// Accessibility elements by element id, through the private HIServices function
/// `_AXUIElementCreateWithRemoteToken` (see `AXRemoteToken`).
///
/// The symbol is looked up at run time with dlsym and never linked by name, so a macOS without
/// it still launches kktcli; `isAvailable` is then false and kktcli behaves as before (no
/// windows on other desktops). `KKTCLI_NO_ELEMENT_ID_SCAN=1` turns it off as well. Only reads
/// go through these elements here; presses stay with the callers' allowlists.
enum RemoteAXElement {
    static let symbolName = "_AXUIElementCreateWithRemoteToken"
    static let disableVariable = "KKTCLI_NO_ELEMENT_ID_SCAN"

    private typealias CreateFunction = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private struct Resolved: @unchecked Sendable {
        let create: CreateFunction?
    }

    private static let resolved: Resolved = {
        if ProcessInfo.processInfo.environment[disableVariable] == "1" {
            return Resolved(create: nil)
        }
        // RTLD_DEFAULT is ((void *) -2) in <dlfcn.h>; Swift does not import that macro.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbolName) else {
            return Resolved(create: nil)
        }
        return Resolved(create: unsafeBitCast(symbol, to: CreateFunction.self))
    }()

    static var isAvailable: Bool {
        resolved.create != nil
    }

    /// The element with id `elementID` in process `pid`, or nil (symbol missing).
    static func element(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        guard let create = resolved.create else { return nil }
        let token = Data(AXRemoteToken.bytes(pid: pid, elementID: elementID)) as CFData
        return create(token)?.takeRetainedValue()
    }

    /// The element still exists (its role can be read). A closed window's element stops
    /// answering with kAXErrorInvalidUIElement.
    static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }
}
