import Observation

/// Window-level UI state shown in the footer and the menu.
@MainActor
@Observable
final class PanelState {
    var isPinned = false
}
