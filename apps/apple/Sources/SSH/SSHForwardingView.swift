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
        #if os(macOS)
        macBody
        #else
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
        #endif
    }

    #if os(macOS)
    private var explanation: String {
        kind == .local
            ? String(localized: "Accept connections at 127.0.0.1 on this device and reach the target through the SSH host.", bundle: .main)
            : String(localized: "Accept connections at 127.0.0.1 on the SSH host and reach the target through this device.", bundle: .main)
    }

    /// The Mac sheet shape: a new forward, the active ones with Stop, and
    /// Done (Esc) and Start Forwarding (Return) trailing.
    private var macBody: some View {
        SheetScaffold(String(localized: "Port Forwarding", bundle: .main), width: .form, onEscape: { dismiss() }) {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.m) {
                GroupBox {
                    VStack(alignment: .leading, spacing: WitermMetrics.Space.s) {
                        Picker(String(localized: "Direction", bundle: .main), selection: $kind) {
                            Text(String(localized: "Local Forward", bundle: .main)).tag(SSHForward.Kind.local)
                            Text(String(localized: "Remote Forward", bundle: .main)).tag(SSHForward.Kind.remote)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel(String(localized: "Direction", bundle: .main))
                        Text(explanation)
                            .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: WitermMetrics.Space.s,
                             verticalSpacing: WitermMetrics.Space.s) {
                            portRow(String(localized: "Listening Port", bundle: .main), text: $listenPort,
                                    identifier: "sshForwardListenPort")
                            portRow(String(localized: "Target Host", bundle: .main), text: $targetHost)
                            portRow(String(localized: "Target Port", bundle: .main), text: $targetPort)
                        }
                        if let issue {
                            Label(issue, systemImage: "exclamationmark.circle")
                                .font(WitermType.rowDetail).foregroundStyle(WitermTheme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(WitermMetrics.Space.xs)
                } label: {
                    Text(String(localized: "New Forward", bundle: .main)).font(WitermType.cardTitle).accessibilityAddTraits(.isHeader)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        if forwards.isEmpty {
                            Text(String(localized: "No Forwards Yet", bundle: .main))
                                .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                                .padding(.vertical, WitermMetrics.Space.xs)
                        }
                        ForEach(forwards) { item in
                            if item.id != forwards.first?.id { Divider() }
                            HStack {
                                VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                                    Text(item.kind == .local ? String(localized: "Local Forward", bundle: .main)
                                         : String(localized: "Remote Forward", bundle: .main))
                                    Text(verbatim: "127.0.0.1:\(item.listenPort) → \(item.targetHost):\(item.targetPort)")
                                        .font(WitermType.codeInline).foregroundStyle(WitermTheme.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                Button(String(localized: "Stop Forwarding", bundle: .main), role: .destructive) {
                                    Task { await connection.stopForward(id: item.id); await refresh() }
                                }
                                .disabled(busy)
                            }
                            .padding(.vertical, WitermMetrics.Space.s)
                            .accessibilityElement(children: .contain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, WitermMetrics.Space.xs)
                } label: {
                    Text(String(localized: "Active Forwards", bundle: .main)).font(WitermType.cardTitle).accessibilityAddTraits(.isHeader)
                }
            }
        } trailing: {
            if busy { ProgressView().controlSize(.small) }
            Button(String(localized: "Done", bundle: .main)) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Start Forwarding", bundle: .main), action: start)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
                .accessibilityIdentifier("sshStartForward")
        }
        .task { await refresh() }
    }

    private func portRow(_ title: String, text: Binding<String>, identifier: String? = nil) -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.trailing)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(WitermType.code)
                .autocorrectionDisabled()
                .accessibilityIdentifier(identifier ?? "")
        }
    }
    #endif

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
