import SwiftUI

/// The single prominent action style. Glass belongs to the control layer;
/// Reduce Transparency and older systems use the standard bordered style.
struct PrimaryButton: View {
    let title: String
    let systemImage: String?
    let fullWidth: Bool
    let tint: Color
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// `tint` is a machine's identity hue when the action targets one; the
    /// neutral accent otherwise. Both keep contrast with `ActionLabel`.
    init(_ title: String, systemImage: String? = nil, fullWidth: Bool = false, tint: Color = WitermTheme.accent,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.fullWidth = fullWidth
        self.tint = tint
        self.action = action
    }

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *), !reduceTransparency {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private var button: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .fontWeight(.semibold)
            .foregroundStyle(WitermTheme.actionLabel)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .fixedSize(horizontal: false, vertical: true)
        }
        .witermControl()
        .tint(tint)
    }
}

/// A recoverable problem: what happened, what to do, and optional actions.
struct IssueBanner<Actions: View>: View {
    let title: String
    let message: String?
    let systemImage: String
    let actions: Actions

    init(_ title: String, message: String? = nil, systemImage: String = "exclamationmark.circle.fill",
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(WitermTheme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WitermTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(WitermTheme.surface, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(WitermTheme.warning.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }
}

extension IssueBanner where Actions == EmptyView {
    init(_ title: String, message: String? = nil, systemImage: String = "exclamationmark.circle.fill") {
        self.init(title, message: message, systemImage: systemImage) { EmptyView() }
    }
}

/// Real, cancellable work in progress. Never shows invented percentages.
struct ActivityRow: View {
    let label: String
    let cancel: (() -> Void)?

    init(_ label: String, cancel: (() -> Void)? = nil) {
        self.label = label
        self.cancel = cancel
    }

    var body: some View {
        HStack(spacing: 12) {
            ConnectionActivity()
            Text(label)
                .font(.subheadline)
                .foregroundStyle(WitermTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let cancel {
                Button(String(localized: "Cancel", bundle: .main), action: cancel)
                    .touchTarget()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Status always pairs a symbol and text; color is never the only signal.
struct StatusBadge: View {
    enum Tone { case neutral, positive, warning }

    let title: String
    let systemImage: String
    let tone: Tone

    init(_ title: String, systemImage: String, tone: Tone = .neutral) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
    }

    // An explicit stack rather than Label: Form rows restyle Labels and would
    // split the symbol from its text.
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .neutral: WitermTheme.secondary
        case .positive: WitermTheme.positive
        case .warning: WitermTheme.warning
        }
    }
}

struct IconTile: View {
    let systemImage: String
    /// A machine's identity hue, or the neutral accent for everything else.
    var tint: Color = WitermTheme.accent
    private let size = WitermMetrics.iconTile

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.47, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A symbol and text. On macOS this is an explicit stack: `Label`, and
/// accessibility-label overrides on selectable text, made AppKit resolve
/// labels recursively in the pairing views and crash under a VoiceOver or
/// XCUITest hierarchy request. iOS keeps the native `Label`.
struct IconText: View {
    let text: String
    let systemImage: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        #if os(macOS)
        HStack(spacing: 6) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(text)
        }
        #else
        Label(text, systemImage: systemImage)
        #endif
    }
}

/// Page title for content panes; navigation titles stay native.
struct PageHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(WitermTheme.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(WitermTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One header for every terminal: what it is, whether input reaches it, and
/// its actions. Wraps actions below the title when space or text size demands.
struct TerminalHeader<Actions: View>: View {
    /// Omitted where the window title already names the terminal (Mac).
    let title: String?
    let destination: String?
    let status: String
    let statusImage: String
    let live: Bool
    /// The connected machine's identity hue; nil for the local machine.
    let hue: Color?
    let actions: Actions

    init(_ title: String?, destination: String? = nil, status: String, statusImage: String, live: Bool, hue: Color? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.destination = destination
        self.status = status
        self.statusImage = statusImage
        self.live = live
        self.hue = hue
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                summary
                Spacer(minLength: 8)
                HStack(spacing: 4) { actions }
            }
            VStack(alignment: .leading, spacing: 4) {
                summary
                HStack(spacing: 4) { actions }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(minHeight: 44)
        // A remote machine's hue washes the header and its edge, so the
        // terminal below always shows where input goes.
        .background(WitermTheme.surface.overlay((hue ?? .clear).opacity(0.1)))
        .overlay(alignment: .bottom) {
            if let hue { Rectangle().fill(hue.opacity(0.55)).frame(height: 1) } else { Divider() }
        }
        // Ink rather than an inherited tint, so text actions keep contrast on
        // the header surface.
        .tint(hue ?? WitermTheme.accent)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(live ? WitermTheme.positive : WitermTheme.secondary.opacity(0.45))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let destination {
                    Text(verbatim: destination)
                        .font(.caption.monospaced())
                        .foregroundStyle(WitermTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(destination)
                        .accessibilityIdentifier("terminalDestination")
                }
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WitermTheme.ink)
                        .lineLimit(1)
                }
                Label(status, systemImage: statusImage)
                    .font(title == nil ? .subheadline : .caption)
                    .foregroundStyle(title == nil ? WitermTheme.ink : WitermTheme.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("terminalInputStatus")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Stable solid content surface. Glass stays in the control layer.
    func witermCard(padding: CGFloat = WitermMetrics.cardPadding) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(WitermTheme.surface, in: .rect(cornerRadius: WitermMetrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WitermMetrics.cardRadius, style: .continuous)
                    .strokeBorder(WitermTheme.divider, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    /// Centers scrolling content at a comfortable reading width.
    func readableContent(padding: CGFloat = WitermMetrics.pagePadding) -> some View {
        self.padding(padding)
            .frame(maxWidth: WitermMetrics.readableWidth)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// The app's neutral ink tint, shared by iOS and the Mac. The Mac sidebar
    /// opts back into the system accent for its selection.
    func witermTint() -> some View {
        tint(WitermTheme.accent)
    }

    /// The shared control size in capsule form: large touch controls on iOS,
    /// regular pointer controls on the Mac.
    func witermControl() -> some View {
        #if os(macOS)
        controlSize(.regular).buttonBorderShape(.capsule)
        #else
        controlSize(.large).buttonBorderShape(.capsule)
        #endif
    }

    /// A 44 pt hit area for free-standing iOS controls. Form and List rows
    /// already provide it, and Mac pointer controls keep their native height.
    func touchTarget(square: Bool = false) -> some View {
        #if os(macOS)
        self
        #else
        frame(minWidth: square ? 44 : nil, minHeight: 44)
        #endif
    }
}
