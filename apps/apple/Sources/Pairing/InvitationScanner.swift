#if os(iOS)
import AVFoundation
import SwiftUI
import VisionKit

/// The camera for an invitation code, inside the continue flow. Scanning
/// only supplies text to the normal review; it never opens a scanned URL.
/// Without a camera, or without permission, it says how to paste instead.
struct InvitationScanner: View {
    let onInvitation: (String) -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraAllowed: Bool?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if !DataScannerViewController.isSupported || failed {
                message(String(localized: "Scanning Is Unavailable", bundle: .main), systemImage: "camera",
                        detail: String(localized: "Copy the invitation on the other device, then paste it below.", bundle: .main))
                    .accessibilityIdentifier("pairingScannerUnavailable")
            } else if cameraAllowed == false {
                VStack(spacing: 12) {
                    message(String(localized: "Camera Access Needed", bundle: .main), systemImage: "camera",
                            detail: String(localized: "Allow camera access in Settings to scan, or paste the invitation below.", bundle: .main))
                    Button(String(localized: "Open Settings", bundle: .main)) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            } else if cameraAllowed == true {
                PairingCamera(failed: $failed) { onInvitation($0) }
                    .overlay(alignment: .bottom) {
                        Text(String(localized: "Point at the code on the other device", bundle: .main))
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.bottom, 14)
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
        .task(id: scenePhase) {
            guard scenePhase == .active, DataScannerViewController.isSupported else { return }
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            cameraAllowed = allowed
            failed = allowed && !DataScannerViewController.isAvailable
        }
    }

    private func message(_ title: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.title).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).multilineTextAlignment(.center).opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(24)
        .accessibilityElement(children: .combine)
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
