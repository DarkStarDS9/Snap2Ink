import CoreGraphics
import XCTest
@testable import Snap2Ink

/// End-to-end: a photograph in, a sendable print out. Also the place the real, measured print sizes
/// are asserted — the number that decides whether the whole approach fits on the wire.
final class PrintPipelineTests: XCTestCase {

    private let geometry = DisplayGeometry.assumedX3

    // MARK: - Orientation

    /// Regression test for a real bug: `PhotoRasterizer` used to reverse the context buffer's rows
    /// to "correct for" a bottom-up bitmap layout that a manually-created `CGContext` never actually
    /// has, silently flipping every captured photo (and its baked-in caption) upside down — visible
    /// on both the phone's own proof preview and the reader, since both come from the same buffer.
    func test_grayscale_preservesOrientation_topLeftStaysTopLeft() {
        let w = 100, h = 100
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Black square in the top-left quadrant only, in normal (top-down) image terms. CG's fill
        // coordinates are bottom-up, so y = h/2..h is the *top* half.
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        let source = ctx.makeImage()!

        let gray = PhotoRasterizer.grayscale(source, filling: PixelSize(width: w, height: h))!

        func isBlack(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Bool {
            for y in y0..<y1 { for x in x0..<x1 where gray[x, y] != 0 { return false } }
            return true
        }
        func isWhite(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Bool {
            for y in y0..<y1 { for x in x0..<x1 where gray[x, y] != 255 { return false } }
            return true
        }
        XCTAssertTrue(isBlack(0, w / 2, 0, h / 2), "the top-left quadrant should stay black")
        XCTAssertTrue(isWhite(w / 2, w, 0, h / 2), "top-right must stay white")
        XCTAssertTrue(isWhite(0, w / 2, h / 2, h), "bottom-left must stay white — this is what regresses if the flip bug returns")
        XCTAssertTrue(isWhite(w / 2, w, h / 2, h), "bottom-right must stay white")
    }

    /// A synthetic marker, non-square so a dimension-swap bug can't hide behind a square coincidence:
    /// black in the top-left quadrant only (in normal, top-down image terms), white elsewhere.
    private func markerImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        // CG's fill coordinates are bottom-up, so the top-left quadrant in image terms is here.
        ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    /// Which quadrant (0 = top-left, 1 = top-right, 2 = bottom-left, 3 = bottom-right) is black,
    /// sampled at each quadrant's centre so resampling blur near an edge can't cause a false miss.
    private func blackQuadrantIndex(_ image: GrayImage) -> Int? {
        let centres = [
            (image.width / 4, image.height / 4),
            (3 * image.width / 4, image.height / 4),
            (image.width / 4, 3 * image.height / 4),
            (3 * image.width / 4, 3 * image.height / 4),
        ]
        return centres.firstIndex { image[$0.0, $0.1] < 128 }
    }

    func test_rotated_leavesTheImageUnchangedAtZeroTurns() {
        let source = markerImage(width: 80, height: 120)

        let rotated = PhotoRasterizer.rotated(source, quarterTurnsCounterClockwise: 0)

        XCTAssertEqual(rotated?.width, source.width)
        XCTAssertEqual(rotated?.height, source.height)
    }

    /// `CameraController` replaced a per-shot `AVCaptureConnection.videoRotationAngle` guess — which
    /// only a physical device could confirm, and was confirmed wrong twice — with this function
    /// applying its own rotation. This cross-checks it against `GrayImage.
    /// rotated90CounterClockwise()`, the plain-arithmetic rotation already relied on for landscape
    /// print layout: both claim the same counter-clockwise direction, so rotating the same source `n`
    /// times with each and rasterizing should land the marker in the same quadrant, independent of
    /// either implementation's own correctness.
    func test_rotated_agreesWithGrayImagesCounterClockwiseConvention() throws {
        let w = 80, h = 120
        let source = markerImage(width: w, height: h)
        let baselineGray = try XCTUnwrap(PhotoRasterizer.grayscale(source, filling: PixelSize(width: w, height: h)))

        for turns in [1, 2, 3] {
            let expected = (0..<turns).reduce(baselineGray) { image, _ in image.rotated90CounterClockwise() }

            let rotatedImage = try XCTUnwrap(
                PhotoRasterizer.rotated(source, quarterTurnsCounterClockwise: turns), "turns=\(turns)"
            )
            XCTAssertEqual(rotatedImage.width, expected.width, "turns=\(turns)")
            XCTAssertEqual(rotatedImage.height, expected.height, "turns=\(turns)")

            let actual = try XCTUnwrap(
                PhotoRasterizer.grayscale(rotatedImage, filling: PixelSize(width: rotatedImage.width, height: rotatedImage.height)),
                "turns=\(turns)"
            )
            XCTAssertEqual(blackQuadrantIndex(actual), blackQuadrantIndex(expected), "turns=\(turns)")
        }
    }

    // MARK: - Layout

    func test_fullBleedLayout_coversThePanelWithNoCaption() {
        let layout = PrintLayout.layout(style: .fullBleed, canvas: geometry.pixels)

        XCTAssertEqual(
            layout.photo,
            PixelRect(x: 0, y: 0, width: geometry.pixels.width, height: geometry.pixels.height)
        )
        XCTAssertNil(layout.caption)
    }

    func test_framedLayout_hasEqualSideBordersAndADeeperCaptionStrip() {
        let layout = PrintLayout.layout(style: .framed, canvas: geometry.pixels)

        let leftBorder = layout.photo.x
        let rightBorder = layout.canvas.width - (layout.photo.x + layout.photo.width)
        XCTAssertEqual(leftBorder, rightBorder, "the frame must be symmetric")
        XCTAssertEqual(layout.photo.y, leftBorder, "top border matches the sides, as on a real print")

        guard let caption = layout.caption else { return XCTFail("framed layout must have a caption strip") }
        XCTAssertGreaterThan(caption.height, leftBorder * 4, "the caption strip is what makes it read as a framed print")
        XCTAssertEqual(caption.y, layout.photo.y + layout.photo.height, "the strip starts where the photo ends")
    }

    func test_framedLayout_staysInsideTheCanvasOnAnUnexpectedPanelSize() {
        for canvas in [DisplayGeometry.assumedX3.pixels, PixelSize(width: 200, height: 200), PixelSize(width: 800, height: 480)] {
            let layout = PrintLayout.layout(style: .framed, canvas: canvas)
            XCTAssertGreaterThanOrEqual(layout.photo.x, 0)
            XCTAssertLessThanOrEqual(layout.photo.x + layout.photo.width, canvas.width, "canvas \(canvas)")
            XCTAssertLessThanOrEqual(layout.photo.y + layout.photo.height, canvas.height, "canvas \(canvas)")
        }
    }

    // MARK: - Cropping

    func test_aspectFill_coversTheTargetAndCentresTheOverflow() {
        // A 4:3 landscape source into a tall portrait target: it has to be scaled by height, and the
        // horizontal overflow split evenly, or the subject drifts out of frame.
        let rect = PhotoRasterizer.aspectFillRect(sourceWidth: 4000, sourceHeight: 3000, target: PixelSize(width: 432, height: 600))

        XCTAssertGreaterThanOrEqual(rect.width, 432)
        XCTAssertEqual(rect.height, 600, accuracy: 0.5)
        XCTAssertEqual(rect.origin.x, (432 - rect.width) / 2, accuracy: 0.5, "overflow is centred")
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.5)
    }

    // MARK: - Dimensions come from the device, never from a constant

    /// The panel size is read from capability bytes 17..20 at runtime. Hardcoding it is exactly the
    /// mistake that shipped 480×800 against a 528×792 panel — and an image at the wrong dimensions
    /// is scaled and resampled on-device, which destroys the dither the whole app exists to control.
    ///
    /// So this asserts the packed payload matches the *advertised* geometry, for sizes that are not
    /// the placeholder, including a landscape one and a deliberately odd one. There is no header to
    /// carry the dimensions any more — the device already has them from the capability characteristic
    /// — so the only thing that can prove this is the payload's byte count.
    func test_printsAreEncodedAtWhateverTheDeviceAdvertises() throws {
        let advertised = [
            PixelSize(width: 528, height: 792),
            PixelSize(width: 480, height: 800),
            PixelSize(width: 800, height: 480),
            PixelSize(width: 411, height: 613),
        ]

        for pixels in advertised {
            let geometry = DisplayGeometry(pixels: pixels, maxImageBytes: 128 * 1024)
            let result = try PrintPipeline.makePrint(
                PrintPipeline.Request(
                    source: TestCard.make(),
                    algorithm: .atkinson,
                    style: .fullBleed,
                    caption: "",
                    geometry: geometry,
                    photoQuarterTurns: 0
                )
            )

            XCTAssertEqual(result.image.width, pixels.width, "\(pixels)")
            XCTAssertEqual(result.image.height, pixels.height, "\(pixels)")

            // Not just the in-memory raster — the bytes actually sent must carry those dimensions.
            XCTAssertEqual(
                result.imageData.count, ImagePacker.bytesPerRow(pixels.width) * pixels.height,
                "packed payload size for \(pixels)"
            )
        }
    }

    func test_framedPrintsAlsoFollowTheAdvertisedGeometry() throws {
        let geometry = DisplayGeometry(pixels: PixelSize(width: 411, height: 613), maxImageBytes: 128 * 1024)
        let result = try PrintPipeline.makePrint(
            PrintPipeline.Request(
                source: TestCard.make(),
                algorithm: .floydSteinberg,
                style: .framed,
                caption: "1 Jan 2026",
                geometry: geometry,
                photoQuarterTurns: 0
            )
        )

        XCTAssertEqual(result.image.width, 411)
        XCTAssertEqual(result.image.height, 613)
    }

    func test_calibrationTargetAlsoFollowsTheAdvertisedGeometry() throws {
        let geometry = DisplayGeometry(pixels: PixelSize(width: 411, height: 613), maxImageBytes: 128 * 1024)
        let result = try PrintPipeline.makeCalibrationPrint(geometry: geometry)

        XCTAssertEqual(result.imageData.count, ImagePacker.bytesPerRow(411) * 613)
    }

    // MARK: - End to end

    func test_makePrint_producesAFullPanelQuantizedPrint() throws {
        let result = try PrintPipeline.makePrint(request(algorithm: .atkinson, style: .fullBleed))

        XCTAssertEqual(result.image.width, geometry.pixels.width)
        XCTAssertEqual(result.image.height, geometry.pixels.height)
        XCTAssertTrue(Quantizer.isQuantized(result.image))
    }

    func test_makePrint_framedLeavesAPureWhiteBorder() throws {
        let result = try PrintPipeline.makePrint(request(algorithm: .atkinson, style: .framed))
        let layout = PrintLayout.layout(style: .framed, canvas: geometry.pixels)

        // The border is paper, not dithered noise — error diffusion must not have bled into it.
        for x in 0..<result.image.width {
            XCTAssertEqual(result.image[x, 0], 255, "top border pixel \(x) is not paper white")
        }
        for y in 0..<layout.photo.y {
            XCTAssertEqual(result.image[0, y], 255, "left border row \(y) is not paper white")
        }
    }

    /// `photoQuarterTurns` is explicit precisely because `compose()` can't infer it from the source's
    /// shape (see `PrintPipeline.Request.photoQuarterTurns`'s doc comment) — this is the regression
    /// that motivated making it explicit: every one of the four turn counts must still produce an
    /// exactly-panel-sized print with an untouched, pure-white border, proof that only the photo
    /// inside the aperture moves, never the frame around it.
    func test_makePrint_photoQuarterTurns_rotatesOnlyThePhotoNeverTheBorder() throws {
        let layout = PrintLayout.layout(style: .framed, canvas: geometry.pixels)

        for turns in 0...3 {
            let result = try PrintPipeline.makePrint(
                PrintPipeline.Request(
                    source: TestCard.make(),
                    algorithm: .atkinson,
                    style: .framed,
                    caption: "1 Jan 2026",
                    geometry: geometry,
                    photoQuarterTurns: turns
                )
            )

            XCTAssertEqual(result.image.width, geometry.pixels.width, "turns=\(turns)")
            XCTAssertEqual(result.image.height, geometry.pixels.height, "turns=\(turns)")
            for x in 0..<result.image.width {
                XCTAssertEqual(result.image[x, 0], 255, "turns=\(turns): top border pixel \(x)")
            }
            for y in 0..<layout.photo.y {
                XCTAssertEqual(result.image[0, y], 255, "turns=\(turns): left border row \(y)")
            }
        }
    }

    /// The panel never rotates, so a landscape source is printed sideways within its aperture rather
    /// than centre-cropped down to a portrait sliver: it is aspect-filled into a landscape-shaped
    /// target and just that photo is rotated to fit. This is the difference between a landscape shot
    /// losing most of its width and losing only the same modest aspect-fill overflow a portrait shot
    /// already tolerates.
    func test_makePrint_landscapeSource_rotatesToFillThePanelInstead() throws {
        let landscape = TestCard.make(width: 1600, height: 1200)
        let result = try PrintPipeline.makePrint(
            PrintPipeline.Request(
                source: landscape,
                algorithm: .atkinson,
                style: .fullBleed,
                caption: "",
                geometry: geometry,
                photoQuarterTurns: 1
            )
        )

        // Still exactly the panel's own portrait dimensions — the rotation happens inside the
        // pipeline, not by handing back a landscape-shaped image the transport has to cope with.
        XCTAssertEqual(result.image.width, geometry.pixels.width)
        XCTAssertEqual(result.image.height, geometry.pixels.height)
    }

    /// The border and caption band are laid out against the true portrait canvas regardless of the
    /// source's orientation — only the photo content inside the aperture rotates — so a landscape
    /// shot's frame has to look exactly like a portrait shot's: same border, same room for a caption.
    /// An earlier version of this rotated the whole frame into landscape space first, which silently
    /// squeezed the caption band out of existence on the panel's actual proportions.
    func test_makePrint_landscapeSource_keepsTheFramedCaptionAttachedAfterRotation() throws {
        let layout = PrintLayout.layout(style: .framed, canvas: geometry.pixels)
        precondition(layout.caption != nil, "the real panel geometry must have room for a caption for this test to mean anything")

        let landscape = TestCard.make(width: 1600, height: 1200)
        let result = try PrintPipeline.makePrint(
            PrintPipeline.Request(
                source: landscape,
                algorithm: .atkinson,
                style: .framed,
                caption: "1 Jan 2026",
                geometry: geometry,
                photoQuarterTurns: 1
            )
        )

        XCTAssertEqual(result.image.width, geometry.pixels.width)
        XCTAssertEqual(result.image.height, geometry.pixels.height)

        // The border is still paper white, exactly as it is for a portrait shot — proof the frame's
        // layout did not shrink or shift to accommodate the landscape source.
        for x in 0..<result.image.width {
            XCTAssertEqual(result.image[x, 0], 255, "top border pixel \(x) is not paper white")
        }

        // The caption band itself isn't pure white throughout — the date/time text was actually
        // drawn into it, not just left as an empty strip.
        guard let captionRect = layout.caption else { return XCTFail("expected a caption rect") }
        var sawInk = false
        for y in captionRect.y..<(captionRect.y + captionRect.height) {
            for x in captionRect.x..<(captionRect.x + captionRect.width) where result.image[x, y] < 255 {
                sawInk = true
            }
        }
        XCTAssertTrue(sawInk, "expected the caption text to have drawn something other than paper white")
    }

    /// A canvas shaped so `PrintLayout` leaves no room for a caption strip: `layout.caption` comes
    /// back `nil`, and the print still has to be exactly the panel's size. Returning the smaller,
    /// unpadded photo raster here was a real bug the landscape-rotation work exposed — a wide, short
    /// canvas is exactly what composing a landscape photo in landscape space produces before it gets
    /// rotated back to portrait.
    func test_makePrint_framedOnACanvasWithNoRoomForACaption_stillFillsTheWholeCanvas() throws {
        let wideAndShort = DisplayGeometry(pixels: PixelSize(width: 792, height: 528), maxImageBytes: 128 * 1024)
        let layout = PrintLayout.layout(style: .framed, canvas: wideAndShort.pixels)
        precondition(layout.caption == nil, "this canvas shape must be the no-caption-room case for the test to mean anything")

        let result = try PrintPipeline.makePrint(
            PrintPipeline.Request(
                source: TestCard.make(),
                algorithm: .atkinson,
                style: .framed,
                caption: "1 Jan 2026",
                geometry: wideAndShort,
                photoQuarterTurns: 0
            )
        )

        XCTAssertEqual(result.image.width, wideAndShort.pixels.width)
        XCTAssertEqual(result.image.height, wideAndShort.pixels.height)
    }

    func test_makePrint_roundTripsThroughThePackedBytesItProduces() throws {
        let result = try PrintPipeline.makePrint(request(algorithm: .floydSteinberg, style: .framed))

        XCTAssertEqual(
            Array(try ImagePacker.pack(result.image)), Array(result.imageData),
            "the bytes sent must be exactly what packing the previewed pixels produces"
        )
    }

    /// Unlike the PNG encoder this pipeline used to call, the packed size is a fixed function of
    /// panel geometry — every algorithm produces exactly the same byte count. So there is only one
    /// number to check per size, not one per algorithm; this asserts the invariant holds and that the
    /// full 528×792 panel fits comfortably under a realistic device cap.
    func test_everyAlgorithm_producesTheSamePackedSize() throws {
        let sizes = try DitherAlgorithm.allCases.map { algorithm in
            try PrintPipeline.makePrint(request(algorithm: algorithm, style: .fullBleed)).byteCount
        }

        XCTAssertEqual(Set(sizes).count, 1, "packed size must not depend on the dither algorithm")
        XCTAssertLessThanOrEqual(sizes[0], geometry.maxImageBytes)
    }

    func test_makePrint_throwsRatherThanSendingSomethingTheDeviceWillReject() {
        let impossible = DisplayGeometry(pixels: geometry.pixels, maxImageBytes: 500)

        XCTAssertThrowsError(
            try PrintPipeline.makePrint(
                PrintPipeline.Request(
                    source: TestCard.make(),
                    algorithm: .atkinson,
                    style: .fullBleed,
                    caption: "",
                    geometry: impossible,
                    photoQuarterTurns: 0
                )
            )
        ) { error in
            guard case PrintPipeline.PipelineError.tooLarge(_, let limit) = error else {
                return XCTFail("expected .tooLarge, got \(error)")
            }
            XCTAssertEqual(limit, 500)
        }
    }

    // MARK: - Helpers

    private func request(algorithm: DitherAlgorithm, style: PrintStyle) -> PrintPipeline.Request {
        PrintPipeline.Request(
            source: TestCard.make(),
            algorithm: algorithm,
            style: style,
            caption: "1 Jan 2026  09:41",
            geometry: geometry,
            photoQuarterTurns: 0
        )
    }
}
