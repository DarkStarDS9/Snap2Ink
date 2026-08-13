import CompanionKit
import Foundation

/// The real transport: `DisplayTransport` implemented over CompanionKit's `CompanionClient`.
///
/// Thin on purpose. CompanionKit owns the handshake, token persistence, asset digests, session
/// filtering and framing; this type owns only the translation into the vocabulary the rest of the
/// app already speaks, and one policy decision the library leaves to the app — which discovered
/// device to connect to.
@MainActor
final class CompanionKitTransport: DisplayTransport {

    private(set) var state: TransportState = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((TransportState) -> Void)?
    var onButtonEvent: ((ButtonPressEvent) -> Void)?

    /// Falls back to the assumed X3 panel until the capability characteristic has been read, so the
    /// user can proof a print before pairing anything.
    private(set) var geometry: DisplayGeometry = .assumedX3

    private let client: CompanionClient
    private var eventTask: Task<Void, Never>?
    /// Kept only for the diagnostics readout — `pushImage` already surfaces the outcome through its
    /// return value and its throws, so nothing in the app branches on this.
    private var lastImageStatus: RenderResult?

    init(client: CompanionClient) {
        self.client = client
    }

    convenience init() {
        self.init(
            client: CompanionClient(
                identity: Snap2InkPeer.identity(),
                assets: Snap2InkAssetProvider(),
                log: { DebugLog.shared.log($0) }
            )
        )
    }

    func connect() {
        // `client.events` is a single-consumer AsyncStream meant to be iterated exactly once for
        // the client's whole lifetime (see `CompanionClient.events`'s doc comment) — cancelling
        // and re-`for await`-ing it after a background/foreground cycle left the stream terminated
        // and every event after the first cycle silently dropped. So this task is started once,
        // ever, and never cancelled; only the switch below decides what a `connect()` call means.
        if eventTask == nil {
            eventTask = Task { [weak self] in
                guard let self else { return }
                for await event in self.client.events {
                    self.handle(event)
                }
            }
        }

        switch state {
        case .idle, .disconnected:
            DebugLog.shared.log("connect() from \(state) — scanning")
            state = .scanning
            client.startScanning()
        default:
            // The BLE link is still up — only the screen was lost, to a preemption or a release.
            // CompanionKit deliberately never re-asks on its own (two apps that both auto-reacquire
            // would ping-pong the screen forever), so "Reconnect" here means "ask for it back."
            DebugLog.shared.log("connect() from \(state) — re-acquiring screen")
            client.acquireScreen()
        }
    }

    func disconnect() {
        DebugLog.shared.log("disconnect() from \(state)")
        client.disconnect()
        state = .disconnected
    }

    func send(_ print: Print) async throws {
        guard case .ready = state else { throw TransportError.notReady }
        guard print.byteCount <= geometry.maxImageBytes else {
            throw TransportError.imageTooLarge(bytes: print.byteCount, limit: geometry.maxImageBytes)
        }

        DebugLog.shared.log("send() starting, \(print.byteCount) bytes")
        state = .sending(progress: 0)
        do {
            _ = try await client.pushImage(print.imageData) { [weak self] fraction in
                // CompanionKit calls this on an arbitrary queue.
                Task { @MainActor in
                    guard let self else { return }
                    guard case .sending = self.state else { return }
                    // `pushImage` reports transfer progress, then keeps awaiting while the device
                    // decodes the PNG and runs its two-pass grayscale settle. Reaching 1.0 is the
                    // only signal that the wait has changed character — so the developing state is
                    // entered here rather than after the await, where it would last no time at all
                    // and the UI would snap from a full progress bar to a finished picture.
                    self.state = fraction >= 1.0 ? .developing : .sending(progress: fraction)
                }
            }
        } catch {
            // `pushImage` only returns once the device has decoded and displayed the image, so a
            // throw here means the print did not land — the UI must not claim it did.
            DebugLog.shared.log("send() failed: \(error)")
            switch state {
            case .sending, .developing: state = .ready(geometry)
            default: break
            }
            throw Self.translate(error)
        }

        DebugLog.shared.log("send() completed")
        state = .ready(geometry)
    }

    // MARK: - Events

    private func handle(_ event: CompanionEvent) {
        DebugLog.shared.log("event: \(event), state was \(state)")
        switch event {
        case .bluetoothStateChanged(let isAvailable):
            if isAvailable {
                state = .scanning
                client.startScanning()
            } else {
                state = .failed("Bluetooth is off.")
            }

        case .discovered(let device):
            // Policy the library deliberately leaves to the app: connect to the first companion
            // display found. Snap2Ink has no device picker because a user with two readers in range
            // is not a case worth a screen — and CompanionKit reconnects to a known peer silently,
            // so the paired one wins in practice.
            state = .connecting
            client.stopScanning()
            client.connect(device)

        case .connected(let capabilities):
            geometry = DisplayGeometry(
                pixels: PixelSize(width: capabilities.screenPixelWidth, height: capabilities.screenPixelHeight),
                maxImageBytes: capabilities.maxImageFieldLength
            )

        case .pairingPending:
            state = .awaitingPairingConfirmation

        case .pairingDenied(let reason):
            state = .pairingRefused(reason)

        case .sessionEstablished:
            // Nothing to do: the client is constructed with `acquireScreenOnConnect` left at its
            // default, so the handshake ends by asking for the screen on its own.
            break

        case .gainedScreen:
            state = .ready(geometry)

        case .lostScreen(let reason):
            state = .backgrounded(reason)

        case .acquireDenied(let reason):
            state = .failed(Self.describe(reason))

        case .buttonEvent(let press):
            onButtonEvent?(
                ButtonPressEvent(button: press.button, duration: press.holdDuration, isFinal: press.isFinal)
            )

        case .disconnected:
            state = .disconnected

        case .failure(let error):
            state = .failed(Self.describe(error))

        case .renderStatus(let result):
            lastImageStatus = result

        case .assetSynced, .stateChanged:
            // Asset sync is the library's business, and `stateChanged` is a coarser view of
            // transitions this type already reports individually.
            break

        case .fieldSeqGap:
            // Only fires for a dropped title/body CHUNK push; Snap2Ink doesn't push those fields
            // yet (image-only), so this can't occur in practice today.
            break

        case .imageChunkAck:
            // Diagnostic progress marker only; pushImage's own progress callback already drives the UI.
            break

        case .listStateAvailable:
            // Only fires for a pending check-off diff on `listDoc`; Snap2Ink pushes no list content
            // (image-only), so this can't occur in practice today.
            break
        }
    }

    // MARK: - Diagnostics

    var diagnostics: [DiagnosticEntry] {
        guard let capabilities = client.deviceCapabilities else {
            return [DiagnosticEntry(label: "Device", value: "not connected")]
        }

        return [
            DiagnosticEntry(label: "Protocol version", value: "\(capabilities.protocolVersion)"),
            DiagnosticEntry(label: "Device id", value: capabilities.deviceIdHex),
            DiagnosticEntry(
                label: "Screen pixels",
                value: "\(capabilities.screenPixelWidth) × \(capabilities.screenPixelHeight)"
            ),
            DiagnosticEntry(
                label: "Screen characters",
                value: "\(capabilities.screenCharacterWidth) × \(capabilities.screenCharacterHeight)"
            ),
            DiagnosticEntry(label: "Max image bytes", value: "\(capabilities.maxImageFieldLength)"),
            DiagnosticEntry(label: "Max text bytes", value: "\(capabilities.maxTextFieldLength)"),
            DiagnosticEntry(label: "Grey levels", value: "\(capabilities.imageGrayLevels)"),
            DiagnosticEntry(
                label: "Icon",
                value: "\(capabilities.iconPixelWidth) × \(capabilities.iconPixelHeight) (\(capabilities.iconByteCount) B)"
            ),
            DiagnosticEntry(label: "Max sessions", value: "\(capabilities.maxConcurrentSessions)"),
            DiagnosticEntry(
                label: "Features",
                value: [
                    capabilities.supportsImage ? "image" : nil,
                    capabilities.supportsUiDeclaration ? "ui" : nil,
                    capabilities.supportsIcons ? "icons" : nil,
                    capabilities.supportsSessions ? "sessions" : nil,
                ].compactMap { $0 }.joined(separator: ", ")
            ),
            DiagnosticEntry(label: "Holds screen", value: client.hasScreen ? "yes" : "no"),
            DiagnosticEntry(
                label: "Last image status",
                value: lastImageStatus.map { "\($0)" } ?? "none yet"
            ),
        ]
    }

    // MARK: - Error translation

    private static func translate(_ error: Error) -> Error {
        switch error {
        case CompanionError.payloadTooLarge(_, let bytes, let limit):
            return TransportError.imageTooLarge(bytes: bytes, limit: limit)
        case CompanionError.disconnected, CompanionError.notConnected:
            return TransportError.disconnectedMidTransfer
        case CompanionError.noSession:
            return TransportError.preemptedMidTransfer
        default:
            return error
        }
    }

    private static func describe(_ reason: AcquireDeniedReason) -> String {
        switch reason {
        case .noUiDeclaration:
            // Should be impossible: CompanionKit pushes the declaration during enrolment and
            // Snap2Ink always supplies one. If it ever happens the asset push failed silently, and
            // saying so is more useful than a generic error.
            return "The reader has no button map for Snap2Ink."
        case .unknownSession:
            return "The reader no longer recognises this session."
        case .unknown:
            return "The reader refused the screen."
        }
    }

    private static func describe(_ error: CompanionError) -> String {
        switch error {
        case .bluetoothUnavailable:
            return "Bluetooth is unavailable."
        case .unsupportedProtocolVersion(let reported, let expected):
            if reported > expected {
                return "That reader speaks protocol v\(reported); Snap2Ink only understands v\(expected). Update Snap2Ink."
            }
            return "That reader speaks protocol v\(reported); Snap2Ink needs v\(expected). Update its firmware."
        case .pairingDenied(let reason):
            return reason == .timeout ? "Nobody confirmed the pairing on the reader in time." : "Pairing was declined on the reader."
        case .imageRejected(let result):
            return "The reader could not display the print (\(result))."
        default:
            return "\(error)"
        }
    }
}
