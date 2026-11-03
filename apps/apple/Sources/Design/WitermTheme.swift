import SwiftUI

enum WitermTheme {
    static let accent = Color("AccentColor")
    static let actionLabel = Color("ActionLabel")
    static let secondary = Color("SecondaryInk")
    static let ink = Color("Ink")
    #if os(macOS)
    static let canvas = Color("Canvas")
    #else
    /// The system grouped background, so custom pages match lists, forms and
    /// system sheets.
    static let canvas = Color(uiColor: .systemGroupedBackground)
    #endif
    static let surface = Color("Surface")
    #if os(macOS)
    static let divider = Color(nsColor: .separatorColor)
    #else
    static let divider = Color(uiColor: .separator)
    #endif
    static let statusFill = Color.primary.opacity(0.06)
    static let warning = Color("Warning")
    /// Healthy state that belongs to no machine: a reachable server, an attached local session.
    static let positive = Color("Positive")
    /// A hairline between parts of a surface.
    static var hairline: Color { divider }
    /// A machine's hue as a tile or badge fill.
    static func tint(_ hue: Color) -> Color { hue.opacity(0.12) }
    /// A machine's hue as an edge line (the 2 pt line over its terminal).
    static func edge(_ hue: Color) -> Color { hue.opacity(0.55) }
    /// A selected card or choice: fill and border (`WitermMetrics.selectedBorder`).
    static let selectedFill = Color("AccentColor").opacity(0.10)
    static let selectedBorder = Color("AccentColor")
    /// The outline of a card, field or choice: none normally (the fill
    /// carries the shape), a visible line with Increase Contrast.
    static func outline(increasedContrast: Bool) -> Color { increasedContrast ? Color.primary.opacity(0.45) : .clear }
    /// Pointer hover on rows and custom controls (Mac). Never on a selected item.
    static func hoverFill(increasedContrast: Bool) -> Color { Color.primary.opacity(increasedContrast ? 0.12 : 0.06) }
}

/// One scale for every screen: compact on the pointer-driven Mac, touch-sized
/// on iOS, and never larger than the content needs. The names are shared;
/// where the platforms differ, the Mac value comes first. See the Design
/// spec in docs/design/README.md.
enum WitermMetrics {
    /// Spacing on a 4 pt grid (2 only for stacked text).
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        #if os(macOS)
        static let xxl: CGFloat = 24
        #else
        static let xxl: CGFloat = 32
        #endif
    }

    /// Corner radii. Inner shapes stay concentric: inner = outer − padding.
    enum Radius {
        #if os(macOS)
        /// Controls, keys, chips, hover and sidebar selection.
        static let s: CGFloat = 6
        /// Fields, inline fills, nested cards, code tiles.
        static let m: CGFloat = 8
        /// Cards, banners, choice cards.
        static let l: CGFloat = 12
        /// Hero tiles.
        static let xl: CGFloat = 16
        #else
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 28
        #endif
    }

    static var cardRadius: CGFloat { Radius.l }
    static let cardPadding: CGFloat = Space.l
    static let iconTile: CGFloat = 32
    static let readableWidth: CGFloat = 640
    static let pagePadding: CGFloat = Space.xl
    /// Horizontal inset of a sheet's header, content and footer.
    static let sheetInset: CGFloat = Space.xl
    static let selectedBorder: CGFloat = 1.5
}

/// Text roles, never sizes, so the system text size and Dynamic Type apply.
/// Weights are regular and semibold only (bold for `heroTitle`).
enum WitermType {
    /// One per sheet or page that has no navigation title.
    static let pageTitle = Font.title2.weight(.semibold)
    /// The tour and empty states only.
    static let heroTitle = Font.title2.bold()
    /// A card's or banner's title; a device's name on its own page.
    static let cardTitle = Font.headline
    /// A list row's title.
    static let rowTitle = Font.body
    /// A row's second line, explanations, status.
    #if os(macOS)
    static let rowDetail = Font.callout
    #else
    static let rowDetail = Font.subheadline
    #endif
    /// Metadata only: ages, counts, hints under fields.
    static let meta = Font.caption
    /// Commands, fingerprints and addresses on a detail page.
    static let code = Font.body.monospaced()
    /// Addresses and last lines inside rows.
    static let codeInline = Font.caption.monospaced()
    /// The one code a person compares on a pairing screen.
    static let codeHero = Font.title3.monospaced()
}

/// One symbol per idea, in both apps.
enum WitermSymbols {
    static let problem = "exclamationmark.triangle.fill"
    static let unpaired = "exclamationmark.shield.fill"
    static let more = "ellipsis.circle"
    static let connected = "circle.fill"
    static let disconnected = "bolt.horizontal.circle"
    static let typing = "keyboard"
    static let watching = "eye"
    static let leave = "rectangle.portrait.and.arrow.right"
    static let disconnect = "xmark.circle"
    static let sharing = "antenna.radiowaves.left.and.right"
    static let keptPrivate = "lock.fill"
    static let pair = "link"
    static let openOn = "laptopcomputer.and.iphone"
    /// Only on a control that does nothing but scan.
    static let scan = "qrcode.viewfinder"
    static let relayServer = "server.rack"
    static let sshHost = "terminal"
    static let offline = "wifi.slash"
}

enum WitermMotion {
    static func transition(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.88)
    }
}

/// The canvas with a faint, static accent glow. Nothing in it animates.
struct WorkspaceBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            WitermTheme.canvas
            if !reduceTransparency, contrast != .increased {
                RadialGradient(
                    colors: [WitermTheme.accent.opacity(0.09), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 520
                )
            }
        }
        .ignoresSafeArea()
    }
}

struct BrandEmblem: View {
    var size: CGFloat = 60

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                // The app icon's graphite tile.
                .fill(LinearGradient(colors: [Color(red: 0.173, green: 0.184, blue: 0.208), Color(red: 0.043, green: 0.047, blue: 0.055)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .padding(size * 0.16)
        }
        .frame(width: size, height: size)
        .shadow(color: WitermTheme.accent.opacity(0.18), radius: 16, x: 0, y: 8)
    }
}
