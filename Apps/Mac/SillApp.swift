import SillCore
import SillMac
import SwiftUI

@main
struct SillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No launch window: the floating panel is owned by AppDelegate.
        // The Settings scene keeps the standard main menu (Edit menu shortcuts work in the panel).
        Settings {
            SettingsScreen()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { appDelegate.newNote() }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy as Markdown") { appDelegate.copyAsMarkdown() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Notes Sidebar") { appDelegate.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            CommandMenu("Note") {
                Toggle(
                    "Pin Window",
                    isOn: Binding(
                        get: { appDelegate.panelState.isPinned },
                        set: { appDelegate.setPinned($0) }
                    )
                )
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Delete Note") { appDelegate.deleteCurrentNote() }
                    .keyboardShortcut(.delete, modifiers: [.command])
            }
        }
    }
}

struct SettingsScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Show Sill")
                KeyboardShortcuts.Recorder(for: .togglePanel)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            Divider()
            if let sync = AppDelegate.shared?.sync {
                PairingView(sync: sync)
            }
        }
        .frame(width: 320)
    }
}
