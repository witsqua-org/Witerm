#if os(macOS)
import SwiftUI

/// The first connection to an SSH host, on the Mac: the host's key to compare,
/// then Cancel (Esc) and Trust and Connect. Trusting is a decision, so Return
/// doesn't press it. iOS keeps `SSHTrustView`.
struct MacSSHTrustSheet: View {
    let prompt: SSHTrustPrompt
    let model: SSHWorkspaceModel

    var body: some View {
        SheetScaffold(String(localized: "First Connection to This Host", bundle: .main),
                      subtitle: String(localized: "Check that this matches the fingerprint the host's owner gives you.", bundle: .main),
                      width: .form) {
            GroupBox {
                VStack(alignment: .leading, spacing: WitermMetrics.Space.s) {
                    LabeledContent(String(localized: "Host", bundle: .main), value: prompt.key.authority)
                    LabeledContent(String(localized: "Key Type", bundle: .main), value: prompt.key.algorithm)
                    Divider()
                    Text(prompt.key.fingerprint)
                        .font(WitermType.code)
                        .foregroundStyle(WitermTheme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(String(localized: "Host fingerprint, \(String(prompt.key.fingerprint))", bundle: .main))
                        .accessibilityIdentifier("sshHostFingerprint")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(WitermMetrics.Space.xs)
            }
        } trailing: {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) { model.rejectHostKey() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Trust and Connect", bundle: .main), systemImage: "checkmark.shield") {
                Task { await model.approveHostKey(prompt) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("sshTrustHost")
        }
        .interactiveDismissDisabled()
    }
}
#endif
