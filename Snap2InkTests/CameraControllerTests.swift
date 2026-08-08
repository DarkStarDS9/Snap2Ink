import AVFoundation
import UIKit
import XCTest
@testable import Snap2Ink

/// Two device-orientation → rotation tables that together fix capture orientation — see
/// `CameraController.correctionQuarterTurns` and `.photoApertureQuarterTurns` — are the one part of
/// the fix that can't be verified without a physical device. These tests don't remove that
/// dependency; they pin down the two mappings themselves, confirmed on-device via the proof screen's
/// "Rotate" button, so a future edit to either switch shows up as a diff to a named case rather than
/// a silent change buried in the capture path.
final class CameraControllerTests: XCTestCase {

    // MARK: - correctionQuarterTurns (raw buffer → correct aspect)

    func test_correctionQuarterTurns_portraitIsThreeTurns() {
        XCTAssertEqual(CameraController.correctionQuarterTurns(for: .portrait), 3)
    }

    func test_correctionQuarterTurns_upsideDownIsOppositeThePortraitValue() {
        let portrait = CameraController.correctionQuarterTurns(for: .portrait)
        let upsideDown = CameraController.correctionQuarterTurns(for: .portraitUpsideDown)

        XCTAssertEqual((portrait - upsideDown + 4) % 4, 2, "180° apart — this stage only fixes aspect, so it stays symmetric regardless of the app's own preserve-the-hold design goal")
    }

    func test_correctionQuarterTurns_landscapeCasesAreOppositeAndBothEven() {
        let left = CameraController.correctionQuarterTurns(for: .landscapeLeft)
        let right = CameraController.correctionQuarterTurns(for: .landscapeRight)

        XCTAssertEqual(left % 2, 0, "an odd value here would make compose() treat this as portrait")
        XCTAssertEqual(right % 2, 0, "an odd value here would make compose() treat this as portrait")
        XCTAssertNotEqual(left, right, "the two landscape holds must not resolve to the same rotation")
        XCTAssertEqual((left - right + 4) % 4, 2, "they must be opposite quarter-turns of each other")
    }

    func test_correctionQuarterTurns_unknownOrientationFallsBackToPortrait() {
        for orientation: UIDeviceOrientation in [.unknown, .faceUp, .faceDown] {
            XCTAssertEqual(
                CameraController.correctionQuarterTurns(for: orientation),
                CameraController.correctionQuarterTurns(for: .portrait),
                "no orientation signal should behave exactly like portrait, not some other default"
            )
        }
    }

    // MARK: - photoApertureQuarterTurns (compose()'s photo-only rotation)

    /// Confirmed on-device: `correctionQuarterTurns(.portrait)` alone already produces a correct
    /// print, so `compose()` needs no further rotation for this case — for either camera.
    func test_photoApertureQuarterTurns_portraitNeedsNoFurtherRotation() {
        for position: AVCaptureDevice.Position in [.front, .back] {
            XCTAssertEqual(CameraController.photoApertureQuarterTurns(for: .portrait, position: position), 0)
        }
    }

    /// Confirmed on-device as 2 (not 0) — despite `correctionQuarterTurns` already producing a
    /// portrait-shaped, "aspect-correct" image for this case the same way it does for plain
    /// `.portrait`, the two orientations still need different aperture treatment. This is the
    /// exact ambiguity `compose()` cannot resolve from shape alone (see `PrintPipeline.Request.
    /// photoQuarterTurns`'s doc comment) — it is why this table has to exist as a second,
    /// orientation-keyed step rather than folding into `correctionQuarterTurns`. Also confirmed
    /// camera-independent, unlike the landscape cases below — a top/bottom distinction survives a
    /// left-right mirror between the front and back sensor unchanged.
    func test_photoApertureQuarterTurns_upsideDownIsOppositeThePortraitValue_forEitherCamera() {
        for position: AVCaptureDevice.Position in [.front, .back] {
            let portrait = CameraController.photoApertureQuarterTurns(for: .portrait, position: position)
            let upsideDown = CameraController.photoApertureQuarterTurns(for: .portraitUpsideDown, position: position)

            XCTAssertEqual((portrait - upsideDown + 4) % 4, 2, "180° apart, position=\(position)")
        }
    }

    func test_photoApertureQuarterTurns_landscapeCasesAreOppositeAndBothOdd_forEitherCamera() {
        for position: AVCaptureDevice.Position in [.front, .back] {
            let left = CameraController.photoApertureQuarterTurns(for: .landscapeLeft, position: position)
            let right = CameraController.photoApertureQuarterTurns(for: .landscapeRight, position: position)

            XCTAssertEqual(left % 2, 1, "position=\(position): an even value here would leave compose() with an untransposed aperture for a source it treats as needing the fit rotation")
            XCTAssertEqual(right % 2, 1, "position=\(position): same — see the assertion above")
            XCTAssertNotEqual(left, right, "position=\(position): landscapeLeft and landscapeRight must not resolve to the same aperture rotation")
            XCTAssertEqual((left - right + 4) % 4, 2, "position=\(position): they must be opposite quarter-turns of each other")
        }
    }

    /// Confirmed on-device: the back camera needs exactly the two landscape aperture values the
    /// front camera does not — a mirror, not a rotation, distinguishes the two sensors' mounting.
    /// `.portrait`/`.portraitUpsideDown` are unaffected by this — see the test above.
    func test_photoApertureQuarterTurns_landscapeCasesAreSwappedBetweenFrontAndBackCamera() {
        XCTAssertEqual(CameraController.photoApertureQuarterTurns(for: .landscapeLeft, position: .front), 1)
        XCTAssertEqual(CameraController.photoApertureQuarterTurns(for: .landscapeLeft, position: .back), 3)
        XCTAssertEqual(CameraController.photoApertureQuarterTurns(for: .landscapeRight, position: .front), 3)
        XCTAssertEqual(CameraController.photoApertureQuarterTurns(for: .landscapeRight, position: .back), 1)
    }

    func test_photoApertureQuarterTurns_unknownOrientationFallsBackToPortrait() {
        for position: AVCaptureDevice.Position in [.front, .back] {
            for orientation: UIDeviceOrientation in [.unknown, .faceUp, .faceDown] {
                XCTAssertEqual(
                    CameraController.photoApertureQuarterTurns(for: orientation, position: position),
                    CameraController.photoApertureQuarterTurns(for: .portrait, position: position),
                    "position=\(position): no orientation signal should behave exactly like portrait, not some other default"
                )
            }
        }
    }
}
