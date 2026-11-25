import Foundation

/// The chat list's state, observed when the wanted row was not found in it.
///
/// KakaoTalk for Mac 26.10.0 keeps a search filter on the chat list:
/// - visible search: an AXTextField (subrole AXSearchField, id `_NS:20`) holds the query; inside
///   it an AXButton described "취소" clears the text and another described "검색" sits next to it.
///   A top-bar AXButton described "검색" (a direct child of the main window) toggles search mode;
///   after clearing the text the list stays empty until that toggle is pressed.
/// - hidden filter: no field is visible, yet the list shows only the rows of an old query.
///   Pressing the top-bar toggle shows the field again with the old text.
public struct ChatListObservation: Equatable, Sendable {
    public var rowCount: Int
    public var searchFieldVisible: Bool
    public var searchText: String?
    public var hasClearButton: Bool
    public var hasSearchToggle: Bool
    /// Rows earlier scans have seen (highest registry last-seen index + 1), when known.
    public var registryRowCount: Int?
    /// The wanted room's last-seen row index (`--chat-id`), when known.
    public var targetLastSeenIndex: Int?

    public init(
        rowCount: Int,
        searchFieldVisible: Bool,
        searchText: String?,
        hasClearButton: Bool,
        hasSearchToggle: Bool,
        registryRowCount: Int? = nil,
        targetLastSeenIndex: Int? = nil
    ) {
        self.rowCount = rowCount
        self.searchFieldVisible = searchFieldVisible
        self.searchText = searchText
        self.hasClearButton = hasClearButton
        self.hasSearchToggle = hasSearchToggle
        self.registryRowCount = registryRowCount
        self.targetLastSeenIndex = targetLastSeenIndex
    }
}

public enum ChatListRecoveryStep: String, Equatable, Sendable {
    /// AXPress on the AXButton described "취소" inside the search field (clears the query).
    case pressClear = "취소"
    /// AXPress on the main window's top-bar AXButton described "검색" (toggles search mode).
    case pressSearchToggle = "검색"
}

public enum ChatListRecoveryPlan: Equatable, Sendable {
    case none(reason: String)
    /// The search field is visible: clear it (when it has text), then toggle search mode off.
    case leaveVisibleSearch([ChatListRecoveryStep])
    /// No field is visible but the list looks filtered: toggle once to reveal the field, then
    /// continue with `ChatListRecovery.stepsAfterReveal`.
    case revealHiddenSearch
}

public enum ChatListRecovery {
    /// A list this short is treated as possibly filtered when the wanted row is missing.
    public static let shortListRowCount = 20

    /// Called only after the wanted row was not found.
    public static func plan(_ observation: ChatListObservation) -> ChatListRecoveryPlan {
        guard observation.hasSearchToggle else {
            return .none(reason: "the main window has no 검색 toggle")
        }
        if observation.searchFieldVisible {
            guard hasText(observation.searchText) else {
                return .leaveVisibleSearch([.pressSearchToggle])
            }
            guard observation.hasClearButton else {
                return .none(reason: "the search field has text but no 취소 button")
            }
            return .leaveVisibleSearch([.pressClear, .pressSearchToggle])
        }
        if listLooksFiltered(observation) {
            return .revealHiddenSearch
        }
        return .none(reason: "the list does not look filtered")
    }

    public static func listLooksFiltered(_ observation: ChatListObservation) -> Bool {
        let rows = observation.rowCount
        if rows == 0 {
            return true
        }
        if let index = observation.targetLastSeenIndex, index >= rows {
            return true
        }
        if let known = observation.registryRowCount, known >= rows * 2, known - rows >= 5 {
            return true
        }
        return rows <= shortListRowCount
    }

    /// After the toggle revealed the field: an old query is cleared and search mode toggled off
    /// again; with no query (nothing was filtered) the toggle is only pressed again to restore
    /// the previous state. Without a 취소 button the toggle restores the previous state too.
    public static func stepsAfterReveal(searchText: String?, hasClearButton: Bool) -> [ChatListRecoveryStep] {
        if hasText(searchText), hasClearButton {
            return [.pressClear, .pressSearchToggle]
        }
        return [.pressSearchToggle]
    }

    private static func hasText(_ text: String?) -> Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The only controls chat-list recovery may press (AXPress). Nothing is typed, Enter is never
/// sent, and no other element is pressed.
public enum ChatListControls {
    public static let searchFieldRole = "AXTextField"
    public static let searchFieldSubrole = "AXSearchField"
    public static let searchFieldIdentifier = "_NS:20"
    public static let clearButtonDescription = "취소"
    public static let searchToggleDescription = "검색"

    public static func isSearchField(_ node: AXNodeSnapshot) -> Bool {
        node.role == searchFieldRole && node.subrole == searchFieldSubrole
    }

    /// The "취소" button inside the search field.
    public static func isClearButton(_ node: AXNodeSnapshot, insideSearchField: Bool) -> Bool {
        insideSearchField && node.role == AXRoleName.button && node.desc == clearButtonDescription
    }

    /// The top-bar "검색" toggle: a direct child of the main window, never the "검색" button
    /// inside the search field.
    public static func isSearchToggle(_ node: AXNodeSnapshot, isDirectChildOfMainWindow: Bool) -> Bool {
        isDirectChildOfMainWindow && node.role == AXRoleName.button && node.desc == searchToggleDescription
    }
}

/// The only menu item that may be pressed to bring back a closed main window: KakaoTalk's
/// menu-extra item "카카오톡 열기" (`showFirstWindow:`).
public enum MainWindowMenuItem {
    public static let identifier = "showFirstWindow:"
    public static let title = "카카오톡 열기"

    public static func isShowMainWindowItem(_ node: AXNodeSnapshot) -> Bool {
        node.role == AXRoleName.menuItem && node.identifier == identifier && node.title == title
    }
}
