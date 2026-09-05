#if os(macOS)
    // Re-exported so the app imports one module for its Mac-only dependencies.
    @_exported import KeyboardShortcuts
    import SillCore

    extension KeyboardShortcuts.Name {
        /// ⌥S by default. Changeable from Settings.
        public static let togglePanel = Self("togglePanel", initial: .init(.s, modifiers: [.option]))
    }
#endif
