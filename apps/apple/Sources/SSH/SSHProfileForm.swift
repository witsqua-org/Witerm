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
    /// How saved credentials are protected on this device, read once.
    @State private var protection = SSHUnlock.method
    /// Face ID (or Touch ID) this device has but Witerm may not use.
    @State private var biometryOff = SSHUnlock.biometryOffForApp
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
                            VStack(alignment: .leading, spacing: WitermMetrics.Space.m) {
                                Text(String(localized: "Jump Host \(index + 1)", bundle: .main)).font(WitermType.cardTitle)
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
                        if !jumps.isEmpty {
                            Text(String(localized: "Jump hosts are connected in list order, followed by the address above.", bundle: .main))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let issue { Section { Text(issue).foregroundStyle(WitermTheme.warning) } }
                #if os(iOS)
                // At accessibility sizes the actions end the form instead of
                // covering a quarter of it.
                if typeSize.isAccessibilitySize {
                    Section { actionButtons }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                #endif
            }
            .formStyle(.grouped)
            .navigationTitle(purpose == .new ? String(localized: "Add SSH Host", bundle: .main)
                             : purpose == .edit ? String(localized: "Edit SSH Host", bundle: .main)
                             : String(localized: "Connect With SSH", bundle: .main))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // A new host starts at its address; one being connected or
                // edited already has it.
                if purpose == .new, target.address.isEmpty { focused = .address(target.id) }
            }
            #endif
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .main)) { dismiss() }.disabled(saving) }
                // Saving without connecting sits where iOS sheets keep Save,
                // so the bar over the keyboard holds only Connect and the
                // form keeps room for its fields.
                if purpose == .new {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Save", bundle: .main)) { submit(connect: false) }
                            .disabled(saving)
                            .accessibilityHint(String(localized: "Saves the host without connecting.", bundle: .main))
                            .accessibilityIdentifier("sshSaveOnly")
                    }
                }
            }
            #endif
            // The actions sit at the bottom, within reach of a thumb; on the
            // Mac, one footer with Cancel beside them. At iOS accessibility
            // sizes they end the form instead.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !actionsInForm { actions }
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

    private var primaryTitle: String {
        switch purpose {
        case .edit: String(localized: "Save", bundle: .main)
        case .new, .connect: String(localized: "Connect", bundle: .main)
        }
    }

    private var actionsInForm: Bool {
        #if os(iOS)
        typeSize.isAccessibilitySize
        #else
        false
        #endif
    }

    private var actions: some View {
        actionButtons
            .padding(.horizontal, WitermMetrics.sheetInset)
            .padding(.vertical, WitermMetrics.Space.m)
            .background(.bar)
    }

    private var actionButtons: some View {
        #if os(iOS)
        let primary = PrimaryButton(primaryTitle, fullWidth: true) { submit(connect: purpose != .edit) }
            .accessibilityIdentifier(purpose == .edit ? "sshSaveProfile" : "sshConnect")
            .keyboardShortcut(.defaultAction)
            .disabled(saving)
        #endif
        #if os(macOS)
        let later = Button { submit(connect: false) } label: {
            ContentActionLabel(String(localized: "Save for Later", bundle: .main), systemImage: "tray.and.arrow.down")
        }
            .accessibilityIdentifier("sshSaveOnly")
            .disabled(saving)
        #endif
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
            primary
            #endif
        }
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
            // iOS shows what it understood once there's an address; until then
            // the field's example is the hint.
            #if os(macOS)
            Text(String(localized: "Add :port after the host if it isn't 22.", bundle: .main))
                .font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
            #endif
        }
        fieldError(.address(draft.wrappedValue.id))
    }

    @ViewBuilder private func signInFields(_ draft: Binding<SSHHostDraft>) -> some View {
        Picker(String(localized: "Sign In With", bundle: .main), selection: draft.useKey) {
            Text(String(localized: "Password", bundle: .main)).tag(false)
            Text(String(localized: "Private Key", bundle: .main)).tag(true)
        }
        .modifier(SignInPickerStyle(accessibilitySize: typeSize.isAccessibilitySize))
        .accessibilityIdentifier("sshAuthentication")
        if draft.wrappedValue.useKey {
            // Two ways to get a key, side by side; the chosen one is outlined.
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 10))) {
                KeyChoiceCard(title: String(localized: "New Key", bundle: .main),
                              detail: String(localized: "Made on this device. Add its public key to the SSH host.", bundle: .main),
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
            // Said when it applies, as soon as an RSA key is in the field.
            if SSHKeyGenerator.isRSAPrivateKey(draft.wrappedValue.privateKey), errors[.credential(draft.wrappedValue.id)] == nil {
                Label(Self.rsaMessage, systemImage: "exclamationmark.circle")
                    .font(WitermType.meta).foregroundStyle(WitermTheme.warning)
                    .accessibilityIdentifier("sshFieldError")
            }
            if let publicKey = draft.wrappedValue.generatedPublicKey {
                generatedKeyDetails(publicKey, remember: draft.wrappedValue.remember)
            }
            if draft.wrappedValue.showingPrivateKey {
                TextEditor(text: draft.privateKey)
                    .font(WitermType.codeInline)
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
                .font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
        }
        Toggle(String(localized: "Save Credentials on This Device", bundle: .main), isOn: draft.remember)
            .witermSwitchTint()
            .disabled(protection == .unavailable)
        // Saved credentials always need Face ID, Touch ID, or the passcode.
        if protection == .unavailable || draft.wrappedValue.remember {
            Text(Self.protectionNote(protection, biometryOff: biometryOff))
                .font(WitermType.meta)
                .foregroundStyle(WitermTheme.secondary)
                .accessibilityIdentifier("sshCredentialProtection")
        }
    }

    static let rsaMessage = String(localized: "This is an RSA key, which Witerm doesn't use. Generate a new Ed25519 key or load an existing one.", bundle: .main)

    /// One line, where saving is chosen, naming what protects saved credentials.
    static func protectionNote(_ method: SSHUnlock.Method, biometryOff: SSHUnlock.Method? = nil) -> String {
        #if os(iOS)
        // Honest about why it isn't Face ID, where the person can change it.
        if method == .passcode, let biometryOff {
            switch biometryOff {
            case .faceID: return String(localized: "Your passcode protects them. Face ID is off for Witerm in Settings.", bundle: .main)
            case .touchID: return String(localized: "Your passcode protects them. Touch ID is off for Witerm in Settings.", bundle: .main)
            case .opticID: return String(localized: "Your passcode protects them. Optic ID is off for Witerm in Settings.", bundle: .main)
            case .passcode, .unavailable: break
            }
        }
        #endif
        return switch method {
        case .faceID: String(localized: "Face ID protects them.", bundle: .main)
        case .touchID: String(localized: "Touch ID protects them.", bundle: .main)
        case .opticID: String(localized: "Optic ID protects them.", bundle: .main)
        #if os(macOS)
        case .passcode: String(localized: "Your login password protects them.", bundle: .main)
        case .unavailable: String(localized: "Set a login password to save them.", bundle: .main)
        #else
        case .passcode: String(localized: "Your passcode protects them.", bundle: .main)
        case .unavailable: String(localized: "Set a device passcode to save them.", bundle: .main)
        #endif
        }
    }

    /// The public half goes into the host's `~/.ssh/authorized_keys`; the
    /// private half never leaves this device.
    @ViewBuilder private func generatedKeyDetails(_ publicKey: String, remember: Bool) -> some View {
        Text(String(localized: "Add this public key to ~/.ssh/authorized_keys on the host, then connect.", bundle: .main))
            .font(.footnote).foregroundStyle(.secondary)
        Text(verbatim: publicKey)
            .font(WitermType.codeInline)
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
                .font(WitermType.meta).foregroundStyle(WitermTheme.warning)
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
                .font(WitermType.meta).foregroundStyle(WitermTheme.warning)
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
                errors[.credential(host.id)] = Self.rsaMessage
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

/// Segments side by side; at accessibility text sizes, where a segmented
/// control keeps its small text, a menu that grows with it.
private struct SignInPickerStyle: ViewModifier {
    let accessibilitySize: Bool

    func body(content: Content) -> some View {
        if accessibilitySize { content.pickerStyle(.menu) } else { content.pickerStyle(.segmented) }
    }
}

/// What the address field understood, as chips that read as one sentence.
private struct AddressChips: View {
    let parsed: SSHAddressInput.Parsed
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // One row when it fits; otherwise one chip per line, so the host,
        // the thing to check, is never cut short.
        ViewThatFits(in: .horizontal) {
            if !typeSize.isAccessibilitySize {
                HStack(spacing: 6) { chips(wrapping: false) }
            }
            VStack(alignment: .leading, spacing: 6) { chips(wrapping: true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "User \(parsed.username) · Host \(parsed.hostname) · Port \(String(parsed.port))", bundle: .main))
        .accessibilityIdentifier("sshAddressSummary")
    }

    @ViewBuilder private func chips(wrapping: Bool) -> some View {
        chip(String(localized: "User", bundle: .main), parsed.username, wrapping: wrapping)
        chip(String(localized: "Host", bundle: .main), parsed.hostname, wrapping: wrapping)
        chip(String(localized: "Port", bundle: .main), String(parsed.port), wrapping: wrapping)
    }

    /// A wrapping chip breaks between characters, never with a hyphen.
    private func chip(_ label: String, _ value: String, wrapping: Bool) -> some View {
        (Text(label + " ").foregroundStyle(WitermTheme.secondary) + Text(verbatim: value.breakingAnywhere).fontWeight(.semibold))
            .font(WitermType.meta)
            .fixedSize(horizontal: !wrapping, vertical: true)
            .padding(.horizontal, WitermMetrics.Space.s)
            .padding(.vertical, 3)
            .background(WitermTheme.statusFill, in: .capsule)
            .witermOutline(Capsule())
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
