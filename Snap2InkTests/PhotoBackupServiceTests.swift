import UniformTypeIdentifiers
import XCTest
@testable import Snap2Ink

/// The EXIF round trip is the whole feature: a photo saved as a backup has to come back out of
/// Photos knowing which dither algorithm printed it, with nothing else in the pipeline to fall
/// back on. Exercises `encode`/`algorithm(fromImageData:)`/`image(fromImageData:)` directly,
/// without `PHPhotoLibrary` — see `PhotoBackupService.encode`'s doc comment.
final class PhotoBackupServiceTests: XCTestCase {

    private let size = PixelSize(width: 8, height: 8)

    func test_algorithm_roundTripsThroughEncodedJPEGData() throws {
        let image = try XCTUnwrap(makeCGImage())

        for algorithm in DitherAlgorithm.allCases {
            let data = try PhotoBackupService.encode(image, algorithm: algorithm)
            XCTAssertEqual(PhotoBackupService.algorithm(fromImageData: data), algorithm)
        }
    }

    func test_image_roundTripsAtTheSamePixelSize() throws {
        let image = try XCTUnwrap(makeCGImage())
        let data = try PhotoBackupService.encode(image, algorithm: .atkinson)

        let decoded = try XCTUnwrap(PhotoBackupService.image(fromImageData: data))
        XCTAssertEqual(decoded.width, size.width)
        XCTAssertEqual(decoded.height, size.height)
    }

    /// A photo with no Snap2Ink marker at all — the ordinary case for anything in the user's
    /// library that Snap2Ink never printed — must read back as "no metadata", not crash and not be
    /// mistaken for a match.
    func test_algorithm_onDataWithNoMarker_returnsNil() throws {
        let image = try XCTUnwrap(makeCGImage())
        let data = try XCTUnwrap(image.dataRepresentation())
        XCTAssertNil(PhotoBackupService.algorithm(fromImageData: data))
    }

    /// A raw value that no longer maps to a case — e.g. written by a future build with a case this
    /// one doesn't have — must come back `nil` rather than crash or silently pick a wrong case.
    func test_algorithm_withUnrecognizedRawValue_returnsNil() throws {
        let image = try XCTUnwrap(makeCGImage())
        let data = try encode(image, comment: "Snap2Ink/1 algorithm=someFutureCase")
        XCTAssertNil(PhotoBackupService.algorithm(fromImageData: data))
    }

    func test_algorithm_onCompletelyInvalidImageData_returnsNilRatherThanCrashing() {
        XCTAssertNil(PhotoBackupService.algorithm(fromImageData: Data([0x00, 0x01, 0x02])))
    }

    // MARK: - Helpers

    private func makeCGImage() -> CGImage? {
        GrayImage(width: size.width, height: size.height, filledWith: Quantizer.levels[2]).makeCGImage()
    }

    /// Encodes with an arbitrary EXIF `UserComment`, to exercise decode paths `PhotoBackupService`
    /// itself never produces (an unrecognized algorithm raw value).
    private func encode(_ image: CGImage, comment: String) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: comment],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private extension CGImage {
    /// A plain PNG with no custom EXIF at all — a stand-in for "any photo Snap2Ink didn't create".
    func dataRepresentation() -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
