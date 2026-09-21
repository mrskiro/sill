import SillCore
import SwiftUI

struct RootView: View {
    @Bindable var model: PhoneModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $model.path) {
            NoteListView(model: model)
                .navigationDestination(for: Destination.self) { destination in
                    EditorView(draft: model.draft(for: destination)) {
                        model.deleteNote(in: destination)
                    }
                    .onDisappear { model.flush(destination) }
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.sync?.start()
            } else {
                model.flush()
                model.sync?.stop()
            }
        }
        .sheet(isPresented: $model.showPairing) {
            if let sync = model.sync { PairingScreen(sync: sync) }
        }
    }
}

struct NoteListView: View {
    let model: PhoneModel
    @State private var pendingDelete: Note?

    var body: some View {
        List {
            ForEach(NoteListGrouping.sections(for: model.notes)) { section in
                Section(section.title) {
                    ForEach(section.notes) { note in
                        NavigationLink(value: Destination.existing(note.id)) {
                            NoteRow(note: note)
                        }
                        // Tinted rather than `role: .destructive`: a destructive swipe starts taking the
                        // row away before the confirmation, and Cancel would leave it half gone.
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash") { pendingDelete = note }
                                .tint(.red)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Named but not shown: there is only one list, so a heading on screen says nothing. The name
        // is still what VoiceOver reads for this screen and for the editor's back button.
        // `.toolbar(removing: .title)` leaves the large title on screen, so the title is made inline
        // and an empty principal item takes its place in the bar.
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(
                    "Settings",
                    systemImage: model.sync?.isPaired == true ? "laptopcomputer.and.iphone" : "qrcode.viewfinder"
                ) {
                    model.showPairing = true
                }
            }
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Note", systemImage: "square.and.pencil") { model.newNote() }
            }
        }
        .deleteNoteConfirmation(for: $pendingDelete) { note in model.deleteNote(id: note.id) }
        // Sync only speaks up here when it has stopped; the everyday status lives in Settings.
        .safeAreaInset(edge: .bottom) {
            if let failure = model.sync?.failure {
                Button {
                    model.showPairing = true
                } label: {
                    Label("Sync failed: \(failure)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(.bar)
            }
        }
    }
}

/// Title in bold, then the date and a one-line preview, like Apple Notes.
struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title.isEmpty ? "New note" : note.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(NoteListGrouping.rowDate(note.updatedAt))
                Text(NoteTitle.preview(of: note.content) ?? "No additional text")
                    .lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

extension View {
    /// The question the Mac asks too: deleting reaches every synced device and cannot be undone.
    /// `item` is captured when the dialog opens, so the answer always applies to what was asked about.
    func deleteNoteConfirmation<Item>(for item: Binding<Item?>, onDelete: @escaping (Item) -> Void) -> some View {
        confirmationDialog(
            "Delete this note?",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { value in
            Button("Delete", role: .destructive) { onDelete(value) }
        } message: { _ in
            Text("The note is removed from every synced device. This cannot be undone.")
        }
    }
}
