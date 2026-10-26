import SwiftUI

struct ConnectionActions: View {
    let isChecking: Bool
    let hasAddress: Bool
    let action: () -> Void
    let cancel: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 8) {
                    primary.buttonStyle(.glassProminent)
                    if isChecking {
                        cancelButton.buttonStyle(.glass)
                            .transition(.opacity)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                primary.buttonStyle(.borderedProminent)
                if isChecking { cancelButton.buttonStyle(.bordered) }
            }
        }
    }

    private var primary: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(isChecking ? String(localized: "Checking…", bundle: .main) : (hasAddress ? String(localized: "Check Connection", bundle: .main) : String(localized: "Add Server", bundle: .main)))
                if !isChecking && !typeSize.isAccessibilitySize {
                    Image(systemName: hasAddress ? "arrow.right" : "plus")
                        .accessibilityHidden(true)
                }
            }
            .fontWeight(.semibold)
            .foregroundStyle(WitermTheme.actionLabel)
            .frame(maxWidth: .infinity)
        }
        .witermControl()
        .tint(WitermTheme.accent)
        .disabled(isChecking)
        .accessibilityIdentifier("primaryAction")
        .keyboardShortcut(.return, modifiers: .command)
    }

    private var cancelButton: some View {
        Button(action: cancel) {
            Image(systemName: "xmark")
                .fontWeight(.semibold)
        }
        .witermControl()
        .buttonBorderShape(.circle)
        .accessibilityLabel(String(localized: "Cancel Check", bundle: .main))
        .accessibilityIdentifier("cancelConnection")
        .help(String(localized: "Cancel Check", bundle: .main))
    }
}

struct ConnectionActivity: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "network")
                    .font(.body)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .tint(WitermTheme.accent)
        .foregroundStyle(WitermTheme.accent)
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
