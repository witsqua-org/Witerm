import SwiftUI

enum TerminalFontSize {
    static let key = "witerm.terminalFontSize"
    static let standard = 14.0
    static let range = 11.0...32.0

    static func clamped(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }
}

/// Every terminal preference, embeddable in any grouped Form: display, then
/// bell and VoiceOver, each with a reset that names what it restores.
struct TerminalAppearanceSections: View {
    var body: some View {
        TerminalDisplaySections()
        TerminalFeedbackSections()
    }
}

/// Text size, color scheme, and contrast.
struct TerminalDisplaySections: View {
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.standard
    @AppStorage("witerm.terminalHighContrast") private var highContrast = false
    @AppStorage(TerminalColorScheme.key) private var palette = TerminalColorScheme.system
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var typeSize
    /// What the terminal actually uses: the setting, grown with the text
    /// size up to the cap, so the preview matches the terminal.
    private var effectiveSize: Double { fontSize * Double(TerminalTextScale.factor(typeSize)) }
    #else
    private var effectiveSize: Double { fontSize }
    #endif

    var body: some View {
        Section("Text") {
            Stepper(value: $fontSize, in: TerminalFontSize.range, step: 1) {
                #if os(iOS)
                LabeledContent(String(localized: "Font Size", bundle: .main), value: String(localized: "\(Int(fontSize)) pt"))
                #else
                LabeledContent("Font size", value: String(localized: "\(Int(fontSize)) pt"))
                #endif
            }
            .accessibilityIdentifier("terminalFontSize")
            Text("Aa 0123456789")
                .font(.system(size: effectiveSize, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .accessibilityLabel(String(localized: "Font preview, \(Int(effectiveSize.rounded())) pt"))
            #if os(macOS)
            Text("Use Command-Plus and Command-Minus to adjust the size while working.")
                .font(.footnote).foregroundStyle(.secondary)
            #endif
        }
        Section {
            #if os(iOS)
            Picker(String(localized: "Color Scheme", bundle: .main), selection: $palette) {
                ForEach(TerminalColorScheme.allCases) { scheme in
                    Text(scheme.title).tag(scheme)
                }
            }
            .accessibilityIdentifier("terminalColorScheme")
            #else
            Picker("Color scheme", selection: $palette) {
                ForEach(TerminalColorScheme.allCases) { scheme in
                    Text(scheme.title).tag(scheme)
                }
            }
            .accessibilityIdentifier("terminalColorScheme")
            #endif
            TerminalSchemePreview(scheme: palette, highContrast: highContrast)
            #if os(iOS)
            Toggle(String(localized: "Increase Terminal Contrast", bundle: .main), isOn: $highContrast).tint(WitermTheme.positive)
                .accessibilityIdentifier("terminalHighContrast")
            #else
            Toggle("Increase terminal contrast", isOn: $highContrast).tint(WitermTheme.positive)
                .accessibilityIdentifier("terminalHighContrast")
            #endif
            Button {
                fontSize = TerminalFontSize.standard
                highContrast = false
                palette = .system
            } label: {
                ContentActionLabel(String(localized: "Restore Display Defaults", bundle: .main), systemImage: "arrow.counterclockwise")
            }
            .disabled(fontSize == TerminalFontSize.standard && !highContrast && palette == .system)
            .accessibilityIdentifier("resetTerminalAppearance")
        } header: {
            Text("Appearance")
        } footer: {
            #if os(macOS)
            Text("Schemes follow the system's light or dark appearance. Increased contrast overrides the scheme.")
            #endif
        }
    }
}

/// The bell and VoiceOver output announcements.
struct TerminalFeedbackSections: View {
    @AppStorage("witerm.terminalAnnounceOutput") private var announceOutput = false
    @AppStorage(TerminalBell.key) private var bell = true

    var body: some View {
        Section {
            #if os(iOS)
            Toggle(String(localized: "Terminal Bell", bundle: .main), isOn: $bell).tint(WitermTheme.positive)
                .accessibilityIdentifier("terminalBell")
            #else
            Toggle("Ring the terminal bell", isOn: $bell).tint(WitermTheme.positive)
                .accessibilityIdentifier("terminalBell")
            #endif
        } header: {
            Text("Bell")
        } footer: {
            #if os(iOS)
            Text("A short vibration plays when a program rings the bell.")
            #else
            Text("The system alert sound plays, and the Dock icon bounces once if Witerm is in the background.")
            #endif
        }
        Section {
            #if os(iOS)
            Toggle(String(localized: "Announce New Output", bundle: .main), isOn: $announceOutput).tint(WitermTheme.positive)
                .accessibilityIdentifier("terminalAnnounceOutput")
            #else
            Toggle("Announce output updates", isOn: $announceOutput).tint(WitermTheme.positive)
                .accessibilityIdentifier("terminalAnnounceOutput")
            #endif
        } header: {
            Text("VoiceOver")
        } footer: {
            Text("VoiceOver announces when the terminal has new output.")
        }
    }
}

#if os(iOS)
/// Keyboard row and snippets, reachable from a terminal's Display sheet.
struct TerminalInputLinks: View {
    var body: some View {
        Section(String(localized: "Keyboard", bundle: .main)) {
            NavigationLink(String(localized: "Keyboard Row", bundle: .main)) { MobileKeyRowSettings() }
                .accessibilityIdentifier("mobileKeyRowSettings")
            NavigationLink(String(localized: "Snippets", bundle: .main)) { SnippetSettingsView() }
                .accessibilityIdentifier("snippetSettings")
        }
    }
}
#endif

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
        .padding(WitermMetrics.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: .rect(cornerRadius: WitermMetrics.Radius.s))
        #if os(iOS)
        // An edge, so a preview the color of the row still reads as one.
        .overlay { RoundedRectangle(cornerRadius: WitermMetrics.Radius.s).strokeBorder(WitermTheme.hairline, lineWidth: 1) }
        #endif
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
            Form {
                TerminalDisplaySections()
                #if os(iOS)
                TerminalInputLinks()
                #endif
                TerminalFeedbackSections()
            }
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
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 400)
        #endif
    }
}
