import AppKit
import SillCore
import SillMac
import Testing

@testable import Sill

/// Runs inside the real Sill process (hosted test bundle) against a throwaway database,
/// so the whole capture loop is exercised without any system automation permissions.
@MainActor
@Suite(.serialized)
struct CaptureFlowTests {
    private var app: AppDelegate { AppDelegate.shared }

    private func textView() throws -> MarkdownTextView {
        try #require(app.panel.contentView?.firstDescendant(of: MarkdownTextView.self))
    }

    private func type(_ text: String) throws {
        let textView = try textView()
        textView.insertText(text, replacementRange: NSRange(location: textView.string.utf16.count, length: 0))
    }

    private enum Key {
        case escape, `return`, tab, shiftTab, commandReturn

        var characters: String {
            switch self {
            case .escape: "\u{1B}"
            case .return, .commandReturn: "\r"
            case .tab: "\t"
            case .shiftTab: "\u{19}"
            }
        }
        var keyCode: UInt16 {
            switch self {
            case .escape: 53
            case .return, .commandReturn: 36
            case .tab, .shiftTab: 48
            }
        }
        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .shiftTab: .shift
            case .commandReturn: .command
            default: []
            }
        }
    }

    /// Sends a real key event through NSTextView.keyDown, the same path the keyboard uses.
    private func press(_ key: Key) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: 0,
                windowNumber: app.panel.windowNumber, context: nil,
                characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false,
                keyCode: key.keyCode
            ))
        try textView().keyDown(with: event)
    }

    private func pressEscape() throws {
        try press(.escape)
    }

    private func waitForAutosave() async throws {
        try await Task.sleep(for: .milliseconds(700))
    }

    /// Polls until `condition` holds (database observation delivers asynchronously).
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out waiting for condition")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func usesThrowawayDatabaseAndNeverTakesKeyFocus() {
        #expect(app.databaseURL.path.contains("sill-tests"))
        #expect(app.panel.keyless)
        #expect(!app.panel.isKeyWindow)
    }

    @Test func typingAutosavesAndTheNoteComesBackAfterEscape() async throws {
        app.newNote()
        try type("# Hello from Sill\n- first item")
        #expect(app.model.text == "# Hello from Sill\n- first item")

        try await waitForAutosave()
        let saved = try #require(app.model.note)
        let savedContent = saved.content
        let storedAfterAutosave = try app.store.note(id: saved.id)?.content
        let modelTextAfterAutosave = app.model.text
        #expect(savedContent == "# Hello from Sill\n- first item")
        #expect(storedAfterAutosave == "# Hello from Sill\n- first item")
        #expect(modelTextAfterAutosave == "# Hello from Sill\n- first item")

        try type("\n- second item")
        let viewBeforeEscape = try textView().string
        #expect(viewBeforeEscape == "# Hello from Sill\n- first item\n- second item")
        let modelBeforeEscape = app.model.text
        #expect(modelBeforeEscape == "# Hello from Sill\n- first item\n- second item")
        try pressEscape()
        #expect(!app.panel.isVisible)
        // Esc flushes immediately, without waiting for the debounce.
        let storedAfterEscape = try app.store.note(id: saved.id)?.content
        #expect(storedAfterEscape == "# Hello from Sill\n- first item\n- second item")

        app.showPanel()
        #expect(app.panel.isVisible)
        #expect(app.model.note?.id == saved.id)
        let viewAfterReopen = try textView().string
        #expect(viewAfterReopen == "# Hello from Sill\n- first item\n- second item")
        #expect(app.panel.firstResponder === (try textView()))
    }

    @Test func emptyNewNoteIsNeverStored() async throws {
        let before = try app.store.liveNotes().count
        app.newNote()
        try type("   \n")
        try await waitForAutosave()
        app.hidePanel()

        #expect(app.model.note == nil)
        #expect(try app.store.liveNotes().count == before)
    }

    @Test func listKeysContinueIndentAndToggleItems() throws {
        app.newNote()
        try type("- item")
        try press(.return)
        #expect(try textView().string == "- item\n- ")
        try type("child")
        try press(.tab)
        #expect(try textView().string == "- item\n  - child")
        try press(.shiftTab)
        #expect(try textView().string == "- item\n- child")
        try press(.commandReturn)
        #expect(try textView().string == "- item\n- [ ] child")
        try press(.return)
        #expect(try textView().string == "- item\n- [ ] child\n- [ ] ")
        try press(.return)
        #expect(try textView().string == "- item\n- [ ] child\n")
        #expect(app.model.text == "- item\n- [ ] child\n")

        // List edits go through the undo-aware change path.
        #expect(try textView().undoManager?.canUndo == true)
    }

    @Test func sidebarListsNotesSwitchesAndDeletes() async throws {
        app.newNote()
        try type("first note")
        app.newNote()  // flushes "first note" immediately
        try type("second note")
        try await waitForAutosave()
        let second = try #require(app.model.note)

        if !app.model.isSidebarVisible { app.toggleSidebar() }
        #expect(app.model.isSidebarVisible)
        try await waitUntil { self.app.model.notes.map(\.title).prefix(2) == ["second note", "first note"] }

        let first = try #require(app.model.notes.first { $0.title == "first note" })
        app.model.open(id: first.id)
        #expect(app.model.note?.id == first.id)
        #expect(try textView().string == "first note")

        app.deleteCurrentNote()  // no confirmation dialog in test mode
        #expect(try app.store.note(id: first.id)?.isDeleted == true)
        #expect(app.model.note?.id == second.id)  // moved on to the most recent live note
        #expect(try textView().string == "second note")
        try await waitUntil { !self.app.model.notes.contains { $0.id == first.id } }

        app.toggleSidebar()
        #expect(!app.model.isSidebarVisible)
    }

    @Test func syncedChangesToTheOpenNoteShowUpOrGetCopiedAside() async throws {
        let phone = UUID()
        try app.store.addPeer(id: phone, name: "Phone", fingerprint: Data(repeating: 1, count: 32))
        app.newNote()
        try type("base")
        try await waitForAutosave()
        let open = try #require(app.model.note)

        // Clean editor + remote version → the editor shows it.
        var remote = open
        remote.content = "edited on the phone"
        remote.version = Version(device: phone, seq: 1)
        try app.store.apply(
            [remote], senderID: phone, senderName: "Phone",
            senderVector: VersionVector([phone: 1, app.store.deviceID: open.version.seq]))
        try await waitUntil { (try? self.textView().string) == "edited on the phone" }
        #expect(app.model.note?.version == remote.version)

        // Dirty editor + remote version → keep typing, remote text copied aside, nothing lost.
        try type(" plus local")
        var newer = remote
        newer.content = "phone wrote more"
        newer.version = Version(device: phone, seq: 2)
        try app.store.apply(
            [newer], senderID: phone, senderName: "Phone",
            senderVector: VersionVector([phone: 2, app.store.deviceID: open.version.seq]))
        try await waitUntil { self.app.model.notes.contains { $0.content == "phone wrote more (Conflict from Phone)" } }
        #expect(try textView().string == "edited on the phone plus local")
        try await waitForAutosave()
        #expect(try app.store.note(id: open.id)?.content == "edited on the phone plus local")
        #expect(try app.store.note(id: open.id)?.version.device == app.store.deviceID)
        try app.store.removePeer(id: phone)
    }

    @Test func pinnedPanelStaysWhenAnotherWindowTakesFocus() async throws {
        app.showPanel()
        app.setPinned(true)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: app.panel)
        #expect(app.panel.isVisible)
        #expect(app.panelState.isPinned)

        app.setPinned(false)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: app.panel)
        #expect(!app.panel.isVisible)
        app.showPanel()
    }

    @Test func showingThePanelAgainIsFast() async throws {
        app.showPanel()
        app.hidePanel()
        try await Task.sleep(for: .milliseconds(50))
        app.showPanel()
        let latency = try #require(app.lastShowLatency)
        #expect(latency < .milliseconds(100), "panel show took \(latency)")
    }

    @Test func copyAsMarkdownPutsTheRawTextOnThePasteboard() throws {
        app.newNote()
        let markdown = "- [ ] todo\n\n```swift\nlet x = \"quoted\" -- dash\n```"
        try type(markdown)
        app.copyAsMarkdown()
        #expect(NSPasteboard.general.string(forType: .string) == markdown)
    }

    @Test func editorNeverRewritesWhatWasTyped() throws {
        let textView = try textView()
        #expect(textView.isRichText == false)
        #expect(textView.isAutomaticQuoteSubstitutionEnabled == false)
        #expect(textView.isAutomaticDashSubstitutionEnabled == false)
        #expect(textView.isAutomaticTextReplacementEnabled == false)
        #expect(textView.isAutomaticSpellingCorrectionEnabled == false)
        #expect(textView.smartInsertDeleteEnabled == false)
    }

    @Test func globalShortcutIsRegisteredAsOptionS() {
        #expect(KeyboardShortcuts.getShortcut(for: .togglePanel) == .init(.s, modifiers: [.option]))
    }

    @Test func panelStaysOutOfTheWayOfOtherApps() {
        app.showPanel()
        #expect(app.panel.styleMask.contains(.nonactivatingPanel))
        #expect(app.panel.level == .floating)
        #expect(app.panel.collectionBehavior.contains(.managed))
        #expect(app.panel.collectionBehavior.contains(.moveToActiveSpace))
    }
}
