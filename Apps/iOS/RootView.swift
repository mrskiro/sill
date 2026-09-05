import SillCore
import SwiftUI

struct RootView: View {
    @Bindable var model: PhoneModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $model.path) {
            NoteListView(model: model)
                .navigationDestination(for: Destination.self) { destination in
                    EditorView(draft: model.draft(for: destination))
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

    var body: some View {
        List {
            ForEach(NoteListGrouping.sections(for: model.notes)) { section in
                Section(section.title) {
                    ForEach(section.notes) { note in
                        NavigationLink(value: Destination.existing(note.id)) {
                            NoteRow(note: note)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { model.deleteNote(id: section.notes[index].id) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Sync", systemImage: model.sync?.isPaired == true ? "laptopcomputer.and.iphone" : "qrcode.viewfinder") {
                    model.showPairing = true
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Note", systemImage: "square.and.pencil") { model.newNote() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let sync = model.sync {
                Text(sync.status.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
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
