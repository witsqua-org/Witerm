import SwiftUI
import WitermCore

struct ServerAddressSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var invalidAddress = false
    @State private var rejection: String?
    @FocusState private var addressFocused: Bool
    let title: String
    /// Returns why the address could not be saved, or nil once it is.
    let onSave: (String) -> String?

    init(title: String, address: String, onSave: @escaping (String) -> String?) {
        self.title = title
        _draft = State(initialValue: address)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Server Address", bundle: .main), text: $draft, prompt: Text("https://witerm.example.com"))
                        .font(.system(.body, design: .monospaced))
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
                        .onChange(of: draft) { invalidAddress = false; rejection = nil }
                } header: {
                    Text(String(localized: "Server Address", bundle: .main))
                } footer: {
                    Text(String(localized: "Enter a complete address, such as https://witerm.example.com.", bundle: .main))
                        .foregroundStyle(WitermTheme.secondary)
                }
                if invalidAddress {
                    Section {
                        Label(String(localized: "Enter a valid HTTP or HTTPS root address without a username, password or path.", bundle: .main), systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(WitermTheme.warning)
                            .accessibilityIdentifier("addressValidationError")
                    }
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
                    Button(String(localized: "Save and Check", bundle: .main), action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("saveServerAddress")
                }
            }
        }
        .witermTint()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 320)
        #endif
    }

    private func save() {
        let address = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try ServerClient.validatedURL(for: address)
        } catch {
            invalidAddress = true
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
