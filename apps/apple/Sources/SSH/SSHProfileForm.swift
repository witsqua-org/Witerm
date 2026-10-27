import SwiftUI
import UniformTypeIdentifiers
import WitermSSH

private struct SSHHostDraft: Identifiable {
    var id: UUID
    var hostname: String
    var port: String
    var username: String
    var useKey = false
    var password = ""
    var privateKey = ""
    var showingPrivateKey = false
    var passphrase = ""
    var remember = false
    var showPort = false
    var credentialsReset = false
    var credentialHost: SSHHost
    init(_ host: SSHHost, credential: SSHCredential? = nil) {
        id = host.id; hostname = host.hostname; port = String(host.port); username = host.username
        credentialHost = host
        showPort = host.port != 22
        switch credential {
        case .password(let value): password = value; remember = true
        case .privateKey(let key, let phrase):
            useKey = true; privateKey = key; passphrase = phrase ?? ""; remember = true
        case nil: break
        }
    }
    var host: SSHHost {
        SSHHost(id: id, hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines),
                port: Int(port) ?? 0, username: username)
    }
    var credential: SSHCredential? {
        if useKey {
            guard !privateKey.isEmpty else { return nil }
            return .privateKey(privateKey, passphrase: passphrase.isEmpty ? nil : passphrase)
        }
        return password.isEmpty ? nil : .password(password)
    }
}

enum SSHFormPurpose { case new, edit, connect }

struct SSHProfileForm: View {
    let profile: SSHProfile?
    let purpose: SSHFormPurpose
    let onSave: (SSHProfile, [UUID: SSHCredential], Set<UUID>) async throws -> Void
    let onConnect: (SSHProfile, [UUID: SSHCredential], Set<UUID>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var profileID = UUID()
    @State private var name = ""
    @State private var target = SSHHostDraft(SSHHost(hostname: "", username: ""))
    @State private var jumps: [SSHHostDraft] = []
    @State private var issue: String?
    @State private var saving = false
    @State private var showJumps = false
    private enum Field: Hashable { case name, address(UUID), port(UUID), username(UUID), credential(UUID) }
    @FocusState private var focused: Field?
    @State private var errors: [Field: String] = [:]
    @State private var importingKey = false
    @State private var importingKeyHost: UUID?

    init(profile: SSHProfile?, credentials: [UUID: SSHCredential], purpose: SSHFormPurpose,
         onSave: @escaping (SSHProfile, [UUID: SSHCredential], Set<UUID>) async throws -> Void,
         onConnect: @escaping (SSHProfile, [UUID: SSHCredential], Set<UUID>) -> Void) {
        self.profile = profile; self.onConnect = onConnect; self.purpose = purpose; self.onSave = onSave
        _showJumps = State(initialValue: !(profile?.jumpHosts.isEmpty ?? true))
        _profileID = State(initialValue: profile?.id ?? UUID())
        _name = State(initialValue: profile?.name ?? "")
        let host = profile?.host ?? SSHHost(hostname: "", username: "")
        _target = State(initialValue: SSHHostDraft(host, credential: credentials[host.id]))
        _jumps = State(initialValue: (profile?.jumpHosts ?? []).map {
            SSHHostDraft($0, credential: credentials[$0.id])
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                #if os(iOS)
                if purpose == .new {
                    Section {
                        Text(String(localized: "SSH connections close when this app goes to the background. Remote programs follow the host’s session rules.", bundle: .main))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                #endif
                Section(String(localized: "Name", bundle: .main)) {
                    TextField(String(localized: "Connection Name (Optional)", bundle: .main), text: $name)
                        .focused($focused, equals: .name).accessibilityIdentifier("sshProfileName")
                        .onChange(of: name) { _, _ in errors[.name] = nil }
                    fieldError(.name)
                }
                Section(String(localized: "Target Host", bundle: .main)) { hostFields($target) }
                Section {
                    DisclosureGroup(String(localized: "Jump Hosts", bundle: .main), isExpanded: $showJumps) {
                        ForEach($jumps) { draft in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(String(localized: "Jump Host", bundle: .main)).font(.headline)
                                hostFields(draft)
                                Button(String(localized: "Remove This Jump Host", bundle: .main), role: .destructive) {
                                    let id = draft.wrappedValue.id
                                    jumps.removeAll { $0.id == id }
                                }
                            }
                        }
                        Button(String(localized: "Add Jump Host", bundle: .main), systemImage: "plus") {
                            jumps.append(SSHHostDraft(SSHHost(hostname: "", username: "")))
                        }
                        .disabled(jumps.count >= 4)
                        Text(String(localized: "Jump hosts are connected in list order, followed by the target host.", bundle: .main))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if purpose == .new {
                    Section {
                        Button(String(localized: "Save Without Connecting", bundle: .main)) { submit(connect: false) }
                            .accessibilityIdentifier("sshSaveOnly")
                    }
                }
                if let issue { Section { Text(issue).foregroundStyle(WitermTheme.warning) } }
            }
            .formStyle(.grouped)
            .navigationTitle(purpose == .new ? String(localized: "New SSH Connection", bundle: .main)
                             : purpose == .edit ? String(localized: "Edit SSH Connection", bundle: .main)
                             : String(localized: "Connect With SSH", bundle: .main))
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .main)) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(purpose == .edit ? String(localized: "Save", bundle: .main)
                           : purpose == .new ? String(localized: "Save and Connect", bundle: .main)
                           : String(localized: "Connect", bundle: .main)) { submit(connect: purpose != .edit) }
                        .accessibilityIdentifier(purpose == .edit ? "sshSaveProfile" : "sshConnect")
                        .keyboardShortcut(.defaultAction)
                        .disabled(saving)
                }
            }
            .fileImporter(isPresented: $importingKey, allowedContentTypes: [.data, .plainText]) { result in
                defer { importingKeyHost = nil }
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 262_144 else {
                        throw SSHFailure.unsupportedPrivateKey
                    }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 262_144, let key = String(data: data, encoding: .utf8) else {
                        throw SSHFailure.unsupportedPrivateKey
                    }
                    if importingKeyHost == target.id {
                        target.privateKey = key; target.showingPrivateKey = false
                    } else if let index = jumps.firstIndex(where: { $0.id == importingKeyHost }) {
                        jumps[index].privateKey = key; jumps[index].showingPrivateKey = false
                    }
                } catch {
                    if (error as NSError).code != CocoaError.userCancelled.rawValue {
                        issue = String(localized: "Unable to read the private key. Choose a valid Ed25519 OpenSSH private key file.", bundle: .main)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 640)
        #endif
    }

    @ViewBuilder private func hostFields(_ draft: Binding<SSHHostDraft>) -> some View {
        LabeledContent(String(localized: "Host Address", bundle: .main)) {
            TextField(String(localized: "Host Address", bundle: .main), text: draft.hostname)
                .labelsHidden()
                .autocorrectionDisabled().sshLiteralInput()
                .focused($focused, equals: .address(draft.wrappedValue.id))
                .accessibilityIdentifier("sshHostAddress")
                .onChange(of: draft.wrappedValue.hostname) { _, _ in errors[.address(draft.wrappedValue.id)] = nil; resetChangedEndpoint(draft) }
        }
        fieldError(.address(draft.wrappedValue.id))
        DisclosureGroup(String(localized: "Advanced Options", bundle: .main), isExpanded: draft.showPort) {
            LabeledContent(String(localized: "Port", bundle: .main)) {
                TextField(String(localized: "Port", bundle: .main), text: draft.port)
                    .labelsHidden()
                    .focused($focused, equals: .port(draft.wrappedValue.id))
                    .accessibilityIdentifier("sshHostPort")
                    .onChange(of: draft.wrappedValue.port) { _, _ in errors[.port(draft.wrappedValue.id)] = nil; resetChangedEndpoint(draft) }
            }
            fieldError(.port(draft.wrappedValue.id))
        }
        LabeledContent(String(localized: "Username", bundle: .main)) {
            TextField(String(localized: "Username", bundle: .main), text: draft.username).textContentType(.username).autocorrectionDisabled().sshLiteralInput()
                .labelsHidden()
                .focused($focused, equals: .username(draft.wrappedValue.id))
                .accessibilityIdentifier("sshHostUsername")
                .onChange(of: draft.wrappedValue.username) { _, _ in errors[.username(draft.wrappedValue.id)] = nil; resetChangedEndpoint(draft) }
        }
        fieldError(.username(draft.wrappedValue.id))
        Picker(String(localized: "Authentication", bundle: .main), selection: draft.useKey) {
            Text(String(localized: "Password", bundle: .main)).tag(false)
            Text(String(localized: "Private Key", bundle: .main)).tag(true)
        }
        if draft.wrappedValue.useKey {
            Text(String(localized: "OpenSSH Private Key", bundle: .main)).font(.subheadline)
            Text(String(localized: "Use an OpenSSH private key in Ed25519 format.", bundle: .main))
                .font(.footnote).foregroundStyle(.secondary)
            Button(String(localized: "Import Private Key File", bundle: .main), systemImage: "square.and.arrow.down") {
                importingKeyHost = draft.wrappedValue.id; importingKey = true
            }
            if draft.wrappedValue.showingPrivateKey {
                TextEditor(text: draft.privateKey)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120).accessibilityLabel(String(localized: "OpenSSH Private Key", bundle: .main))
                    .autocorrectionDisabled()
                    .focused($focused, equals: .credential(draft.wrappedValue.id))
                    .sshLiteralInput()
                Button(String(localized: "Hide Private Key", bundle: .main)) { draft.wrappedValue.showingPrivateKey = false }
            } else {
                Text(draft.wrappedValue.privateKey.isEmpty ? String(localized: "No Private Key Loaded", bundle: .main) : String(localized: "Private Key Loaded", bundle: .main))
                    .foregroundStyle(.secondary)
                Button(String(localized: "Enter or Edit Private Key", bundle: .main)) { draft.wrappedValue.showingPrivateKey = true }
            }
            SecureField(String(localized: "Private Key Passphrase (Optional)", bundle: .main), text: draft.passphrase)
        } else {
            SecureField(String(localized: "Password", bundle: .main), text: draft.password).textContentType(.password)
                .focused($focused, equals: .credential(draft.wrappedValue.id))
                .accessibilityIdentifier("sshHostPassword")
        }
        fieldError(.credential(draft.wrappedValue.id))
        if draft.wrappedValue.credentialsReset {
            Text(String(localized: "Credentials cleared because the connection address changed. Enter them again if needed.", bundle: .main))
                .font(.caption).foregroundStyle(WitermTheme.secondary)
        }
        Toggle(String(localized: "Save Credentials on This Device", bundle: .main), isOn: draft.remember)
            .tint(WitermTheme.positive)
    }

    private func resetChangedEndpoint(_ draft: Binding<SSHHostDraft>) {
        guard draft.wrappedValue.host != draft.wrappedValue.credentialHost else { return }
        draft.wrappedValue.credentialsReset = draft.wrappedValue.credentialsReset || draft.wrappedValue.credential != nil
        draft.wrappedValue.password = ""; draft.wrappedValue.privateKey = ""; draft.wrappedValue.passphrase = ""
        draft.wrappedValue.showingPrivateKey = false
        draft.wrappedValue.remember = false
        draft.wrappedValue.credentialHost = draft.wrappedValue.host
    }

    @ViewBuilder private func fieldError(_ field: Field) -> some View {
        if let error = errors[field] {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(WitermTheme.warning)
                .accessibilityIdentifier("sshFieldError")
        }
    }

    private func submit(connect: Bool) {
        guard !saving else { return }
        errors = [:]
        issue = nil
        let endpoints = jumps + [target]
        for endpoint in endpoints {
            let host = endpoint.host
            if host.hostname.isEmpty || host.hostname.utf8.count > 253
                || host.hostname.contains(where: { $0.isWhitespace || $0.isNewline })
                || host.hostname.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                errors[.address(host.id)] = String(localized: "Enter a valid host address without spaces.", bundle: .main)
            }
            if !(1...65535).contains(host.port) {
                errors[.port(host.id)] = String(localized: "Enter a port from 1 to 65535.", bundle: .main)
                if host.id == target.id { target.showPort = true }
                else if let index = jumps.firstIndex(where: { $0.id == host.id }) { jumps[index].showPort = true }
            }
            if host.username.isEmpty || host.username.utf8.count > 255
                || host.username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                errors[.username(host.id)] = String(localized: "Enter a valid username.", bundle: .main)
            }
            if (connect || endpoint.remember), endpoint.credential == nil {
                errors[.credential(host.id)] = String(localized: "Enter a password or load a private key.", bundle: .main)
                if endpoint.useKey {
                    if host.id == target.id { target.showingPrivateKey = true }
                    else if let index = jumps.firstIndex(where: { $0.id == host.id }) { jumps[index].showingPrivateKey = true }
                }
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 80 || trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            errors[.name] = String(localized: "Use a name of up to 80 characters without control characters.", bundle: .main)
        }
        let order: [Field] = [.name] + endpoints.flatMap { [.address($0.id), .port($0.id), .username($0.id), .credential($0.id)] }
        if let first = order.first(where: { errors[$0] != nil }) {
            if !jumps.isEmpty { showJumps = true }
            focused = first
            return
        }
        let automaticName = String("\(target.host.username)@\(target.host.hostname)".prefix(80))
        let profile = SSHProfile(id: profileID, name: trimmed.isEmpty ? automaticName : trimmed,
                                 host: target.host, jumpHosts: jumps.map(\.host))
        do { try profile.validate() } catch { issue = SSHUIError.message(error); return }
        let credentials = Dictionary(uniqueKeysWithValues: endpoints.compactMap { endpoint in
            endpoint.credential.map { (endpoint.id, $0) }
        })
        let remember = Set(endpoints.filter(\.remember).map(\.id))
        if connect {
            onConnect(profile, credentials, remember)
            dismiss()
        } else {
            saving = true
            Task {
                do {
                    try await onSave(profile, credentials, remember)
                    if !Task.isCancelled { dismiss() }
                } catch { issue = SSHUIError.message(error) }
                saving = false
            }
        }
    }

}

extension View {
    @ViewBuilder func sshLiteralInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
