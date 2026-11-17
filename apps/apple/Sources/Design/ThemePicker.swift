import SwiftUI

/// The themes as cards, each a small picture of the theme in the current
/// appearance: its canvas, a card with text and the accent, and a terminal
/// line in its colors. Choosing one recolors every window at once.
struct ThemePicker: View {
    #if os(macOS)
    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: WitermMetrics.Space.m)]
    #else
    private let columns = [GridItem(.flexible(), spacing: WitermMetrics.Space.m), GridItem(.flexible(), spacing: WitermMetrics.Space.m)]
    #endif

    var body: some View {
        let chosen = ThemeStore.shared.theme
        LazyVGrid(columns: columns, alignment: .leading, spacing: WitermMetrics.Space.m) {
            ForEach(AppTheme.allCases) { theme in
                SelectableCard(selected: theme == chosen, cornerRadius: WitermMetrics.Radius.l,
                               padding: WitermMetrics.Space.s, action: { ThemeStore.shared.theme = theme }) {
                    VStack(alignment: .leading, spacing: WitermMetrics.Space.s) {
                        ThemeSwatch(theme: theme)
                        VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                            HStack(spacing: WitermMetrics.Space.xs) {
                                Text(theme.title)
                                    .font(WitermType.rowTitle.weight(.medium))
                                    .foregroundStyle(WitermTheme.ink)
                                Spacer(minLength: 0)
                                if theme == chosen {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(WitermTheme.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                            Text(theme.summary)
                                .font(WitermType.meta)
                                .foregroundStyle(WitermTheme.secondary)
                                .lineLimit(2, reservesSpace: true)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, WitermMetrics.Space.xxs)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(theme.title)
                .accessibilityValue(theme.summary)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(theme == chosen ? .isSelected : [])
                .accessibilityIdentifier("theme-\(theme.rawValue)")
            }
        }
    }
}

/// One theme in miniature, drawn in its own colors.
struct ThemeSwatch: View {
    let theme: AppTheme
    @Environment(\.colorScheme) private var appearance
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let colors = ThemeColors(theme)
        let terminal = theme.terminal(dark: appearance == .dark)
        let outer = WitermMetrics.Radius.m
        let inset = WitermMetrics.Space.s
        VStack(alignment: .leading, spacing: inset) {
            // A card: a title, a line of detail, and the accent as a button.
            HStack(alignment: .center, spacing: WitermMetrics.Space.s) {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(colors.ink).frame(width: 46, height: 5)
                    Capsule().fill(colors.secondary.opacity(0.75)).frame(width: 30, height: 4)
                }
                Spacer(minLength: 0)
                Capsule().fill(colors.accent).frame(width: 26, height: 12)
            }
            .padding(.horizontal, WitermMetrics.Space.s)
            .frame(height: 30)
            .background(colors.surface, in: .rect(cornerRadius: outer - inset / 2, style: .continuous))
            // A terminal line: the prompt, then its ANSI colors.
            HStack(spacing: 4) {
                Text(verbatim: "$")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(terminalRGB: terminal.foreground))
                ForEach([1, 2, 3, 4, 5, 6], id: \.self) { index in
                    Circle().fill(Color(terminalRGB: terminal.ansi[index])).frame(width: 7, height: 7)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WitermMetrics.Space.s)
            .frame(height: 20)
            .background(Color(terminalRGB: terminal.background), in: .rect(cornerRadius: outer - inset / 2, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: outer - inset / 2, style: .continuous)
                    .strokeBorder(Color(terminalRGB: terminal.foreground).opacity(0.10), lineWidth: 1)
            }
        }
        .padding(inset)
        .frame(maxWidth: .infinity)
        .background(colors.canvas, in: .rect(cornerRadius: outer, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: outer, style: .continuous)
                .strokeBorder(WitermTheme.hairline.opacity(contrast == .increased ? 1 : 0.6), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
