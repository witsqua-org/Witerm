import SwiftUI
import UniformTypeIdentifiers
import WitermSSH

/// Imports hosts from an OpenSSH config file the person picks. Only names,
/// addresses, ports, users, and jump hosts come across; credentials are
/// entered on first connect, like any new host.
struct SSHConfigImportView: View {
    let model: SSHWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SSHConfigImport.Entry]?
    @State private var selected: Set<String> = []
    @State private var choosingFile = false
    @State private var issue: String?
    @State private var saving = false

    private var importable: [SSHConfigImport.Entry] {
        (entries ?? []).filter { $0.profile != nil && !alreadySaved($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let issue {
                    Section { IssueBanner(issue) { EmptyView() } }
                }
                if let entries {
                    list(entries)
                } else {
                    source
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Import SSH Hosts", bundle: .main))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .main)) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                if entries != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Import \(selected.count) Hosts", bundle: .main)) { Task { await save() } }
                            .disabled(selected.isEmpty || saving)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("sshImportConfirm")
                    }
                }
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data, .plainText, .text]) { result in
                guard case .success(let url) = result else { return }
                read(url, scoped: true)
            }
        }
        .witermTint()
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 420)
        #endif
    }

    private var source: some View {
        Section {
            Text(String(localized: "Choose an OpenSSH config file. Host names, addresses, ports, users, and jump hosts are imported. Keys and passwords are not; you enter them when you first connect.", bundle: .main))
                .font(.subheadline)
                .foregroundStyle(WitermTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            Button(String(localized: "Read ~/.ssh/config", bundle: .main), systemImage: "doc.text") {
                read(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config"), scoped: false)
            }
            .accessibilityIdentifier("sshImportDefaultConfig")
            #endif
            Button(String(localized: "Choose File…", bundle: .main), systemImage: "folder") { choosingFile = true }
                .accessibilityIdentifier("sshImportChooseFile")
        }
    }

    @ViewBuilder private func list(_ entries: [SSHConfigImport.Entry]) -> some View {
        if entries.isEmpty {
            Section { Text(String(localized: "No hosts were found in this file.", bundle: .main)).foregroundStyle(WitermTheme.secondary) }
        }
        Section {
            ForEach(entries) { entry in
                if let profile = entry.profile, !alreadySaved(entry) {
                    Toggle(isOn: Binding(get: { selected.contains(entry.alias) },
                                         set: { if $0 { selected.insert(entry.alias) } else { selected.remove(entry.alias) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.alias)
                            Text(verbatim: profile.endpointSummary
                                 + (profile.jumpHosts.isEmpty ? "" : " · " + String(localized: "via \(profile.jumpHosts.map(\.hostname).joined(separator: ", "))", bundle: .main)))
                                .font(.caption.monospaced())
                                .foregroundStyle(WitermTheme.secondary)
                        }
                    }
                    .accessibilityValue(profile.accessibilitySummary)
                } else {
                    LabeledContent {
                        Text(reason(entry)).font(.caption).foregroundStyle(WitermTheme.secondary)
                    } label: {
                        Text(verbatim: entry.alias).foregroundStyle(WitermTheme.secondary)
                    }
                }
            }
        } footer: {
            Text(String(localized: "Identity files, agents, and other options in the file are not used. Each host's key is verified when you first connect.", bundle: .main))
        }
    }

    private func reason(_ entry: SSHConfigImport.Entry) -> String {
        if alreadySaved(entry) { return String(localized: "Already saved", bundle: .main) }
        switch entry.skipped {
        case .missingUser: return String(localized: "No user set", bundle: .main)
        case .unsupportedJump: return String(localized: "Jump hosts can't be used", bundle: .main)
        case .invalid, nil: return String(localized: "Can't be imported", bundle: .main)
        }
    }

    private func alreadySaved(_ entry: SSHConfigImport.Entry) -> Bool {
        guard let profile = entry.profile else { return false }
        func endpoints(_ value: SSHProfile) -> [String] {
            (value.jumpHosts + [value.host]).map { "\($0.username)@\($0.hostname.lowercased()):\($0.port)" }
        }
        return model.profiles.contains { endpoints($0) == endpoints(profile) }
    }

    private func read(_ url: URL, scoped: Bool) {
        let access = scoped && url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) <= SSHConfigImport.maximumSize,
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            issue = String(localized: "Unable to read this file. Choose an OpenSSH config file up to 256 KB.", bundle: .main)
            return
        }
        #if os(macOS)
        let user: String? = NSUserName()
        #else
        let user: String? = nil
        #endif
        issue = nil
        let parsed = SSHConfigImport.parse(text, defaultUsername: user)
        entries = parsed
        selected = Set(parsed.filter { $0.profile != nil && !alreadySaved($0) }.map(\.alias))
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let chosen = importable.filter { selected.contains($0.alias) }.compactMap(\.profile)
        for profile in chosen {
            do { try await model.saveProfile(profile, credentials: [:], remember: []) }
            catch { issue = SSHUIError.message(error); return }
        }
        dismiss()
    }
}
