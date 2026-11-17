#if os(macOS)
import SwiftUI
import WitermCore

/// Settings ▸ Orbit: the OpenAI API key, the model, and the conversations
/// kept on this Mac.
struct OrbitSettings: View {
    @Bindable var orbit: OrbitService
    @State private var key = ""
    @State private var remember = true
    @State private var model = ""
    @State private var clearing = false
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "API Key", bundle: .main), value: keyStatus)
                    .accessibilityIdentifier("orbitKeyStatus")
                SecureField(String(localized: "OpenAI API Key", bundle: .main), text: $key,
                            prompt: Text(verbatim: "sk-…"))
                    .accessibilityIdentifier("orbitKeyField")
                Toggle(String(localized: "Keep in Keychain on This Mac", bundle: .main), isOn: $remember)
                    .help(String(localized: "Off: Witerm forgets the key when it quits.", bundle: .main))
                HStack {
                    Button(orbit.keyState == .none ? String(localized: "Save Key", bundle: .main)
                                                   : String(localized: "Replace Key", bundle: .main)) {
                        Task {
                            saved = await orbit.setKey(key, remember: remember)
                            if saved { key = "" }
                        }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("orbitSaveKey")
                    if orbit.keyState != .none {
                        Button(String(localized: "Remove Key", bundle: .main), role: .destructive) {
                            Task { await orbit.removeKey() }
                        }
                    }
                    Spacer()
                }
                if let problem = orbit.problem {
                    Text(problem).font(WitermType.rowDetail).foregroundStyle(WitermTheme.warning)
                }
            } header: {
                Text(verbatim: "OpenAI")
            } footer: {
                Text(String(localized: "Orbit uses your own API key from platform.openai.com. What Orbit reads in your terminals is sent to OpenAI to answer you; nothing goes to Witerm’s servers.", bundle: .main))
            }
            Section {
                TextField(String(localized: "Model", bundle: .main), text: $model)
                    .onSubmit(saveModel)
                    .accessibilityIdentifier("orbitModel")
                HStack {
                    Button(String(localized: "Use Model", bundle: .main), action: saveModel)
                        .disabled(!OrbitWire.validModel(model.trimmingCharacters(in: .whitespaces)) || model == orbit.model)
                    Button(String(localized: "Default", bundle: .main)) {
                        model = OrbitWire.defaultModel
                        saveModel()
                    }
                    .disabled(orbit.model == OrbitWire.defaultModel)
                    Spacer()
                }
            } footer: {
                Text(String(localized: "Any OpenAI model that supports the Responses API and function calling. The default is \(OrbitWire.defaultModel).", bundle: .main))
            }
            Section {
                LabeledContent(String(localized: "Conversations", bundle: .main), value: "\(orbit.threads.count)")
                Button(String(localized: "Delete All Conversations…", bundle: .main), role: .destructive) { clearing = true }
                    .disabled(orbit.threads.isEmpty)
            } header: {
                Text(String(localized: "On This Mac", bundle: .main))
            } footer: {
                Text(String(localized: "Conversations and tasks are kept only on this Mac, and removed after 30 days without use.", bundle: .main))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model = orbit.model
            orbit.watch()
        }
        .onDisappear { orbit.unwatch() }
        .alert(String(localized: "Delete All Conversations?", bundle: .main), isPresented: $clearing) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
                // Return cancels: deleting can't be undone.
                .keyboardShortcut(.defaultAction)
            Button(String(localized: "Delete All", bundle: .main), role: .destructive) { Task { await orbit.clearAll() } }
        } message: {
            Text(String(localized: "Every conversation and task is removed from this Mac, and running ones stop. Terminals keep running.", bundle: .main))
        }
    }

    private var keyStatus: String {
        switch orbit.keyState {
        case .keychain: String(localized: "Saved in Keychain", bundle: .main)
        case .session: String(localized: "Kept until Witerm quits", bundle: .main)
        case .none: String(localized: "Not set", bundle: .main)
        }
    }

    private func saveModel() {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard OrbitWire.validModel(trimmed) else { return }
        model = trimmed
        orbit.model = trimmed
    }
}
#endif
