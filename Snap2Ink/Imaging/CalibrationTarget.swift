import Foundation

/// A print designed to make the four-level contract **checkable by eye**.
///
/// The claim the whole pipeline rests on is that the panel shows the phone's bit pattern verbatim:
/// the phone dithers, the firmware decodes with its own dither disabled, and nothing resamples or
/// re-quantizes in between. "Compare them pixel for pixel" is the correct test and a human cannot
/// perform it — two greys on an e-ink panel photographed next to a phone screen prove nothing.
///
/// So this converts that comparison into things a person can genuinely judge from arm's length:
/// *count the distinct greys*, *is this band striped or flat*, *is the border one pixel or two*.
/// Each region fails in a specific, recognisable way:
///
/// | Region | Correct | What a failure means |
/// |---|---|---|
/// | Four patches | four distinct greys | fewer than four → the palette collapsed; wrong order → inversion |
/// | 1px vertical stripes | crisp stripes | flat grey → horizontal resampling |
/// | 1px horizontal stripes | crisp stripes | flat grey → vertical resampling |
/// | 1px checkerboard | fine texture | flat grey → resampling in both axes |
/// | 2px vertical stripes | crisp, wider than the 1px band | flat while 1px is crisp → downscale by ~2 |
/// | Level-pair checkerboards | three distinct textures | any band flat → adjacent levels merged |
/// | Level staircase | repeating 4-step ramp | banding/merging → bucket boundaries are off |
/// | 1px border + centre cross | exactly 1px, touching all four edges | thick, missing or inset → scaling or centring |
///
/// Every pixel is already one of `Quantizer.levels`, so this bypasses dithering entirely — it is
/// pushed through `PrintPipeline.makeCalibrationPrint(geometry:)`, which does not rasterize,
/// dither or compose. Any difference on the panel is therefore the firmware's or the wire's, never
/// this app's, which is exactly what makes it a usable bisection tool.
///
/// Pure, with no Core Graphics: the target is generated identically on any machine, so two people
/// running the checklist are looking at the same bytes.
enum CalibrationTarget {

    private static let black = Quantizer.levels[0]    // 0
    private static let darkGrey = Quantizer.levels[1] // 85
    private static let lightGrey = Quantizer.levels[2] // 170
    private static let white = Quantizer.levels[3]    // 255

    /// The eight bands, top to bottom. Their order is the order the checklist reads them in, so a
    /// tester can count down the panel and know which region they are looking at.
    ///
    /// Both the generator and its tests derive row ranges from `rows(in:)` rather than computing
    /// offsets independently — two sets of hand-computed band arithmetic is exactly how a test ends
    /// up probing the wrong stripe and reporting a fault that is not there.
    enum Band: Int, CaseIterable {
        case levelPatches
        case verticalStripes1px
        case horizontalStripes1px
        case checkerboard1px
        case verticalStripes2px
        case levelPairs
        case staircase
        /// Plain paper: a reference for "is white actually white", and somewhere the border and
        /// centre cross can be seen against nothing else.
        case whiteReference

        func rows(in size: PixelSize) -> Range<Int> {
            let bandHeight = max(1, size.height / Band.allCases.count)
            let start = rawValue * bandHeight
            // The last band absorbs any remainder so the target always fills the panel exactly — a
            // short final band would itself look like a rendering fault.
            let isLast = rawValue == Band.allCases.count - 1
            let end = isLast ? size.height : min((rawValue + 1) * bandHeight, size.height)
            return start..<max(start + 1, end)
        }

        /// A row safely inside the band, clear of its edges — what a probe should sample.
        func probeRow(in size: PixelSize) -> Int {
            let range = rows(in: size)
            return range.lowerBound + max(1, range.count / 2)
        }
    }

    /// Builds the target at the panel's exact pixel size.
    static func image(size: PixelSize) -> GrayImage {
        var image = GrayImage(width: size.width, height: size.height, filledWith: white)

        levelPatches(&image, rows: Band.levelPatches.rows(in: size))
        verticalStripes(&image, rows: Band.verticalStripes1px.rows(in: size), barWidth: 1)
        horizontalStripes(&image, rows: Band.horizontalStripes1px.rows(in: size))
        checkerboard(&image, rows: Band.checkerboard1px.rows(in: size), a: black, b: white)
        verticalStripes(&image, rows: Band.verticalStripes2px.rows(in: size), barWidth: 2)
        levelPairCheckerboards(&image, rows: Band.levelPairs.rows(in: size))
        levelStaircase(&image, rows: Band.staircase.rows(in: size))

        registrationMarks(&image)
        return image
    }

    // MARK: - Regions

    /// The four levels side by side, darkest on the left. Establishes both that all four survive and
    /// which way round they are.
    private static func levelPatches(_ image: inout GrayImage, rows: Range<Int>) {
        let patchWidth = max(1, image.width / 4)
        for y in rows {
            for x in 0..<image.width {
                let index = min(x / patchWidth, 3)
                image[x, y] = Quantizer.levels[index]
            }
        }
    }

    /// Alternating vertical bars. At `barWidth: 1` this is the strictest resampling test the panel
    /// can be given — any horizontal filtering at all turns it into flat grey.
    private static func verticalStripes(_ image: inout GrayImage, rows: Range<Int>, barWidth: Int) {
        for y in rows {
            for x in 0..<image.width {
                image[x, y] = (x / barWidth) % 2 == 0 ? black : white
            }
        }
    }

    private static func horizontalStripes(_ image: inout GrayImage, rows: Range<Int>) {
        for y in rows {
            let value: UInt8 = y % 2 == 0 ? black : white
            for x in 0..<image.width {
                image[x, y] = value
            }
        }
    }

    private static func checkerboard(_ image: inout GrayImage, rows: Range<Int>, a: UInt8, b: UInt8) {
        for y in rows {
            for x in 0..<image.width {
                image[x, y] = (x + y) % 2 == 0 ? a : b
            }
        }
    }

    /// Three 50/50 checkerboards of *adjacent* levels: 0/85, 85/170, 170/255. These are the
    /// comparisons that catch a bucket-boundary error — a palette that has merged two neighbouring
    /// levels shows one of these bands as flat while the others stay textured.
    private static func levelPairCheckerboards(_ image: inout GrayImage, rows: Range<Int>) {
        let pairs: [(UInt8, UInt8)] = [(black, darkGrey), (darkGrey, lightGrey), (lightGrey, white)]
        let sectionWidth = max(1, image.width / pairs.count)

        for y in rows {
            for x in 0..<image.width {
                let (a, b) = pairs[min(x / sectionWidth, pairs.count - 1)]
                image[x, y] = (x + y) % 2 == 0 ? a : b
            }
        }
    }

    /// Narrow columns cycling through all four levels repeatedly, so every level sits next to every
    /// other one somewhere. Catches bleeding between adjacent levels that a large flat patch hides.
    private static func levelStaircase(_ image: inout GrayImage, rows: Range<Int>) {
        let stepWidth = max(1, image.width / 16)
        for y in rows {
            for x in 0..<image.width {
                image[x, y] = Quantizer.levels[(x / stepWidth) % 4]
            }
        }
    }

    /// A one-pixel black border on all four edges plus a one-pixel cross through the centre.
    ///
    /// The border is the geometry check: the firmware centres an image and scales it down only if it
    /// is *larger* than the screen, so a correctly sized print shows a border exactly one pixel wide
    /// touching all four edges. Two pixels means it was scaled; an inset border with white outside
    /// means the target was smaller than the panel and got centred.
    private static func registrationMarks(_ image: inout GrayImage) {
        for x in 0..<image.width {
            image[x, 0] = black
            image[x, image.height - 1] = black
        }
        for y in 0..<image.height {
            image[0, y] = black
            image[image.width - 1, y] = black
        }

        let midX = image.width / 2
        let midY = image.height / 2
        for x in 0..<image.width { image[x, midY] = black }
        for y in 0..<image.height { image[midX, y] = black }
    }
}
