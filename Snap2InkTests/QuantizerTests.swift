import XCTest
@testable import Snap2Ink

/// The four levels are a wire contract with the firmware, not a preference — see `Quantizer`'s doc
/// comment. These tests pin the exact bucket boundaries so a "harmless" tidy-up of the rounding
/// cannot silently shift every midtone on the panel by one level.
final class QuantizerTests: XCTestCase {

    func test_levels_areExactlyTheFourValuesTheFirmwareExpects() {
        XCTAssertEqual(Quantizer.levels, [0, 85, 170, 255])
    }

    func test_levelIndex_roundsToNearestLevel() {
        XCTAssertEqual(Quantizer.levelIndex(for: 0), 0)
        XCTAssertEqual(Quantizer.levelIndex(for: 41), 0, "just below the 0/85 midpoint")
        XCTAssertEqual(Quantizer.levelIndex(for: 43), 1, "just above the 0/85 midpoint")
        XCTAssertEqual(Quantizer.levelIndex(for: 85), 1)
        XCTAssertEqual(Quantizer.levelIndex(for: 170), 2)
        XCTAssertEqual(Quantizer.levelIndex(for: 255), 3)
    }

    /// Error diffusion routinely drives a working value past both ends of the byte range; clamping
    /// has to happen here rather than trapping or wrapping.
    func test_levelIndex_clampsOutOfRangeInput() {
        XCTAssertEqual(Quantizer.levelIndex(for: -900), 0)
        XCTAssertEqual(Quantizer.levelIndex(for: 9000), 3)
    }

    func test_nearestLevel_neverReturnsAValueOutsideTheLegalSet() {
        let legal = Set(Quantizer.levels)
        for value in -300...600 {
            XCTAssertTrue(legal.contains(Quantizer.nearestLevel(value)), "value \(value) produced an illegal level")
        }
    }

    func test_isQuantized_rejectsAnyStrayValue() {
        let legal = GrayImage(width: 2, height: 2, pixels: [0, 85, 170, 255])
        XCTAssertTrue(Quantizer.isQuantized(legal))

        let strayed = GrayImage(width: 2, height: 2, pixels: [0, 85, 128, 255])
        XCTAssertFalse(Quantizer.isQuantized(strayed), "128 is in no bucket centre and must be caught")
    }
}
