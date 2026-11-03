import CoreImage.CIFilterBuiltins
import SwiftUI

/// An invitation as a QR code, on a white tile so any camera can read it.
struct PairingQRCode: View {
    let value: String
    @State private var image: CGImage?

    var body: some View {
        // A fixed frame even before the image exists: an empty view never
        // appears, so its task would never make the image.
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .privacySensitive()
            }
        }
        .frame(width: 168, height: 168)
        .padding(12)
        .background(.white, in: .rect(cornerRadius: WitermMetrics.Radius.xl, style: .continuous))
        .witermOutline(cornerRadius: WitermMetrics.Radius.xl, hairline: true)
        .accessibilityHidden(true)
        .task(id: value) {
            image = makeImage()
        }
    }

    private func makeImage() -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
