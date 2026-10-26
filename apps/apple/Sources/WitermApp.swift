import SwiftUI

@main
struct WitermApp: App {
    @State private var servers = ServerList()
    #if os(macOS)
    @State private var service = LocalAgentService()
    #endif

    var body: some Scene {
        mainWindow
        #if os(macOS)
        Settings {
            MacSettingsView(service: service)
                .environment(servers)
        }
        #endif
    }

    private var mainWindow: some Scene {
        WindowGroup {
            #if DEBUG
                if TerminalAccessibilityHarness.requested {
                    TerminalAccessibilityHarnessView()
                } else {
                    workspace
                }
            #else
                workspace
            #endif
        }
        #if os(macOS)
            .defaultSize(width: 1180, height: 760)
            .windowResizability(.contentMinSize)
            .commands { WitermCommands() }
        #endif
    }

    private var workspace: some View {
        Group {
            #if os(macOS)
                MacWorkspaceView(service: service)
            #else
                MobileWorkspaceView()
            #endif
        }
        .connectionLifecycle()
        .environment(servers)
    }
}

#if os(macOS)
/// Actions the focused workspace window offers to the menu bar.
struct WorkspaceActions {
    var newSession: (() -> Void)?
    var newSSHConnection: () -> Void
    var refresh: () -> Void
}

extension FocusedValues {
    @Entry var workspaceActions: WorkspaceActions?
}

struct WitermCommands: Commands {
    @FocusedValue(\.workspaceActions) private var actions
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.standard

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "New Terminal Session", bundle: .main)) { actions?.newSession?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions?.newSession == nil)
            Button(String(localized: "New SSH Connection", bundle: .main)) { actions?.newSSHConnection() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        CommandGroup(before: .toolbar) {
            Button(String(localized: "Refresh", bundle: .main)) { actions?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions == nil)
            Divider()
            Button(String(localized: "Increase Text Size", bundle: .main)) { fontSize = TerminalFontSize.clamped(fontSize + 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(fontSize >= TerminalFontSize.range.upperBound)
            Button(String(localized: "Decrease Text Size", bundle: .main)) { fontSize = TerminalFontSize.clamped(fontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(fontSize <= TerminalFontSize.range.lowerBound)
            Button(String(localized: "Actual Text Size", bundle: .main)) { fontSize = TerminalFontSize.standard }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}
#endif
