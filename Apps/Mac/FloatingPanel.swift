import AppKit

/// Compact floating scratchpad window. Showing or clicking it activates Sill, so the menu bar
/// carries Sill's menus; Esc hides the app again and focus returns to where the user was.
/// It floats above other windows and stays put when they are clicked — a flow note is written
/// next to whatever it came from — until Esc, the hotkey, or the close button puts it away.
final class FloatingPanel: NSPanel {
    var onHide: (() -> Void)?
    /// Esc pressed while focus is outside the text view (e.g. in the sidebar), or the close button / ⌘W.
    var onEscape: (() -> Void)?
    /// Test mode: show without becoming key, so keystrokes meant for other apps never land here.
    var keyless = false

    private static let frameName = "SillPanel"

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable],
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
        self.contentView = contentView

        let hasSavedFrame = UserDefaults.standard.object(forKey: "NSWindow Frame \(Self.frameName)") != nil
        setFrameAutosaveName(Self.frameName)
        if !hasSavedFrame { center() }

        // Settings is a normal-level window, so it would open under the floating panel and could
        // not be clicked in front of it. While another normal window of Sill's is in use the panel
        // steps down to the same level, and floats again once that window closes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(otherWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(otherWindowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func otherWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window !== self, window.level == .normal else { return }
        level = .normal
    }

    @objc private func otherWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window !== self, window.level == .normal else { return }
        level = .floating
    }

    override var canBecomeKey: Bool { !keyless }
    override var canBecomeMain: Bool { false }

    func show() {
        if isMiniaturized { deminiaturize(nil) }
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

    override func miniaturize(_ sender: Any?) {
        onHide?()  // save on the way to the Dock, like every other way out
        super.miniaturize(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// The close button and ⌘W hide the panel the way Esc does; the single window is never torn down.
    override func close() {
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
