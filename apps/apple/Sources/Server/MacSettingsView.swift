#if os(macOS)
import SwiftUI

/// The selected Settings tab. Other views set it before opening Settings to
/// land on a specific tab.
enum SettingsTab: String, CaseIterable {
    case general, appearance, terminal, snippets
    static let key = "witerm.settingsTab"
}

struct MacSettingsView: View {
    let service: LocalAgentService
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general.rawValue
    /// Settings is its own scene, so it watches the network itself.
    @State private var network = NetworkStatus()

    var body: some View {
        // No app tint: switches, radios, checkboxes and links keep the
        // system accent, as in other Mac apps' settings.
        TabView(selection: $tab) {
            MacGeneralSettings(service: service)
                .settingsPane()
                .tabItem { Label(String(localized: "General", bundle: .main), systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            MacAppearanceSettings()
                .settingsPane()
                .tabItem { Label(String(localized: "Appearance", bundle: .main), systemImage: "paintpalette") }
                .tag(SettingsTab.appearance.rawValue)
            Form { TerminalAppearanceSections() }
                .formStyle(.grouped)
                .settingsPane()
                .tabItem { Label(String(localized: "Terminal", bundle: .main), systemImage: "textformat.size") }
                .tag(SettingsTab.terminal.rawValue)
            Form { SnippetSections() }
                .formStyle(.grouped)
                .settingsPane()
                .tabItem { Label(String(localized: "Snippets", bundle: .main), systemImage: "text.insert") }
                .tag(SettingsTab.snippets.rawValue)
        }
        .environment(network)
        // Devices moved to the main window (Round 27) and Command Line into
        // General (Round 28); a tab saved before that opens General.
        .onAppear { if SettingsTab(rawValue: tab) == nil { tab = SettingsTab.general.rawValue } }
    }
}

private extension View {
    /// One size for every tab, so switching tabs never resizes the window;
    /// longer content scrolls inside.
    func settingsPane() -> some View { frame(width: 640, height: 600) }
}

/// The theme, as cards that show it.
private struct MacAppearanceSettings: View {
    @AppStorage(TerminalColorScheme.key) private var palette = TerminalColorScheme.standard

    var body: some View {
        Form {
            Section {
                ThemePicker()
                    .padding(.vertical, WitermMetrics.Space.xs)
            } header: {
                Text("Theme")
            } footer: {
                Text(palette == .theme
                     ? String(localized: "A theme colors the window, its cards and buttons, and your terminals, in light and dark. Machine colors stay the same in every theme.", bundle: .main)
                     : String(localized: "A theme colors the window, its cards and buttons, in light and dark. Your terminals use the \(palette.title) scheme chosen in Terminal settings.", bundle: .main))
            }
        }
        .formStyle(.grouped)
    }
}

private struct MacGeneralSettings: View {
    let service: LocalAgentService
    @State private var stopping = false

    var body: some View {
        Form {
            Section(String(localized: "This Mac", bundle: .main)) {
                // What the background service is for, not what it is: terminals
                // here exist and keep running only while it's on.
                LabeledContent(String(localized: "Terminals", bundle: .main), value: serviceStatus)
                    .help(String(localized: "Witerm keeps terminals running on this Mac in the background, even after you quit it.", bundle: .main))
                HStack {
                    switch service.state {
                    case .ready:
                        Button(String(localized: "Turn Off…", bundle: .main), role: .destructive) { stopping = true }
                            .accessibilityIdentifier("turnOffTerminals")
                    case .requiresApproval:
                        Button(String(localized: "Open Login Items Settings", bundle: .main), action: service.openSettings)
                    case .starting:
                        ProgressView().controlSize(.small)
                    case .notRegistered, .unavailable:
                        Button(String(localized: "Turn On Terminals", bundle: .main)) { Task { await service.start() } }
                            .accessibilityIdentifier("turnOnTerminals")
                    }
                    Spacer()
                }
                if let issue = service.issue {
                    Text(issue).font(WitermType.rowDetail).foregroundStyle(WitermTheme.warning)
                }
            }
            CommandLineToolSections()
        }
        .formStyle(.grouped)
        .task { await service.refresh() }
        .alert(String(localized: "Turn Off Terminals on This Mac?", bundle: .main), isPresented: $stopping) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            Button(String(localized: "Turn Off", bundle: .main), role: .destructive) {
                Task { await service.stop() }
            }
        } message: {
            Text(String(localized: "Your terminals keep running, but you can’t open them here or from other devices until you turn this back on.", bundle: .main))
        }
    }

    private var serviceStatus: String {
        switch service.state {
        case .ready: String(localized: "On", bundle: .main)
        case .starting: String(localized: "Turning on terminals…", bundle: .main)
        case .requiresApproval: String(localized: "Waiting for approval in System Settings", bundle: .main)
        case .notRegistered: String(localized: "Off", bundle: .main)
        case .unavailable: String(localized: "Not responding", bundle: .main)
        }
    }
}
#endif
