import SwiftUI

enum TerminalFontSize {
    static let key = "witerm.terminalFontSize"
    static let standard = 14.0
    static let range = 11.0...32.0

    static func clamped(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }
}

/// Terminal display sections, embeddable in any grouped Form.
struct TerminalAppearanceSections: View {
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.standard
    @AppStorage("witerm.terminalHighContrast") private var highContrast = false
    @AppStorage("witerm.terminalAnnounceOutput") private var announceOutput = false
    @AppStorage(TerminalBell.key) private var bell = true
    @AppStorage(TerminalColorScheme.key) private var palette = TerminalColorScheme.system

    var body: some View {
        Section("Text") {
            Stepper(value: $fontSize, in: TerminalFontSize.range, step: 1) {
                LabeledContent("Font size", value: String(localized: "\(Int(fontSize)) pt"))
            }
            .accessibilityIdentifier("terminalFontSize")
            Text("Aa 0123456789")
                .font(.system(size: fontSize, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .accessibilityLabel(String(localized: "Font preview, \(Int(fontSize)) pt"))
            #if os(iOS)
            Text("Terminal text also adjusts to the system text size.")
                .font(.footnote).foregroundStyle(.secondary)
            #else
            Text("Use Command-Plus and Command-Minus to adjust the size while working.")
                .font(.footnote).foregroundStyle(.secondary)
            #endif
        }
        Section("Appearance") {
            Picker("Color scheme", selection: $palette) {
                ForEach(TerminalColorScheme.allCases) { scheme in
                    Text(scheme.title).tag(scheme)
                }
            }
            .accessibilityIdentifier("terminalColorScheme")
            TerminalSchemePreview(scheme: palette, highContrast: highContrast)
            Toggle("Increase terminal contrast", isOn: $highContrast).tint(WitermTheme.positive)
                .accessibilityIdentifier("terminalHighContrast")
            Text("Schemes follow the system's light or dark appearance. Increased contrast overrides the scheme.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        #if os(iOS)
        Section(String(localized: "Input", bundle: .main)) {
            NavigationLink(String(localized: "Keyboard Row", bundle: .main)) { MobileKeyRowSettings() }
                .accessibilityIdentifier("mobileKeyRowSettings")
            NavigationLink(String(localized: "Snippets", bundle: .main)) { SnippetSettingsView() }
                .accessibilityIdentifier("snippetSettings")
        }
        #endif
        Section("Bell") {
            Toggle("Ring the terminal bell", isOn: $bell).tint(WitermTheme.positive)
                .accessibilityIdentifier("terminalBell")
            #if os(iOS)
            Text("A short vibration plays when a program rings the bell.")
                .font(.footnote).foregroundStyle(.secondary)
            #else
            Text("The system alert sound plays, and the Dock icon bounces once if Witerm is in the background.")
                .font(.footnote).foregroundStyle(.secondary)
            #endif
        }
        Section("VoiceOver") {
            Toggle("Announce output updates", isOn: $announceOutput).tint(WitermTheme.positive)
                .accessibilityIdentifier("terminalAnnounceOutput")
            Text("VoiceOver announces when the terminal has new output.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            Button("Restore Defaults") {
                fontSize = TerminalFontSize.standard
                highContrast = false
                announceOutput = false
                bell = true
                palette = .system
            }
            .accessibilityIdentifier("resetTerminalAppearance")
        }
    }
}

/// A few lines of sample output in the chosen scheme, in the current appearance.
private struct TerminalSchemePreview: View {
    let scheme: TerminalColorScheme
    let highContrast: Bool
    @Environment(\.colorScheme) private var appearance

    var body: some View {
        let dark = appearance == .dark
        let values = highContrast ? nil : scheme.values(dark: dark)
        let ansi = values?.ansi
        let background = values.map { Color(terminalRGB: $0.background) } ?? (highContrast ? (dark ? .black : .white) : Color(white: dark ? 0.12 : 1))
        let foreground = values.map { Color(terminalRGB: $0.foreground) } ?? (dark ? .white : .black)
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "~/project $ git status").foregroundStyle(foreground)
            HStack(spacing: 0) {
                Text(verbatim: "modified: ").foregroundStyle(ansi.map { Color(terminalRGB: $0[1]) } ?? .red)
                Text(verbatim: "app.swift ").foregroundStyle(foreground)
                Text(verbatim: "✓ tests").foregroundStyle(ansi.map { Color(terminalRGB: $0[2]) } ?? .green)
            }
            Text(verbatim: "branch main → origin").foregroundStyle(ansi.map { Color(terminalRGB: $0[4]) } ?? .blue)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: .rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

extension Color {
    init(terminalRGB value: UInt32) {
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255)
    }
}

/// Terminal display presented from within a terminal.
struct TerminalAppearanceSettings: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { TerminalAppearanceSections() }
                .formStyle(.grouped)
                .navigationTitle("Terminal Display")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("closeTerminalAppearance")
                    }
                }
        }
        .witermTint()
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 400)
        #endif
    }
}
