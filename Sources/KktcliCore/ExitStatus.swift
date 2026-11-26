/// Exit statuses of kktcli commands (documented in USAGE.md). 0 is success and 1 any other
/// failure.
public enum KktcliExitStatus {
    /// UNREAD_REFUSED / UNREAD_UNVERIFIED (`--skip-unread`).
    public static let refused: Int32 = 3
    /// OPEN_CHAT_LIST: the row opens something that is not a chat.
    public static let notAChat: Int32 = 4
    /// CHAT_ID_STALE: the chat_id was retired.
    public static let staleChatID: Int32 = 5
    /// CHAT_AMBIGUOUS: same-name rooms cannot be told apart for this chat_id.
    public static let ambiguousChatID: Int32 = 6
    /// SEND_UNVERIFIED and the other failures once a send started: see the code.
    public static let sendUnverified: Int32 = 8
    /// SEND_DISABLED: sending is off (`kktcli config set send on` turns it on).
    public static let sendDisabled: Int32 = 9
    /// Invalid arguments (EX_USAGE).
    public static let usage: Int32 = 64
    /// KAKAOTALK_IN_USE (EX_TEMPFAIL).
    public static let inUse: Int32 = 75
    /// Ctrl-C / SIGTERM.
    public static let interrupted: Int32 = 130
}
