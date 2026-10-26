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
            Toggle("Increase terminal contrast", isOn: $highContrast).tint(WitermTheme.positive)
                .accessibilityIdentifier("terminalHighContrast")
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
            }
            .accessibilityIdentifier("resetTerminalAppearance")
        }
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
