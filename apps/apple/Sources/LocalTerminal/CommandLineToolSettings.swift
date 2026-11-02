#if os(macOS)
import AppKit
import Darwin
import Observation
import SwiftUI

/// The `witerm` command inside this app, and the link that puts it on the
/// command line. The link points into the app bundle, so the command always
/// matches the background service it talks to.
@MainActor @Observable
final class CommandLineToolModel {
    /// One state for Settings and the empty-state hint, so installing in one
    /// shows in the other.
    static let shared = CommandLineToolModel()

    enum State: Equatable {
        /// Nothing at the link path.
        case notInstalled
        /// The link points at this app's command.
        case installed
        /// A link to another copy of Witerm's command, such as an older app.
        case otherCopy(String)
        /// Something that isn't Witerm's link; it is never replaced.
        case blocked
    }

    private(set) var state = State.notInstalled
    private(set) var issue: String?

    let linkURL: URL = CommandLineToolModel.homeDirectory.appendingPathComponent(".local/bin/witerm")
    var bundledURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/witerm") }
    var isBundled: Bool { FileManager.default.isExecutableFile(atPath: bundledURL.path) }
    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        return (info?["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }

    /// The command to type: `witerm` once installed, otherwise the full path.
    var command: String {
        state == .installed ? "witerm" : "'" + bundledURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func refresh() {
        issue = nil
        let manager = FileManager.default
        guard let destination = try? manager.destinationOfSymbolicLink(atPath: linkURL.path) else {
            var info = stat()
            state = lstat(linkURL.path, &info) == 0 ? .blocked : .notInstalled
            return
        }
        let target = URL(fileURLWithPath: destination, relativeTo: linkURL.deletingLastPathComponent()).standardizedFileURL
        if target.path == bundledURL.standardizedFileURL.path {
            state = .installed
        } else if Self.isWitermCommand(target) {
            state = .otherCopy(target.path)
        } else {
            state = .blocked
        }
    }

    func install() {
        refresh()
        guard isBundled, state != .blocked else { return }
        do {
            let directory = linkURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if state != .notInstalled { try FileManager.default.removeItem(at: linkURL) }
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: bundledURL)
        } catch {
            issue = String(localized: "Unable to install the command. Check that you can write to ~/.local/bin.", bundle: .main)
        }
        if issue == nil { refresh() } else { let failure = issue; refresh(); issue = failure }
    }

    func remove() {
        refresh()
        guard state == .installed || { if case .otherCopy = state { return true }; return false }() else { return }
        do { try FileManager.default.removeItem(at: linkURL) } catch {
            issue = String(localized: "Unable to remove the command. Try again.", bundle: .main)
        }
        if issue == nil { refresh() } else { let failure = issue; refresh(); issue = failure }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A `witerm` executable in some Witerm app's `Contents/Helpers`.
    private static func isWitermCommand(_ url: URL) -> Bool {
        url.lastPathComponent == "witerm"
            && url.deletingLastPathComponent().lastPathComponent == "Helpers"
            && url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents"
    }

    /// The account's home, not the app's environment.
    private static var homeDirectory: URL {
        if let entry = getpwuid(geteuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: FileManager.default.string(withFileSystemRepresentation: directory, length: strlen(directory)), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// Settings → Command Line: install the `witerm` command and copy examples.
struct CommandLineToolSettings: View {
    private let model = CommandLineToolModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Status", bundle: .main)) {
                    StatusBadge(statusTitle, systemImage: statusSymbol, tone: model.state == .installed ? .positive : .neutral)
                        .accessibilityIdentifier("commandLineStatus")
                }
                LabeledContent(String(localized: "Command", bundle: .main)) {
                    Text(model.linkURL.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(String(localized: "Version", bundle: .main), value: model.version)
                if case .otherCopy(let path) = model.state {
                    Text(String(localized: "The installed command belongs to another copy of Witerm at \(path).", bundle: .main))
                        .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                }
                if model.state == .blocked {
                    Text(String(localized: "Another file already uses this path. Witerm won't replace it.", bundle: .main))
                        .font(.subheadline).foregroundStyle(WitermTheme.warning)
                }
                if !model.isBundled {
                    Text(String(localized: "This copy of Witerm doesn't include the command. Reinstall Witerm.", bundle: .main))
                        .font(.subheadline).foregroundStyle(WitermTheme.warning)
                }
                if let issue = model.issue {
                    Text(issue).font(.subheadline).foregroundStyle(WitermTheme.warning)
                }
                HStack {
                    switch model.state {
                    case .installed:
                        Button(String(localized: "Uninstall", bundle: .main), role: .destructive, action: model.remove)
                            .accessibilityIdentifier("uninstallCommandLine")
                    case .otherCopy:
                        Button(String(localized: "Use This Copy", bundle: .main), action: model.install)
                            .accessibilityIdentifier("installCommandLine")
                    case .notInstalled:
                        Button(String(localized: "Install", bundle: .main), action: model.install)
                            .disabled(!model.isBundled)
                            .accessibilityIdentifier("installCommandLine")
                    case .blocked:
                        EmptyView()
                    }
                    Spacer()
                }
            } header: {
                Text(String(localized: "Command Line Tool", bundle: .main))
            }

            if model.state == .installed {
                Section {
                    CopyableCommand("export PATH=\"$HOME/.local/bin:$PATH\"")
                } header: {
                    Text(String(localized: "If your shell can't find witerm", bundle: .main))
                }
            }

            Section(String(localized: "Examples", bundle: .main)) {
                CopyableCommand("\(model.command) new --share", caption: String(localized: "Start a shared session in the current folder", bundle: .main))
                CopyableCommand("\(model.command) sessions", caption: String(localized: "List sessions and who is attached", bundle: .main))
                CopyableCommand("\(model.command) attach <session>", caption: String(localized: "Attach; press Enter then ~. to detach", bundle: .main))
                CopyableCommand("\(model.command) unshare", caption: String(localized: "Stop sharing the session you're in", bundle: .main))
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: model.refresh)
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh() } }
    }

    private var statusTitle: String {
        switch model.state {
        case .installed: String(localized: "Installed", bundle: .main)
        case .notInstalled: String(localized: "Not Installed", bundle: .main)
        case .otherCopy: String(localized: "Installed from Another Copy", bundle: .main)
        case .blocked: String(localized: "Path In Use", bundle: .main)
        }
    }

    private var statusSymbol: String {
        switch model.state {
        case .installed: "checkmark.circle.fill"
        case .notInstalled: "circle.dashed"
        case .otherCopy, .blocked: "exclamationmark.circle"
        }
    }
}

/// A command in monospaced text with a Copy button.
struct CopyableCommand: View {
    let command: String
    let caption: String?

    init(_ command: String, caption: String? = nil) {
        self.command = command
        self.caption = caption
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(WitermTheme.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(String(localized: "Copy", bundle: .main)) { CommandLineToolModel.copy(command) }
                .accessibilityLabel(String(localized: "Copy \(command)", bundle: .main))
        }
    }
}
#endif
