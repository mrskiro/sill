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

    /// Format menu: runs one `MarkdownEditing` command on the editor, sharing the code path
    /// (and the undo grouping) with the keys the text view handles itself. Menu shortcuts fire
    /// application-wide, so this only acts when the editor is the thing being typed into — not
    /// when focus is in the sidebar, the Settings window, or the panel is hidden.
    func format(_ command: (String, NSRange) -> TextEdit?) {
        guard let textView = textView as? MarkdownTextView, textView.window?.isVisible == true,
            textView.window?.firstResponder === textView,
            let edit = command(textView.string, textView.selectedRange())
        else { return }
        textView.apply(edit)  // didChangeText() inside notifies the delegate, which autosaves
    }

    /// Copies the note twice over: the Markdown itself, and an HTML rendering of it. Somewhere
    /// that only takes text still gets the exact characters; somewhere that reads the rich
    /// flavour — Slack, Docs, Mail, Notes — gets real lists and real emphasis instead of a line
    /// that happens to start with a hyphen. The plain flavour is written last so it stays the
    /// one a text-only target falls back to.
    func copyAsMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString(MarkdownHTML.fragment(from: text), forType: .html)
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
                if let result = try store.saveEdit(id: existing.id, text: current, expecting: existing.version) {
                    let changed = result.note.version != existing.version || result.copiedAside != nil
                    note = result.note
                    if let copied = result.copiedAside {
                        log.notice("kept local edits; copied remote version of \(existing.id) aside as \(copied.id)")
                    }
                    if changed { onSaved?() }
                } else {
                    note = nil
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

    /// Sync changed the note that is open: show it when the editor is clean. A dirty editor keeps
    /// typing; `saveEdit` copies the replaced text aside when the local text is saved.
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
