#if os(iOS)
import UIKit

/// The one style for buttons that float over a terminal (the keyboard
/// button, Jump to Latest) and for Hide Keyboard on the key row: a 44 pt
/// system glass capsule on iOS 26 and later, which brings its own depth;
/// with Reduce Transparency (or before iOS 26) a solid gray capsule with
/// the same soft shadow, so it still reads as something to press rather
/// than a flat label. Restyled when Reduce Transparency changes.
@MainActor enum FloatingTerminalButton {
    /// Width and height of a floating button.
    static let side: CGFloat = 44
    /// Space from the trailing edge, or the safe area when that's wider.
    static let trailing: CGFloat = WitermMetrics.Space.l
    /// Space between a floating button and what it sits above.
    static let gap: CGFloat = WitermMetrics.Space.s

    static var usesGlass: Bool {
        if #available(iOS 26.0, *) { return !UIAccessibility.isReduceTransparencyEnabled }
        return false
    }

    static func configuration(symbol: String, textStyle: UIFont.TextStyle = .body) -> UIButton.Configuration {
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *), usesGlass { configuration = .glass() } else { configuration = .gray() }
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: textStyle)
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        return configuration
    }

    /// Applies the style, and the fallback's shadow (glass has its own).
    static func style(_ button: UIButton, symbol: String, textStyle: UIFont.TextStyle = .body) {
        button.configuration = configuration(symbol: symbol, textStyle: textStyle)
        button.backgroundColor = nil
        let layer = button.layer
        if usesGlass {
            layer.shadowOpacity = 0
        } else {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.18
            layer.shadowRadius = 6
            layer.shadowOffset = CGSize(width: 0, height: 2)
        }
    }
}
#endif
