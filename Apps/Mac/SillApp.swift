import AppKit
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
            // The same `MarkdownEditing` commands the iOS keyboard toolbar offers.
            CommandMenu("Format") {
                Button("Heading") { appDelegate.format(MarkdownEditing.toggleHeading) }
                Divider()
                Button("Bold") { appDelegate.format { MarkdownEditing.toggleInline(.bold, in: $0, selection: $1) } }
                    .keyboardShortcut("b", modifiers: [.command])
                Button("Italic") { appDelegate.format { MarkdownEditing.toggleInline(.italic, in: $0, selection: $1) } }
                    .keyboardShortcut("i", modifiers: [.command])
                Button("Code") { appDelegate.format { MarkdownEditing.toggleInline(.code, in: $0, selection: $1) } }
                Divider()
                Button("Bulleted List") { appDelegate.format(MarkdownEditing.toggleBullet) }
                    .keyboardShortcut("7", modifiers: [.command, .shift])
                Button("Numbered List") { appDelegate.format(MarkdownEditing.toggleNumbered) }
                    .keyboardShortcut("9", modifiers: [.command, .shift])
                // No ⌘Return here: a menu key equivalent is dispatched before the responder
                // chain, so it would shadow MarkdownTextView.keyDown, which already owns the
                // shortcut and reaches the editor whether or not the app is active.
                Button("Checklist") { appDelegate.format(MarkdownEditing.toggleCheckbox) }
                Button("Outdent") { appDelegate.format(MarkdownEditing.outdent) }
                Button("Indent") { appDelegate.format(MarkdownEditing.indent) }
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
            // Under "About Sill" in the app menu, where a Sparkle-style updater would sit.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await UpdateCheck.run() } }
            }
            CommandGroup(replacing: .help) {
                Button("Report an Issue…") {
                    NSWorkspace.shared.open(
                        Support.newIssueURL(environment: Support.environmentSummary()))
                }
                // The log names devices and carries pairing-code prefixes, so it is revealed,
                // never attached: the user reads it before pasting anything into an issue.
                Button("Reveal Sync Log in Finder") { revealSyncLog() }
            }
        }
    }
}

/// Selects `sync.log` in Finder, or opens its folder when sync has not written anything yet.
private func revealSyncLog() {
    let log = SyncLog.url
    if FileManager.default.fileExists(atPath: log.path) {
        NSWorkspace.shared.activateFileViewerSelecting([log])
    } else {
        let folder = log.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
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
