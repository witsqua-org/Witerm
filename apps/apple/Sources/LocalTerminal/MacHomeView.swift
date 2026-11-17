#if os(macOS)
import SwiftUI
import WitermCore

/// A terminal on this Mac as Home shows it.
struct HomeTerminal: Identifiable {
    let id: String
    let name: String
    /// Where it is and what it's doing (title and folder), or when it started.
    let detail: String
    /// A path or output, set in the code font; "Started …" isn't.
    let detailIsCode: Bool
    /// Its last line as last seen here, when that adds something.
    let lastLine: String?
    /// How this window has it open, if it does.
    let here: LocalAttachmentMode?
    let shared: Bool
    let keptPrivate: Bool
    /// Who else has it open: Typing on iPhone, Watching on iPad.
    let elsewhere: [String]
    /// A long command that ended while it wasn't shown here, until it's
    /// opened (Round 28).
    var finished: LocalTerminalModel.FinishedCommand? = nil
}

/// A saved SSH host as Home shows it.
struct HomeHost: Identifiable {
    let id: UUID
    let name: String
    let detail: String?
    let connected: Bool
    let favorite: Bool
    let hue: Color
}

/// The Devices row's state, the same words the sidebar uses.
struct HomeDevices {
    let status: String
    let symbol: String
    let tint: Color
    /// The paired devices by name, or how to start.
    let detail: String
}

/// Home (Round 27): what a person sees first, instead of an empty pane.
/// A command bar that reaches everything by name and acts in place (Open
/// Quickly, inline), then this Mac's terminals, the SSH hosts, and the
/// devices that can open them, each as cards that open with one click, and
/// each section's one way to add more. Problems that stop a section from
/// working (terminals off, tmux missing) show in that section with their fix,
/// so nothing on the page is a button that silently can't work.
struct MacHomeView: View {
    let service: LocalAgentService
    let terminalModel: LocalTerminalModel
    let terminals: [HomeTerminal]
    let hosts: [HomeHost]
    let devices: HomeDevices
    let canCreate: Bool
    let items: [QuickOpenItem]
    let suggestions: (String) -> [QuickOpenItem]
    let newTerminal: () -> Void
    let addHost: () -> Void
    let importHosts: () -> Void
    let openTerminal: (String, LocalAttachmentMode) -> Void
    let openHost: (UUID) -> Void
    let showDevices: () -> Void
    let pairDevice: () -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @State private var recent = QuickOpenRanking.loadRecent()
    @FocusState private var fieldFocused: Bool
    /// The command bar takes the keyboard when Home first appears after
    /// launch, so typing a name and Return is the fastest way anywhere; after
    /// that it waits for a click, so arrowing through the sidebar isn't
    /// interrupted.
    @MainActor private static var focusedOnce = false

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: WitermMetrics.Space.m)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xxl + WitermMetrics.Space.s) {
                commandBar
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    thisMac
                    sshHosts
                    devicesSection
                }
            }
            .padding(.horizontal, WitermMetrics.Space.xxl + WitermMetrics.Space.s)
            .padding(.vertical, WitermMetrics.Space.xxl)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .background(WitermTheme.canvas)
        .navigationTitle("Witerm")
        .onAppear {
            if !Self.focusedOnce {
                Self.focusedOnce = true
                fieldFocused = true
            }
        }
    }

    // MARK: Command bar

    private var results: [QuickOpenItem] {
        suggestions(query) + QuickOpenRanking.rank(items, query: query, recent: recent)
    }

    private var commandBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: WitermMetrics.Space.s) {
                QuickOpenField(query: $query, focused: $fieldFocused,
                               prompt: String(localized: "Open a terminal, connect to a host, or run a command", bundle: .main),
                               move: { highlighted = QuickOpenCursor.moved($0, in: results, from: highlighted) },
                               submit: { if let item = QuickOpenCursor.current(in: results, highlighted: highlighted) { choose(item) } })
                    .onExitCommand { query = "" }
                Text(verbatim: "⇧⌘O")
                    .font(WitermType.meta)
                    .foregroundStyle(WitermTheme.secondary)
                    .help(String(localized: "Open Quickly from anywhere", bundle: .main))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, WitermMetrics.Space.l)
            .padding(.vertical, WitermMetrics.Space.m)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider()
                // As tall as its results, up to a screenful; no results says so.
                let shown = results
                QuickOpenResults(results: shown, query: query, highlighted: $highlighted, open: choose)
                    .frame(height: shown.isEmpty ? 200 : min(CGFloat(shown.count) * 52 + 16, 420))
            }
        }
        .background(WitermTheme.surface, in: .rect(cornerRadius: WitermMetrics.Radius.l, style: .continuous))
        .witermOutline(cornerRadius: WitermMetrics.Radius.l, hairline: true)
        .onChange(of: query) { highlighted = results.first?.id }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("homeCommandBar")
    }

    private func choose(_ item: QuickOpenItem) {
        recent = QuickOpenRanking.remember(item.id, in: recent)
        QuickOpenRanking.saveRecent(recent)
        query = ""
        fieldFocused = false
        item.perform()
    }

    // MARK: This Mac

    private var thisMac: some View {
        HomeSection(String(localized: "This Mac", bundle: .main)) {
            // With none yet, the card where they'll appear is the way in.
            if !terminals.isEmpty {
                Button(String(localized: "New Terminal", bundle: .main), systemImage: "plus", action: newTerminal)
                    .disabled(!canCreate)
                    .help(LocalTerminalHelp.newTerminal)
                    .accessibilityIdentifier("homeNewTerminal")
            }
        } content: {
            if service.state != .ready || service.client == nil {
                // Why there's nothing to open, and the one thing that fixes it.
                LocalServiceSetupView(service: service)
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .homeSurface()
            } else if !terminalModel.tmuxAvailable, let client = service.client {
                LocalDependencyView(model: terminalModel, client: client)
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .homeSurface()
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: WitermMetrics.Space.m) {
                    ForEach(terminals) { terminal in terminalCard(terminal) }
                    if terminals.isEmpty {
                        HomeAddCard(title: String(localized: "New Terminal", bundle: .main),
                                    detail: String(localized: "Keeps running after you quit, and opens on your other devices", bundle: .main),
                                    systemImage: "terminal", shortcut: "⌘N", action: newTerminal)
                            .disabled(!canCreate)
                            .accessibilityIdentifier("homeNewTerminalCard")
                    }
                }
                if terminals.isEmpty {
                    // Terminals started from any terminal app show up here too.
                    HStack(spacing: WitermMetrics.Space.s) {
                        Text(String(localized: "Or start one from any terminal app:", bundle: .main))
                            .font(WitermType.rowDetail)
                            .foregroundStyle(WitermTheme.secondary)
                        StartFromTerminalHint()
                    }
                }
            }
        }
    }

    private func terminalCard(_ terminal: HomeTerminal) -> some View {
        HomeCard(title: terminal.name, detail: terminal.detail, detailIsCode: terminal.detailIsCode, extra: terminal.lastLine,
                 systemImage: terminal.here == nil ? "terminal" : "terminal.fill",
                 tint: terminal.here == nil ? WitermTheme.accent : WitermTheme.positive) {
            openTerminal(terminal.id, .control)
        } status: {
            HStack(spacing: WitermMetrics.Space.s) {
                if let finished = terminal.finished {
                    // Refreshed each minute, so "just finished" ages honestly.
                    TimelineView(.everyMinute) { context in
                        Label(MacWorkspaceView.finishedText(finished, now: context.date), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(WitermTheme.positive)
                            .lineLimit(1)
                    }
                }
                if terminal.here == .control {
                    Label(String(localized: "Typing", bundle: .main), systemImage: WitermSymbols.typing)
                } else if terminal.here == .view {
                    Label(String(localized: "Watching", bundle: .main), systemImage: WitermSymbols.watching)
                }
                if terminal.keptPrivate {
                    Label(String(localized: "Private", bundle: .main), systemImage: WitermSymbols.keptPrivate)
                } else if terminal.shared {
                    Label(String(localized: "Shared", bundle: .main), systemImage: WitermSymbols.sharing)
                }
                if !terminal.elsewhere.isEmpty {
                    Label(ListFormatter.localizedString(byJoining: terminal.elsewhere), systemImage: WitermSymbols.openOn)
                        .foregroundStyle(WitermTheme.positive)
                        .lineLimit(1)
                }
            }
            .labelStyle(.titleAndIcon)
        }
        .contextMenu {
            Button(LocalTerminalHelp.open, systemImage: WitermSymbols.typing) { openTerminal(terminal.id, .control) }
            Button(String(localized: "Watch", bundle: .main), systemImage: WitermSymbols.watching) { openTerminal(terminal.id, .view) }
        }
        .accessibilityIdentifier("homeTerminal-\(terminal.id)")
    }

    // MARK: SSH Hosts

    private var sshHosts: some View {
        HomeSection(String(localized: "SSH Hosts", bundle: .main)) {
            Button(String(localized: "Import…", bundle: .main), systemImage: "square.and.arrow.down", action: importHosts)
                .help(String(localized: "Import hosts from an OpenSSH config file", bundle: .main))
            if !hosts.isEmpty {
                Button(String(localized: "Add SSH Host…", bundle: .main), systemImage: "plus", action: addHost)
                    .help(LocalTerminalHelp.addSSHHost)
                    .accessibilityIdentifier("homeAddSSHHost")
            }
        } content: {
            LazyVGrid(columns: columns, alignment: .leading, spacing: WitermMetrics.Space.m) {
                ForEach(hosts) { host in
                    HomeCard(title: host.name, detail: host.detail, systemImage: host.connected ? "terminal.fill" : WitermSymbols.sshHost,
                             tint: host.hue) {
                        openHost(host.id)
                    } status: {
                        HStack(spacing: WitermMetrics.Space.s) {
                            if host.connected {
                                Label(String(localized: "Connected", bundle: .main), systemImage: WitermSymbols.connected)
                                    .foregroundStyle(WitermTheme.positive)
                            } else {
                                Label(String(localized: "Not connected", bundle: .main), systemImage: WitermSymbols.disconnected)
                            }
                            if host.favorite {
                                Label(String(localized: "Favorite", bundle: .main), systemImage: "star.fill")
                            }
                        }
                    }
                    .accessibilityIdentifier("homeHost-\(host.id.uuidString)")
                }
                if hosts.isEmpty {
                    HomeAddCard(title: String(localized: "Add SSH Host…", bundle: .main),
                                detail: String(localized: "Sign in to another computer. No relay server needed.", bundle: .main),
                                systemImage: "network", shortcut: "⇧⌘N", action: addHost)
                        .accessibilityIdentifier("homeAddSSHHostCard")
                }
            }
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        HomeSection(String(localized: "Devices", bundle: .main)) {
            Button(String(localized: "Pair a Device…", bundle: .main), systemImage: WitermSymbols.pair, action: pairDevice)
                .accessibilityIdentifier("homePairDevice")
        } content: {
            Button(action: showDevices) {
                HStack(spacing: WitermMetrics.Space.m) {
                    IconTile(systemImage: WitermSymbols.openOn)
                    VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                        Label(devices.status, systemImage: devices.symbol)
                            .foregroundStyle(devices.tint)
                            .font(WitermType.rowTitle)
                        Text(devices.detail)
                            .font(WitermType.rowDetail)
                            .foregroundStyle(WitermTheme.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: WitermMetrics.Space.s)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(WitermTheme.secondary)
                        .accessibilityHidden(true)
                }
                .padding(WitermMetrics.Space.m)
                .contentShape(Rectangle())
                .homeSurface()
                .witermHover(cornerRadius: WitermMetrics.Radius.l)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Devices", bundle: .main))
            .accessibilityValue("\(devices.status), \(devices.detail)")
            .accessibilityIdentifier("homeDevices")
        }
    }
}

/// A Home section: a heading with its actions on the right, then content.
private struct HomeSection<Actions: View, Content: View>: View {
    let title: String
    let actions: Actions
    let content: Content

    init(_ title: String, @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.title = title
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WitermMetrics.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: WitermMetrics.Space.s) {
                Text(title)
                    .font(WitermType.cardTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: WitermMetrics.Space.s)
                actions
                    .buttonStyle(.borderless)
                    .controlSize(.regular)
            }
            content
        }
    }
}

/// One thing to open: a tile in its color, its name, one line of what it is
/// or is doing, and its state in words and symbols. The whole card is the
/// button.
private struct HomeCard<Status: View>: View {
    let title: String
    let detail: String?
    var detailIsCode = true
    /// A second line of output (a terminal's last line).
    var extra: String? = nil
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @ViewBuilder let status: () -> Status

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: WitermMetrics.Space.m) {
                IconTile(systemImage: systemImage, tint: tint)
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                    Text(title)
                        .font(WitermType.rowTitle)
                        .foregroundStyle(WitermTheme.ink)
                        .lineLimit(1)
                    if let detail {
                        Text(verbatim: detail)
                            .font(detailIsCode ? WitermType.codeInline : WitermType.rowDetail)
                            .foregroundStyle(WitermTheme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let extra {
                        Text(verbatim: extra)
                            .font(WitermType.codeInline)
                            .foregroundStyle(WitermTheme.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    status()
                        .font(WitermType.meta)
                        .foregroundStyle(WitermTheme.secondary)
                        .padding(.top, WitermMetrics.Space.xxs)
                }
                Spacer(minLength: 0)
            }
            .padding(WitermMetrics.Space.m)
            // Centered in the row's height, so a card with fewer lines than
            // its neighbours doesn't leave a band at its foot.
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .contentShape(Rectangle())
            .background(alignment: .top) {
                // The machine's hue along the top edge, as on its terminal.
                if tint != WitermTheme.accent, tint != WitermTheme.positive {
                    tint.opacity(0.55).frame(height: 3).accessibilityHidden(true)
                }
            }
            .background(WitermTheme.surface)
            .clipShape(.rect(cornerRadius: WitermMetrics.Radius.l, style: .continuous))
            .witermOutline(cornerRadius: WitermMetrics.Radius.l, hairline: true)
            .witermHover(cornerRadius: WitermMetrics.Radius.l)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// The way to make the first one of something, where it would appear.
private struct HomeAddCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let shortcut: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: WitermMetrics.Space.m) {
                IconTile(systemImage: systemImage)
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                    HStack {
                        Text(title).font(WitermType.rowTitle)
                        Spacer(minLength: WitermMetrics.Space.s)
                        Text(verbatim: shortcut)
                            .font(WitermType.meta)
                            .foregroundStyle(WitermTheme.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(detail)
                        .font(WitermType.rowDetail)
                        .foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(WitermMetrics.Space.m)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: WitermMetrics.Radius.l, style: .continuous)
                    .strokeBorder(WitermTheme.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .witermHover(cornerRadius: WitermMetrics.Radius.l, active: enabled)
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// A card's solid surface and edge.
    func homeSurface() -> some View {
        background(WitermTheme.surface, in: .rect(cornerRadius: WitermMetrics.Radius.l, style: .continuous))
            .witermOutline(cornerRadius: WitermMetrics.Radius.l, hairline: true)
    }
}
#endif
