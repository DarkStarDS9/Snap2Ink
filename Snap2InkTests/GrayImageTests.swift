import XCTest
@testable import Snap2Ink

final class GrayImageTests: XCTestCase {

    /// A 2×3 image, each pixel a distinct value, so a wrong axis or a wrong direction shows up as a
    /// mismatched pixel rather than a dimension check alone passing by coincidence.
    ///
    ///   0 1
    ///   2 3
    ///   4 5
    func test_rotated90CounterClockwise_swapsDimensionsAndTurnsTheRightColumnIntoTheTopRow() {
        let image = GrayImage(width: 2, height: 3, pixels: [0, 1, 2, 3, 4, 5])

        let rotated = image.rotated90CounterClockwise()

        XCTAssertEqual(rotated.width, 3)
        XCTAssertEqual(rotated.height, 2)
        // Counter-clockwise: the original top-right corner (1) lands at the top-left; the original
        // bottom-right corner (5) lands at the bottom-left.
        XCTAssertEqual(rotated[0, 0], 1)
        XCTAssertEqual(rotated[1, 0], 3)
        XCTAssertEqual(rotated[2, 0], 5)
        XCTAssertEqual(rotated[0, 1], 0)
        XCTAssertEqual(rotated[1, 1], 2)
        XCTAssertEqual(rotated[2, 1], 4)
    }
}
