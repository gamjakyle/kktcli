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

    /// A row as KakaoTalk exposes it: the AXRow and its AXCell carry the row's frame, which
    /// the parser measures the content against.
    static func row(_ children: [AXNodeSnapshot]) -> TranscriptRow {
        TranscriptRow(nodes: [
            node("AXRow", frame: transcriptFrame, depth: 0),
            node("AXCell", frame: transcriptFrame, depth: 1),
        ] + children)
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

/// Rows with the geometry of a live KakaoTalk 26.10.0 dump (2026-11-27): a 380 pt wide row
/// whose AXRow/AXCell frames start at `x`; the profile button is a 36 pt square 10 pt in, the
/// name 55 pt in, other people's bubbles start 60 pt in, mine end 18 pt before the right edge
/// with the meta label to their left. Texts are placeholders.
enum LiveRow {
    static let width: CGFloat = 380

    static func row(x: CGFloat, y: CGFloat = 0, height: CGFloat = 36, _ children: [AXNodeSnapshot]) -> TranscriptRow {
        let frame = CGRect(x: x, y: y, width: width, height: height)
        return TranscriptRow(nodes: [
            Fixture.node("AXRow", frame: frame, depth: 0),
            Fixture.node("AXCell", frame: frame, depth: 1),
        ] + children)
    }

    /// Another person's first message: profile button (described "프로필" unless `profileDesc`
    /// is nil), name, bubble and optional meta to the right of the bubble.
    static func otherFirst(x: CGFloat, _ name: String, _ body: String, bodyWidth: CGFloat = 150, meta: String? = nil, profileDesc: String? = "프로필") -> TranscriptRow {
        var children = [
            Fixture.node("AXButton", desc: profileDesc, frame: CGRect(x: x + 10, y: 10, width: 36, height: 36)),
            Fixture.node("AXStaticText", value: name, frame: CGRect(x: x + 55, y: 9, width: 36, height: 18)),
            Fixture.node("AXTextArea", value: body, frame: CGRect(x: x + 60, y: 43, width: bodyWidth, height: 16)),
        ]
        if let meta {
            children.append(Fixture.node("AXStaticText", value: meta, frame: CGRect(x: x + 60 + bodyWidth + 9, y: 49, width: 48, height: 16)))
        }
        return row(x: x, height: 65, children)
    }

    /// Another person's next message: bubble 60 pt in, optional meta to its right, optional
    /// reaction buttons (24 pt) below it.
    static func otherNext(x: CGFloat, _ body: String, bodyWidth: CGFloat = 150, meta: String? = nil, reactions: Bool = false) -> TranscriptRow {
        var children = [Fixture.node("AXTextArea", value: body, frame: CGRect(x: x + 60, y: 13, width: bodyWidth, height: 16))]
        if let meta {
            children.append(Fixture.node("AXStaticText", value: meta, frame: CGRect(x: x + 60 + bodyWidth + 9, y: 19, width: 48, height: 16)))
        }
        if reactions {
            children.append(Fixture.node("AXButton", frame: CGRect(x: x + 95, y: 39, width: 24, height: 24)))
            children.append(Fixture.node("AXButton", frame: CGRect(x: x + 121, y: 39, width: 24, height: 24)))
        }
        return row(x: x, height: reactions ? 65 : 36, children)
    }

    /// My message: bubble ending 18 pt before the right edge, optional meta to its left.
    static func mine(x: CGFloat, _ body: String, bodyWidth: CGFloat = 90, meta: String? = nil) -> TranscriptRow {
        let bubbleX = x + width - 18 - bodyWidth
        var children: [AXNodeSnapshot] = []
        if let meta {
            children.append(Fixture.node("AXStaticText", value: meta, frame: CGRect(x: bubbleX - 58, y: 19, width: 48, height: 16)))
        }
        children.append(Fixture.node("AXTextArea", value: body, frame: CGRect(x: bubbleX, y: 13, width: bodyWidth, height: 16)))
        return row(x: x, children)
    }

    /// A shared card I sent: card buttons, artwork, a title static text and a caption, right
    /// aligned like my bubbles, no meta.
    static func myCard(x: CGFloat, title: String, caption: String) -> TranscriptRow {
        row(x: x, height: 398, [
            Fixture.node("AXButton", title: "버튼", frame: CGRect(x: x + 156, y: 4, width: 212, height: 395)),
            Fixture.node("AXImage", frame: CGRect(x: x + 156, y: 44, width: 212, height: 275)),
            Fixture.node("AXImage", frame: CGRect(x: x + 166, y: 17, width: 17, height: 17)),
            Fixture.node("AXStaticText", value: title, frame: CGRect(x: x + 187, y: 16, width: 171, height: 18)),
            Fixture.node("AXTextArea", value: caption, frame: CGRect(x: x + 167, y: 328, width: 190, height: 13)),
        ])
    }
}
