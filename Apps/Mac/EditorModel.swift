import AppKit
import Observation
import SillCore
import os

/// Holds the note being edited and autosaves it. Owns the text view directly so that
/// switching notes updates the editor synchronously (no SwiftUI round trip).
/// A new note is not written to the database until it has non-blank content,
/// so abandoned empty notes never exist.
@MainActor
@Observable
final class EditorModel {
    private let store: NoteStore
    private(set) var note: Note?
    private(set) var text: String = ""
    /// Live notes, newest first. Fed by the database observation.
    private(set) var notes: [Note] = []
    var isSidebarVisible: Bool {
        didSet { UserDefaults.standard.set(isSidebarVisible, forKey: Self.sidebarKey) }
    }

    /// Called after a write reached the database (sync uses it to poke the phone).
    @ObservationIgnored var onSaved: (() -> Void)?
    @ObservationIgnored private weak var textView: NSTextView?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private let log = Logger(subsystem: "com.mrskiro.sill", category: "editor")
    private static let sidebarKey = "sidebarVisible"

    init(store: NoteStore) {
        self.store = store
        isSidebarVisible = UserDefaults.standard.bool(forKey: Self.sidebarKey)
    }

    var title: String {
        note?.title ?? ""
    }

    /// Called once by the editor view when its NSTextView exists.
    func attach(_ textView: NSTextView) {
        self.textView = textView
        textView.string = text
    }

    /// Keeps `notes` in sync with the database (own edits and, later, incoming sync).
    func startObservingNotes() {
        observationTask?.cancel()
        observationTask = Task { [weak self, store] in
            do {
                for try await notes in store.observeLiveNotes() {
                    self?.notes = notes
                    self?.reconcileOpenNote()
                }
            } catch {
                self?.log.error("note observation failed: \(error)")
            }
        }
    }

    /// Called by the text view delegate on every edit.
    func textDidChange(_ newText: String) {
        guard newText != text else { return }
        text = newText
        log.debug("textDidChange length=\(newText.count)")
        scheduleSave()
    }

    /// First show: open the most recently edited note.
    func loadLastNoteIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let last = try? store.lastEditedNote() {
            load(last)
        }
    }

    func newNote() {
        flush()
        note = nil
        setText("")
    }

    /// Switches to another note (sidebar selection).
    func open(id: UUID) {
        guard id != note?.id, let target = try? store.note(id: id), !target.isDeleted else { return }
        load(target)
    }

    /// Tombstones the current note and moves to the next most recent one.
    func deleteCurrentNote() {
        saveTask?.cancel()
        saveTask = nil
        let deletedID = note?.id
        if let deletedID {
            do {
                try store.deleteNote(id: deletedID)
                onSaved?()
            } catch {
                log.error("delete failed: \(error)")
                return
            }
        }
        note = nil
        setText("")
        if let next = try? store.lastEditedNote(), next.id != deletedID {
            load(next)
        }
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func focusEditor() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func copyAsMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Writes pending changes now. Called on hide, on switching notes, and on quit.
    /// Reads the text view itself so nothing is lost even if a change notification was missed.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        let current = textView?.string ?? text
        text = current
        do {
            if let existing = note {
                if existing.content != current, let updated = try store.updateNote(id: existing.id, content: current) {
                    note = updated
                    log.debug("flush: updated note length=\(current.count)")
                    onSaved?()
                }
            } else if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note = try store.createNote(content: current)
                log.debug("flush: created note length=\(current.count)")
                onSaved?()
            }
        } catch {
            log.error("save failed: \(error)")
        }
    }

    private func load(_ note: Note) {
        flush()
        self.note = note
        setText(note.content)
    }

    /// Sync changed the note that is open: show it, or keep typing and copy the remote text aside.
    /// Never lets a later local save silently erase what another device wrote.
    private func reconcileOpenNote() {
        guard let open = note else { return }
        let current = try? store.note(id: open.id)
        switch OpenNoteReconciliation.decide(open: open, editorText: textView?.string ?? text, current: current) {
        case .unchanged:
            break
        case .reload(let latest):
            note = latest
            setText(latest.content)
        case .deletedRemotely:
            note = nil
            setText("")
            if let next = try? store.lastEditedNote() { load(next) }
        case .keepLocalAndCopyRemote(let latest):
            let peerName = (try? store.peer(id: latest.version.device))?.name ?? "another device"
            if !latest.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try? store.createNote(content: NoteTitle.markingConflict(in: latest.content, from: peerName))
                onSaved?()
            }
            note = latest // the next flush writes the local text as a version on top of it
            log.notice("kept local edits; copied remote version of \(open.id) aside")
        }
    }

    private func setText(_ newText: String) {
        saveTask?.cancel()
        saveTask = nil
        text = newText
        if let textView, textView.string != newText {
            textView.string = newText
            textView.undoManager?.removeAllActions()
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
