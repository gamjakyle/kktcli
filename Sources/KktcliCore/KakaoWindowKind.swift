import Foundation

/// What a KakaoTalk window that 채팅방 열기 opened turned out to be.
public enum KakaoWindowKind: Equatable, Sendable {
    /// A chat: transcript (`_NS:32` holding an AXTable) or message input (`_NS:51`).
    case chat
    /// The list of 1:1 open-chat conversations that some "오픈채팅, …" rows open instead of
    /// a chat (KakaoTalk 26.10.0): an untitled window whose scroll area `_NS:14` holds the
    /// table `_NS:18`, one row per conversation with an `_NS:40` title.
    case openChatList(OpenChatList)
    case unknown
}

public struct OpenChatList: Equatable, Sendable {
    public struct Conversation: Equatable, Sendable {
        /// The row's `_NS:40` text (e.g. "대화상대 없음").
        public var title: String
        /// The row's `_NS:69` time label, nil when empty.
        public var time: String?

        public init(title: String, time: String?) {
            self.title = title
            self.time = time
        }
    }

    /// Conversations read from the snapshot (may be fewer than the table's rows when the read
    /// was cut short).
    public var conversations: [Conversation]

    public init(conversations: [Conversation]) {
        self.conversations = conversations
    }
}

/// Classifies a window from a flatten of its subtree: depth 0 is the window, 1 its direct
/// children. Reads only; nothing in the window is ever pressed.
public enum KakaoWindowClassifier {
    public static let transcriptScrollAreaIdentifier = "_NS:32"
    public static let messageInputIdentifier = "_NS:51"
    public static let openChatListScrollAreaIdentifier = "_NS:14"
    public static let openChatListTableIdentifier = "_NS:18"

    public static func classify(_ nodes: [AXNodeSnapshot]) -> KakaoWindowKind {
        if isChat(nodes) {
            return .chat
        }
        // A list only when nothing of a chat window is there, not even an empty transcript.
        let chatIdentifiers: Set<String> = [transcriptScrollAreaIdentifier, messageInputIdentifier]
        if !nodes.contains(where: { chatIdentifiers.contains($0.identifier) }), let list = openChatList(nodes) {
            return .openChatList(list)
        }
        return .unknown
    }

    static func isChat(_ nodes: [AXNodeSnapshot]) -> Bool {
        for index in nodes.indices {
            let node = nodes[index]
            if node.role == AXRoleName.textArea, node.identifier == messageInputIdentifier {
                return true
            }
            if node.depth == 1, node.role == AXRoleName.scrollArea, node.identifier == transcriptScrollAreaIdentifier,
               directChildren(of: index, in: nodes).contains(where: { nodes[$0].role == AXRoleName.table })
            {
                return true
            }
        }
        return false
    }

    /// The direct child scroll area `_NS:14` holding the table `_NS:18` whose rows carry an
    /// `_NS:40` title; nil when there is none or no row shows a title.
    static func openChatList(_ nodes: [AXNodeSnapshot]) -> OpenChatList? {
        for index in nodes.indices {
            let scrollArea = nodes[index]
            guard scrollArea.depth == 1, scrollArea.role == AXRoleName.scrollArea,
                  scrollArea.identifier == openChatListScrollAreaIdentifier
            else {
                continue
            }
            for tableIndex in directChildren(of: index, in: nodes)
                where nodes[tableIndex].role == AXRoleName.table && nodes[tableIndex].identifier == openChatListTableIdentifier
            {
                let conversations = directChildren(of: tableIndex, in: nodes)
                    .filter { nodes[$0].role == AXRoleName.row }
                    .compactMap { conversation(inRow: $0, nodes: nodes) }
                if !conversations.isEmpty {
                    return OpenChatList(conversations: conversations)
                }
            }
        }
        return nil
    }

    private static func conversation(inRow row: Int, nodes: [AXNodeSnapshot]) -> OpenChatList.Conversation? {
        let subtree = TranscriptParser.subtree(of: row, in: nodes).dropFirst()
        let title = subtree.first { nodes[$0].identifier == ChatRowAnalyzer.titleIdentifier }
            .map { nodes[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let title, !title.isEmpty else { return nil }
        let time = subtree.first { nodes[$0].identifier == ChatRowAnalyzer.timeIdentifier }
            .map { nodes[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return OpenChatList.Conversation(title: title, time: (time?.isEmpty ?? true) ? nil : time)
    }

    private static func directChildren(of index: Int, in nodes: [AXNodeSnapshot]) -> [Int] {
        let depth = nodes[index].depth
        var result: [Int] = []
        var cursor = index + 1
        while cursor < nodes.count, nodes[cursor].depth > depth {
            if nodes[cursor].depth == depth + 1 {
                result.append(cursor)
            }
            cursor += 1
        }
        return result
    }
}
