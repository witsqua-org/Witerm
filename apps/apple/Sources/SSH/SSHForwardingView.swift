import SwiftUI
import WitermSSH

struct SSHForwardingView: View {
    let connection: SSHConnection
    @State private var forwards: [SSHForward] = []
    @State private var kind = SSHForward.Kind.local
    @State private var listenPort = "8080"
    @State private var targetHost = "127.0.0.1"
    @State private var targetPort = "80"
    @State private var busy = false
    @State private var issue: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "New Forward", bundle: .main)) {
                    Picker(String(localized: "Direction", bundle: .main), selection: $kind) {
                        Text(String(localized: "Local Forward", bundle: .main)).tag(SSHForward.Kind.local)
                        Text(String(localized: "Remote Forward", bundle: .main)).tag(SSHForward.Kind.remote)
                    }
                    Text(kind == .local
                         ? String(localized: "Accept connections at 127.0.0.1 on this device and reach the target through the SSH host.", bundle: .main)
                         : String(localized: "Accept connections at 127.0.0.1 on the SSH host and reach the target through this device.", bundle: .main))
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField(String(localized: "Listening Port", bundle: .main), text: $listenPort).accessibilityIdentifier("sshForwardListenPort")
                    TextField(String(localized: "Target Host", bundle: .main), text: $targetHost).autocorrectionDisabled().sshLiteralInput()
                    TextField(String(localized: "Target Port", bundle: .main), text: $targetPort)
                    Button(String(localized: "Start Forwarding", bundle: .main), systemImage: "arrow.left.arrow.right", action: start)
                        .disabled(busy)
                        .accessibilityIdentifier("sshStartForward")
                }
                if let issue { Section { Text(issue).foregroundStyle(WitermTheme.warning) } }
                Section(String(localized: "Active Forwards", bundle: .main)) {
                    if forwards.isEmpty { Text(String(localized: "No Forwards Yet", bundle: .main)).foregroundStyle(.secondary) }
                    ForEach(forwards) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.kind == .local ? String(localized: "Local Forward", bundle: .main) : String(localized: "Remote Forward", bundle: .main)).font(WitermType.cardTitle)
                            Text(verbatim: "127.0.0.1:\(item.listenPort) → \(item.targetHost):\(item.targetPort)")
                                .font(WitermType.codeInline).textSelection(.enabled)
                            Button(String(localized: "Stop Forwarding", bundle: .main), role: .destructive) {
                                Task { await connection.stopForward(id: item.id); await refresh() }
                            }.disabled(busy)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Port Forwarding", bundle: .main))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done", bundle: .main)) { dismiss() } } }
            .task { await refresh() }
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 580)
        #endif
    }

    private func start() {
        guard let listen = Int(listenPort), let target = Int(targetPort) else {
            issue = String(localized: "Enter a valid port.", bundle: .main); return
        }
        busy = true; issue = nil
        Task {
            defer { busy = false }
            do {
                _ = try await connection.startForward(kind: kind, listenPort: listen,
                    targetHost: targetHost.trimmingCharacters(in: .whitespacesAndNewlines), targetPort: target)
                await refresh()
            } catch { issue = SSHUIError.message(error) }
        }
    }

    private func refresh() async { forwards = await connection.activeForwards() }
}
