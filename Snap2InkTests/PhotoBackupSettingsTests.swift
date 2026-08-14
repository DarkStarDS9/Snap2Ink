import XCTest
@testable import Snap2Ink

/// The photo-backup toggle, album choice and first-launch prompt should survive an app restart —
/// same contract as `DitherAlgorithmPersistenceTests`, for a different setting.
final class PhotoBackupSettingsTests: XCTestCase {

    func test_isEnabled_withNothingSaved_defaultsToFalse() {
        let defaults = Self.scratchDefaults()
        XCTAssertFalse(PhotoBackupSettings.isEnabled(defaults: defaults))
    }

    func test_setEnabled_persistsAcrossReads() {
        let defaults = Self.scratchDefaults()
        PhotoBackupSettings.setEnabled(true, defaults: defaults)
        XCTAssertTrue(PhotoBackupSettings.isEnabled(defaults: defaults))
    }

    /// Opt-out has to be the deliberate act — a fresh install with the feature never configured
    /// must never silently write to the user's Photos library.
    func test_isEnabled_defaultsToOff_soAFreshInstallNeverBacksUpWithoutConsent() {
        let defaults = Self.scratchDefaults()
        XCTAssertFalse(PhotoBackupSettings.isEnabled(defaults: defaults))
    }

    func test_usesAlbum_withNothingSaved_defaultsToTrue() {
        let defaults = Self.scratchDefaults()
        XCTAssertTrue(PhotoBackupSettings.usesAlbum(defaults: defaults))
    }

    func test_setUsesAlbum_toFalse_persists() {
        let defaults = Self.scratchDefaults()
        PhotoBackupSettings.setUsesAlbum(false, defaults: defaults)
        XCTAssertFalse(PhotoBackupSettings.usesAlbum(defaults: defaults))
    }

    func test_albumName_withNothingSaved_fallsBackToTheDefaultName() {
        let defaults = Self.scratchDefaults()
        XCTAssertEqual(PhotoBackupSettings.albumName(defaults: defaults), PhotoBackupSettings.defaultAlbumName)
    }

    func test_setAlbumName_persistsAndTrims() {
        let defaults = Self.scratchDefaults()
        PhotoBackupSettings.setAlbumName("  Trips  ", defaults: defaults)
        XCTAssertEqual(PhotoBackupSettings.albumName(defaults: defaults), "Trips")
    }

    /// An empty name (the user cleared the field) falls back to the default rather than saving
    /// into a nameless/untitled album.
    func test_setAlbumName_toEmptyString_fallsBackToTheDefaultName() {
        let defaults = Self.scratchDefaults()
        PhotoBackupSettings.setAlbumName("Trips", defaults: defaults)
        PhotoBackupSettings.setAlbumName("   ", defaults: defaults)
        XCTAssertEqual(PhotoBackupSettings.albumName(defaults: defaults), PhotoBackupSettings.defaultAlbumName)
    }

    func test_hasPrompted_withNothingSaved_defaultsToFalse() {
        let defaults = Self.scratchDefaults()
        XCTAssertFalse(PhotoBackupSettings.hasPrompted(defaults: defaults))
    }

    func test_setHasPrompted_persists() {
        let defaults = Self.scratchDefaults()
        PhotoBackupSettings.setHasPrompted(defaults: defaults)
        XCTAssertTrue(PhotoBackupSettings.hasPrompted(defaults: defaults))
    }

    // MARK: - Helpers

    private static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "snap2ink.tests.\(UUID().uuidString)")!
    }
}
