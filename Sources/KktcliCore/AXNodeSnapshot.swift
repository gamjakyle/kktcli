import CoreGraphics
import Foundation

/// A plain-data copy of one accessibility node, captured with a single batched
/// attribute read. The parsers in this module only ever see these snapshots, so
/// they can be tested without KakaoTalk or the Accessibility API.
///
/// `depth` is relative to the element that was flattened (0 = that element).
/// Snapshots produced by a depth-first flatten keep pre-order, so the subtree of
/// the node at index `i` is every following node whose depth is greater than
/// `nodes[i].depth`, up to the next node that is not deeper.
public struct AXNodeSnapshot: Equatable, Sendable {
    public var role: String
    public var subrole: String
    public var identifier: String
    public var value: String?
    public var title: String?
    public var desc: String?
    public var help: String?
    public var frame: CGRect?
    public var depth: Int
    public var childCount: Int
    public var selected: Bool?
    /// The batched read of this node failed (or a flatten ran out of budget here), so the
    /// node's real content is unknown.
    public var readFailed: Bool

    public init(
        role: String,
        subrole: String = "",
        identifier: String = "",
        value: String? = nil,
        title: String? = nil,
        desc: String? = nil,
        help: String? = nil,
        frame: CGRect? = nil,
        depth: Int = 0,
        childCount: Int = 0,
        selected: Bool? = nil,
        readFailed: Bool = false
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.value = value
        self.title = title
        self.desc = desc
        self.help = help
        self.frame = frame
        self.depth = depth
        self.childCount = childCount
        self.selected = selected
        self.readFailed = readFailed
    }

    /// The node's text: its value when non-empty, otherwise its title, otherwise "".
    public var text: String {
        if let value, !value.isEmpty { return value }
        if let title, !title.isEmpty { return title }
        return ""
    }

    /// What a button-like node is labelled with: description, then title, then text.
    public var label: String {
        if let desc, !desc.isEmpty { return desc }
        if let title, !title.isEmpty { return title }
        return text
    }
}

public enum AXRoleName {
    public static let staticText = "AXStaticText"
    public static let textArea = "AXTextArea"
    public static let button = "AXButton"
    public static let image = "AXImage"
    public static let link = "AXLink"
    public static let row = "AXRow"
    public static let cell = "AXCell"
    public static let table = "AXTable"
    public static let scrollArea = "AXScrollArea"
    public static let menu = "AXMenu"
    public static let menuItem = "AXMenuItem"
    public static let window = "AXWindow"
}

extension String {
    var kktTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
