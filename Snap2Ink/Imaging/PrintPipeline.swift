import CoreGraphics
import Foundation

/// What the app knows about the panel it is printing to. Read from the device's capability
/// characteristic when connected; `.assumedX3` covers the "not connected yet, but the user wants to
/// see a preview now" case.
struct DisplayGeometry: Equatable, Sendable {
    let pixels: PixelSize
    /// The device's advertised `kMaxImageFieldLen`. v6 widened the START packet's total-length
    /// field to uint32, so this is no longer bounded by 65,535 — read it at runtime rather than
    /// assuming.
    let maxImageBytes: Int

    /// The XTEINK X3's panel and image cap.
    ///
    /// **528×792, not 480×800.** `lib/Xtc/Xtc/XtcTypes.h` defines `DISPLAY_WIDTH = 480` /
    /// `DISPLAY_HEIGHT = 800`, which is a trap: the X3 (UC8253, 792×528 glass) and the X4
    /// (SSD1677, 800×480) share one binary, and that header holds the X4's numbers. The protocol
    /// document states it outright — *"Companion Mode reports 528 x 792, not the 800 x 480 that
    /// older notes in this repo assume"* — and the framebuffer arithmetic agrees: 528 × 792 / 8 =
    /// 52,272 bytes.
    ///
    /// The firmware does not hardcode either: `CompanionBle.cpp` fills the capability
    /// characteristic from `renderer.getScreenWidth()/getScreenHeight()` at runtime. So this
    /// constant is only a placeholder, replaced by the advertised values the moment a device
    /// connects (v6 bytes 17..20 for pixels, 6..9 for the cap). It exists so a proof can be
    /// rendered before anything is paired — the user is entitled to see a print before committing
    /// to a device — and being wrong here costs a slightly mis-sized preview, never a bad push.
    static let assumedX3 = DisplayGeometry(
        pixels: PixelSize(width: 528, height: 792),
        maxImageBytes: 128 * 1024
    )
}

/// A finished print: the exact pixels the panel will show, and the bytes that carry them.
struct Print: Equatable {
    let image: GrayImage
    let imageData: Data
    let algorithm: DitherAlgorithm
    let style: PrintStyle

    var byteCount: Int { imageData.count }
}

/// Assembles a `Print` from a captured frame: rasterize, dither, compose, encode.
///
/// Synchronous and pure apart from `PhotoRasterizer`'s Core Graphics use. A full 480×800 print takes
/// a few tens of milliseconds, so callers run it off the main actor and show the result; there is no
/// progress reporting here because there is nothing slow enough to report on. The slow part is the
/// transfer, which is `DisplayTransport`'s problem.
enum PrintPipeline {

    enum PipelineError: Error, Equatable {
        case rasterizationFailed
        /// The packed image exceeds the device's advertised cap. Since the packed size is fixed by
        /// panel geometry alone, this means the geometry itself is too large for the cap — no retry
        /// fixes it. Carries both numbers so the UI can say something more useful than "too big".
        case tooLarge(bytes: Int, limit: Int)
    }

    struct Request {
        let source: CGImage
        let algorithm: DitherAlgorithm
        let style: PrintStyle
        /// Caption for `.framed`; ignored for `.fullBleed`, which has no strip to put it in.
        let caption: String
        let geometry: DisplayGeometry
        /// How many quarter-turns (counter-clockwise) the photo gets before it is blitted into the
        /// aperture.
        ///
        /// Deliberately not inferred from `source`'s aspect ratio — an earlier version of `compose`
        /// did that, and it cannot work: a landscape-left and a landscape-right photo are the same
        /// shape but need *different* rotations (as do an upright and an upside-down portrait photo),
        /// so shape alone can't distinguish them. The caller — `CameraController.
        /// photoApertureQuarterTurns(for:)` for a real capture — is the only thing that still knows
        /// which of those cases this photo actually was.
        var photoQuarterTurns: Int
    }

    static func makePrint(_ request: Request) throws -> Print {
        let composed = try compose(request, algorithm: request.algorithm)
        let packed = try ImagePacker.pack(composed)

        // Unlike the PNG encoder this replaced, the packed size is a fixed function of the panel's
        // dimensions — bytesPerRow * height, always, no matter which dither algorithm ran. So there
        // is nothing to retry with: if it doesn't fit, no choice of algorithm will make it fit.
        guard packed.count <= request.geometry.maxImageBytes else {
            throw PipelineError.tooLarge(bytes: packed.count, limit: request.geometry.maxImageBytes)
        }

        return Print(
            image: composed,
            imageData: packed,
            algorithm: request.algorithm,
            style: request.style
        )
    }

    /// Builds the calibration target as a sendable print.
    ///
    /// Deliberately bypasses rasterizing, dithering and composition: `CalibrationTarget` is already
    /// exactly quantized at the panel's pixel size, and every one of those stages could alter it.
    /// Going straight to the encoder is what makes the result a bisection tool — if the panel shows
    /// anything other than this, the fault is downstream of the phone.
    static func makeCalibrationPrint(geometry: DisplayGeometry) throws -> Print {
        let image = CalibrationTarget.image(size: geometry.pixels)
        let packed = try ImagePacker.pack(image)
        guard packed.count <= geometry.maxImageBytes else {
            throw PipelineError.tooLarge(bytes: packed.count, limit: geometry.maxImageBytes)
        }
        return Print(image: image, imageData: packed, algorithm: .none, style: .fullBleed)
    }

    /// Rasterize → dither → drop into the frame.
    ///
    /// The panel is a fixed 480×800 portrait rectangle that never rotates, but a photo shot with the
    /// phone held sideways is landscape. Rather than centre-cropping that scene down to a portrait
    /// sliver, it is aspect-filled into a landscape-shaped target — the photo aperture's own
    /// dimensions, transposed — and then just that photo is rotated to fit the aperture. The border
    /// and caption band are always laid out against the true portrait canvas, never a landscape one,
    /// so a landscape shot's frame looks exactly like a portrait shot's: same proportions, same room
    /// for the caption. Rotating the whole frame instead (an earlier version of this) put the border
    /// math through a canvas shape it was never designed for and starved the caption band to nothing.
    private static func compose(_ request: Request, algorithm: DitherAlgorithm) throws -> GrayImage {
        let layout = PrintLayout.layout(style: request.style, canvas: request.geometry.pixels)

        let turns = ((request.photoQuarterTurns % 4) + 4) % 4

        // An odd turn count swaps the aperture's own dimensions before the rotation swaps them back;
        // an even one (0 or 2) doesn't touch the aperture shape at all.
        let fillSize = turns % 2 == 1
            ? PixelSize(width: layout.photo.height, height: layout.photo.width)
            : layout.photo.size
        guard let photo = PhotoRasterizer.grayscale(request.source, filling: fillSize) else {
            throw PipelineError.rasterizationFailed
        }
        var dithered = Ditherer.dither(photo, using: algorithm)
        for _ in 0..<turns {
            dithered = dithered.rotated90CounterClockwise()
        }

        // `.fullBleed`'s photo rect already covers the whole canvas, so `dithered` alone is the full
        // print. `.framed` always pads out to the full canvas — even on a canvas so oddly shaped that
        // `layout.caption` comes back `nil` for want of room — because the result has to be exactly
        // `layout.canvas`'s size regardless; returning the smaller, unpadded photo raster in that
        // case would silently hand back an undersized print.
        let composed: GrayImage
        if request.style == .framed {
            // Paper white, so the border and any unfilled caption strip are level 3 exactly.
            var canvas = GrayImage(
                width: layout.canvas.width,
                height: layout.canvas.height,
                filledWith: Quantizer.levels[3]
            )
            canvas.blit(dithered, atX: layout.photo.x, y: layout.photo.y)

            if let captionRect = layout.caption, !request.caption.isEmpty,
               let caption = PhotoRasterizer.captionRaster(request.caption, size: captionRect.size) {
                canvas.blit(caption, atX: captionRect.x, y: captionRect.y)
            }
            composed = canvas
        } else {
            composed = dithered
        }

        return composed
    }
}
