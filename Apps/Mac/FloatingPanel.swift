import AppKit

/// Compact floating scratchpad window. Non-activating: it becomes key without
/// activating Sill, so the app the user was in stays in front and gets focus back on Esc.
final class FloatingPanel: NSPanel {
    var onHide: (() -> Void)?
    /// Esc pressed while focus is outside the text view (e.g. in the sidebar).
    var onEscape: (() -> Void)?
    /// Test mode: show without becoming key, so keystrokes meant for other apps never land here.
    var keyless = false
    /// Pinned: stays on screen when another window takes focus (it is always on top anyway).
    var isPinned: Bool {
        get { UserDefaults.standard.bool(forKey: "panelPinned") }
        set { UserDefaults.standard.set(newValue, forKey: "panelPinned") }
    }

    private static let frameName = "SillPanel"

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // `.managed` keeps the panel in Mission Control; `.canJoinAllSpaces` would drop it from Exposé.
        // `.moveToActiveSpace` brings it to whichever Space the hotkey is pressed on.
        collectionBehavior = [.moveToActiveSpace, .managed, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 320, height: 200)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        self.contentView = contentView

        let hasSavedFrame = UserDefaults.standard.object(forKey: "NSWindow Frame \(Self.frameName)") != nil
        setFrameAutosaveName(Self.frameName)
        if !hasSavedFrame { center() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
    }

    override var canBecomeKey: Bool { !keyless }
    override var canBecomeMain: Bool { false }

    func show() {
        if keyless {
            orderFrontRegardless()
        } else {
            makeKeyAndOrderFront(nil)
        }
        if let textView = contentView?.firstDescendant(of: NSTextView.self) {
            makeFirstResponder(textView)
        }
    }

    /// Always flushes, even if the panel was already hidden by losing key status.
    func hide() {
        onHide?()
        if isVisible { orderOut(nil) }
    }

    /// Clicking anywhere else hides the panel, unless it is pinned.
    @objc private func didResignKey() {
        guard !isPinned else { return }
        hide()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
