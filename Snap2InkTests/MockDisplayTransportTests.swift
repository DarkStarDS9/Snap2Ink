import CompanionKit
import XCTest
@testable import Snap2Ink

/// The mock is a stand-in for hardware, so what is worth testing is that it moves through the same
/// states the real device does — including the two awkward ones (`awaitingPairingConfirmation` and
/// being preempted mid-transfer) that exist specifically so the UI for them can be built before
/// there is any way to provoke them for real.
@MainActor
final class MockDisplayTransportTests: XCTestCase {

    func test_firstConnect_waitsForConfirmationOnTheDevice() async throws {
        let transport = MockDisplayTransport()
        var seen: [TransportState] = []
        transport.onStateChange = { seen.append($0) }

        transport.connect()
        try await waitUntilReady(transport)

        XCTAssertTrue(
            seen.contains(.awaitingPairingConfirmation),
            "an unknown peer must be made to confirm on the device — see the pairing flow in the design doc"
        )
    }

    func test_secondConnect_skipsTheConfirmationPrompt() async throws {
        let transport = MockDisplayTransport()
        transport.alreadyPaired = true

        var seen: [TransportState] = []
        transport.onStateChange = { seen.append($0) }

        transport.connect()
        try await waitUntilReady(transport)

        XCTAssertFalse(
            seen.contains(.awaitingPairingConfirmation),
            "a known peer with a valid token connects without prompting"
        )
    }

    func test_declinedPairing_endsInRefusalRatherThanReady() async throws {
        let transport = MockDisplayTransport()
        transport.refuseNextPairing = true

        transport.connect()
        try await wait(for: transport) { $0 == .pairingRefused(.userRejected) }

        XCTAssertEqual(transport.state, .pairingRefused(.userRejected))
    }

    func test_send_beforeReady_isRefused() async {
        let transport = MockDisplayTransport()

        do {
            try await transport.send(Self.tinyPrint())
            XCTFail("sending to a transport that is not ready must throw")
        } catch {
            XCTAssertEqual(error as? TransportError, .notReady)
        }
    }

    func test_send_reportsMonotonicProgressAndThenDevelops() async throws {
        let transport = MockDisplayTransport()
        transport.alreadyPaired = true
        transport.connect()
        try await waitUntilReady(transport)

        var progresses: [Double] = []
        var sawDeveloping = false
        transport.onStateChange = { state in
            if case .sending(let progress) = state { progresses.append(progress) }
            if state == .developing { sawDeveloping = true }
        }

        try await transport.send(Self.tinyPrint())

        XCTAssertFalse(progresses.isEmpty)
        XCTAssertEqual(progresses, progresses.sorted(), "progress must never go backwards")
        XCTAssertEqual(try XCTUnwrap(progresses.last), 1.0, accuracy: 0.0001)
        XCTAssertTrue(sawDeveloping, "the panel settle is a distinct state, not part of the transfer")
    }

    func test_beingPreemptedMidTransfer_throwsAndReportsBackgrounded() async throws {
        let transport = MockDisplayTransport()
        transport.alreadyPaired = true
        transport.connect()
        try await waitUntilReady(transport)
        transport.preemptNextSend = true

        do {
            try await transport.send(Self.tinyPrint())
            XCTFail("a preempted transfer must not report success")
        } catch {
            XCTAssertEqual(error as? TransportError, .preemptedMidTransfer)
            XCTAssertEqual(transport.state, .backgrounded(.preempted))
        }
    }

    func test_send_refusesAPrintOverTheDeviceCap() async throws {
        let transport = MockDisplayTransport()
        transport.alreadyPaired = true
        transport.connect()
        try await waitUntilReady(transport)

        let oversized = Print(
            image: GrayImage(width: 2, height: 2, filledWith: 0),
            imageData: Data(repeating: 0, count: transport.geometry.maxImageBytes + 1),
            algorithm: .atkinson,
            style: .fullBleed
        )

        do {
            try await transport.send(oversized)
            XCTFail("an oversized print must be refused before any bytes go out")
        } catch {
            guard case TransportError.imageTooLarge = error else {
                return XCTFail("expected .imageTooLarge, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func waitUntilReady(_ transport: MockDisplayTransport) async throws {
        try await wait(for: transport) { if case .ready = $0 { return true } else { return false } }
    }

    /// Polls rather than using an expectation: the transport drives its own `Task` timeline, and
    /// polling keeps the test on the main actor with it.
    private func wait(
        for transport: MockDisplayTransport,
        timeout: TimeInterval = 10,
        until predicate: (TransportState) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(transport.state) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting; last state was \(transport.state)")
    }

    private static func tinyPrint() -> Print {
        Print(
            image: GrayImage(width: 4, height: 4, filledWith: 255),
            // Small enough that the mock's simulated 20ms-per-packet pacing keeps the test quick.
            imageData: Data(repeating: 0, count: 900),
            algorithm: .atkinson,
            style: .fullBleed
        )
    }
}
