#if os(macOS)
import CoreTransferable
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WitermSSH

/// A remote file dragged out of the browser. The download starts only when
/// the drop lands, into a private (0700) temporary folder, with the same
/// filename checks as Download.
private struct RemoteFile: Transferable {
    let entry: SSHFileEntry
    let connection: SSHConnection

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            guard MacSFTPModel.usableName(file.entry.name) else { throw SSHFailure.invalidPath }
            let directory = try MacSFTPModel.privateDirectory()
            let destination = directory.appendingPathComponent(file.entry.name)
            try await file.connection.download(remotePath: file.entry.path, to: destination)
            return SentTransferredFile(destination, allowAccessingOriginalFile: false)
        }
    }
}

/// The SFTP browser's state on the Mac: one listing, one transfer at a time,
/// cancellable, never recursive, with downloads in a private folder that's
/// removed once saved. The same rules as iOS's `SSHFilesView`.
@MainActor @Observable
final class MacSFTPModel {
    /// The folder shown: what was asked for until a listing names it.
    var path = "."
    var entries: [SSHFileEntry] = []
    var loading = false
    var transferring = false
    var transferred: UInt64 = 0
    var total: UInt64?
    var issue: String?
    var exportURL: URL?
    var exporting = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var exportDirectory: URL?

    /// Absolute path components, for the breadcrumb; empty until known.
    var components: [String] {
        guard path.hasPrefix("/") else { return [] }
        return path.split(separator: "/").map(String.init)
    }

    func list(_ connection: SSHConnection, path next: String? = nil) async {
        guard !loading, !transferring else { return }
        loading = true; issue = nil
        defer { loading = false }
        do {
            let requested = next ?? path
            let result = try await connection.listDirectory(path: requested)
            try Task.checkCancellation()
            // Entries carry canonical paths; their folder is the one shown.
            if let first = result.first {
                path = (first.path as NSString).deletingLastPathComponent
            } else {
                path = requested
            }
            entries = result
        } catch { if !Task.isCancelled { issue = SSHUIError.message(error) } }
    }

    func child(_ name: String) -> String { (path == "/" ? "" : path) + "/" + name }

    /// The folder above, by path; "." until the folder's own path is known.
    var parent: String? {
        guard path.hasPrefix("/"), path != "/" else { return path == "/" ? nil : ".." }
        let up = (path as NSString).deletingLastPathComponent
        return up.isEmpty ? "/" : up
    }

    func upload(_ urls: [URL], connection: SSHConnection) {
        beginTransfer {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try Task.checkCancellation()
                try await connection.upload(localURL: url, to: self.child(url.lastPathComponent)) { _, _ in }
            }
        } completion: { await self.list(connection) }
    }

    func download(_ entry: SSHFileEntry, connection: SSHConnection) {
        guard Self.usableName(entry.name) else { issue = String(localized: "Unable to use this filename.", bundle: .main); return }
        beginTransfer {
            self.cleanupExport()
            let directory = try Self.privateDirectory()
            self.exportDirectory = directory
            let destination = directory.appendingPathComponent(entry.name)
            try await connection.download(remotePath: entry.path, to: destination) { _, _ in }
            try Task.checkCancellation()
            self.exportURL = destination
            self.exporting = true
        }
    }

    private func beginTransfer(_ operation: @escaping @MainActor () async throws -> Void,
                               completion: @escaping @MainActor () async -> Void = {}) {
        guard !transferring else { return }
        transferring = true; issue = nil
        task = Task {
            do { try await operation() } catch {
                cleanupExport()
                if !Task.isCancelled { issue = SSHUIError.message(error) }
            }
            transferring = false; task = nil
            if !Task.isCancelled { await completion() }
        }
    }

    func cancel() { task?.cancel() }

    func cleanupExport() {
        exportURL = nil
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
    }

    nonisolated static func usableName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    nonisolated static func privateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("witerm-sftp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }
}

/// SFTP Files on the Mac: a native table with selection. Double-click opens a
/// folder or downloads a file; the context menu offers Open, Download and
/// Delete…; files drag out to Finder and drop in to upload; a breadcrumb names
/// the folder. Deleting stays confirmed and never recursive.
struct MacSFTPBrowser: View {
    let connection: SSHConnection
    @State private var model = MacSFTPModel()
    @State private var selection = Set<SSHFileEntry.ID>()
    @State private var importing = false
    @State private var creating = false
    @State private var folderName = ""
    @State private var removing: SSHFileEntry?
    @State private var dropTargeted = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(String(localized: "SFTP Files", bundle: .main), width: .flow, height: 520, scrolls: false,
                      onEscape: close) {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.s) {
                breadcrumb
                if let issue = model.issue {
                    IssueBanner(issue).accessibilityIdentifier("sshSFTPIssue")
                }
                table
                    .overlay {
                        RoundedRectangle(cornerRadius: WitermMetrics.Radius.m, style: .continuous)
                            .strokeBorder(dropTargeted ? WitermTheme.selectedBorder : WitermTheme.hairline,
                                          lineWidth: dropTargeted ? WitermMetrics.selectedBorder : 1)
                            .allowsHitTesting(false)
                    }
                    .clipShape(.rect(cornerRadius: WitermMetrics.Radius.m, style: .continuous))
                    .dropDestination(for: URL.self) { urls, _ in
                        let files = urls.filter { $0.isFileURL }
                        guard !files.isEmpty, !model.transferring else { return false }
                        model.upload(files, connection: connection)
                        return true
                    } isTargeted: { dropTargeted = $0 }
                if model.transferring {
                    ActivityRow(String(localized: "Transferring…", bundle: .main), cancel: model.cancel)
                }
            }
        } leading: {
            Menu {
                Button(String(localized: "Upload File", bundle: .main), systemImage: "square.and.arrow.up") { importing = true }
                Button(String(localized: "New Folder", bundle: .main), systemImage: "folder.badge.plus") { folderName = ""; creating = true }
                Divider()
                Button(String(localized: "Refresh", bundle: .main), systemImage: "arrow.clockwise") { Task { await model.list(connection) } }
            } label: {
                Label(String(localized: "File Actions", bundle: .main), systemImage: WitermSymbols.more)
            }
            .fixedSize()
            .disabled(model.transferring || model.loading)
        } trailing: {
            Button(String(localized: "Done", bundle: .main), action: close)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .task { await model.list(connection) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.upload(urls, connection: connection)
            case .failure: model.issue = String(localized: "Unable to open the selected file.", bundle: .main)
            }
        }
        .fileMover(isPresented: $model.exporting, file: model.exportURL) { result in
            if case .failure(let error) = result, (error as NSError).code != CocoaError.userCancelled.rawValue {
                model.issue = String(localized: "Unable to save the file. Try again.", bundle: .main)
            }
            model.cleanupExport()
        }
        .alert(String(localized: "New Folder", bundle: .main), isPresented: $creating) {
            TextField(String(localized: "Folder Name", bundle: .main), text: $folderName)
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            Button(String(localized: "Create", bundle: .main)) {
                Task {
                    guard MacSFTPModel.usableName(folderName) else { model.issue = String(localized: "Enter a single folder name.", bundle: .main); return }
                    do { try await connection.createDirectory(path: model.child(folderName)); await model.list(connection) }
                    catch { model.issue = SSHUIError.message(error) }
                }
            }
        }
        .alert(String(localized: "Delete Remote Item?", bundle: .main), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) { removing = nil }
            Button(String(localized: "Delete", bundle: .main), role: .destructive) {
                guard let entry = removing else { return }
                removing = nil
                Task {
                    do { try await connection.remove(path: entry.path, isDirectory: entry.isDirectory); await model.list(connection) }
                    catch { model.issue = SSHUIError.message(error) }
                }
            }
        } message: { Text(String(localized: "“\(String(removing?.name ?? ""))” will be permanently deleted. This cannot be undone.", bundle: .main)) }
        .onDisappear { model.cancel(); if !model.transferring && !model.exporting { model.cleanupExport() } }
    }

    private func close() {
        model.cancel()
        dismiss()
    }

    /// The folder as a path of buttons, root first; the up arrow goes to the folder above.
    private var breadcrumb: some View {
        HStack(spacing: WitermMetrics.Space.xs) {
            Button(String(localized: "Enclosing Folder", bundle: .main), systemImage: "chevron.up") { go(model.parent) }
                .labelStyle(.iconOnly)
                .disabled(model.parent == nil || model.loading || model.transferring)
                .help(String(localized: "Enclosing Folder", bundle: .main))
                .accessibilityIdentifier("sshSFTPUp")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: WitermMetrics.Space.xxs) {
                    // Until a listing names the folder (an empty home folder
                    // doesn't), it's the sign-in folder, "~", never "/".
                    if model.path.hasPrefix("/") {
                        crumb("/", path: "/")
                    } else {
                        crumb("~", path: model.path)
                    }
                    ForEach(Array(model.components.enumerated()), id: \.offset) { index, name in
                        Image(systemName: "chevron.right").font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
                            .accessibilityHidden(true)
                        crumb(name, path: "/" + model.components.prefix(index + 1).joined(separator: "/"))
                    }
                }
            }
            if model.loading { ProgressView().controlSize(.small) }
        }
        .font(WitermType.rowDetail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Remote Path", bundle: .main))
        .accessibilityIdentifier("sshSFTPPath")
    }

    private func crumb(_ title: String, path: String) -> some View {
        Button(title) { go(path) }
            .buttonStyle(.plain)
            .fontWeight(path == model.path ? .semibold : .regular)
            .padding(.horizontal, WitermMetrics.Space.xs).padding(.vertical, WitermMetrics.Space.xxs)
            .witermHover(cornerRadius: WitermMetrics.Radius.s)
            .disabled(path == model.path || model.loading || model.transferring)
    }

    private func go(_ path: String?) {
        guard let path else { return }
        selection = []
        Task { await model.list(connection, path: path) }
    }

    private var table: some View {
        Table(of: SSHFileEntry.self, selection: $selection) {
            TableColumn(String(localized: "Name", bundle: .main)) { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: entry.isDirectory ? "folder" : "doc").foregroundStyle(WitermTheme.secondary)
                }
            }
            TableColumn(String(localized: "Size", bundle: .main)) { entry in
                Text(entry.isDirectory || entry.size == nil ? "—"
                     : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size ?? 0), countStyle: .file))
                    .monospacedDigit()
                    .foregroundStyle(WitermTheme.secondary)
            }
            .width(min: 60, ideal: 90, max: 120)
        } rows: {
            ForEach(model.entries) { entry in
                if entry.isDirectory {
                    TableRow(entry)
                } else {
                    TableRow(entry).draggable(RemoteFile(entry: entry, connection: connection))
                }
            }
        }
        .contextMenu(forSelectionType: SSHFileEntry.ID.self) { ids in
            if let entry = entries(ids).first, ids.count == 1 {
                Button(String(localized: "terminal.open", defaultValue: "Open", bundle: .main)) { open(entry) }
                    .disabled(!entry.isDirectory)
                if !entry.isDirectory {
                    Button(String(localized: "Download", bundle: .main)) { model.download(entry, connection: connection) }
                }
                Divider()
                Button(String(localized: "Delete…", bundle: .main), role: .destructive) { removing = entry }
            }
        } primaryAction: { ids in
            if let entry = entries(ids).first, ids.count == 1 { open(entry) }
        }
        .disabled(model.transferring)
        .overlay {
            if model.entries.isEmpty, !model.loading, model.issue == nil {
                ContentUnavailableView(String(localized: "Folder Is Empty", bundle: .main), systemImage: "folder")
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("sshSFTPTable")
    }

    private func entries(_ ids: Set<SSHFileEntry.ID>) -> [SSHFileEntry] { model.entries.filter { ids.contains($0.id) } }

    /// A folder opens in place; a file downloads (Save asks where).
    private func open(_ entry: SSHFileEntry) {
        if entry.isDirectory { go(entry.path) } else { model.download(entry, connection: connection) }
    }
}
#endif
