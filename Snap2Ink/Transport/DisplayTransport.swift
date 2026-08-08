import CompanionKit
import Foundation

/// A button press reported back by the device, reduced to what the app actually acts on.
///
/// CompanionKit's `CompanionButtonEvent` carries a `sessionId` and an echoed content-id too; both
/// are the transport's business — filtering notifications to our own session is not optional, and
/// doing it once at the seam is better than making every caller remember.
struct ButtonPressEvent: Equatable {
    let button: CompanionButton
    /// Elapsed hold time since the initial press. Zero for the initial-down event.
    let duration: TimeInterval
    /// The release event. Callers **must not** rely on this alone to detect release: a disconnect
    /// mid-hold means it never arrives.
    let isFinal: Bool
}

/// One labelled fact about the link, for the in-app diagnostics readout.
///
/// Strings rather than typed fields on purpose: this exists to be *displayed*, nothing branches on
/// it, and a transport should be able to report whatever it knows without the seam growing a
/// property per capability byte.
struct DiagnosticEntry: Equatable, Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

/// Everything the UI needs to know about the link, as one value.
///
/// Modelled as a single enum rather than a bag of booleans because these states are genuinely
/// exclusive and the UI is a state machine: "developing" and "awaiting pairing" want completely
/// different screens, and any combination of them is meaningless.
enum TransportState: Equatable {
    case idle
    case scanning
    case connecting
    /// HELLO sent, device is showing its confirmation prompt. The user has to walk over and press a
    /// button — the UI says so rather than spinning.
    case awaitingPairingConfirmation
    case pairingRefused(HelloDeniedReason)
    /// Connected, enrolled, and holding the foreground session. Ready to print.
    case ready(DisplayGeometry)
    /// Pushing a print. `progress` is bytes acknowledged over bytes total, 0...1.
    case sending(progress: Double)
    /// All bytes delivered; the panel is running its two-pass grayscale settle. Nothing more will
    /// arrive over BLE — this is the developing.
    case developing
    case backgrounded(BackgroundReason)
    case disconnected
    case failed(String)
}

enum TransportError: Error, Equatable {
    case notReady
    case imageTooLarge(bytes: Int, limit: Int)
    case disconnectedMidTransfer
    case preemptedMidTransfer
}

/// The seam between the app and the Companion Display Protocol.
///
/// Nothing above this line knows about CoreBluetooth, GATT characteristics, START/CHUNK/END framing,
/// sessions or HELLO — that is all `CompanionKitTransport`'s business, and the mock's job is to
/// imitate its *timing*, not its bytes. Keeping the seam this narrow is what let the entire capture
/// and dither half of the app be built and tested before the protocol existed.
@MainActor
protocol DisplayTransport: AnyObject {
    var state: TransportState { get }
    var onStateChange: ((TransportState) -> Void)? { get set }
    var onButtonEvent: ((ButtonPressEvent) -> Void)? { get set }

    /// The connected device's geometry, or `DisplayGeometry.assumedX3` before one is known — the
    /// dither pipeline needs target dimensions to show a preview, and the user is entitled to a
    /// preview before they pair anything.
    var geometry: DisplayGeometry { get }

    /// What the device has told us about itself, for the diagnostics readout.
    ///
    /// Exists because `MANUAL-DEVICE-TESTS.md` asks the tester to record the advertised pixel size
    /// and image cap, and without this there is no way to see either from the phone — the capability
    /// block is otherwise only readable over a serial cable. A checklist step nobody can perform is
    /// worse than no step at all.
    var diagnostics: [DiagnosticEntry] { get }

    func connect()
    func disconnect()

    /// Pushes a finished print and returns once the device has all the bytes. The panel's settle
    /// happens after this returns, and is reported as `.developing`.
    func send(_ print: Print) async throws
}
