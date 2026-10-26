import SwiftTerm

enum TerminalPalette {
    /// Foreground-oriented ANSI16 palette. True-color TUI choices remain owned
    /// by the remote application; this does not promise arbitrary color pairs.
    static func colors(highContrast: Bool, dark: Bool) -> [SwiftTerm.Color] {
        guard highContrast else { return SwiftTerm.Color.defaultInstalledColors }
        let values: [UInt32] = dark
            ? [0x767676, 0xFF8C8C, 0x8EE28E, 0xF4DE88, 0x91BEFF, 0xEAA4EA, 0x88DDDD, 0xEEEEEE,
               0xAAAAAA, 0xFFAFAF, 0xB2F4B2, 0xFFEDA5, 0xB8D5FF, 0xF4C2F4, 0xB0F2F2, 0xFFFFFF]
            : [0x111111, 0x9A1515, 0x226522, 0x725300, 0x174EA6, 0x792879, 0x006262, 0x595959,
               0x4A4A4A, 0xAB2020, 0x226822, 0x765300, 0x2055AD, 0x852985, 0x006767, 0x656565]
        return values.map { SwiftTerm.Color(red8: UInt16(($0 >> 16) & 255), green8: UInt16(($0 >> 8) & 255), blue8: UInt16($0 & 255)) }
    }
}
