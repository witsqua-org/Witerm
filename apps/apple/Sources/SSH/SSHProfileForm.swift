import SwiftUI
import UniformTypeIdentifiers
import WitermSSH

private struct SSHHostDraft: Identifiable {
    var id: UUID
    /// `user@host[:port]`, parsed by `SSHAddressInput`.
    var address: String
    var useKey = false
    var password = ""
    var privateKey = ""
    var showingPrivateKey = false
    var passphrase = ""
    var remember = false
    var credentialsReset = false
    var credentialHost: SSHHost
    /// A key made in this form, shown with its public half until the key text changes.
    var generated: (privateKey: String, publicKey: String)?
    var generatedPublicKey: String? { generated.flatMap { $0.privateKey == privateKey ? $0.publicKey : nil } }
    init(_ host: SSHHost, credential: SSHCredential? = nil) {
        id = host.id; address = SSHAddressInput.format(host)
        credentialHost = host
        switch credential {
        case .password(let value): password = value; remember = true
        case .privateKey(let key, let phrase):
            useKey = true; privateKey = key; passphrase = phrase ?? ""; remember = true
        case nil: break
        }
    }
    var parsed: Result<SSHAddressInput.Parsed, SSHAddressInput.ProblemError> { SSHAddressInput.parse(address) }
    /// The endpoint as typed so far; an unreadable address has no host name.
    var host: SSHHost {
        guard case .success(let value) = parsed else { return SSHHost(id: id, hostname: "", port: 22, username: "") }
        return SSHHost(id: id, hostname: value.hostname, port: value.port, username: value.username)
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
    /// Name and jump hosts; open when either is already set.
    @State private var showMore = false
    private enum Field: Hashable { case name, address(UUID), credential(UUID) }
    @FocusState private var focused: Field?
    @State private var errors: [Field: String] = [:]
    @State private var importingKey = false
    @State private var importingKeyHost: UUID?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(profile: SSHProfile?, credentials: [UUID: SSHCredential], purpose: SSHFormPurpose, address: String? = nil,
         onSave: @escaping (SSHProfile, [UUID: SSHCredential], Set<UUID>) async throws -> Void,
         onConnect: @escaping (SSHProfile, [UUID: SSHCredential], Set<UUID>) -> Void) {
        self.profile = profile; self.onConnect = onConnect; self.purpose = purpose; self.onSave = onSave
        _showMore = State(initialValue: profile.map {
            !$0.jumpHosts.isEmpty || $0.name != "\($0.host.username)@\($0.host.hostname)"
        } ?? false)
        _profileID = State(initialValue: profile?.id ?? UUID())
        _name = State(initialValue: profile?.name ?? "")
        let host = profile?.host ?? SSHHost(hostname: "", username: "")
        var draft = SSHHostDraft(host, credential: credentials[host.id])
        if profile == nil, let address { draft.address = address }
        _target = State(initialValue: draft)
        _jumps = State(initialValue: (profile?.jumpHosts ?? []).map {
            SSHHostDraft($0, credential: credentials[$0.id])
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Address", bundle: .main)) { addressFields($target) }
                Section(String(localized: "Sign In", bundle: .main)) { signInFields($target) }
                Section {
                    Button {
                        withAnimation(WitermMotion.transition(reduceMotion: reduceMotion)) { showMore.toggle() }
                    } label: {
                        HStack {
                            Text(String(localized: "More Options", bundle: .main))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showMore ? 90 : 0))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                        #if os(macOS)
                        .witermHover(cornerRadius: 6)
                        #endif
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showMore ? String(localized: "Expanded", bundle: .main) : String(localized: "Collapsed", bundle: .main))
                    .accessibilityHint(String(localized: "Name and jump hosts", bundle: .main))
                    .accessibilityIdentifier("sshMoreOptions")
                    if showMore {
                        TextField(String(localized: "Name", bundle: .main), text: $name,
                                  prompt: Text(String(localized: "Uses the address if empty", bundle: .main)))
                            .focused($focused, equals: .name).accessibilityIdentifier("sshProfileName")
                            .onChange(of: name) { _, _ in errors[.name] = nil }
                        fieldError(.name)
                        ForEach(Array($jumps.enumerated()), id: \.element.wrappedValue.id) { index, draft in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(String(localized: "Jump Host \(index + 1)", bundle: .main)).font(.headline)
                                addressFields(draft)
                                signInFields(draft)
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
                        Text(String(localized: "Jump hosts are connected in list order, followed by the address above.", bundle: .main))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let issue { Section { Text(issue).foregroundStyle(WitermTheme.warning) } }
            }
            .formStyle(.grouped)
            .navigationTitle(purpose == .new ? String(localized: "Add SSH Host", bundle: .main)
                             : purpose == .edit ? String(localized: "Edit SSH Host", bundle: .main)
                             : String(localized: "Connect With SSH", bundle: .main))
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .main)) { dismiss() }.disabled(saving) }
            }
            #endif
            // The actions sit at the bottom, within reach of a thumb; on the
            // Mac, one footer with Cancel beside them.
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
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

    private var primaryTitle: String {
        switch purpose {
        case .edit: String(localized: "Save", bundle: .main)
        case .new, .connect: String(localized: "Connect", bundle: .main)
        }
    }

    private var actions: some View {
        #if os(iOS)
        let primary = PrimaryButton(primaryTitle, fullWidth: true) { submit(connect: purpose != .edit) }
            .accessibilityIdentifier(purpose == .edit ? "sshSaveProfile" : "sshConnect")
            .keyboardShortcut(.defaultAction)
            .disabled(saving)
        #endif
        let later = Button(String(localized: "Save for Later", bundle: .main)) { submit(connect: false) }
            .accessibilityIdentifier("sshSaveOnly")
            .disabled(saving)
        return Group {
            #if os(macOS)
            // The sheet footer: Save for Later leading, Cancel and the
            // primary trailing, at the system's regular size.
            HStack(spacing: WitermMetrics.Space.s) {
                if purpose == .new { later }
                Spacer(minLength: WitermMetrics.Space.s)
                Button(String(localized: "Cancel", bundle: .main)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(primaryTitle) { submit(connect: purpose != .edit) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
                    .accessibilityIdentifier(purpose == .edit ? "sshSaveProfile" : "sshConnect")
            }
            .controlSize(.regular)
            #else
            VStack(spacing: 4) {
                primary
                if purpose == .new { later.touchTarget() }
            }
            #endif
        }
        .padding(.horizontal, WitermMetrics.sheetInset)
        .padding(.vertical, WitermMetrics.Space.m)
        .background(.bar)
    }

    /// One field for `user@host:port`, with what it understood shown below.
    @ViewBuilder private func addressFields(_ draft: Binding<SSHHostDraft>) -> some View {
        TextField(String(localized: "Address", bundle: .main), text: draft.address,
                  prompt: Text(verbatim: "deploy@server.example.com"))
            .autocorrectionDisabled().sshLiteralInput()
            #if os(iOS)
            .keyboardType(.asciiCapable)
            #endif
            .focused($focused, equals: .address(draft.wrappedValue.id))
            .accessibilityIdentifier("sshHostAddress")
            .onChange(of: draft.wrappedValue.address) { _, _ in errors[.address(draft.wrappedValue.id)] = nil; resetChangedEndpoint(draft) }
        if case .success(let value) = draft.wrappedValue.parsed {
            AddressChips(parsed: value)
        } else if errors[.address(draft.wrappedValue.id)] == nil {
            Text(String(localized: "Add :port after the host if it isn't 22.", bundle: .main))
                .font(.caption).foregroundStyle(WitermTheme.secondary)
        }
        fieldError(.address(draft.wrappedValue.id))
    }

    @ViewBuilder private func signInFields(_ draft: Binding<SSHHostDraft>) -> some View {
        Picker(String(localized: "Sign In With", bundle: .main), selection: draft.useKey) {
            Text(String(localized: "Password", bundle: .main)).tag(false)
            Text(String(localized: "Private Key", bundle: .main)).tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("sshAuthentication")
        if draft.wrappedValue.useKey {
            // Two ways to get a key, side by side; the chosen one is outlined.
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 10))) {
                KeyChoiceCard(title: String(localized: "New Key", bundle: .main),
                              detail: String(localized: "Made on this device. Copy the public key to the server.", bundle: .main),
                              systemImage: "key.fill", selected: draft.wrappedValue.generatedPublicKey != nil) {
                    let day = Date.now.formatted(.iso8601.year().month().day())
                    let key = SSHKeyGenerator.ed25519(comment: "witerm-\(day)")
                    draft.wrappedValue.generated = key
                    draft.wrappedValue.privateKey = key.privateKey
                    draft.wrappedValue.passphrase = ""
                    draft.wrappedValue.showingPrivateKey = false
                    errors[.credential(draft.wrappedValue.id)] = nil
                }
                .accessibilityIdentifier("sshGenerateKey")
                KeyChoiceCard(title: String(localized: "Existing Key", bundle: .main),
                              detail: String(localized: "Import an Ed25519 OpenSSH key file.", bundle: .main),
                              systemImage: "square.and.arrow.down",
                              selected: !draft.wrappedValue.privateKey.isEmpty && draft.wrappedValue.generatedPublicKey == nil) {
                    importingKeyHost = draft.wrappedValue.id; importingKey = true
                }
                .accessibilityIdentifier("sshImportKey")
            }
            .buttonStyle(.plain)
            Text(String(localized: "RSA keys aren't supported because they would be signed with SHA-1.", bundle: .main))
                .font(.footnote).foregroundStyle(.secondary)
            if let publicKey = draft.wrappedValue.generatedPublicKey {
                generatedKeyDetails(publicKey, remember: draft.wrappedValue.remember)
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
                // The cards say which key is in use; pasting stays available.
                Button(draft.wrappedValue.privateKey.isEmpty ? String(localized: "Paste a Key Instead", bundle: .main)
                       : String(localized: "Enter or Edit Private Key", bundle: .main)) { draft.wrappedValue.showingPrivateKey = true }
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

    /// The public half goes into the host's `~/.ssh/authorized_keys`; the
    /// private half never leaves this device.
    @ViewBuilder private func generatedKeyDetails(_ publicKey: String, remember: Bool) -> some View {
        Text(String(localized: "Add this public key to ~/.ssh/authorized_keys on the host, then connect.", bundle: .main))
            .font(.footnote).foregroundStyle(.secondary)
        Text(verbatim: publicKey)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityIdentifier("sshGeneratedPublicKey")
        HStack {
            Button(String(localized: "Copy Public Key", bundle: .main), systemImage: "doc.on.doc") {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(publicKey, forType: .string)
                #else
                UIPasteboard.general.string = publicKey
                #endif
            }
            .accessibilityIdentifier("sshCopyPublicKey")
            ShareLink(item: publicKey) { Label(String(localized: "Share", bundle: .main), systemImage: "square.and.arrow.up") }
        }
        .buttonStyle(.bordered)
        if !remember {
            Text(String(localized: "Turn on Save Credentials on This Device to keep this key. Otherwise it is discarded when Witerm closes.", bundle: .main))
                .font(.caption).foregroundStyle(WitermTheme.warning)
        }
    }

    private func resetChangedEndpoint(_ draft: Binding<SSHHostDraft>) {
        guard draft.wrappedValue.host != draft.wrappedValue.credentialHost else { return }
        draft.wrappedValue.credentialsReset = draft.wrappedValue.credentialsReset || draft.wrappedValue.credential != nil
        draft.wrappedValue.password = ""; draft.wrappedValue.privateKey = ""; draft.wrappedValue.passphrase = ""
        draft.wrappedValue.showingPrivateKey = false
        draft.wrappedValue.generated = nil
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
            if case .failure(let problem) = endpoint.parsed { errors[.address(host.id)] = problem.message }
            if endpoint.useKey, SSHKeyGenerator.isRSAPrivateKey(endpoint.privateKey) {
                errors[.credential(host.id)] = String(localized: "This is an RSA key, which Witerm doesn't use. Generate a new Ed25519 key or load an existing one.", bundle: .main)
            } else if (connect || endpoint.remember), endpoint.credential == nil {
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
        let order: [Field] = [.address(target.id), .credential(target.id), .name]
            + jumps.flatMap { [.address($0.id), .credential($0.id)] }
        if let first = order.first(where: { errors[$0] != nil }) {
            if first == .name || !jumps.isEmpty { showMore = true }
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

/// What the address field understood, as chips that read as one sentence.
private struct AddressChips: View {
    let parsed: SSHAddressInput.Parsed
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 6))
        layout {
            chip(String(localized: "User", bundle: .main), parsed.username)
            chip(String(localized: "Host", bundle: .main), parsed.hostname)
            chip(String(localized: "Port", bundle: .main), String(parsed.port))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "User \(parsed.username) · Host \(parsed.hostname) · Port \(String(parsed.port))", bundle: .main))
        .accessibilityIdentifier("sshAddressSummary")
    }

    private func chip(_ label: String, _ value: String) -> some View {
        (Text(label + " ").foregroundStyle(WitermTheme.secondary) + Text(verbatim: value).fontWeight(.semibold))
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(WitermTheme.statusFill, in: .capsule)
    }
}

/// One way to sign in with a key, as a `SelectableCard`. iOS keeps its 12 pt
/// corners and 44 pt minimum height.
private struct KeyChoiceCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        #if os(macOS)
        let radius = WitermMetrics.Radius.l
        #else
        let radius = WitermMetrics.Radius.m
        #endif
        SelectableCard(selected: selected, cornerRadius: radius, padding: WitermMetrics.Space.m, action: action) {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
                    .foregroundStyle(WitermTheme.ink)
                Text(detail).font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        }
    }
}
