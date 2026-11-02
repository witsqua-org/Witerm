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

    init(_ title: String, message: String? = nil, systemImage: String = WitermSymbols.problem,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: WitermMetrics.Space.m) {
            Image(systemName: systemImage)
                .font(WitermType.rowTitle)
                .foregroundStyle(WitermTheme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WitermMetrics.Space.s) {
                Text(title)
                    .font(WitermType.rowDetail.weight(.semibold))
                    .foregroundStyle(WitermTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(WitermType.rowDetail)
                        .foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(WitermMetrics.Space.m)
        .background(WitermTheme.surface, in: .rect(cornerRadius: WitermMetrics.Radius.l, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WitermMetrics.Radius.l, style: .continuous)
                .strokeBorder(WitermTheme.warning.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }
}

extension IssueBanner where Actions == EmptyView {
    init(_ title: String, message: String? = nil, systemImage: String = WitermSymbols.problem) {
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
        HStack(spacing: WitermMetrics.Space.m) {
            ConnectionActivity()
            Text(label)
                .font(WitermType.rowDetail)
                .foregroundStyle(WitermTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: WitermMetrics.Space.s)
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
        HStack(spacing: WitermMetrics.Space.xs) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(WitermType.meta.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, WitermMetrics.Space.s)
        .padding(.vertical, WitermMetrics.Space.xs)
        .background(WitermTheme.tint(color), in: .capsule)
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
    /// Grows with the text on iOS, so a row keeps its proportions at every
    /// text size; the Mac keeps its fixed tile.
    #if os(iOS)
    @ScaledMetric(relativeTo: .body) private var size = WitermMetrics.iconTile
    #else
    private let size = WitermMetrics.iconTile
    #endif

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.47, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(WitermTheme.tint(tint), in: .rect(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// An action inside content (Edit Address, Add Host, Save for Later): a
/// leading symbol and the semibold weight, so it never reads as a label.
/// The Mac keeps a plain title, where controls already look like controls.
struct ContentActionLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        #if os(iOS)
        Label(title, systemImage: systemImage).fontWeight(.semibold)
        #else
        Text(title)
        #endif
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
            HStack(spacing: WitermMetrics.Space.m) {
                summary
                Spacer(minLength: WitermMetrics.Space.s)
                HStack(spacing: WitermMetrics.Space.xs) { actions }
            }
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                summary
                HStack(spacing: WitermMetrics.Space.xs) { actions }
            }
        }
        .padding(.horizontal, WitermMetrics.Space.m)
        .padding(.vertical, WitermMetrics.Space.xxs)
        .frame(minHeight: 44)
        // A remote machine's hue washes the header and its edge, so the
        // terminal below always shows where input goes.
        .background(WitermTheme.surface.overlay(WitermTheme.tint(hue ?? .clear)))
        .overlay(alignment: .bottom) {
            if let hue { Rectangle().fill(WitermTheme.edge(hue)).frame(height: 1) } else { Divider() }
        }
        // Ink rather than an inherited tint, so text actions keep contrast on
        // the header surface.
        .tint(hue ?? WitermTheme.accent)
    }

    private var summary: some View {
        HStack(spacing: WitermMetrics.Space.s) {
            Circle()
                .fill(live ? WitermTheme.positive : WitermTheme.secondary)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                if let destination {
                    Text(verbatim: destination)
                        .font(WitermType.codeInline)
                        .foregroundStyle(WitermTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(destination)
                        .accessibilityIdentifier("terminalDestination")
                }
                if let title {
                    Text(title)
                        .font(WitermType.rowDetail.weight(.semibold))
                        .foregroundStyle(WitermTheme.ink)
                        .lineLimit(1)
                }
                Label(status, systemImage: statusImage)
                    .font(title == nil ? WitermType.rowDetail : WitermType.meta)
                    .foregroundStyle(title == nil ? WitermTheme.ink : WitermTheme.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("terminalInputStatus")
            }
        }
        .padding(.vertical, WitermMetrics.Space.s)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Stable solid content surface. Glass stays in the control layer.
    func witermCard(padding: CGFloat = WitermMetrics.cardPadding) -> some View {
        modifier(WitermCard(padding: padding))
    }

    /// Centers scrolling content at a comfortable reading width.
    func readableContent(padding: CGFloat = WitermMetrics.pagePadding) -> some View {
        self.padding(padding)
            .frame(maxWidth: WitermMetrics.readableWidth)
            .frame(maxWidth: .infinity)
    }
}

#if os(iOS)
import UIKit

/// An address, path, or code. SwiftUI text hyphenates a long word when it
/// wraps, which would show a host name that doesn't exist ("ex-ample"), so
/// this breaks only between characters, never adding a hyphen. One line
/// truncates in the middle; `lines: 0` wraps (accessibility text sizes).
struct AddressText: UIViewRepresentable {
    let text: String
    var lines = 1
    var style: UIFont.TextStyle = .caption1
    var monospaced = true
    var color = UIColor(named: "SecondaryInk") ?? .secondaryLabel

    init(_ text: String, lines: Int = 1, style: UIFont.TextStyle = .caption1, monospaced: Bool = true,
         color: UIColor = UIColor(named: "SecondaryInk") ?? .secondaryLabel) {
        self.text = text
        self.lines = lines
        self.style = style
        self.monospaced = monospaced
        self.color = color
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let metrics = UIFontMetrics(forTextStyle: style)
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        label.font = metrics.scaledFont(for: monospaced ? .monospacedSystemFont(ofSize: base.pointSize, weight: .regular) : base)
        label.numberOfLines = lines
        let paragraph = NSMutableParagraphStyle()
        paragraph.hyphenationFactor = 0
        paragraph.lineBreakMode = lines == 1 ? .byTruncatingMiddle : .byCharWrapping
        label.attributedText = NSAttributedString(string: text, attributes: [
            .paragraphStyle: paragraph, .font: label.font as Any, .foregroundColor: color])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(width, ceil(size.width)), height: ceil(size.height))
    }
}
#endif

/// A card holds one live object. On iOS its outline appears only with
/// Increase Contrast, like the system's grouped sections; the Mac keeps it.
private struct WitermCard: ViewModifier {
    let padding: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(WitermTheme.surface, in: .rect(cornerRadius: WitermMetrics.cardRadius, style: .continuous))
            .overlay {
                if showsOutline {
                    RoundedRectangle(cornerRadius: WitermMetrics.cardRadius, style: .continuous)
                        .strokeBorder(WitermTheme.hairline, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }

    private var showsOutline: Bool {
        #if os(iOS)
        contrast == .increased
        #else
        true
        #endif
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

#if os(macOS)
import AppKit

/// Hover feedback for custom, plain, or borderless clickable elements that
/// have no native hover, and for sidebar rows: a faint fill behind the
/// element. Native bordered buttons, toolbar items, and menus already respond
/// and don't use it. No feedback while disabled or inactive (a selected row);
/// a 150 ms fade, or none with Reduce Motion; twice as strong with Increase
/// Contrast. Hover never reveals anything that isn't already on screen.
private struct WitermHover: ViewModifier {
    var cornerRadius: CGFloat
    /// How far the fill reaches past the element, such as to a row's edges.
    var outset: CGSize = .zero
    var isActive = true
    var strength = 0.08
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            // The whole element responds, not only its text and symbols.
            .contentShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovering && isEnabled && isActive ? (contrast == .increased ? strength * 2 : strength) : 0))
                    .padding(.horizontal, -outset.width)
                    .padding(.vertical, -outset.height)
                    .allowsHitTesting(false)
            }
            // An AppKit tracking area rather than `onHover`, which missed
            // the pointer inside scroll views (forms, the Continue sheet).
            .background(HoverTracker { inside in
                if reduceMotion { hovering = inside } else { withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
            }
            .padding(.horizontal, -outset.width)
            .padding(.vertical, -outset.height))
    }
}

/// Reports the pointer entering and leaving its frame, wherever it sits, and
/// never takes clicks.
private struct HoverTracker: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.changed = changed }

    final class TrackingView: NSView {
        var changed: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { changed?(true) }
        override func mouseExited(with event: NSEvent) { changed?(false) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { changed?(false) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The pointing hand, for links and link-like text controls only; never for
/// bordered buttons, toolbar items, sidebar rows, or menus. A disabled
/// control keeps the arrow.
private struct WitermLinkPointer: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var pushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(isEnabled ? .link : nil)
        } else {
            content.onHover { inside in
                if inside, isEnabled, !pushed { NSCursor.pointingHand.push(); pushed = true }
                else if !inside, pushed { NSCursor.pop(); pushed = false }
            }
        }
    }
}

extension View {
    /// Hover feedback for a custom clickable element; see `WitermHover`.
    func witermHover(cornerRadius: CGFloat = 8) -> some View { modifier(WitermHover(cornerRadius: cornerRadius)) }

    /// Hover for a sidebar row: a lighter fill than selection, in the
    /// selection's shape, and none on the selected row. List selection,
    /// dragging, context menus, and keyboard use are untouched.
    func witermRowHover(selected: Bool) -> some View {
        modifier(WitermHover(cornerRadius: 6, outset: CGSize(width: 8, height: 4), isActive: !selected, strength: 0.06))
    }

    /// The pointing hand over a link or link-like text control.
    func witermLinkPointer() -> some View { modifier(WitermLinkPointer()) }
}
#endif
