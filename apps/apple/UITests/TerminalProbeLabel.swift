import Foundation

/// Reads the DEBUG layout probe that terminals add to their reading text's
/// label (`--witerm-ui-test-layout-probe`): ` key=value` fields, never
/// terminal content.
enum TerminalProbeLabel {
    static func text(_ label: String, _ key: String) -> String? {
        guard let range = label.range(of: " " + key + "=") else { return nil }
        return String(label[range.upperBound...].prefix { !$0.isWhitespace })
    }

    /// `x,y,w,h` fields such as `cursorCell`.
    static func numbers(_ label: String, _ key: String) -> [Double] {
        (text(label, key) ?? "").split(separator: ",").compactMap { Double($0.filter { $0 != "]" }) }
    }

    /// Round 22: after the keyboard was told to leave (the last `wcf`
    /// whose frame starts at `screenHeight` or below), how many
    /// milliseconds until the grid changed (`g…`) and until the keyboard
    /// said it had gone (`dh`). The probe's `events` are tags with the
    /// milliseconds since the one before.
    static func keyboardLeaving(_ label: String, screenHeight: Double) -> (grid: Int?, gone: Int?, events: String) {
        let events = text(label, "events") ?? ""
        let tags = events.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        // Tags hold commas inside parentheses: join them back.
        var joined: [String] = []
        for tag in tags {
            if let last = joined.last, last.contains("("), !last.contains(")") { joined[joined.count - 1] = last + "," + tag }
            else { joined.append(tag) }
        }
        func split(_ tag: String) -> (name: String, ms: Int) {
            guard let plus = tag.lastIndex(of: "+") else { return (tag, 0) }
            return (String(tag[..<plus]), Int(tag[tag.index(after: plus)...]) ?? 0)
        }
        let parsed = joined.map(split)
        guard let start = parsed.lastIndex(where: { tag in
            guard tag.name.hasPrefix("wcf("), let y = Double(tag.name.dropFirst(4).prefix { $0 != "," }) else { return false }
            return y >= screenHeight - 1
        }) else { return (nil, nil, events) }
        var elapsed = 0, grid: Int?, gone: Int?
        for tag in parsed[(start + 1)...] {
            elapsed += tag.ms
            if grid == nil, tag.name.hasPrefix("g"), tag.name.dropFirst().first?.isNumber == true { grid = elapsed }
            if gone == nil, tag.name.hasPrefix("dh(") { gone = elapsed }
        }
        return (grid, gone, events)
    }
}
