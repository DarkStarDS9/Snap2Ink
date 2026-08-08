import XCTest
@testable import Snap2Ink

/// The calibration target is a measuring instrument, so it has to be correct in ways the checklist
/// then assumes. If a band that is supposed to be striped ships flat, a human following
/// MANUAL-DEVICE-TESTS.md would report a firmware bug that does not exist.
final class CalibrationTargetTests: XCTestCase {

    private let size = DisplayGeometry.assumedX3.pixels

    func test_target_fillsThePanelExactly() {
        let target = CalibrationTarget.image(size: size)

        // The firmware centres an image and scales it down only if it is larger than the screen.
        // A target that is not exactly panel-sized would be centred or resampled, and the border
        // check in the checklist would misreport that as a firmware fault.
        XCTAssertEqual(target.width, size.width)
        XCTAssertEqual(target.height, size.height)
    }

    func test_target_isAlreadyExactlyQuantized() {
        // It bypasses the ditherer entirely, so nothing downstream will fix a stray value.
        XCTAssertTrue(Quantizer.isQuantized(CalibrationTarget.image(size: size)))
    }

    func test_target_usesAllFourLevels() {
        let present = Set(CalibrationTarget.image(size: size).pixels)
        XCTAssertEqual(present, Set(Quantizer.levels), "a target missing a level cannot detect a lost one")
    }

    /// The patches are the "count the greys" test, and their order is what tells the tester whether
    /// the panel is inverted.
    func test_levelPatches_runDarkestToLightestLeftToRight() {
        let target = CalibrationTarget.image(size: size)
        let y = CalibrationTarget.Band.levelPatches.probeRow(in: size)

        for (index, level) in Quantizer.levels.enumerated() {
            let x = index * (size.width / 4) + 20  // inside the patch, clear of its edges
            XCTAssertEqual(target[x, y], level, "patch \(index) should be level \(level)")
        }
    }

    /// The strictest resampling test on the sheet: adjacent columns must differ everywhere.
    func test_singlePixelVerticalStripes_alternateOnEveryColumn() {
        let target = CalibrationTarget.image(size: size)
        let y = CalibrationTarget.Band.verticalStripes1px.probeRow(in: size)

        for x in 1..<(size.width - 1) {
            XCTAssertNotEqual(target[x, y], target[x - 1, y], "columns \(x - 1) and \(x) must differ")
        }
    }

    func test_singlePixelHorizontalStripes_alternateOnEveryRow() {
        let target = CalibrationTarget.image(size: size)
        let x = size.width / 4  // clear of the centre cross, which blacks out the middle column
        let rows = CalibrationTarget.Band.horizontalStripes1px.rows(in: size)

        for y in (rows.lowerBound + 1)..<rows.upperBound where y != size.height / 2 {
            XCTAssertNotEqual(target[x, y], target[x, y - 1], "rows \(y - 1) and \(y) must differ")
        }
    }

    /// Two-pixel bars must actually be two pixels wide, or the "wider than the 1px band" instruction
    /// in the checklist is meaningless.
    func test_twoPixelVerticalStripes_areTwoPixelsWide() {
        let target = CalibrationTarget.image(size: size)
        let y = CalibrationTarget.Band.verticalStripes2px.probeRow(in: size)

        XCTAssertEqual(target[100, y], target[101, y], "a bar's two columns must match")
        XCTAssertNotEqual(target[101, y], target[102, y], "adjacent bars must differ")
    }

    /// Each pair band must contain exactly its two levels — that is what makes a merged pair show up
    /// as a flat band while its neighbours stay textured.
    func test_levelPairBands_containExactlyTheirTwoAdjacentLevels() {
        let target = CalibrationTarget.image(size: size)
        let expected: [Set<UInt8>] = [[0, 85], [85, 170], [170, 255]]
        let sectionWidth = size.width / 3

        for (index, levels) in expected.enumerated() {
            var seen = Set<UInt8>()
            // Inset from the section edges to avoid the centre cross and neighbouring sections.
            let rows = CalibrationTarget.Band.levelPairs.rows(in: size)
            for x in (index * sectionWidth + 5)..<(index * sectionWidth + sectionWidth - 5)
            where x != size.width / 2 {
                for y in (rows.lowerBound + 2)..<(rows.upperBound - 2) where y != size.height / 2 {
                    seen.insert(target[x, y])
                }
            }
            XCTAssertEqual(seen, levels, "pair band \(index)")
        }
    }

    /// The geometry check. A correct print shows exactly one black pixel at every edge.
    func test_registrationBorder_isOnePixelOnAllFourEdges() {
        let target = CalibrationTarget.image(size: size)

        for x in 0..<size.width {
            XCTAssertEqual(target[x, 0], 0, "top edge at \(x)")
            XCTAssertEqual(target[x, size.height - 1], 0, "bottom edge at \(x)")
        }
        for y in 0..<size.height {
            XCTAssertEqual(target[0, y], 0, "left edge at \(y)")
            XCTAssertEqual(target[size.width - 1, y], 0, "right edge at \(y)")
        }

        // Row 1 must not also be black in the white reference band, or the border would read as two
        // pixels thick and a correct print would be reported as scaled.
        XCTAssertEqual(target[size.width / 4, size.height - 2], 255, "the border must be exactly one pixel")
    }

    /// Every band must be where `Band.rows(in:)` says it is — the checklist tells a human to count
    /// bands down the panel, and the probes below trust the same mapping.
    func test_bands_tileThePanelWithoutGapsOrOverlap() {
        var expectedStart = 0
        for band in CalibrationTarget.Band.allCases {
            let rows = band.rows(in: size)
            XCTAssertEqual(rows.lowerBound, expectedStart, "\(band) does not start where the previous band ended")
            expectedStart = rows.upperBound
        }
        XCTAssertEqual(expectedStart, size.height, "the bands must cover the panel exactly")
    }

    func test_centreCross_marksTheExactMiddle() {
        let target = CalibrationTarget.image(size: size)
        XCTAssertEqual(target[size.width / 2, size.height - 20], 0, "vertical arm, in the white reference band")
        XCTAssertEqual(target[size.width / 4, size.height / 2], 0, "horizontal arm")
    }

    // MARK: - As a print

    func test_calibrationPrint_encodesAndRoundTripsExactly() throws {
        let print = try PrintPipeline.makeCalibrationPrint(geometry: .assumedX3)

        XCTAssertEqual(print.algorithm, .none, "the target must not be dithered — it is already exact")
        XCTAssertEqual(print.style, .fullBleed)

        let repacked = try ImagePacker.pack(print.image)
        XCTAssertEqual(repacked, print.imageData, "the bytes sent must be the target exactly")
    }

    /// A single-pixel checkerboard is close to incompressible, so this is the worst case the wire
    /// will ever see from this app — worth knowing it fits before someone tries it on hardware.
    func test_calibrationPrint_fitsUnderTheDeviceCap() throws {
        let print = try PrintPipeline.makeCalibrationPrint(geometry: .assumedX3)
        XCTAssertLessThanOrEqual(print.byteCount, DisplayGeometry.assumedX3.maxImageBytes)
        Swift.print(">>> calibration target: \(print.byteCount) bytes")
    }

    func test_target_scalesToAPanelOfADifferentSize() {
        // The geometry comes from the capability characteristic, so the target cannot assume 528×792.
        let small = CalibrationTarget.image(size: PixelSize(width: 200, height: 320))

        XCTAssertEqual(small.width, 200)
        XCTAssertEqual(small.height, 320)
        XCTAssertTrue(Quantizer.isQuantized(small))
        XCTAssertEqual(Set(small.pixels), Set(Quantizer.levels))
    }
}
