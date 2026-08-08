import CoreGraphics
import Foundation

/// The app's one piece of state: what stage the user is at, what the current print looks like, and
/// what the link is doing.
///
/// Deliberately a single model rather than one per screen. The three stages share the same photo,
/// the same dither settings and the same transport, and a remote shutter press has to be able to
/// drive the whole capture → dither → send sequence from outside any view — which is awkward when
/// that sequence is spread across three view models.
@MainActor
final class PrintStudioModel: ObservableObject {

    enum Stage: Equatable {
        /// Live viewfinder, waiting for the shutter.
        case viewfinder
        /// A photo has been taken and dithered. The user is choosing how it should look before
        /// committing it to the panel — a print takes several seconds and cannot be taken back.
        case proofing
        /// On its way to the device, or settling on the panel.
        case printing
        /// Done. The panel is holding the picture.
        case printed
    }

    @Published private(set) var stage: Stage = .viewfinder
    @Published private(set) var transportState: TransportState = .idle
    @Published private(set) var proof: Print?
    /// Set while the pipeline is re-dithering after a settings change, so the UI can dim rather
    /// than flicker between two prints.
    @Published private(set) var isRendering = false
    @Published var errorMessage: String?

    @Published var algorithm: DitherAlgorithm = DitherAlgorithm.lastUsed() {
        didSet {
            guard oldValue != algorithm else { return }
            DitherAlgorithm.setLastUsed(algorithm)
            rerenderProof()
        }
    }
    @Published var style: PrintStyle = .framed {
        didSet { if oldValue != style { rerenderProof() } }
    }
    /// Seconds between a shutter press and the capture. Only meaningful with the reader as a remote
    /// — if you are holding the phone you do not need a delay.
    @Published var selfTimerSeconds = 0
    @Published private(set) var countdown: Int?

    /// Overrides `PrintPipeline.Request.photoQuarterTurns` for the current proof instead of the
    /// confirmed per-orientation value `CameraController.photoApertureQuarterTurns(for:)` already
    /// supplied at capture time (see `rerenderProof`) — `nil` means "use that confirmed value,"
    /// matching every real print.
    ///
    /// A stand-in for a faster confirmation loop than another TestFlight build, kept around for
    /// whatever the next orientation surprise turns out to be: cycling this and re-rendering searches
    /// the four possibilities for real, through the same `compose()` code path an actual print takes
    /// — so the border and caption (pure canvas geometry, never the source of an orientation bug)
    /// stay exactly where they belong, and only the photo itself moves. Reset to `nil` on every new
    /// capture; it describes a search for *this* photo, not a standing preference.
    @Published private(set) var manualRotationOverride: Int? {
        didSet { rerenderProof() }
    }

    let camera: CameraController
    let transport: DisplayTransport

    /// The un-dithered capture, kept so changing the algorithm re-dithers the original rather than
    /// dithering an already-dithered image.
    private var sourceImage: CGImage?
    private var renderTask: Task<Void, Never>?

    /// `camera` has no default value: a default argument is evaluated in a nonisolated context, and
    /// `CameraController` is main-actor isolated. Callers construct it, which they are already on
    /// the main actor to do.
    init(camera: CameraController, transport: DisplayTransport) {
        self.camera = camera
        self.transport = transport

        transport.onStateChange = { [weak self] state in
            self?.transportState = state
            self?.reactToTransportState(state)
        }
        transport.onButtonEvent = { [weak self] event in
            self?.handleButton(event)
        }
        transportState = transport.state
    }

    // MARK: - Capture

    func shutter() {
        guard stage == .viewfinder, countdown == nil else { return }

        guard selfTimerSeconds > 0 else {
            Task { await capture() }
            return
        }

        Task {
            for remaining in stride(from: selfTimerSeconds, through: 1, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            countdown = nil
            await capture()
        }
    }

    private func capture() async {
        do {
            let image = try await camera.capturePhoto()
            sourceImage = image
            manualRotationOverride = nil
            stage = .proofing
            rerenderProof()
        } catch {
            errorMessage = "Couldn't take the photo. \(error.localizedDescription)"
        }
    }

    /// Steps through automatic → 0 → 1 → 2 → 3 → back to automatic — see `manualRotationOverride`.
    func cycleManualRotation() {
        manualRotationOverride = switch manualRotationOverride {
        case nil: 0
        case 3: nil
        case let turns?: turns + 1
        }
    }

    #if DEBUG
    /// Loads the calibration target as the current proof, ready to send.
    ///
    /// DEBUG-only: it is a bring-up instrument, not a feature, and a consumer camera app has no
    /// business shipping a test card behind a gesture. It goes through the app's own encoder and
    /// transport on purpose — pushing the same target with the firmware's Python script would prove
    /// the firmware works while saying nothing about whether *this app's* bytes survive the trip.
    ///
    /// See MANUAL-DEVICE-TESTS.md § "The dither fidelity check".
    func loadCalibrationTarget() {
        renderTask?.cancel()
        sourceImage = nil
        do {
            proof = try PrintPipeline.makeCalibrationPrint(geometry: transport.geometry)
            stage = .proofing
        } catch {
            errorMessage = Self.describe(error)
        }
    }
    #endif

    func retake() {
        renderTask?.cancel()
        sourceImage = nil
        proof = nil
        manualRotationOverride = nil
        stage = .viewfinder
    }

    // MARK: - Dithering

    /// Re-runs the pipeline against the stored capture. Cancels any render already in flight, so
    /// dragging through the algorithm picker does not queue up four full 480×800 dithers.
    private func rerenderProof() {
        guard stage == .proofing || stage == .printed else { return }

        // The calibration target has no camera capture behind it — regenerate it at the new size
        // rather than leaving a mis-sized sheet, which would make the geometry check in
        // MANUAL-DEVICE-TESTS.md § 4 report a fault that is the app's own.
        guard let sourceImage else {
            #if DEBUG
            if proof != nil { loadCalibrationTarget() }
            #endif
            return
        }

        renderTask?.cancel()
        isRendering = true

        // The confirmed per-orientation value from the actual shot, unless the debug Rotate button
        // is searching for a different one right now.
        let photoQuarterTurns = manualRotationOverride ?? camera.lastCaptureDebugInfo?.photoApertureQuarterTurns ?? 0

        let request = PrintPipeline.Request(
            source: sourceImage,
            algorithm: algorithm,
            style: style,
            caption: Self.captionForNow(),
            geometry: transport.geometry,
            photoQuarterTurns: photoQuarterTurns
        )

        renderTask = Task { [weak self] in
            // Off the main actor: a full-panel error diffusion is tens of milliseconds, which is
            // long enough to be felt as a stutter in the picker if it runs inline.
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PrintPipeline.makePrint(request) }
            }.value

            guard !Task.isCancelled, let self else { return }
            self.isRendering = false

            switch result {
            case .success(let print):
                self.proof = print
            case .failure(let error):
                self.proof = nil
                self.errorMessage = Self.describe(error)
            }
        }
    }

    /// The framed-print caption: the moment the photo was taken, which is the only thing anyone ever
    /// actually writes on the white strip.
    private static func captionForNow() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy  HH:mm"
        return formatter.string(from: Date())
    }

    // MARK: - Sending

    /// Set while a background-triggered disconnect is deferred because a send was in flight — see
    /// `disconnectForBackground()`.
    private var backgroundDisconnectPending = false

    func connect() {
        DebugLog.shared.log("PrintStudioModel.connect(), stage \(stage)")
        backgroundDisconnectPending = false
        transport.connect()
    }

    /// Drops the BLE link when the app backgrounds.
    ///
    /// Unlike an audio or navigation app, Snap2Ink has no reason to keep the reader's screen (or the
    /// link) while the user is elsewhere — there is no remote shutter to preserve. But a send already
    /// in flight is a different story: the bytes are paid for the moment they're on the wire, and
    /// backgrounding mid-transfer would abort a print the user already committed to. So a send in
    /// progress is left alone here — `send()` drops the link itself once the transfer settles, if the
    /// app is still backgrounded by then.
    func disconnectForBackground() {
        guard stage != .printing else {
            DebugLog.shared.log("disconnectForBackground() deferred — a send is in flight")
            backgroundDisconnectPending = true
            return
        }
        DebugLog.shared.log("disconnectForBackground()")
        transport.disconnect()
    }

    func send() {
        guard let proof else { return }
        guard case .ready = transportState else {
            errorMessage = "Your reader isn't connected yet."
            return
        }

        // A print whose dimensions do not match the panel is scaled and resampled on-device, which
        // destroys the dither — the exact failure the four-level contract exists to prevent, and one
        // that looks like a vague quality problem rather than a bug. It is reachable: a proof made
        // before connecting is rendered against the placeholder geometry, and the real size only
        // arrives with the capability read. `reactToTransportState` re-renders when that happens;
        // this is the backstop for any path that slips past it.
        let panel = transport.geometry.pixels
        guard proof.image.width == panel.width, proof.image.height == panel.height else {
            rerenderProof()
            errorMessage = "Resizing the print for your reader — try again in a moment."
            return
        }

        DebugLog.shared.log("send() from stage \(stage)")
        stage = .printing
        Task {
            do {
                try await transport.send(proof)
                stage = .printed
            } catch {
                DebugLog.shared.log("send() threw: \(error)")
                stage = .proofing
                errorMessage = Self.describe(error)
            }
            if backgroundDisconnectPending {
                backgroundDisconnectPending = false
                transport.disconnect()
            }
        }
    }

    // MARK: - Device buttons

    /// Routes a `REMOTE` button press from the reader. The firmware reports raw button identity and
    /// nothing else — what "button 1" means is decided here, and has to agree with the labels
    /// `ButtonMap` told the device to draw.
    private func handleButton(_ event: ButtonPressEvent) {
        // Act on the press, not the release: a shutter that fires when you let go feels broken, and
        // the repeat notifications during a hold would otherwise fire it once every 100ms.
        guard !event.isFinal, event.duration == 0 else { return }

        switch event.button {
        case .back:
            switch stage {
            case .viewfinder:
                shutter()
            case .proofing:
                // The reader is across the room; the user pressed the button they can reach. Taking
                // the proof they are looking at is the only sensible reading of that.
                send()
            case .printing, .printed:
                break
            }

        case .confirm, .up, .down, .left, .right, .power:
            // Mapped to NONE — the device never notifies for these.
            break
        }
    }

    private func reactToTransportState(_ state: TransportState) {
        switch state {
        case .ready(let geometry):
            // The capability characteristic is the only authority on panel size, and it arrives
            // after a proof may already have been rendered against the placeholder. Re-render so
            // what the user approved is what actually gets sent.
            if let proof, proof.image.width != geometry.pixels.width || proof.image.height != geometry.pixels.height {
                rerenderProof()
            }

        case .backgrounded(.preempted):
            errorMessage = "Another app took over your reader's screen."
        case .backgrounded(.linkLost), .disconnected:
            if stage == .printing { stage = .proofing }
        case .pairingRefused(let reason):
            errorMessage = reason == .timeout
                ? "Nobody confirmed the pairing on the reader in time."
                : "Pairing was declined on the reader."
        case .failed(let reason):
            errorMessage = reason
        default:
            break
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case PrintPipeline.PipelineError.tooLarge(let bytes, let limit):
            return "This print is \(bytes) bytes and the device accepts at most \(limit)."
        case PrintPipeline.PipelineError.rasterizationFailed:
            return "Couldn't prepare the photo for printing."
        case TransportError.preemptedMidTransfer:
            return "Another app took the screen while the print was sending."
        case TransportError.disconnectedMidTransfer:
            return "The reader disconnected while the print was sending."
        case TransportError.imageTooLarge(let bytes, let limit):
            return "This print is \(bytes) bytes and the device accepts at most \(limit)."
        case TransportError.notReady:
            return "Your reader isn't connected yet."
        default:
            return error.localizedDescription
        }
    }
}
