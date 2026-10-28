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
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.headline).foregroundStyle(WitermTheme.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: 4)
                    if let changed = activity?.changedAt {
                        ActivityAge(date: changed).font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                }
                Text(verbatim: [location, activity?.folder(home: home)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(WitermTheme.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.middle)
                if let line = activity?.lastLine {
                    Text(verbatim: line)
                        .font(.caption.monospaced())
                        .foregroundStyle(WitermTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WitermTheme.statusFill, in: .rect(cornerRadius: 6))
                }
                if let status {
                    StatusBadge(status, systemImage: "bolt.horizontal.circle")
                } else {
                    StatusBadge(activity?.title.map { String(localized: "Connected · \($0)", bundle: .main) }
                                ?? String(localized: "Connected", bundle: .main),
                                systemImage: "circle.fill", tone: .positive)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
