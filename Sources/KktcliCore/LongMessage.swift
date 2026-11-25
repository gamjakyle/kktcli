import CoreGraphics
import Foundation

/// Long messages on KakaoTalk for Mac 26.10: the bubble shows the beginning of the text,
/// ends it with "…" (U+2026), and a "전체보기" (see all) control sits right below the text.
///
/// Observed in AX dumps of 26.10.0 (4 cut messages): the bubble's AXTextArea value was 501
/// Unicode scalars (500 + "…"), and the control was an AXButton WITHOUT title, description,
/// help, identifier or value, 35 pt tall, about as wide as the text and starting where the text
/// area ends. A 498-character message that was not cut had neither the "…" nor the button.
public enum LongMessage {
    public static let ellipsis = "\u{2026}"
    /// Characters KakaoTalk shows before the "…".
    public static let visibleLimit = 500
    /// The control's label, should a KakaoTalk build expose one.
    public static let seeAllLabel = "전체보기"

    /// The text ends with "…" and is about as long as the visible limit (in whatever unit
    /// KakaoTalk counts: at least ~450 UTF-16 units, at most ~520 characters).
    public static func looksCut(_ text: String) -> Bool {
        text.hasSuffix(ellipsis) && text.utf16.count >= visibleLimit - 50 && text.count <= visibleLimit + 20
    }

    /// KakaoTalk's exact cut: the visible limit plus the "…".
    public static func isExactCut(_ text: String) -> Bool {
        guard text.hasSuffix(ellipsis) else { return false }
        let cut = visibleLimit + 1
        return text.count == cut || text.unicodeScalars.count == cut || text.utf16.count == cut
    }

    /// The node is the see-all control of the text area framed `textFrame`: a button or link
    /// labelled exactly "전체보기", or an unlabeled button right below the text and about as
    /// wide as it.
    public static func isSeeAllControl(_ node: AXNodeSnapshot, textFrame: CGRect?) -> Bool {
        guard node.role == AXRoleName.button || node.role == AXRoleName.link else { return false }
        let labels = [node.title, node.desc, node.help]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if labels.contains(seeAllLabel) {
            return true
        }
        guard node.role == AXRoleName.button, labels.isEmpty, node.identifier.isEmpty,
              (node.value ?? "").isEmpty, node.childCount == 0,
              let textFrame, let frame = node.frame
        else {
            return false
        }
        return isRightBelow(frame, textFrame: textFrame)
    }

    static func isRightBelow(_ frame: CGRect, textFrame: CGRect) -> Bool {
        abs(frame.minY - textFrame.maxY) <= 6
            && frame.height >= 24 && frame.height <= 48
            && abs(frame.minX - textFrame.minX) <= 20
            && frame.width >= textFrame.width * 0.8 && frame.width <= textFrame.width + 40
    }

    /// The message text is cut: it looks cut and the see-all control is there, or it is
    /// KakaoTalk's exact cut (in case the control could not be read).
    public static func isTruncated(text: String, hasSeeAllControl: Bool) -> Bool {
        guard looksCut(text) else { return false }
        return hasSeeAllControl || isExactCut(text)
    }

    /// Index (into `nodes`) of the see-all control for the text area at `textIndex`, among the
    /// cell's direct children (`depth` 2) of one transcript row.
    public static func seeAllControl(for textIndex: Int, in nodes: [AXNodeSnapshot]) -> Int? {
        let depth = nodes[textIndex].depth
        let textFrame = nodes[textIndex].frame
        return nodes.indices.first { index in
            index != textIndex && nodes[index].depth == depth && isSeeAllControl(nodes[index], textFrame: textFrame)
        }
    }

    /// `candidate` is the full text of the message whose bubble shows `cut`: longer than the
    /// visible part and starting with it (compared without spacing, punctuation and symbols,
    /// minus the last few characters, which the cut may split).
    public static func isFullText(_ candidate: String, of cut: String) -> Bool {
        let visible = cut.hasSuffix(ellipsis) ? String(cut.dropLast()) : cut
        guard candidate.count > visible.count else { return false }
        let prefix = ChatQueryMatcher.normalize(visible)
        let full = ChatQueryMatcher.normalize(candidate)
        let required = String(prefix.dropLast(min(3, prefix.count / 10)))
        guard required.count >= 20 else { return false }
        return full.hasPrefix(required) && full.count > prefix.count
    }
}
