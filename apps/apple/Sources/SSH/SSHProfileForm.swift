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
    var credentialHost: SSHHost
    init(_ host: SSHHost, credential: SSHCredential? = nil) {
        id = host.id; hostname = host.hostname; port = String(host.port); username = host.username
        credentialHost = host
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

struct SSHProfileForm: View {
    let profile: SSHProfile?
    let onConnect: (SSHProfile, [UUID: SSHCredential], Set<UUID>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var profileID = UUID()
    @State private var name = ""
    @State private var target = SSHHostDraft(SSHHost(hostname: "", username: ""))
    @State private var jumps: [SSHHostDraft] = []
    @State private var issue: String?
    @State private var importingKey = false
    @State private var importingKeyHost: UUID?

    init(profile: SSHProfile?, credentials: [UUID: SSHCredential],
         onConnect: @escaping (SSHProfile, [UUID: SSHCredential], Set<UUID>) -> Void) {
        self.profile = profile; self.onConnect = onConnect
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
                Section(String(localized: "Name", bundle: .main)) {
                    TextField(String(localized: "Connection Name", bundle: .main), text: $name).accessibilityIdentifier("sshProfileName")
                }
                Section(String(localized: "Target Host", bundle: .main)) { hostFields($target) }
                ForEach($jumps) { draft in
                    let index = jumps.firstIndex(where: { $0.id == draft.wrappedValue.id }) ?? 0
                    Section(String(localized: "Jump Host \(String(index + 1))", bundle: .main)) {
                        hostFields(draft)
                        Button(String(localized: "Remove This Jump Host", bundle: .main), role: .destructive) {
                            let id = draft.wrappedValue.id
                            jumps.removeAll { $0.id == id }
                        }
                    }
                }
                Section {
                    Button(String(localized: "Add Jump Host", bundle: .main), systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                        jumps.append(SSHHostDraft(SSHHost(hostname: "", username: "")))
                    }
                    .disabled(jumps.count >= 4)
                    if !jumps.isEmpty {
                        Text(String(localized: "Jump hosts are connected in list order, followed by the target host.", bundle: .main))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let issue { Section { Text(issue).foregroundStyle(WitermTheme.warning) } }
            }
            .formStyle(.grouped)
            .navigationTitle(profile == nil ? String(localized: "New SSH Connection", bundle: .main) : String(localized: "Connect With SSH", bundle: .main))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .main)) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Connect", bundle: .main), action: submit).accessibilityIdentifier("sshConnect")
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
        TextField(String(localized: "Host Address", bundle: .main), text: draft.hostname)
            .autocorrectionDisabled().sshLiteralInput()
            .accessibilityIdentifier("sshHostAddress")
            .onChange(of: draft.wrappedValue.hostname) { _, _ in resetChangedEndpoint(draft) }
        TextField(String(localized: "Port", bundle: .main), text: draft.port)
            .accessibilityIdentifier("sshHostPort")
            .onChange(of: draft.wrappedValue.port) { _, _ in resetChangedEndpoint(draft) }
        TextField(String(localized: "Username", bundle: .main), text: draft.username).textContentType(.username).autocorrectionDisabled().sshLiteralInput()
            .accessibilityIdentifier("sshHostUsername")
            .onChange(of: draft.wrappedValue.username) { _, _ in resetChangedEndpoint(draft) }
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
                .accessibilityIdentifier("sshHostPassword")
        }
        Toggle(String(localized: "Save Credentials on This Device", bundle: .main), isOn: draft.remember)
            .tint(WitermTheme.positive)
    }

    private func resetChangedEndpoint(_ draft: Binding<SSHHostDraft>) {
        guard draft.wrappedValue.host != draft.wrappedValue.credentialHost else { return }
        draft.wrappedValue.password = ""; draft.wrappedValue.privateKey = ""; draft.wrappedValue.passphrase = ""
        draft.wrappedValue.showingPrivateKey = false
        draft.wrappedValue.remember = false
        draft.wrappedValue.credentialHost = draft.wrappedValue.host
    }

    private func submit() {
        let profile = SSHProfile(id: profileID, name: name, host: target.host, jumpHosts: jumps.map(\.host))
        do {
            try profile.validate()
            var credentials: [UUID: SSHCredential] = [:]
            var remember: Set<UUID> = []
            for endpoint in jumps + [target] {
                guard let credential = endpoint.credential else { throw SSHFailure.missingCredential }
                credentials[endpoint.id] = credential
                if endpoint.remember { remember.insert(endpoint.id) }
            }
            onConnect(profile, credentials, remember)
            dismiss()
        } catch { issue = SSHUIError.message(error) }
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
