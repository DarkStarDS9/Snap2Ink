import CompanionKit
import Foundation

/// A `DisplayTransport` that talks to nothing, at realistic speed.
///
/// This exists because the simulator has no Bluetooth, but its real value is that it makes the
/// *pace* of the app developable. The whole "developing" experience is a timing design — how long
/// the bar creeps, when the print starts to appear, how long the panel settles — and getting that
/// right by flashing firmware and walking to a reader every iteration would be miserable. The
/// numbers below are taken from the real link's constraints, not invented:
///
/// - iOS negotiates around a 185-byte MTU with this firmware; 3 bytes go to ATT overhead and 1 more
///   to the CHUNK opcode, leaving ~181 payload bytes per packet.
/// - Write-with-response lands roughly one packet per connection interval, and iOS typically
///   settles on 15–30ms with a peripheral of this class.
/// - The panel's two-pass grayscale settle is several seconds and is not overlapped with anything.
///
/// It also simulates the awkward paths deliberately: first connect always demands an on-device
/// confirmation, and `preemptNextSend` reproduces being pushed off the screen by another app
/// mid-transfer — a case that is nearly impossible to provoke on demand with real hardware.
@MainActor
final class MockDisplayTransport: DisplayTransport {

    private(set) var state: TransportState = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((TransportState) -> Void)?
    var onButtonEvent: ((ButtonPressEvent) -> Void)?
    private(set) var geometry: DisplayGeometry = .assumedX3

    /// Set to make the next `send` fail partway through as if another app had grabbed the screen.
    var preemptNextSend = false
    /// Set to make the next connect end in the user declining the on-device prompt.
    var refuseNextPairing = false
    /// Pretend this install has already paired, skipping the confirmation prompt — which is what
    /// every connect after the first looks like.
    var alreadyPaired = false

    private var connectTask: Task<Void, Never>?

    private let bytesPerPacket = 181
    private let secondsPerPacket = 0.020
    private let settleSeconds = 4.0

    /// Mirrors what a real X3 advertises, so the diagnostics screen can be laid out and read without
    /// hardware. The values are the firmware's own constants, not invented.
    var diagnostics: [DiagnosticEntry] {
        guard case .ready = state else {
            return [DiagnosticEntry(label: "Device", value: "not connected (mock)")]
        }
        return [
            DiagnosticEntry(label: "Protocol version", value: "6"),
            DiagnosticEntry(label: "Device id", value: "6fb1e87c"),
            DiagnosticEntry(label: "Screen pixels", value: "\(geometry.pixels.width) × \(geometry.pixels.height)"),
            DiagnosticEntry(label: "Max image bytes", value: "\(geometry.maxImageBytes)"),
            DiagnosticEntry(label: "Grey levels", value: "4"),
            DiagnosticEntry(label: "Icon", value: "64 × 64 (512 B)"),
            DiagnosticEntry(label: "Holds screen", value: "yes"),
            DiagnosticEntry(label: "Last image status", value: "mock — nothing was sent"),
        ]
    }

    func connect() {
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            self.state = .scanning
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }

            self.state = .connecting
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            if !self.alreadyPaired {
                // HELLO_PENDING: the device is showing "Pair with Snap2Ink? CONFIRM / BACK" and
                // will sit there until somebody walks over to it.
                self.state = .awaitingPairingConfirmation
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }

                if self.refuseNextPairing {
                    self.refuseNextPairing = false
                    self.state = .pairingRefused(.userRejected)
                    return
                }
                self.alreadyPaired = true
            }

            self.state = .ready(self.geometry)
        }
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        state = .disconnected
    }

    func send(_ print: Print) async throws {
        guard case .ready = state else { throw TransportError.notReady }
        guard print.byteCount <= geometry.maxImageBytes else {
            throw TransportError.imageTooLarge(bytes: print.byteCount, limit: geometry.maxImageBytes)
        }

        let packets = max(1, (print.byteCount + bytesPerPacket - 1) / bytesPerPacket)
        let preemptAt = preemptNextSend ? packets / 3 : Int.max
        preemptNextSend = false

        state = .sending(progress: 0)
        for packet in 1...packets {
            try await Task.sleep(for: .seconds(secondsPerPacket))
            if packet == preemptAt {
                state = .backgrounded(.preempted)
                throw TransportError.preemptedMidTransfer
            }
            state = .sending(progress: Double(packet) / Double(packets))
        }

        state = .developing
        try await Task.sleep(for: .seconds(settleSeconds))
        state = .ready(geometry)
    }

    // MARK: - Test / preview hooks

    /// Fakes a press of one of Snap2Ink's `REMOTE` buttons, so the shutter-from-the-reader path can
    /// be exercised without a reader.
    func simulateButton(_ button: CompanionButton, heldFor duration: TimeInterval = 0, isFinal: Bool = true) {
        onButtonEvent?(ButtonPressEvent(button: button, duration: duration, isFinal: isFinal))
    }
}
