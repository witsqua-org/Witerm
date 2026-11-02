import SwiftUI
import WitermSSH

private struct SSHStoredHostKeyRow: Identifiable {
    let id: UUID
    let role: String
    let authority: String
    let key: SSHHostKey?
}

struct SSHHostKeysView: View {
    let profile: SSHProfile
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [SSHStoredHostKeyRow] = []
    @State private var loading = false
    @State private var issue: String?
    @State private var removing: SSHHostKey?

    var body: some View {
        NavigationStack {
            List {
                if let issue {
                    Text(issue).foregroundStyle(WitermTheme.warning)
                        .accessibilityIdentifier("sshHostKeysIssue")
                }
                ForEach(rows) { row in
                    Section(row.role) {
                        Text(row.authority).font(WitermType.code)
                            .textSelection(.enabled)
                        if let key = row.key {
                            LabeledContent(String(localized: "Key Type", bundle: .main), value: key.algorithm)
                            Text(key.fingerprint).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityLabel(String(localized: "Host fingerprint, \(String(key.fingerprint))", bundle: .main))
                            Button(String(localized: "Remove Host Trust", bundle: .main), role: .destructive) { removing = key }
                                .accessibilityIdentifier("sshRemoveHostTrust-\(row.id.uuidString)")
                        } else {
                            Text(String(localized: "No Saved Host Key", bundle: .main)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .disabled(loading)
            .navigationTitle(String(localized: "Host Keys", bundle: .main))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done", bundle: .main)) { dismiss() } }
            }
            .overlay { if loading { ProgressView(String(localized: "Loading host keys…", bundle: .main)) } }
            .task { await load() }
            .alert(String(localized: "Remove Host Trust?", bundle: .main), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) { removing = nil }
                Button(String(localized: "Remove Trust", bundle: .main), role: .destructive) {
                    guard let key = removing else { return }
                    removing = nil
                    Task { await forget(key) }
                }.accessibilityIdentifier("sshConfirmForgetHostKey")
            } message: {
                Text(String(localized: "The saved key for \(String(removing?.authority ?? "")) will be removed. Verify the host change first; you will need to compare its fingerprint when connecting again.", bundle: .main))
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 560, minHeight: 420)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let store = try SSHKnownHosts()
            var result: [SSHStoredHostKeyRow] = []
            let hosts = [(String(localized: "Target Host", bundle: .main), profile.host)]
                + profile.jumpHosts.enumerated().map { (String(localized: "Jump Host \(String($0.offset + 1))", bundle: .main), $0.element) }
            for (role, host) in hosts {
                let key = try await store.storedKey(authority: host.authority)
                try Task.checkCancellation()
                result.append(SSHStoredHostKeyRow(id: host.id, role: role, authority: host.authority, key: key))
            }
            rows = result
        } catch { if !Task.isCancelled { issue = SSHUIError.message(error) } }
    }

    private func forget(_ key: SSHHostKey) async {
        loading = true; issue = nil
        do {
            // Delete only the fingerprint actually displayed and confirmed.
            // A concurrent change must be reviewed rather than silently removed.
            try await SSHKnownHosts().forget(authority: key.authority, expectedFingerprint: key.fingerprint)
            await load()
        } catch {
            if error as? SSHFailure == .hostKeyChanged {
                issue = String(localized: "The host key has changed. Review it again before continuing.", bundle: .main)
                await load()
            } else { issue = SSHUIError.message(error) }
            loading = false
        }
    }
}
