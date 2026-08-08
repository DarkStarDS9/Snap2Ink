import CoreGraphics
import Foundation

extension GrayImage {
    /// A `CGImage` view of this raster, for showing the dithered result on the phone.
    ///
    /// The preview is the print — the same pixel buffer that gets encoded is what the user sees, so
    /// "it looked different on my phone" can only ever be the panel's contrast, never the app
    /// rendering something else. Scale it up with nearest-neighbour interpolation at the SwiftUI
    /// layer or the dither pattern turns to mush.
    func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
