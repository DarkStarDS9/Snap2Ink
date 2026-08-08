import AVFoundation
import CoreGraphics
import Foundation
import UIKit

/// The viewfinder and the shutter. Nothing else — no filters, no gallery, no capture modes. The
/// interesting work in this app happens after the shutter, in `PrintPipeline`.
@MainActor
final class CameraController: NSObject, ObservableObject {

    enum CameraError: Error, Equatable {
        case unavailable
        case denied
        case captureFailed
    }

    /// False in the simulator, and on a device where the user has refused camera access. Both cases
    /// fall back to a synthetic test card so the rest of the app stays usable — the dither pipeline
    /// is worth developing against without a camera, and that is most of the app.
    @Published private(set) var isAvailable = false
    @Published private(set) var position: AVCaptureDevice.Position = .back

    /// The current `videoZoomFactor`, and the range `setZoom` will clamp to. On a multi-lens device
    /// these are one continuous range spanning every constituent lens — the device switches lenses
    /// under the hood as the factor crosses `lensSwitchZoomFactors`, exactly as the stock Camera app
    /// does, so there is no separate "which lens" state to track.
    @Published private(set) var zoomFactor: CGFloat = 1.0
    @Published private(set) var minZoomFactor: CGFloat = 1.0
    @Published private(set) var maxZoomFactor: CGFloat = 1.0
    /// Zoom factors at which the virtual device hands off between lenses, e.g. `[2, 6]` on a triple
    /// camera. Empty on a single-lens device (most front cameras). Exposed so the UI can offer them
    /// as quick-tap buttons — that *is* "lens switching" on a virtual multi-camera device.
    @Published private(set) var lensSwitchZoomFactors: [CGFloat] = []
    /// What raw `videoZoomFactor` corresponds to the "1×" label the stock Camera app would show.
    /// On a device with an ultra-wide lens, raw factor 1.0 *is* the ultra-wide — Apple's own "1×" is
    /// the main wide lens, which only kicks in at the first handoff point in
    /// `lensSwitchZoomFactors`. Without an ultra-wide, raw factor 1.0 already is the main lens, so
    /// this is 1.0. Divide a raw factor by this to get the number the UI should print.
    @Published private(set) var displayZoomReferenceFactor: CGFloat = 1.0

    /// What the last `capturePhoto()` actually saw, before and after its own rotation correction —
    /// surfaced on-screen (`ProofView`'s debug strip) rather than only to a console, because the
    /// orientation table this feeds is the one part of the pipeline still confirmed on a physical
    /// device rather than a test, and the last three such confirmations were each wrong in a way a
    /// TestFlight round-trip was too slow to catch quickly. Reading this off the phone that took the
    /// photo is the fast version of that same confirmation.
    struct CaptureDebugInfo: Equatable {
        let rawWidth: Int
        let rawHeight: Int
        let deviceOrientation: UIDeviceOrientation
        let appliedQuarterTurns: Int
        /// What `photoApertureQuarterTurns(for:)` says `PrintPipeline` should apply to this shot —
        /// see that function's doc comment for why `compose()` cannot work this out on its own.
        let photoApertureQuarterTurns: Int
    }
    @Published private(set) var lastCaptureDebugInfo: CaptureDebugInfo?

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private var captureContinuation: CheckedContinuation<CGImage, Error>?
    private var currentDevice: AVCaptureDevice?
    private var zoomFactorAtGestureStart: CGFloat = 1.0

    /// Requests access, builds the session and starts it. Safe to call more than once.
    func start() async {
        guard !session.isRunning else { return }

        // `UIDevice.orientation` reads `.unknown` until something asks for updates — this is the
        // only source of truth for how the phone is physically held, independent of the app's own
        // portrait-locked interface, which never rotates regardless.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted, configureSession(position: position) else {
            isAvailable = false
            return
        }

        isAvailable = true
        // `startRunning` blocks for a noticeable moment; keeping it off the main actor is what stops
        // the viewfinder appearing with a stutter.
        let session = session
        await Task.detached { session.startRunning() }.value

        // Setting `videoZoomFactor` before the session is actually running doesn't reliably engage
        // a virtual multi-camera device's lens switch — the framing silently stays on whichever
        // lens was already active, until some *later* zoom change nudges it. Apply the default here,
        // once capture is actually live, rather than inside `configureSession`.
        setZoom(displayZoomReferenceFactor)
    }

    func stop() {
        guard session.isRunning else { return }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        let session = session
        Task.detached { session.stopRunning() }
    }

    func flipCamera() {
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        guard configureSession(position: next) else { return }
        position = next
        setZoom(displayZoomReferenceFactor)
    }

    /// Takes a photo, or synthesises a test card where there is no camera.
    func capturePhoto() async throws -> CGImage {
        guard isAvailable else { return TestCard.make() }

        // Read the device's physical orientation at the moment of the shutter press, not at session
        // configuration time — it updates continuously as the phone turns, and the app's own
        // interface stays portrait-locked throughout, so this is the only source of truth for
        // whether the shot the user framed was portrait or landscape.
        let orientation = UIDevice.current.orientation

        let raw = try await withCheckedThrowingContinuation { continuation in
            captureContinuation = continuation
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            photoOutput.capturePhoto(with: settings, delegate: self)
        }

        let turns = Self.correctionQuarterTurns(for: orientation)
        lastCaptureDebugInfo = CaptureDebugInfo(
            rawWidth: raw.width,
            rawHeight: raw.height,
            deviceOrientation: orientation,
            appliedQuarterTurns: turns,
            photoApertureQuarterTurns: Self.photoApertureQuarterTurns(for: orientation, position: position)
        )
        return PhotoRasterizer.rotated(raw, quarterTurnsCounterClockwise: turns) ?? raw
    }

    // MARK: - Zoom

    /// Sets the zoom factor directly, e.g. from a lens-switch button. Ramped rather than snapped so
    /// a jump between lenses reads as a smooth optical transition rather than a jarring cut.
    func setZoom(_ factor: CGFloat) {
        guard let device = currentDevice else { return }
        let clamped = min(max(factor, minZoomFactor), maxZoomFactor)
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.ramp(toVideoZoomFactor: clamped, withRate: 8)
        device.unlockForConfiguration()
        zoomFactor = clamped
    }

    /// Call when a pinch gesture begins, so `updateZoomGesture` has a baseline to scale from.
    func beginZoomGesture() {
        zoomFactorAtGestureStart = zoomFactor
    }

    /// Call continuously with a `UIPinchGestureRecognizer`'s `scale` as the gesture changes. Applied
    /// immediately, not ramped — a pinch is already a continuous, user-driven motion, and ramping on
    /// top of it would make the zoom lag behind the user's fingers.
    func updateZoomGesture(scale: CGFloat) {
        guard let device = currentDevice else { return }
        let clamped = min(max(zoomFactorAtGestureStart * scale, minZoomFactor), maxZoomFactor)
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        zoomFactor = clamped
    }

    // MARK: - Focus

    /// Focuses and exposes on a point in the frame, as a device point in `(0, 0)`–`(1, 1)` — the
    /// coordinate space `AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)`
    /// already produces, so the caller (`CameraPreview`) can pass a tap straight through.
    ///
    /// Reverts to continuous auto-focus/-exposure rather than staying locked on the tapped point —
    /// a one-shot lock is right for a single deliberate tap, but this is a viewfinder someone keeps
    /// moving, and a focus point from ten seconds ago going stale silently would be worse than never
    /// having offered tap-to-focus at all.
    func focus(at devicePoint: CGPoint) {
        guard let device = currentDevice else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = devicePoint
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = devicePoint
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    // MARK: - Orientation

    /// How many quarter-turns counter-clockwise (`PhotoRasterizer.rotated`) a photo needs, on top of
    /// the connection's fixed portrait rotation, to come out right-side up for a shot taken with the
    /// phone in `orientation`.
    ///
    /// The connection itself is pinned to a single fixed angle in `configureSession` — the same one
    /// this app used, correctly, for portrait-only capture before landscape support existed (see the
    /// history of `configureSession` below). Letting `AVCaptureConnection.videoRotationAngle` vary
    /// per shot was tried twice (`AVCaptureDevice.RotationCoordinator`, then a hand-derived
    /// `AVCaptureVideoOrientation`-based table), and both were "confirmed on a physical device" and
    /// still wrong — because that confirmation is the *only* way to check an AVFoundation-applied
    /// rotation, so a bad guess costs a full TestFlight round-trip to even notice. This table instead
    /// feeds a rotation this codebase applies itself (`PhotoRasterizer.rotated`), which a synthetic
    /// image in `PrintPipelineTests` verifies without any device at all — only the *mapping* below
    /// (which `UIDeviceOrientation` case needs how many turns) still needs on-device confirmation,
    /// not whether the rotation code itself is correct.
    ///
    /// All four values confirmed on-device via the proof screen's Rotate button, together with
    /// `photoApertureQuarterTurns` below. The goal is deliberately *not* "always come out upright" —
    /// the app preserves whatever the phone was actually doing at the shutter (a photo taken upside
    /// down prints upside down), so `.portrait` and `.portraitUpsideDown` do not need to differ by a
    /// clean 180° here the way a "make everything upright" table would; neither do `.landscapeLeft`
    /// and `.landscapeRight`. Do not "simplify" this by re-deriving it from a symmetry argument —
    /// that argument assumes the wrong goal and has already produced a wrong fix once.
    ///
    /// The raw connection is pinned to a *fixed* angle (see `configureSession`) and its buffer comes
    /// back the same `4032×3024` landscape shape regardless of how the phone is actually held. An odd
    /// turn count here is what's needed to reach the shape `PrintPipeline.compose()`'s aperture math
    /// expects for that orientation — see `photoApertureQuarterTurns`, which supplies the *other*
    /// half of the correction and cannot be derived from this table alone.
    ///
    /// Internal, not private: `CameraControllerTests` asserts this mapping directly, so a change to
    /// it is a visible, reviewed diff rather than a silent one inside a capture path no test touches.
    /// `nonisolated` because it is pure — no instance state, no main-actor requirement — which also
    /// lets the test call it synchronously.
    nonisolated static func correctionQuarterTurns(for orientation: UIDeviceOrientation) -> Int {
        switch orientation {
        case .portrait: return 3
        case .portraitUpsideDown: return 1
        case .landscapeLeft: return 0
        case .landscapeRight: return 2
        default: return 3 // faceUp/faceDown/unknown carry no orientation signal — assume portrait.
        }
    }

    /// How many quarter-turns (counter-clockwise) `PrintPipeline.compose()` applies to the photo
    /// before blitting it into the aperture — see `PrintPipeline.Request.photoQuarterTurns`.
    ///
    /// This can't be inferred from the image's aspect ratio inside `compose()` itself, the way an
    /// earlier version of this tried to: `.landscapeLeft` and `.landscapeRight` both hand `compose()`
    /// a landscape-shaped image (see `correctionQuarterTurns`), but need *different* aperture
    /// rotations — shape alone can't tell those two cases apart, only the device orientation this
    /// function is keyed on can. Same reasoning covers `.portrait` vs. `.portraitUpsideDown`, which
    /// both hand `compose()` a portrait-shaped image.
    ///
    /// `position` matters only for the landscape cases, and confirms a mirror rather than a rotation
    /// distinguishes the front and back camera's sensor mounting: swapping which physical landscape
    /// hold needs which aperture rotation (a mirror flips left/right) while leaving `.portrait` /
    /// `.portraitUpsideDown` unaffected (a top/bottom distinction survives a left-right mirror
    /// unchanged) — confirmed on-device, back camera needing exactly the two landscape values the
    /// front camera does not.
    ///
    /// All values confirmed on-device via the proof screen's Rotate button, together with
    /// `correctionQuarterTurns` above — see that function's doc comment for the design goal these
    /// serve (preserving how the phone was actually held, not forcing everything upright).
    nonisolated static func photoApertureQuarterTurns(
        for orientation: UIDeviceOrientation, position: AVCaptureDevice.Position
    ) -> Int {
        switch orientation {
        case .portrait: return 0
        case .portraitUpsideDown: return 2
        case .landscapeLeft: return position == .back ? 3 : 1
        case .landscapeRight: return position == .back ? 1 : 3
        default: return 0 // faceUp/faceDown/unknown carry no orientation signal — assume portrait.
        }
    }

    /// Prefers the widest virtual multi-camera the device offers — triple (ultra-wide + wide + tele),
    /// then dual-wide, then plain dual, falling back to the single wide lens every device has. Using
    /// the virtual device is what makes zoom a single continuous `videoZoomFactor` range with the OS
    /// switching lenses underneath it, rather than the app managing separate `AVCaptureDeviceInput`s.
    private static func discoverDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
        ]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return nil
    }

    private func configureSession(position: AVCaptureDevice.Position) -> Bool {
        guard let device = Self.discoverDevice(position: position),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach(session.removeInput)
        guard session.canAddInput(input) else { return false }
        session.addInput(input)

        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else { return false }
            session.addOutput(photoOutput)
        }

        if let connection = photoOutput.connection(with: .video) {
            // Pinned, not set per-shot: this is the fixed angle the app used, correctly, back when it
            // only supported portrait capture. `capturePhoto` applies whatever further rotation the
            // phone's actual orientation needs itself (`PhotoRasterizer.rotated`), rather than asking
            // AVFoundation to vary this per shot — see `correctionQuarterTurns` for why.
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            // The live viewfinder mirrors the front camera on its own connection (standard — that's
            // how you frame a shot). The captured photo must not: it becomes a physical print with a
            // caption baked in, and a mirrored photo next to correctly-oriented text reads as broken,
            // not stylistic. Pin this connection to the true (un-mirrored) image regardless of camera.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        currentDevice = device
        minZoomFactor = device.minAvailableVideoZoomFactor
        // Capped well below `maxAvailableVideoZoomFactor`, which on some lenses reports a factor so
        // high the frame is almost entirely digital upscale — a number with no real photographic use.
        maxZoomFactor = min(device.maxAvailableVideoZoomFactor, 10)
        lensSwitchZoomFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        displayZoomReferenceFactor = hasUltraWide ? (lensSwitchZoomFactors.first ?? 1.0) : 1.0
        // The actual `videoZoomFactor` is applied by the caller (`start`/`flipCamera`) once the
        // session is running — setting it here, before `startRunning`, doesn't reliably engage a
        // virtual multi-camera device's lens switch. `zoomFactor` itself is updated eagerly so the
        // UI reads correctly even in the brief window before that happens.
        zoomFactor = displayZoomReferenceFactor

        session.sessionPreset = .photo
        return true
    }
}

extension UIDeviceOrientation {
    /// A short, human-readable name for the debug strip — `UIDeviceOrientation`'s own description
    /// isn't public API to rely on.
    var debugName: String {
        switch self {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        default: return "unknown"
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let result: Result<CGImage, Error>
        if let error {
            result = .failure(error)
        } else if let cgImage = photo.cgImageRepresentation() {
            result = .success(cgImage)
        } else {
            result = .failure(CameraError.captureFailed)
        }

        Task { @MainActor [weak self] in
            guard let continuation = self?.captureContinuation else { return }
            self?.captureContinuation = nil
            continuation.resume(with: result)
        }
    }
}
