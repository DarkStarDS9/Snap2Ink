import XCTest
@testable import Snap2Ink

/// The pipeline's central invariant — *every* algorithm, on *every* input, emits only the panel's
/// four levels — plus the behavioural differences that are the whole reason there is more than one
/// algorithm to choose from.
final class DithererTests: XCTestCase {

    // MARK: - The invariant

    func test_everyAlgorithm_emitsOnlyLegalLevels_acrossTheFullInputRange() {
        // A 256×64 sweep hits every possible input byte, in every column phase of the Bayer matrix.
        let sweep = GrayImage(
            width: 256,
            height: 64,
            pixels: (0..<(256 * 64)).map { UInt8($0 % 256) }
        )

        for algorithm in DitherAlgorithm.allCases {
            let result = Ditherer.dither(sweep, using: algorithm)
            let illegal = Set(result.pixels).subtracting(Quantizer.levels)
            XCTAssertTrue(
                illegal.isEmpty,
                "\(algorithm) emitted values outside {0,85,170,255}: \(illegal.sorted())"
            )
        }
    }

    func test_everyAlgorithm_emitsOnlyLegalLevels_forHardEdgesThatPushErrorOutOfRange() {
        // Alternating black and white is the worst case for error diffusion: the running error is
        // driven hard in both directions and the naive `UInt8` implementation of this would wrap.
        let checker = GrayImage(
            width: 64,
            height: 64,
            pixels: (0..<(64 * 64)).map { ($0 / 64 + $0 % 64) % 2 == 0 ? 0 : 255 }
        )

        for algorithm in DitherAlgorithm.allCases {
            XCTAssertTrue(
                Quantizer.isQuantized(Ditherer.dither(checker, using: algorithm)),
                "\(algorithm) failed the invariant on a hard-edged input"
            )
        }
    }

    func test_everyAlgorithm_preservesDimensions() {
        let source = GrayImage(width: 37, height: 19, filledWith: 140)

        for algorithm in DitherAlgorithm.allCases {
            let result = Ditherer.dither(source, using: algorithm)
            XCTAssertEqual(result.width, 37, "\(algorithm)")
            XCTAssertEqual(result.height, 19, "\(algorithm)")
            XCTAssertEqual(result.pixels.count, 37 * 19, "\(algorithm)")
        }
    }

    /// The preview the user approves and the bytes that get sent are produced by two separate runs
    /// of the pipeline, so a non-deterministic ditherer would print something other than what was
    /// proofed.
    func test_ditheringIsDeterministic() {
        let source = Self.photographicGradient(width: 80, height: 80)

        for algorithm in DitherAlgorithm.allCases {
            XCTAssertEqual(
                Ditherer.dither(source, using: algorithm).pixels,
                Ditherer.dither(source, using: algorithm).pixels,
                "\(algorithm) is not deterministic"
            )
        }
    }

    // MARK: - Values that are already legal

    func test_alreadyQuantizedInput_passesThroughUnchanged() {
        // Re-dithering a finished print must be a no-op; otherwise re-rendering a proof would
        // degrade it a little more each time.
        let quantized = GrayImage(width: 4, height: 4, pixels: [
            0, 85, 170, 255,
            255, 170, 85, 0,
            0, 0, 255, 255,
            85, 85, 170, 170,
        ])

        for algorithm in DitherAlgorithm.allCases where algorithm != .orderedBayer {
            XCTAssertEqual(
                Ditherer.dither(quantized, using: algorithm).pixels,
                quantized.pixels,
                "\(algorithm) altered pixels that were already exactly on level centres"
            )
        }
    }

    // MARK: - Character of each algorithm

    /// Floyd–Steinberg diffuses all of its error, so on a large flat field the mean output level
    /// tracks the input closely. This is the property that distinguishes it from Atkinson, and it
    /// is what "faithful" in its description actually means.
    func test_floydSteinberg_preservesMeanBrightnessOnAFlatField() {
        for inputLevel in [40, 128, 200] {
            let field = GrayImage(width: 128, height: 128, filledWith: UInt8(inputLevel))
            let mean = Self.mean(Ditherer.dither(field, using: .floydSteinberg))
            XCTAssertEqual(mean, Double(inputLevel), accuracy: 6.0, "input \(inputLevel)")
        }
    }

    /// Atkinson deliberately discards 2/8 of every pixel's error, so unlike Floyd–Steinberg it does
    /// *not* preserve mean brightness: on a flat field the output drifts toward mid-grey, in
    /// whichever direction that is from the input. Measured on a 128×128 field: input 64 comes back
    /// at ~71 and input 192 at ~184, against Floyd–Steinberg's ~65 and ~191.
    ///
    /// If this test ever fails because Atkinson got *more* accurate, someone has "fixed" the 6/8
    /// kernel into an 8/8 one and quietly turned it into Floyd–Steinberg with extra taps.
    func test_atkinson_sacrificesToneAccuracyByDiscardingError() {
        for input in [64, 192] {
            let field = GrayImage(width: 128, height: 128, filledWith: UInt8(input))

            let atkinsonError = abs(Self.mean(Ditherer.dither(field, using: .atkinson)) - Double(input))
            let floydError = abs(Self.mean(Ditherer.dither(field, using: .floydSteinberg)) - Double(input))

            XCTAssertGreaterThan(
                atkinsonError, floydError + 3.0,
                "at input \(input), Atkinson should hold the tone less faithfully than Floyd–Steinberg"
            )
        }
    }

    /// The direction of that drift is toward mid-grey, not toward an extreme — which is what makes
    /// it read as reduced contrast in flat areas rather than as clipping.
    func test_atkinsonDriftsTowardMidGreyRatherThanTowardAnExtreme() {
        let dark = Self.mean(Ditherer.dither(GrayImage(width: 128, height: 128, filledWith: 64), using: .atkinson))
        let light = Self.mean(Ditherer.dither(GrayImage(width: 128, height: 128, filledWith: 192), using: .atkinson))

        XCTAssertGreaterThan(dark, 64.0, "a dark flat should come back lighter")
        XCTAssertLessThan(light, 192.0, "a light flat should come back darker")
    }

    /// The ordered dither's output is periodic with the 4×4 Bayer matrix. That periodicity is not
    /// cosmetic — it is exactly why `PrintPipeline` falls back to this algorithm when a print will
    /// not fit: deflate compresses a repeating pattern far better than diffusion noise.
    func test_orderedBayer_isPeriodicEveryFourPixels() {
        let field = GrayImage(width: 32, height: 32, filledWith: 128)
        let result = Ditherer.dither(field, using: .orderedBayer)

        for y in 0..<result.height {
            for x in 0..<result.width {
                XCTAssertEqual(
                    result[x, y], result[x % 4, y % 4],
                    "ordered output should tile the 4×4 matrix exactly, but (\(x),\(y)) does not"
                )
            }
        }
    }

    func test_orderedBayer_breaksAFlatMidGreyIntoMoreThanOneLevel() {
        let field = GrayImage(width: 32, height: 32, filledWith: 128)
        let distinct = Set(Ditherer.dither(field, using: .orderedBayer).pixels)
        XCTAssertGreaterThan(distinct.count, 1, "a flat midtone must not come out as a solid block")
    }

    func test_flat_snapsEveryPixelWithoutDiffusingAnything() {
        let field = GrayImage(width: 16, height: 16, filledWith: 128)
        let result = Ditherer.dither(field, using: .none)
        XCTAssertEqual(Set(result.pixels), [170], "128 is nearest to 170; no dithering means no variation")
    }

    // MARK: - Helpers

    static func mean(_ image: GrayImage) -> Double {
        Double(image.pixels.reduce(0) { $0 + Int($1) }) / Double(image.pixels.count)
    }

    /// A smooth two-axis gradient — enough tonal range for the determinism and size tests to be
    /// meaningful without needing a real photograph in the test bundle.
    static func photographicGradient(width: Int, height: Int) -> GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = (Double(x) / Double(width) * 0.6 + Double(y) / Double(height) * 0.4) * 255.0
                pixels[y * width + x] = UInt8(min(max(value, 0), 255))
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }
}
