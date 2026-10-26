import SwiftUI

enum WitermTheme {
    static let accent = Color("AccentColor")
    static let actionLabel = Color("ActionLabel")
    static let secondary = Color("SecondaryInk")
    static let ink = Color("Ink")
    static let canvas = Color("Canvas")
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
}

/// One scale for every screen: compact on the pointer-driven Mac, touch-sized
/// on iOS, and never larger than the content needs.
enum WitermMetrics {
    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let iconTile: CGFloat = 32
    static let readableWidth: CGFloat = 640
    static let pagePadding: CGFloat = 20
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
