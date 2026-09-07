import AppKit
import SillCore
import SillMac
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI wraps the real `NSApp.delegate`, so tests reach the app through this instead.
    private(set) static var shared: AppDelegate!

    private(set) var databaseURL: URL!
    private(set) var store: NoteStore!
    private(set) var model: EditorModel!
    private(set) var panel: FloatingPanel!
    private(set) var sync: MacSync?
    let panelState = PanelState()
    private let signposter = OSSignposter(subsystem: "com.mrskiro.sill", category: "panel")
    private let log = Logger(subsystem: "com.mrskiro.sill", category: "panel")

    private static var identityLabel: String {
        isTestMode ? "com.mrskiro.sill.device-identity.test" : "com.mrskiro.sill.device-identity"
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tests must not steal the user's focus: no Dock icon, no activation on launch.
        if Self.isTestMode { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        databaseURL = Self.resolveDatabaseURL()
        do {
            let database = try AppDatabase.open(at: databaseURL)
            store = try NoteStore(database: database, deviceName: Host.current().localizedName ?? "Mac")
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        let model = EditorModel(store: store)
        self.model = model
        model.startObservingNotes()

        do {
            let identityStore = IdentityStore(label: Self.identityLabel)
            if Self.isTestMode { try? identityStore.delete() }  // fresh identity per test run
            let identity = try identityStore.loadOrCreate(deviceID: store.deviceID)
            let sync = MacSync(store: store, identity: identity, advertise: !Self.isTestMode)
            self.sync = sync
            sync.start()
            model.onSaved = { sync.poke() }
        } catch {
            NSLog("Sill: sync unavailable: \(error)")
        }

        let screen = EditorScreen(
            model: model, sync: sync, panelState: panelState,
            onEscape: { [weak self] in self?.hidePanel() },
            onNewNote: { [weak self] in self?.newNote() }
        )
        panel = FloatingPanel(contentView: NSHostingView(rootView: screen))
        panelState.isPinned = panel.isPinned
        panel.onHide = { model.flush() }
        panel.onEscape = { [weak self] in self?.hidePanel() }
        panel.keyless = Self.isTestMode

        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in
            MainActor.assumeIsolated { self?.togglePanel() }
        }
        showPanel()
    }

    /// Dock icon click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    /// ⌘Tab back to Sill.
    func applicationDidBecomeActive(_ notification: Notification) {
        if let panel, !panel.isVisible { showPanel() }
    }

    /// `sill://debug/...` commands, only when launched with SILL_DEBUG=1 (real-device sync checks).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard ProcessInfo.processInfo.environment["SILL_DEBUG"] == "1" else { return }
        for url in urls where url.scheme == "sill" && url.host == "debug" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch url.path {
            case "/create":
                if let content = query.first(where: { $0.name == "content" })?.value,
                    let note = try? store.createNote(content: content)
                {
                    SyncLog.write("debug: created note \(note.id)")
                    sync?.poke()
                }
            case "/settings":
                NSApp.activate()
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            case "/delete":
                if let prefix = query.first(where: { $0.name == "title" })?.value, let notes = try? store.liveNotes() {
                    for note in notes where note.title.hasPrefix(prefix) { try? store.deleteNote(id: note.id) }
                    SyncLog.write("debug: deleted notes titled \(prefix)*")
                    sync?.poke()
                }
            default:
                break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.flush()
        sync?.stop()
        if Self.isTestMode { try? IdentityStore(label: Self.identityLabel).delete() }
    }

    func togglePanel() {
        if panel.isKeyWindow { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        let start = ContinuousClock.now
        let state = signposter.beginInterval("Show panel")
        model.loadLastNoteIfNeeded()
        // After Esc from a Dock/⌘Tab activation the app is hidden; bring the panel back
        // without stealing activation from whatever the user is doing now.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        panel.show()
        signposter.endInterval("Show panel", state)
        let elapsed = ContinuousClock.now - start
        lastShowLatency = elapsed
        log.info("panel shown in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// Hotkey → panel on screen with the editor focused. Watched by tests; goal < 100 ms.
    private(set) var lastShowLatency: Duration?

    func setPinned(_ pinned: Bool) {
        panel.isPinned = pinned
        panelState.isPinned = pinned
    }

    func hidePanel() {
        panel.hide()
        // Give focus back to the previous app when Sill had been activated via Dock or ⌘Tab.
        if NSApp.isActive { NSApp.hide(nil) }
    }

    func newNote() {
        showPanel()
        model.newNote()
    }

    func copyAsMarkdown() {
        model.copyAsMarkdown()
    }

    /// File ▸ Export Notes…: pick where it goes, and a `Sill Notes` folder appears there holding
    /// one `.md` file per note.
    ///
    /// A folder chooser rather than a save panel: typing a name that already exists into a save
    /// panel makes it navigate into that folder instead of returning it, and the Replace it offers
    /// covers the folder, never the files inside one.
    ///
    /// The app's own window is non-activating, so without activating first the modal can open
    /// behind whatever the user was working in.
    func exportNotes() {
        NSApp.activate()
        let openPanel = NSOpenPanel()
        openPanel.message = "Choose where to put a folder of Markdown files, one per note."
        openPanel.prompt = "Export"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        guard openPanel.runModal() == .OK, let parent = openPanel.url else { return }
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try exportNotes(into: parent)])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Writes into a folder that did not exist a moment ago, so nothing of the user's is ever
    /// overwritten, and a run that fails part way leaves nothing behind rather than a folder holding
    /// some of the notes. The note being typed into is saved first, so what is on screen is in it.
    @discardableResult
    func exportNotes(into parent: URL) throws -> URL {
        model.flush()
        let directory = MarkdownExport.availableDirectory(in: parent, named: "Sill Notes")
        // Create it here, and refuse to create it over anything: only then is the folder provably
        // ours, which is what earns the right to delete it again below. Asking for intermediate
        // directories would quietly accept an entry that is already sitting at that path.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try MarkdownExport.write(store.liveNotes(), to: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return directory
    }

    func format(_ command: (String, NSRange) -> TextEdit?) {
        model.format(command)
    }

    func toggleSidebar() {
        showPanel()
        model.toggleSidebar()
    }

    func deleteCurrentNote() {
        guard model.note != nil || !model.text.isEmpty else { return }
        if !Self.isTestMode {
            let alert = NSAlert()
            alert.messageText = "Delete this note?"
            alert.informativeText = "The note is removed from every synced device. This cannot be undone."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.deleteCurrentNote()
    }

    /// `SILL_TEST_MODE=1` (set by the test scheme): throwaway database, panel never takes key focus.
    static var isTestMode: Bool {
        ProcessInfo.processInfo.environment["SILL_TEST_MODE"] == "1"
    }

    private static func resolveDatabaseURL() -> URL {
        if isTestMode {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("sill-tests/\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("sill.sqlite")
        }
        return AppDatabase.defaultURL()
    }
}
