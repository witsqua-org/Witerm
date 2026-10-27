#if os(iOS)
import AVFoundation
import SwiftUI
import VisionKit

/// Scanning only supplies invitation text to the normal identity-review flow.
/// It never opens a scanned URL or joins a pairing automatically.
struct PairingScannerView: View {
    let onInvitation: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraAllowed: Bool?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported || failed {
                    unavailable(String(localized: "Scanning Is Unavailable", bundle: .main),
                                detail: String(localized: "Copy the pairing invitation on your Mac, then paste it on the previous screen.", bundle: .main))
                } else if cameraAllowed == false {
                    ContentUnavailableView {
                        Label(String(localized: "Camera Access Needed", bundle: .main), systemImage: "camera")
                    } description: {
                        Text(String(localized: "Allow camera access in Settings to scan, or go back and paste the invitation.", bundle: .main))
                    } actions: {
                        Button(String(localized: "Open Settings", bundle: .main)) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                } else if cameraAllowed == true {
                    PairingCamera(failed: $failed) { value in
                        onInvitation(value)
                        dismiss()
                    }
                    .overlay(alignment: .bottom) {
                        Text(String(localized: "Point the camera at the pairing QR code on your Mac.", bundle: .main))
                            .font(.subheadline)
                            .padding()
                            .background(.regularMaterial, in: .rect(cornerRadius: 16))
                            .padding()
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(String(localized: "Scan Pairing Invitation", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .main)) { dismiss() }
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, DataScannerViewController.isSupported else { return }
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            cameraAllowed = allowed
            failed = allowed && !DataScannerViewController.isAvailable
        }
    }

    private func unavailable(_ title: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "qrcode.viewfinder", description: Text(detail))
            .accessibilityIdentifier("pairingScannerUnavailable")
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
