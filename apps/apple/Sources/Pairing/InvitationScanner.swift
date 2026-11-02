#if os(iOS)
import AVFoundation
import SwiftUI
import VisionKit

/// The camera for an invitation code, inside the continue flow. Scanning
/// only supplies text to the normal review; it never opens a scanned URL.
/// Without a camera, or without permission, it shrinks to a short note on
/// how to paste instead, so paste and typing stay on screen (and above the
/// keyboard) rather than below an empty camera frame.
struct InvitationScanner: View {
    let onInvitation: (String) -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraAllowed: Bool?
    @State private var failed = false

    /// Whether this device has a camera that can scan codes at all.
    static var isSupported: Bool { DataScannerViewController.isSupported }

    var body: some View {
        Group {
            if !Self.isSupported || failed {
                FallbackNote(title: String(localized: "Scanning Is Unavailable", bundle: .main),
                             detail: String(localized: "Copy the invitation on the other device, then paste it below.", bundle: .main))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pairingScannerUnavailable")
            } else if cameraAllowed == false {
                FallbackNote(title: String(localized: "Camera Access Needed", bundle: .main),
                             detail: String(localized: "Allow camera access in Settings to scan, or paste the invitation below.", bundle: .main)) {
                    Button(String(localized: "Open Settings", bundle: .main)) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.bordered)
                    .touchTarget()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pairingScannerDenied")
            } else {
                camera
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, Self.isSupported else { return }
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            cameraAllowed = allowed
            failed = allowed && !DataScannerViewController.isAvailable
        }
    }

    /// The live camera in a square, or a placeholder while access is decided.
    private var camera: some View {
        ZStack {
            Color.black
            if cameraAllowed == true {
                PairingCamera(failed: $failed) { onInvitation($0) }
                    .overlay(alignment: .bottom) {
                        Text(String(localized: "Point at the code on the other device", bundle: .main))
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}

/// Why scanning isn't possible and what to do instead. It takes the height
/// of its text, so it wraps at every text size instead of truncating.
private struct FallbackNote<Actions: View>: View {
    let title: String
    let detail: String
    let actions: Actions
    @Environment(\.dynamicTypeSize) private var typeSize

    init(title: String, detail: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if !typeSize.isAccessibilitySize {
                IconTile(systemImage: "camera", tint: WitermTheme.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(WitermTheme.ink)
                Text(detail).font(.subheadline).foregroundStyle(WitermTheme.secondary)
                actions.padding(.top, 6)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .witermCard()
    }
}

private struct PairingCamera: UIViewControllerRepresentable {
    @Binding var failed: Bool
    let onInvitation: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                recognizesMultipleItems: false,
                                                isHighlightingEnabled: true)
        context.coordinator.task = Task { @MainActor [weak scanner] in
            guard let scanner else { return }
            do { try scanner.startScanning() } catch { failed = true; return }
            for await items in scanner.recognizedItems {
                guard !Task.isCancelled else { return }
                for case .barcode(let barcode) in items {
                    if let value = barcode.payloadStringValue {
                        scanner.stopScanning()
                        onInvitation(value)
                        return
                    }
                }
            }
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.task?.cancel()
        scanner.stopScanning()
    }

    @MainActor final class Coordinator { var task: Task<Void, Never>? }
}
#endif
