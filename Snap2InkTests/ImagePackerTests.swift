import XCTest
@testable import Snap2Ink

/// The packer is hand-rolled and has no framing or checksums to catch a mistake, so these tests
/// carry the same weight the old PNG encoder's did: nothing else stands between a bad byte here and
/// a device that rejects (or, worse, silently misdraws) a print.
final class ImagePackerTests: XCTestCase {

    // MARK: - Packing

    /// The worked example from the companion protocol's image field spec: width=2, height=2,
    /// row0=[3,0], row1=[1,2]. byte0 = 0b11000000 = 0xC0, byte1 = 0b01100000 = 0x60.
    func test_pack_matchesTheProtocolWorkedExample() throws {
        let image = GrayImage(width: 2, height: 2, pixels: [
            Quantizer.levels[3], Quantizer.levels[0],
            Quantizer.levels[1], Quantizer.levels[2],
        ])

        XCTAssertEqual(Array(try ImagePacker.pack(image)), [0xC0, 0x60])
    }

    func test_pack_packsFourPixelsPerByteMostSignificantFirst() throws {
        // levels 0,1,2,3 -> samples 00 01 10 11 -> 0b00011011 == 0x1B
        let row = GrayImage(width: 4, height: 1, pixels: [0, 85, 170, 255])
        XCTAssertEqual(Array(try ImagePacker.pack(row)), [0x1B])
    }

    func test_pack_padsEachRowToAWholeByte() throws {
        let image = GrayImage(width: 5, height: 2, filledWith: 255)
        // 5 pixels needs 2 bytes per row (4 + 1 padded).
        XCTAssertEqual(try ImagePacker.pack(image).count, 2 * 2)
    }

    func test_pack_producesExactlyBytesPerRowTimesHeight_regardlessOfContent() throws {
        for width in [1, 2, 3, 4, 5, 7, 13, 528] {
            for algorithm in DitherAlgorithm.allCases {
                let image = Ditherer.dither(Self.gradient(width: width, height: 6), using: algorithm)
                let packed = try ImagePacker.pack(image)
                XCTAssertEqual(packed.count, ImagePacker.bytesPerRow(width) * 6, "width \(width), \(algorithm)")
            }
        }
    }

    func test_bytesPerRow_matchesThePanelWorkedExample() {
        // 528x792 panel: bytesPerRow = ceil(528/4) = 132.
        XCTAssertEqual(ImagePacker.bytesPerRow(528), 132)
    }

    // MARK: - Round trip

    func test_roundTrip_recoversEveryPixelExactly() throws {
        let source = Ditherer.dither(Self.gradient(width: 61, height: 43), using: .atkinson)
        let packed = try ImagePacker.pack(source)

        let decoded = Self.unpack(packed, width: source.width, height: source.height)
        XCTAssertEqual(decoded.pixels, source.pixels)
    }

    func test_roundTrip_survivesWidthsThatDoNotDivideByFour() throws {
        for width in [1, 2, 3, 5, 7, 13] {
            let source = Ditherer.dither(Self.gradient(width: width, height: 6), using: .orderedBayer)
            let decoded = Self.unpack(try ImagePacker.pack(source), width: width, height: 6)
            XCTAssertEqual(decoded.pixels, source.pixels, "width \(width) did not round-trip")
        }
    }

    // MARK: - Refusals

    func test_pack_refusesAnImageThatIsNotQuantized() {
        let stray = GrayImage(width: 2, height: 2, pixels: [0, 85, 128, 255])

        XCTAssertThrowsError(try ImagePacker.pack(stray)) { error in
            XCTAssertEqual(error as? ImagePacker.PackError, .notQuantized)
        }
    }

    // MARK: - Helpers

    static func gradient(width: Int, height: Int) -> GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = UInt8((x * 255 / max(width - 1, 1) + y * 255 / max(height - 1, 1)) / 2)
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    /// An independent unpacker mirroring the firmware's `expandSampleToByte(s, 2) = s * 255 / 3`, so
    /// a round trip through it is real evidence the packing matches the wire contract, not just that
    /// the packer agrees with itself.
    private static func unpack(_ data: Data, width: Int, height: Int) -> GrayImage {
        let bytesPerRow = ImagePacker.bytesPerRow(width)
        var pixels = [UInt8](repeating: 0, count: width * height)

        for y in 0..<height {
            let rowStart = data.startIndex + y * bytesPerRow
            for x in 0..<width {
                let byte = data[rowStart + x / 4]
                let shift = 6 - 2 * (x % 4)
                let sample = (byte >> UInt8(shift)) & 0x03
                pixels[y * width + x] = UInt8(UInt32(sample) * 255 / 3)
            }
        }

        return GrayImage(width: width, height: height, pixels: pixels)
    }
}
