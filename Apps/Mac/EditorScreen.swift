import SwiftUI

struct EditorScreen: View {
    let model: EditorModel
    var sync: MacSync?
    var onEscape: () -> Void
    var onNewNote: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onDeleteNote: (UUID) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let headerHeight: CGFloat = 30
    /// Clears the close / minimize / zoom buttons at the leading edge of the title-bar band.
    private static let windowButtonsWidth: CGFloat = 78

    var body: some View {
        // The sidebar's material bleeds up into the transparent title-bar band, so the
        // header has to be painted after it — a VStack would leave it buried underneath.
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if model.isSidebarVisible {
                    HStack(spacing: 0) {
                        SidebarView(model: model, onDelete: onDeleteNote)
                            .frame(width: 200)
                        Divider()
                    }
                    .transition(.move(edge: .leading))
                }
                EditorTextView(model: model, onEscape: onEscape)
            }
            .clipped()
            // Animated here rather than at each call site, so the header button and the menu
            // item (⌥⌘S) both slide the same way.
            .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: model.isSidebarVisible)
            .padding(.top, Self.headerHeight + 1)  // + the header's divider
            VStack(spacing: 0) {
                header
                Divider()
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
            Spacer()
            // Sync only speaks up when it needs attention; the everyday status lives in Settings.
            if let failure = sync?.failure {
                Button(action: onOpenSettings) {
                    Image(systemName: "exclamationmark.triangle")
                }
                .buttonStyle(.plain)
                .help("Sync failed: \(failure)")
            }
            Button(action: onNewNote) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("New note (⌘N)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, Self.windowButtonsWidth)
        .padding(.trailing, 12)
        .frame(height: Self.headerHeight)
    }
}
