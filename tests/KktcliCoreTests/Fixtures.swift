import CoreGraphics
@testable import KktcliCore

/// Builders for synthetic AX snapshots shaped like KakaoTalk 26.10 dumps.
enum Fixture {
    static let transcriptFrame = CGRect(x: 0, y: 0, width: 380, height: 600)

    static func node(
        _ role: String,
        id: String = "",
        value: String? = nil,
        title: String? = nil,
        desc: String? = nil,
        frame: CGRect? = nil,
        depth: Int = 2
    ) -> AXNodeSnapshot {
        AXNodeSnapshot(role: role, identifier: id, value: value, title: title, desc: desc, frame: frame, depth: depth)
    }

    static func row(_ children: [AXNodeSnapshot]) -> TranscriptRow {
        TranscriptRow(nodes: [node("AXRow", depth: 0), node("AXCell", depth: 1)] + children)
    }

    static func dateSeparator(_ text: String) -> TranscriptRow {
        row([node("AXButton", desc: text, frame: CGRect(x: 120, y: 0, width: 140, height: 20))])
    }

    /// First message of another person's run: profile button, name, body, optional meta to the right.
    static func otherFirst(_ name: String, _ body: String, meta: String? = nil) -> TranscriptRow {
        var children = [
            node("AXButton", desc: "프로필", frame: CGRect(x: 8, y: 0, width: 36, height: 36)),
            node("AXStaticText", value: name, frame: CGRect(x: 52, y: 0, width: 80, height: 16)),
            node("AXTextArea", value: body, frame: CGRect(x: 52, y: 18, width: 180, height: 30)),
        ]
        if let meta {
            children.append(node("AXStaticText", value: meta, frame: CGRect(x: 236, y: 34, width: 70, height: 14)))
        }
        return row(children)
    }

    /// Continuation of another person's run: body (left aligned) and optional meta to the right.
    static func otherNext(_ body: String, meta: String? = nil) -> TranscriptRow {
        var children = [node("AXTextArea", value: body, frame: CGRect(x: 52, y: 0, width: 160, height: 30))]
        if let meta {
            children.append(node("AXStaticText", value: meta, frame: CGRect(x: 216, y: 16, width: 70, height: 14)))
        }
        return row(children)
    }

    /// My message: body right aligned, meta to the LEFT of the body.
    static func mine(_ body: String, meta: String? = nil) -> TranscriptRow {
        var children: [AXNodeSnapshot] = []
        if let meta {
            children.append(node("AXStaticText", value: meta, frame: CGRect(x: 150, y: 16, width: 70, height: 14)))
        }
        children.append(node("AXTextArea", value: body, frame: CGRect(x: 226, y: 0, width: 140, height: 30)))
        return row(children)
    }

    static func system(_ text: String) -> TranscriptRow {
        row([node("AXTextArea", id: "_NS:30", value: text, frame: CGRect(x: 60, y: 0, width: 260, height: 20))])
    }
}
