import SwiftUI

extension TerminalActivity {
    /// The folder, with the home folder written as `~` when it is known.
    func folder(home: String?) -> String? {
        guard let directory else { return nil }
        guard let home, !home.isEmpty, directory == home || directory.hasPrefix(home + "/") else { return directory }
        return "~" + directory.dropFirst(home.count)
    }

    /// One line for compact rows: what is running and where, or else the last line.
    func summary(home: String?) -> String? {
        let parts = [title, folder(home: home)].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return lastLine
    }
}

/// How long ago output last arrived, refreshed once a minute.
struct ActivityAge: View {
    let date: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date.timeIntervalSince(date) < 60
                 ? String(localized: "now", bundle: .main)
                 : date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
        }
    }
}

/// A live terminal on a list: where it is, its last line, and what runs
/// there, so a person can tell from the list whether to open it.
struct TerminalActivityCard: View {
    let name: String
    let location: String
    let activity: TerminalActivity?
    let hue: Color
    var home: String? = nil
    /// Shown as the status pill when the terminal is not live.
    var status: String? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 0) {
            hue.frame(width: 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: WitermMetrics.Space.s) {
                    Text(name).font(WitermType.cardTitle).foregroundStyle(WitermTheme.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: WitermMetrics.Space.xs)
                    if let changed = activity?.changedAt {
                        ActivityAge(date: changed).font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
                    }
                }
                place
                if let line = activity?.lastLine {
                    Text(verbatim: line)
                        .font(WitermType.codeInline)
                        .foregroundStyle(WitermTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, WitermMetrics.Space.s)
                        .padding(.vertical, WitermMetrics.Space.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WitermTheme.statusFill, in: .rect(cornerRadius: WitermMetrics.Radius.s))
                }
                if let status {
                    StatusBadge(status, systemImage: WitermSymbols.disconnected)
                } else {
                    StatusBadge(activity?.title.map { String(localized: "Connected · \($0)", bundle: .main) }
                                ?? String(localized: "Connected", bundle: .main),
                                systemImage: WitermSymbols.connected, tone: .positive)
                }
            }
            .padding(.horizontal, WitermMetrics.Space.m)
            .padding(.vertical, WitermMetrics.Space.s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Where it is and the folder. On iOS an address wraps between
    /// characters at large sizes, never with a hyphen.
    @ViewBuilder private var place: some View {
        let text = [location, activity?.folder(home: home)].compactMap { $0 }.joined(separator: " · ")
        #if os(iOS)
        AddressText(text, lines: typeSize.isAccessibilitySize ? 0 : 1, monospaced: false)
        #else
        Text(verbatim: text)
            .font(WitermType.meta)
            .foregroundStyle(WitermTheme.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        #endif
    }
}
