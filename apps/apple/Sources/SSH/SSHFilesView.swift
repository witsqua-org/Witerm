import SwiftUI
import Observation
import UniformTypeIdentifiers
import WitermSSH

private final class SSHTransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (UInt64, UInt64?) = (0, nil)
    func update(_ count: UInt64, _ total: UInt64?) {
        lock.lock(); defer { lock.unlock() }
        value = (count, total)
    }
    func snapshot() -> (UInt64, UInt64?) {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private final class SSHLocalExport: Sendable {
    let directory: URL
    init(_ directory: URL) { self.directory = directory }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor @Observable
private final class SSHFilesModel {
    var path = "."
    var entries: [SSHFileEntry] = []
    var loading = false
    var transferring = false
    var transferred: UInt64 = 0
    var total: UInt64?
    var issue: String?
    var exportURL: URL?
    var exporting = false
    private var task: Task<Void, Never>?
    private var temporaryDirectory: SSHLocalExport?
    private let progress = SSHTransferProgress()

    func list(_ connection: SSHConnection, path next: String? = nil) async {
        guard !loading, !transferring else { return }
        loading = true; issue = nil
        defer { loading = false }
        do {
            let requested = next ?? path
            let result = try await connection.listDirectory(path: requested)
            try Task.checkCancellation()
            path = requested
            entries = result.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch { if !Task.isCancelled { issue = SSHUIError.message(error) } }
    }

    func upload(_ url: URL, connection: SSHConnection) {
        beginTransfer {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let progress = self.progress
            try await connection.upload(localURL: url, to: self.child(url.lastPathComponent)) { count, total in
                progress.update(count, total)
            }
        } completion: { await self.list(connection) }
    }

    func download(_ entry: SSHFileEntry, connection: SSHConnection) {
        guard !entry.name.isEmpty, entry.name != ".", entry.name != "..", !entry.name.contains("/"),
              !entry.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { issue = String(localized: "Unable to use this filename.", bundle: .main); return }
        beginTransfer {
            self.cleanupExport()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("witerm-sftp-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            self.temporaryDirectory = SSHLocalExport(directory)
            let destination = directory.appendingPathComponent(entry.name)
            let progress = self.progress
            try await connection.download(remotePath: entry.path, to: destination) { count, total in
                progress.update(count, total)
            }
            try Task.checkCancellation()
            self.exportURL = destination
            self.exporting = true
        }
    }

    private func beginTransfer(_ operation: @escaping @MainActor () async throws -> Void,
                               completion: @escaping @MainActor () async -> Void = {}) {
        guard !transferring else { return }
        transferring = true; transferred = 0; total = nil; issue = nil
        progress.update(0, nil)
        task = Task {
            // One latest-value slot and one sampler keep a fast transfer from
            // creating a MainActor task for every network chunk.
            let sampler = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let value = self.progress.snapshot()
                    self.transferred = value.0; self.total = value.1
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
            defer { sampler.cancel() }
            do { try await operation() }
            catch {
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
        temporaryDirectory = nil
    }
    func child(_ name: String) -> String { (path == "/" ? "" : path) + "/" + name }
}

struct SSHFilesView: View {
    let connection: SSHConnection
    @State private var model = SSHFilesModel()
    @State private var importing = false
    @State private var creating = false
    @State private var folderName = ""
    @State private var removing: SSHFileEntry?
    @State private var pathInput = "."
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField(String(localized: "Remote Path", bundle: .main), text: $pathInput)
                        .font(.system(.body, design: .monospaced)).autocorrectionDisabled().sshLiteralInput()
                        .onSubmit { navigate() }.accessibilityIdentifier("sshSFTPPath")
                    Button(String(localized: "Go", bundle: .main), action: navigate).touchTarget()
                }.padding(.horizontal)
                if model.transferring {
                    HStack {
                        if let total = model.total, total > 0 {
                            ProgressView(value: Double(model.transferred), total: Double(total))
                        } else { ProgressView() }
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.transferred), countStyle: .file))
                            .font(.caption).monospacedDigit()
                        Button(String(localized: "Cancel", bundle: .main), action: model.cancel).touchTarget()
                    }.padding()
                }
                if let issue = model.issue {
                    Text(issue).foregroundStyle(WitermTheme.warning).padding().accessibilityIdentifier("sshSFTPIssue")
                }
                if model.loading { ProgressView(String(localized: "Loading files…", bundle: .main)).padding() }
                List {
                    Button { Task { await model.list(connection, path: model.child("..")); pathInput = model.path } } label: {
                        Label(String(localized: "Parent Folder", bundle: .main), systemImage: "arrow.up")
                    }
                    ForEach(model.entries) { entry in
                        HStack {
                            Button {
                                if entry.isDirectory {
                                    Task { await model.list(connection, path: entry.path); pathInput = model.path }
                                } else { model.download(entry, connection: connection) }
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.name).lineLimit(2)
                                        if let size = entry.size, !entry.isDirectory {
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                } icon: { Image(systemName: entry.isDirectory ? "folder" : "doc") }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                #if os(macOS)
                                .witermHover(cornerRadius: 6)
                                #endif
                            }.buttonStyle(.plain)
                            Menu {
                                if !entry.isDirectory { Button(String(localized: "Download", bundle: .main)) { model.download(entry, connection: connection) } }
                                Button(String(localized: "Delete", bundle: .main), role: .destructive) { removing = entry }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel(String(localized: "Actions for \(String(entry.name))", bundle: .main))
                        }
                    }
                }
                .disabled(model.transferring || model.loading)
                .overlay {
                    if model.entries.isEmpty && !model.loading && model.issue == nil {
                        ContentUnavailableView(String(localized: "Folder Is Empty", bundle: .main), systemImage: "folder")
                            .allowsHitTesting(false)
                    }
                }
            }
            .navigationTitle(String(localized: "SFTP Files", bundle: .main))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Done", bundle: .main)) { model.cancel(); dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(String(localized: "Upload File", bundle: .main), systemImage: "square.and.arrow.up") { importing = true }
                        Button(String(localized: "New Folder", bundle: .main), systemImage: "folder.badge.plus") { folderName = ""; creating = true }
                        Button(String(localized: "Refresh", bundle: .main), systemImage: "arrow.clockwise") { Task { await model.list(connection) } }
                    } label: { Label(String(localized: "File Actions", bundle: .main), systemImage: "ellipsis.circle") }
                    .disabled(model.transferring || model.loading)
                }
            }
            .task { await model.list(connection); pathInput = model.path }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { model.upload(url, connection: connection) }
                case .failure: model.issue = String(localized: "Unable to open the selected file.", bundle: .main)
                }
            }
            .fileMover(isPresented: $model.exporting, file: model.exportURL) { result in
                if case .failure(let error) = result,
                   (error as NSError).code != CocoaError.userCancelled.rawValue {
                    model.issue = String(localized: "Unable to save the file. Try again.", bundle: .main)
                }
                model.cleanupExport()
            }
            .alert(String(localized: "New Folder", bundle: .main), isPresented: $creating) {
                TextField(String(localized: "Folder Name", bundle: .main), text: $folderName)
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
                Button(String(localized: "Create", bundle: .main)) {
                    Task {
                        guard validName(folderName) else { model.issue = String(localized: "Enter a single folder name.", bundle: .main); return }
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
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 680, minHeight: 540)
        #endif
        .onDisappear { model.cancel(); if !model.transferring && !model.exporting { model.cleanupExport() } }
    }

    private func navigate() { Task { await model.list(connection, path: pathInput); pathInput = model.path } }
    private func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
        && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
