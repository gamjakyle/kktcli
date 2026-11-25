import ApplicationServices.HIServices
import Foundation
import KmsgCore

/// One element read with a single batched AX call, plus its children.
struct AXLiveNode {
    let element: AXUIElement
    let snapshot: AXNodeSnapshot
    let children: [AXUIElement]
}

/// Batched Accessibility reads: `AXUIElementCopyMultipleAttributeValues` fetches role,
/// identifier, texts, frame and children in one round trip per element instead of one per
/// attribute. Read-only except for the explicit setters/actions at the bottom.
enum AXNodeReader {
    private static let attributeNames: [String] = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXIdentifierAttribute,
        kAXValueAttribute,
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXHelpAttribute,
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXChildrenAttribute,
        kAXSelectedAttribute,
    ]

    static func read(_ element: AXUIElement, depth: Int = 0) -> AXLiveNode {
        var output: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            attributeNames as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &output
        )
        guard status == .success, let values = output as? [AnyObject], values.count == attributeNames.count else {
            return AXLiveNode(element: element, snapshot: AXNodeSnapshot(role: "", depth: depth), children: [])
        }

        var frame: CGRect?
        if let position = axValue(values[7]), let size = axValue(values[8]) {
            var point = CGPoint.zero
            var extent = CGSize.zero
            if AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) {
                frame = CGRect(origin: point, size: extent)
            }
        }

        let children = isAXError(values[9]) ? [] : ((values[9] as? [AXUIElement]) ?? [])
        let selected = isAXError(values[10]) ? nil : (values[10] as? Bool)

        let snapshot = AXNodeSnapshot(
            role: string(values[0]) ?? "",
            subrole: string(values[1]) ?? "",
            identifier: string(values[2]) ?? "",
            value: string(values[3]),
            title: string(values[4]),
            desc: string(values[5]),
            help: string(values[6]),
            frame: frame,
            depth: depth,
            childCount: children.count,
            selected: selected
        )
        return AXLiveNode(element: element, snapshot: snapshot, children: children)
    }

    /// Depth-first, pre-order flatten of `root` (depth 0) limited by depth and node budget.
    static func flatten(_ root: AXUIElement, maxDepth: Int, budget: Int) -> [AXNodeSnapshot] {
        var remaining = budget
        var result: [AXNodeSnapshot] = []
        flatten(root, depth: 0, maxDepth: maxDepth, remaining: &remaining, into: &result)
        return result
    }

    private static func flatten(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        remaining: inout Int,
        into result: inout [AXNodeSnapshot]
    ) {
        guard remaining > 0 else { return }
        remaining -= 1
        let node = read(element, depth: depth)
        result.append(node.snapshot)
        guard depth < maxDepth else { return }
        for child in node.children {
            guard remaining > 0 else { return }
            flatten(child, depth: depth + 1, maxDepth: maxDepth, remaining: &remaining, into: &result)
        }
    }

    /// Breadth-first search for the first node matching `predicate`.
    static func firstDescendant(
        of root: AXUIElement,
        maxNodes: Int,
        where predicate: (AXLiveNode) -> Bool
    ) -> AXLiveNode? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < maxNodes {
            let (element, depth) = queue[index]
            index += 1
            let node = read(element, depth: depth)
            if depth > 0, predicate(node) {
                return node
            }
            queue.append(contentsOf: node.children.map { ($0, depth + 1) })
        }
        return nil
    }

    // MARK: Single attributes

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func count(_ element: AXUIElement, _ attribute: String) -> Int? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success else { return nil }
        return count
    }

    static func rows(of table: AXUIElement) -> [AXUIElement] {
        if let rows = attribute(table, kAXRowsAttribute) as? [AXUIElement], !rows.isEmpty {
            return rows
        }
        return children(table).filter { read($0).snapshot.role == AXRoleName.row }
    }

    static func rowCount(of table: AXUIElement) -> Int {
        if let count = count(table, kAXRowsAttribute), count > 0 {
            return count
        }
        return rows(of: table).count
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        read(element).snapshot.frame
    }

    static func doubleValue(_ element: AXUIElement) -> Double? {
        (attribute(element, kAXValueAttribute) as? NSNumber)?.doubleValue
    }

    static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func setMessagingTimeout(_ element: AXUIElement, seconds: Float) {
        _ = AXUIElementSetMessagingTimeout(element, seconds)
    }

    // MARK: Changes (attribute sets and actions only; never input events)

    @discardableResult
    static func setNumber(_ element: AXUIElement, _ name: String, _ value: Double) -> AXError {
        AXUIElementSetAttributeValue(element, name as CFString, NSNumber(value: value))
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    // MARK: Value conversion

    private static func isAXError(_ value: AnyObject) -> Bool {
        CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError
    }

    private static func axValue(_ value: AnyObject) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        return AXValueGetType(axValue) == .axError ? nil : axValue
    }

    private static func string(_ value: AnyObject) -> String? {
        if isAXError(value) { return nil }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
