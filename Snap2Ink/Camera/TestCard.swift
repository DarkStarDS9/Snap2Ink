import CoreGraphics
import Foundation

/// A synthetic photograph, for the simulator and for anywhere the camera is unavailable.
///
/// Deliberately not a flat colour chart. To be any use for judging a dither it has to contain the
/// things that separate the algorithms: a smooth full-range gradient (where ordered dithering shows
/// its hatch and Floyd–Steinberg shows its worms), a soft radial falloff (where Atkinson blows out
/// the highlight), hard edges, and a fine detail region that no four-level palette can resolve.
enum TestCard {

    static func make(width: Int = 1200, height: Int = 1600) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!

        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: width * height)
        let w = Double(width)
        let h = Double(height)

        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x) / w
                let fy = Double(y) / h

                // Vertical sweep across the full range, the backbone of the card.
                var value = fy

                // A soft off-centre highlight — the shape Atkinson clips and Floyd–Steinberg keeps.
                let glow = exp(-(pow(fx - 0.34, 2) + pow(fy - 0.62, 2)) / 0.045)
                value = min(1.0, value + 0.55 * glow)

                // Hard-edged bars along the top: quantization has nothing to dither here, so any
                // speckle that appears in them is error bleeding in from a neighbour.
                if fy < 0.16 {
                    value = Double(Int(fx * 6.0) % 2) * 0.85 + 0.05
                }

                // Fine diagonal detail below the resolution of four levels, where the algorithms
                // differ most visibly.
                if fy > 0.82 {
                    value = 0.5 + 0.42 * sin((fx * w + fy * h) * 0.35)
                }

                buffer[y * width + x] = UInt8(min(max(value, 0.0), 1.0) * 255.0)
            }
        }

        return context.makeImage()!
    }
}
