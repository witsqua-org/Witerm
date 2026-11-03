import SwiftUI
import WitermCore

extension Notification.Name {
    /// Asks the workspace to open the new SSH host form; `object` is the
    /// `user@host:port` text to start from.
    static let witermAddSSHHost = Notification.Name("witerm.addSSHHost")
    /// Asks the workspace to continue from an invitation; `object` is its link.
    static let witermUseInvitation = Notification.Name("witerm.useInvitation")
}

/// Adds or edits a continuation server. Says, as you type, which address it
/// will use, and turns SSH logins, pasted invitations and URLs with paths
/// into a specific fix instead of a generic error.
struct ServerAddressSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var rejection: String?
    @State private var submitted = false
    @FocusState private var addressFocused: Bool
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var typeSize
    #endif
    let title: String
    let actionTitle: String
    /// Returns why the address could not be saved, or nil once it is.
    let onSave: (String) -> String?

    init(title: String, actionTitle: String, address: String, onSave: @escaping (String) -> String?) {
        self.title = title
        self.actionTitle = actionTitle
        _draft = State(initialValue: address)
        self.onSave = onSave
    }

    private var input: ServerAddressInput { ServerAddressInput(draft) }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Relay Server Address", bundle: .main), text: $draft, prompt: Text(verbatim: "witerm.example.com"))
                        .font(WitermType.code)
                        .focused($addressFocused)
                        .textContentType(.URL)
                        .accessibilityIdentifier("serverAddressField")
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        #endif
                        .onSubmit(save)
                        .onChange(of: draft) { rejection = nil; submitted = false }
                    interpretation
                } header: {
                    Text(String(localized: "Relay Server Address", bundle: .main))
                } footer: {
                    // iOS says it once in the title; an SSH login typed here
                    // still offers Add as SSH Host… below.
                    #if os(macOS)
                    Text(String(localized: "The server your devices use to reach each other. To sign in to a computer with SSH, add it under SSH Hosts instead.", bundle: .main))
                        .foregroundStyle(WitermTheme.secondary)
                    #endif
                }
                if let problem = input.problem, problem != .empty, (submitted || problem != .invalid) {
                    Section { problemView }
                }
                if let rejection {
                    Section {
                        Label(rejection, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(WitermTheme.warning)
                            .accessibilityIdentifier("serverListError")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .main), role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, action: save)
                        .disabled(input.address == nil)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("saveServerAddress")
                }
            }
        }
        .witermTint()
        #if os(iOS)
        // The largest text sizes need the whole height for the field and its title.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .onAppear { if draft.isEmpty { addressFocused = true } }
        #else
        .presentationDetents([.medium, .large])
        #endif
        .presentationDragIndicator(.visible)
        #endif
    }

    #if os(macOS)
    /// The Mac sheet shape: the field, what it will connect to or how to fix
    /// it, then Cancel and the action trailing.
    private var macBody: some View {
        SheetScaffold(title, subtitle: String(localized: "The server your devices use to reach each other.", bundle: .main),
                      width: .form, onEscape: { dismiss() }) {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.s) {
                TextField(String(localized: "Relay Server Address", bundle: .main), text: $draft, prompt: Text(verbatim: "witerm.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .font(WitermType.code)
                    .focused($addressFocused)
                    .textContentType(.URL)
                    .accessibilityIdentifier("serverAddressField")
                    .onSubmit(save)
                    .onChange(of: draft) { rejection = nil; submitted = false }
                interpretation
                if let problem = input.problem, problem != .empty, (submitted || problem != .invalid) {
                    problemView
                }
                if let rejection {
                    Label(rejection, systemImage: "exclamationmark.circle")
                        .font(WitermType.rowDetail)
                        .foregroundStyle(WitermTheme.warning)
                        .accessibilityIdentifier("serverListError")
                }
            }
        } trailing: {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(actionTitle, action: save)
                .buttonStyle(.borderedProminent)
                .disabled(input.address == nil)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("saveServerAddress")
        }
        .onAppear { addressFocused = true }
    }
    #endif

    /// What will be used, once the text is a usable address.
    @ViewBuilder private var interpretation: some View {
        if let address = input.address {
            let local = address.hasPrefix("http://")
            Label {
                Text(local ? String(localized: "Connects to \(address) on this device", bundle: .main)
                           : String(localized: "Connects to \(address)", bundle: .main))
                    .font(.subheadline)
            } icon: {
                Image(systemName: local ? "desktopcomputer" : "lock.fill")
                    .foregroundStyle(local ? WitermTheme.secondary : WitermTheme.positive)
            }
            .foregroundStyle(WitermTheme.secondary)
            .accessibilityIdentifier("serverAddressInterpretation")
        }
    }

    private var problemView: some View {
        VStack(alignment: .leading, spacing: WitermMetrics.Space.s) {
            if let title = input.title {
                Label(title, systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WitermTheme.warning)
                    .accessibilityIdentifier("addressValidationError")
            }
            if let detail = input.detail {
                Text(detail).font(.subheadline).foregroundStyle(WitermTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let fix = input.fix {
                    Button(String(localized: "Use \(fix)", bundle: .main)) { draft = fix }
                        .accessibilityIdentifier("serverAddressFix")
                }
                if let ssh = input.sshAddress {
                    Button(String(localized: "Add as SSH Host…", bundle: .main)) {
                        dismiss()
                        NotificationCenter.default.post(name: .witermAddSSHHost, object: ssh)
                    }
                    .accessibilityIdentifier("serverAddressAddSSH")
                }
                if input.problem == .invitation {
                    Button(String(localized: "Use Invitation", bundle: .main)) {
                        let link = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                        NotificationCenter.default.post(name: .witermUseInvitation, object: link)
                    }
                    .accessibilityIdentifier("serverAddressUseInvitation")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func save() {
        submitted = true
        guard let address = input.address, (try? ServerClient.validatedURL(for: address)) != nil else {
            addressFocused = true
            return
        }
        if let reason = onSave(address) {
            rejection = reason
            addressFocused = true
        } else {
            dismiss()
        }
    }
}
