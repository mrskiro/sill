import SwiftUI

struct EditorScreen: View {
    let model: EditorModel
    var sync: MacSync?
    var panelState: PanelState?
    var onEscape: () -> Void
    var onNewNote: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if model.isSidebarVisible {
                    SidebarView(model: model)
                        .frame(width: 200)
                    Divider()
                }
                EditorTextView(model: model, onEscape: onEscape)
            }
        }
        .frame(minWidth: 320, minHeight: 200)
        .ignoresSafeArea()  // the header itself occupies the transparent title-bar band
    }

    /// Sits in the transparent title-bar band; the empty parts still drag the window.
    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(model.isSidebarVisible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Notes (⌥⌘S)")
            Button(action: onNewNote) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("New note (⌘N)")
            Text(model.title.isEmpty ? "New note" : model.title)
                .lineLimit(1)
            Spacer()
            Text(sync?.statusText ?? "")
            if panelState?.isPinned == true {
                Image(systemName: "pin.fill")
                    .help("Pinned: stays open when you click elsewhere (⌘⇧P)")
            }
            Text("⌥S")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}
