import Observation
import SillCore
import SwiftUI
import os

/// Where the app is: the list, or one note's editor. A new note has no id until it is saved.
enum Destination: Hashable {
    case existing(UUID)
    case new(UUID)  // draft token, so two "new" pushes are distinct
}

@MainActor
@Observable
final class PhoneModel {
    /// Hosted tests reach the app through this.
    static var shared: PhoneModel!

    let store: NoteStore
    let databaseURL: URL
    private(set) var sync: PhoneSync?
    private(set) var notes: [Note] = []
    var path: [Destination] = []
    var showPairing = false

    @ObservationIgnored private var drafts: [Destination: NoteDraft] = [:]
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.mrskiro.sill", category: "phone")

    static var isTestMode: Bool {
        ProcessInfo.processInfo.environment["SILL_TEST_MODE"] == "1"
    }

    private static var identityLabel: String {
        isTestMode ? "com.mrskiro.sill.device-identity.test" : "com.mrskiro.sill.device-identity"
    }

    static func make() throws -> PhoneModel {
        let url =
            isTestMode
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("sill-tests/\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("sill.sqlite")
            : AppDatabase.defaultURL()
        let database = try AppDatabase.open(at: url)
        let store = try NoteStore(database: database, deviceName: UIDevice.current.name)
        return PhoneModel(store: store, databaseURL: url)
    }

    init(store: NoteStore, databaseURL: URL) {
        self.store = store
        self.databaseURL = databaseURL
        do {
            let identityStore = IdentityStore(label: Self.identityLabel)
            if Self.isTestMode { try? identityStore.delete() }
            let identity = try identityStore.loadOrCreate(deviceID: store.deviceID)
            sync = PhoneSync(store: store, identity: identity)
        } catch {
            log.error("sync unavailable: \(error)")
        }
        startObserving()
        openLastNoteOnLaunch()
        applyAutotestHooks()
    }

    /// `devicectl … launch -e '{"SILL_AUTOTEST_NOTE": "…"}'` creates a note on launch so a
    /// real-device sync check can run without anyone typing on the phone.
    /// `SILL_AUTOTEST_SCREEN=list|sync` lands on that screen instead of the last note, for
    /// `scripts/app-store-screenshots.sh`, which has no way to tap.
    private func applyAutotestHooks() {
        let environment = ProcessInfo.processInfo.environment
        if let content = environment["SILL_AUTOTEST_NOTE"], !content.isEmpty {
            if let note = try? store.createNote(content: content) {
                SyncLog.write("autotest: created note \(note.id)")
                sync?.localChanged()
            }
        }
        switch environment["SILL_AUTOTEST_SCREEN"] {
        case "list": path = []
        case "sync":
            path = []
            showPairing = true
        default: break
        }
    }

    private func startObserving() {
        observationTask = Task { [weak self, store] in
            do {
                for try await notes in store.observeLiveNotes() {
                    self?.notes = notes
                    self?.reconcileDrafts()
                }
            } catch {
                self?.log.error("note observation failed: \(error)")
            }
        }
    }

    /// Launch lands in the editor: the last note, or an empty new one.
    func openLastNoteOnLaunch() {
        if let last = try? store.lastEditedNote() {
            path = [.existing(last.id)]
        } else {
            path = [.new(UUID())]
        }
    }

    func openNote(id: UUID) {
        path.append(.existing(id))
    }

    func newNote() {
        path.append(.new(UUID()))
    }

    func deleteNote(id: UUID) {
        do {
            try store.deleteNote(id: id)
            sync?.localChanged()
        } catch {
            log.error("delete failed: \(error)")
        }
    }

    /// The editor session for a destination; created on first use, kept while it is on the stack.
    func draft(for destination: Destination) -> NoteDraft {
        if let draft = drafts[destination] { return draft }
        let note: Note? = if case .existing(let id) = destination { try? store.note(id: id) } else { nil }
        let draft = NoteDraft(store: store, note: note)
        draft.onSaved = { [weak self] in self?.sync?.localChanged() }
        drafts[destination] = draft
        return draft
    }

    /// Sync changed a note that is open in an editor.
    private func reconcileDrafts() {
        for draft in drafts.values {
            draft.reconcile()
        }
    }

    /// Called when a destination leaves the stack, and when the app goes to the background.
    func flush(_ destination: Destination? = nil) {
        if let destination {
            drafts[destination]?.flush()
            if !path.contains(destination) { drafts[destination] = nil }
        } else {
            for draft in drafts.values { draft.flush() }
        }
    }
}

/// One note being edited on the phone: lazy creation, debounced autosave, explicit flush.
@MainActor
@Observable
final class NoteDraft: Identifiable {
    let id = UUID()
    private let store: NoteStore
    private(set) var note: Note?
    var text: String {
        didSet { if text != oldValue { scheduleSave() } }
    }

    @ObservationIgnored var onSaved: (() -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.mrskiro.sill", category: "draft")

    init(store: NoteStore, note: Note?) {
        self.store = store
        self.note = note
        text = note?.content ?? ""
    }

    /// See `OpenNoteReconciliation`: show a synced version, or keep typing and copy it aside.
    func reconcile() {
        guard let open = note else { return }
        let current = try? store.note(id: open.id)
        switch OpenNoteReconciliation.decide(open: open, editorText: text, current: current) {
        case .unchanged:
            break
        case .reload(let latest):
            note = latest
            text = latest.content
        case .deletedRemotely:
            note = nil
            text = ""
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        do {
            if let existing = note {
                if let result = try store.saveEdit(id: existing.id, text: text, expecting: existing.version) {
                    let changed = result.note.version != existing.version || result.copiedAside != nil
                    note = result.note
                    if changed { onSaved?() }
                } else {
                    note = nil
                }
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note = try store.createNote(content: text)
                onSaved?()
            }
        } catch {
            log.error("save failed: \(error)")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
