import SwiftUI

/// The one choice card on both platforms: one of several mutually exclusive
/// options, such as a device to open a terminal on or a way to sign in with a
/// key. Selected: `selectedFill` with a 1.5 pt accent border and the
/// `.isSelected` trait; otherwise a hairline, which Increase Contrast turns
/// into `WitermTheme.outline`. On the Mac the pointer adds
/// `hoverFill`, never on the selected card, so hover and selection can't be
/// mistaken for each other.
struct SelectableCard<Label: View>: View {
    let selected: Bool
    var cornerRadius: CGFloat = WitermMetrics.Radius.l
    var padding: CGFloat = WitermMetrics.Space.m
    let action: () -> Void
    let label: Label
    @Environment(\.colorSchemeContrast) private var contrast

    init(selected: Bool, cornerRadius: CGFloat = WitermMetrics.Radius.l, padding: CGFloat = WitermMetrics.Space.m,
         action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.selected = selected
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.action = action
        self.label = label()
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(padding)
                .background {
                    shape.fill(WitermTheme.surface)
                        .overlay(shape.fill(selected ? WitermTheme.selectedFill : .clear))
                }
                .overlay {
                    shape.strokeBorder(selected ? WitermTheme.selectedBorder
                                       : contrast == .increased ? WitermTheme.outline(increasedContrast: true) : WitermTheme.hairline,
                                       lineWidth: selected || contrast == .increased ? WitermMetrics.selectedBorder : 1)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                #if os(macOS)
                .witermHover(cornerRadius: cornerRadius, active: !selected)
                #endif
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The edge of a card, field, choice or code tile with Increase Contrast:
/// `WitermTheme.outline` at 1.5 pt. Otherwise a hairline where the shape
/// sits on a surface of the same color (`hairline: true`), or nothing where
/// its fill already carries the shape.
private struct WitermOutline: ViewModifier {
    let cornerRadius: CGFloat
    let hairline: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if contrast == .increased {
                shape.strokeBorder(WitermTheme.outline(increasedContrast: true), lineWidth: WitermMetrics.selectedBorder)
                    .allowsHitTesting(false)
            } else if hairline {
                shape.strokeBorder(WitermTheme.hairline, lineWidth: 1).allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// See `WitermOutline`.
    func witermOutline(cornerRadius: CGFloat, hairline: Bool = false) -> some View {
        modifier(WitermOutline(cornerRadius: cornerRadius, hairline: hairline))
    }

    /// Switch tint: the system accent on the Mac, where system controls keep
    /// the system's color; Positive on iOS, as before.
    @ViewBuilder func witermSwitchTint() -> some View {
        #if os(macOS)
        self
        #else
        tint(WitermTheme.positive)
        #endif
    }
}
