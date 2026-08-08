import CompanionKit
import CryptoKit
import XCTest
@testable import Snap2Ink

/// Everything the firmware sees of Snap2Ink: its identity, its button map, its icon.
///
/// The encoding and tagging of those assets belongs to CompanionKit and is tested there. What is
/// tested here is Snap2Ink's *choices* — which are wire-visible and, in the `appId`'s case,
/// permanent. These are pins, not exploration.
final class DeviceContractTests: XCTestCase {

    // MARK: - Identity

    /// **If this test fails, do not update it.** The `appId` is fixed forever: it is what groups
    /// every install of Snap2Ink into one tile on a device's sleep screen, and changing it orphans
    /// every existing pairing on every device, with no protocol opcode to clean them up.
    func test_appId_isTheFixedSixteenBytesAndNeverChanges() {
        let identity = Snap2InkPeer.identity(defaults: Self.scratchDefaults())

        XCTAssertEqual(identity.appId.count, 16)
        XCTAssertEqual(Array(identity.appId), [
            0xD7, 0x42, 0xC3, 0x01, 0xE3, 0x9C, 0x5A, 0xF0,
            0x81, 0xD1, 0x25, 0x17, 0xA4, 0x90, 0x48, 0xAD,
        ])
    }

    /// The appId is derived, not picked — so it can be re-derived and checked rather than taken on
    /// faith. This recomputes UUIDv5(DNS, "app.snap2ink.camera") the long way and compares.
    func test_appId_isReproducibleFromTheAppsReverseDNSName() throws {
        // RFC 4122 §4.3: SHA-1 over the namespace UUID's bytes followed by the name, then the
        // version and variant bits forced.
        let dnsNamespace = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        var input = Data(Self.bytes(of: dnsNamespace))
        input.append(Data("app.snap2ink.camera".utf8))

        var digest = Array(Insecure.SHA1.hash(data: input).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50  // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80  // RFC 4122 variant

        XCTAssertEqual(digest, Self.bytes(of: Snap2InkPeer.appId))
    }

    func test_displayName_isWhatTheDevicePutsInItsPairingPrompt() {
        XCTAssertEqual(Snap2InkPeer.identity(defaults: Self.scratchDefaults()).displayName, "Snap2Ink")
    }

    func test_installId_isGeneratedOnceAndThenStable() {
        let defaults = Self.scratchDefaults()

        let first = Snap2InkPeer.identity(defaults: defaults).installId
        let second = Snap2InkPeer.identity(defaults: defaults).installId

        XCTAssertEqual(first.count, 16)
        XCTAssertEqual(first, second, "a regenerated installId makes the device treat this as a new phone")
    }

    func test_installId_differsBetweenInstalls() {
        XCTAssertNotEqual(
            Snap2InkPeer.identity(defaults: Self.scratchDefaults()).installId,
            Snap2InkPeer.identity(defaults: Self.scratchDefaults()).installId
        )
    }

    // MARK: - User label

    /// Two installs pairing the same reader need to be told apart in its gallery picker —
    /// CompanionKit's own device-name default is a generic "iPhone" on iOS 16+, useless for that.
    func test_userLabel_isSentAsUserNameOnceSet() {
        let defaults = Self.scratchDefaults()
        Snap2InkPeer.setUserLabel("Alex's iPhone", defaults: defaults)

        XCTAssertEqual(Snap2InkPeer.identity(defaults: defaults).userName, "Alex's iPhone")
    }

    func test_userLabel_trimsWhitespace() {
        let defaults = Self.scratchDefaults()
        Snap2InkPeer.setUserLabel("  Sam's iPad  ", defaults: defaults)

        XCTAssertEqual(Snap2InkPeer.userLabel(defaults: defaults), "Sam's iPad")
    }

    /// Setting an empty (or all-whitespace) label clears it back to "not set" rather than sending an
    /// empty string, which `CompanionIdentity` would otherwise fall back to `displayName` for —
    /// identical across every install, exactly as unhelpful as "iPhone".
    func test_userLabel_clearingFallsBackToTheDeviceDefault() {
        let defaults = Self.scratchDefaults()
        Snap2InkPeer.setUserLabel("Alex's iPhone", defaults: defaults)
        Snap2InkPeer.setUserLabel("   ", defaults: defaults)

        XCTAssertEqual(Snap2InkPeer.userLabel(defaults: defaults), "")
        XCTAssertEqual(Snap2InkPeer.identity(defaults: defaults).userName, CompanionIdentity.defaultUserName)
    }

    // MARK: - Helpers

    /// A throwaway `UserDefaults` suite, so these tests neither read nor clobber a real install id.
    private static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "snap2ink.tests.\(UUID().uuidString)")!
    }

    private static func bytes(of uuid: UUID) -> [UInt8] {
        let u = uuid.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    // MARK: - Button map

    /// A peer with no button map is refused the screen, so this is not optional polish — an
    /// incomplete map is an app that cannot print.
    func test_buttonMap_bindsEveryButtonTheFirmwareWillEverNotify() {
        let bound = Set(Snap2InkPeer.uiDeclaration.buttons.map(\.button))
        for button in [CompanionButton.back, .confirm, .left, .right, .up, .down] {
            XCTAssertTrue(bound.contains(button), "\(button) has no binding")
        }
    }

    /// POWER stays firmware-owned in every app, so that a wedged app can never make a device
    /// un-sleepable. CompanionKit drops any entry for it; Snap2Ink does not offer one either.
    func test_buttonMap_doesNotAttemptToRemapPower() {
        XCTAssertFalse(Snap2InkPeer.uiDeclaration.buttons.contains { $0.button == .power })
    }

    /// The reader is across the room; making it a shutter is the one thing this pair of devices can
    /// do that neither can alone. If this binding disappears the app has lost its best feature.
    func test_backIsTheRemoteShutter() {
        let back = Snap2InkPeer.binding(for: .back)
        XCTAssertEqual(back?.routing, .remote)
        XCTAssertEqual(back?.label, "Shutter")
    }

    /// Local paging acts on buffered body text, of which a print has none. Binding these would draw
    /// page-turn hints over the photograph.
    func test_pagingButtonsAreDeadInThisApp() {
        XCTAssertEqual(Snap2InkPeer.binding(for: .left)?.routing, ButtonRouting.none)
        XCTAssertEqual(Snap2InkPeer.binding(for: .right)?.routing, ButtonRouting.none)
        XCTAssertEqual(Snap2InkPeer.binding(for: .left)?.label, "")
    }

    /// A remote toggle for the self-timer doesn't make sense — it's a phone-only control now (see
    /// `ViewfinderView`), not a device button.
    func test_confirmUpAndDownAreUnbound() {
        XCTAssertEqual(Snap2InkPeer.binding(for: .confirm)?.routing, ButtonRouting.none)
        XCTAssertEqual(Snap2InkPeer.binding(for: .up)?.routing, ButtonRouting.none)
        XCTAssertEqual(Snap2InkPeer.binding(for: .down)?.routing, ButtonRouting.none)
    }

    /// Every `.remote` binding has to have a handler in `PrintStudioModel`, and every handled button
    /// has to be declared `.remote` here, or the label the device draws is a lie.
    func test_everyRemoteButtonIsOneTheAppActuallyActsOn() {
        let remote = Snap2InkPeer.uiDeclaration.buttons.filter { $0.routing == .remote }.map(\.button)
        XCTAssertEqual(Set(remote), [.back])
        for entry in Snap2InkPeer.uiDeclaration.buttons where entry.routing == .remote {
            XCTAssertFalse(entry.label.isEmpty, "\(entry.button) notifies the phone but is unlabelled on screen")
        }
    }

    // MARK: - Icon

    func test_icon_packsToOneBitPerPixelAtTheAdvertisedSize() {
        XCTAssertEqual(
            DeviceIcon.encoded(width: 64, height: 64, expectedByteCount: 64 * 64 / 8)?.count,
            512,
            "64×64 at 1bpp is 512 bytes"
        )
        XCTAssertEqual(DeviceIcon.encoded(width: 32, height: 32, expectedByteCount: 32 * 32 / 8)?.count, 128)
    }

    /// The protocol guarantees the advertised icon width is always a multiple of 8, so every size a
    /// conforming device can ask for produces bytes. Checked across the plausible range rather than
    /// only at today's 64×64.
    func test_icon_isProducedForEveryByteAlignedWidthADeviceCouldAdvertise() {
        for size in [16, 24, 32, 48, 64, 96, 128] {
            XCTAssertEqual(
                DeviceIcon.encoded(width: size, height: size, expectedByteCount: size * size / 8)?.count,
                size * size / 8,
                "\(size)×\(size) should produce an icon"
            )
        }
    }

    /// The backstop, for a device that violates the width guarantee. Sending nothing costs a tile;
    /// sending a wrong-length asset costs a rejected enrolment asset and a confusing error.
    func test_icon_isWithheldRatherThanGuessedIfTheGuaranteeIsEverViolated() {
        XCTAssertNil(DeviceIcon.encoded(width: 60, height: 64, expectedByteCount: 60 * 64 / 8))
    }

    func test_icon_packsMostSignificantBitFirst() {
        // Only the leftmost pixel of the top row set → the first byte's high bit, and nothing else.
        var pixels = [Bool](repeating: false, count: 8 * 8)
        pixels[0] = true
        XCTAssertEqual(Array(DeviceIcon.packed(pixels, width: 8, height: 8)).first, 0x80)

        pixels[0] = false
        pixels[7] = true
        XCTAssertEqual(Array(DeviceIcon.packed(pixels, width: 8, height: 8)).first, 0x01, "the eighth pixel is the low bit")
    }

    func test_icon_isNeitherBlankNorSolid() {
        let pixels = DeviceIcon.bitmap(width: 64, height: 64)
        let inked = pixels.filter { $0 }.count

        XCTAssertGreaterThan(inked, pixels.count / 10, "an almost-empty tile is unreadable on the sleep screen")
        XCTAssertLessThan(inked, pixels.count * 3 / 4, "an almost-solid tile is equally unreadable")
    }

    /// The geometry is expressed in fractions of the canvas precisely so the device can ask for a
    /// dimension other than the 64×64 the design doc proposes — that number is still open.
    func test_icon_rendersAtAnySizeTheDeviceMightAskFor() {
        for size in [16, 32, 48, 64, 96] {
            let pixels = DeviceIcon.bitmap(width: size, height: size)
            XCTAssertEqual(pixels.count, size * size)
            XCTAssertTrue(pixels.contains(true), "size \(size) produced a blank icon")
            XCTAssertTrue(pixels.contains(false), "size \(size) produced a solid icon")
        }
    }
}
