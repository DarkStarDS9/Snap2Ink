import CoreGraphics
import CoreText
import Foundation

/// The one place Core Graphics touches the print pipeline: turning a captured `CGImage` into an
/// 8-bit `GrayImage` of exactly the right pixel dimensions, and drawing the caption text.
///
/// Everything downstream of here — dithering, composition, PNG encoding — is plain arithmetic over
/// `GrayImage`. Keeping the rasterizer this thin is what lets the interesting half of the pipeline
/// be tested without a rendering context or a device.
enum PhotoRasterizer {

    /// Renders `source` into a grayscale raster of exactly `size`, scaled to fill and centre-cropped
    /// — a portrait photo pushed to a portrait panel keeps its framing, and any aspect mismatch
    /// costs the edges rather than adding letterbox bars.
    ///
    /// Returns `nil` only if Core Graphics refuses to make the context, which on a device means the
    /// requested size was nonsense.
    static func grayscale(_ source: CGImage, filling size: PixelSize) -> GrayImage? {
        guard let context = makeGrayContext(size: size) else { return nil }

        // White ground: if the source somehow fails to cover the canvas, unpainted pixels should be
        // paper, not ink. On e-ink, black is what costs the user's eye.
        context.setFillColor(gray: 1.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.interpolationQuality = .high
        context.draw(source, in: aspectFillRect(source: source, target: size))

        return image(from: context, size: size)
    }

    /// Draws `text` centred in a raster of `size`, black on white, then snaps it to the panel's
    /// levels without dithering.
    ///
    /// Caption text is *deliberately* not error-diffused. Diffusion across a glyph's anti-aliased
    /// edge scatters isolated pixels into the surrounding white, which at this size reads as dirt
    /// on the print rather than as texture. Snapping keeps the letterforms crisp — and the
    /// four-level palette means the anti-aliasing still survives as two intermediate greys.
    static func captionRaster(_ text: String, size: PixelSize) -> GrayImage? {
        guard let context = makeGrayContext(size: size) else { return nil }

        context.setFillColor(gray: 1.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))

        let pointSize = max(12.0, Double(size.height) * 0.34)
        let font = CTFontCreateWithName("Menlo" as CFString, pointSize, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: CGColor(gray: 0.0, alpha: 1.0),
            ]
        )

        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        // Core Graphics' origin is bottom-left; the caption sits on an optical baseline slightly
        // below centre, which is where a handwritten instant-print caption actually falls.
        context.textPosition = CGPoint(
            x: (Double(size.width) - bounds.width) / 2.0,
            y: (Double(size.height) - bounds.height) / 2.0 - bounds.origin.y
        )
        CTLineDraw(line, context)

        guard var raster = image(from: context, size: size) else { return nil }
        raster.pixels = raster.pixels.map { Quantizer.nearestLevel(Int($0)) }
        return raster
    }

    /// Rotates `image` by `turns` quarter-turns counter-clockwise, swapping width and height on an
    /// odd number of turns — the same direction `GrayImage.rotated90CounterClockwise()` uses, so a
    /// caller can reason about one rotation convention for the whole pipeline.
    ///
    /// Pure Core Graphics geometry: given any `CGImage`, this needs no camera, no device, and no
    /// `AVFoundation` behaviour to verify, unlike the connection-level `videoRotationAngle` this
    /// replaces for device-orientation correction — that made "is this rotation right?" a question
    /// only a physical device could answer. This makes it a question a synthetic test image answers,
    /// in `PrintPipelineTests`.
    static func rotated(_ image: CGImage, quarterTurnsCounterClockwise turns: Int) -> CGImage? {
        let normalized = ((turns % 4) + 4) % 4
        guard normalized != 0 else { return image }

        let swapsDimensions = normalized % 2 == 1
        let newWidth = swapsDimensions ? image.height : image.width
        let newHeight = swapsDimensions ? image.width : image.height

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Rotate about the new canvas' centre, then draw the source centred on its own dimensions —
        // one formula for all three non-trivial cases rather than a hand-derived translate per case.
        context.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
        context.rotate(by: CGFloat(normalized) * .pi / 2)
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) / 2,
                y: -CGFloat(image.height) / 2,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        return context.makeImage()
    }

    // MARK: - Internals

    private static func makeGrayContext(size: PixelSize) -> CGContext? {
        guard size.width > 0, size.height > 0 else { return nil }
        return CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            // One byte per pixel, no row padding — matches `GrayImage`'s layout exactly, so
            // extracting the buffer is a straight copy rather than a row-by-row unpack.
            bytesPerRow: size.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    }

    private static func image(from context: CGContext, size: PixelSize) -> GrayImage? {
        guard let data = context.data else { return nil }
        let count = size.width * size.height
        // Despite the origin being bottom-left in the drawing coordinate system, a manually-created
        // `CGContext`'s backing buffer is already stored row 0 = top, matching `GrayImage` — verified
        // empirically (a shape filled into the "top" of the drawing coordinate space lands in the
        // first rows of `context.data`). Reversing the rows "to correct for" a bottom-up buffer that
        // was never actually bottom-up silently flips every photo and caption upside down.
        let buffer = UnsafeRawBufferPointer(start: data, count: count)
        return GrayImage(width: size.width, height: size.height, pixels: Array(buffer))
    }

    /// The rect to draw `source` into so it covers `target` completely, centred, with no distortion.
    /// Exposed for tests — the crop is the difference between a portrait shot that frames the
    /// subject and one that cuts their head off.
    static func aspectFillRect(source: CGImage, target: PixelSize) -> CGRect {
        aspectFillRect(sourceWidth: source.width, sourceHeight: source.height, target: target)
    }

    static func aspectFillRect(sourceWidth: Int, sourceHeight: Int, target: PixelSize) -> CGRect {
        let scale = max(Double(target.width) / Double(sourceWidth), Double(target.height) / Double(sourceHeight))
        let width = Double(sourceWidth) * scale
        let height = Double(sourceHeight) * scale
        return CGRect(
            x: (Double(target.width) - width) / 2.0,
            y: (Double(target.height) - height) / 2.0,
            width: width,
            height: height
        )
    }
}
