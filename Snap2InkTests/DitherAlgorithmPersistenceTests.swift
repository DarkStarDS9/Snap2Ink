import XCTest
@testable import Snap2Ink

/// The dithering mode a user picks should survive an app restart rather than silently reverting to
/// the default every launch.
final class DitherAlgorithmPersistenceTests: XCTestCase {

    func test_lastUsed_withNothingSaved_defaultsToAtkinson() {
        let defaults = Self.scratchDefaults()
        XCTAssertEqual(DitherAlgorithm.lastUsed(defaults: defaults), .atkinson)
    }

    func test_setLastUsed_persistsAcrossReads() {
        let defaults = Self.scratchDefaults()

        DitherAlgorithm.setLastUsed(.orderedBayer, defaults: defaults)

        XCTAssertEqual(DitherAlgorithm.lastUsed(defaults: defaults), .orderedBayer)
    }

    func test_setLastUsed_overwritesAPreviousChoice() {
        let defaults = Self.scratchDefaults()

        DitherAlgorithm.setLastUsed(.floydSteinberg, defaults: defaults)
        DitherAlgorithm.setLastUsed(.none, defaults: defaults)

        XCTAssertEqual(DitherAlgorithm.lastUsed(defaults: defaults), .none)
    }

    /// A raw value that no longer maps to a case (e.g. saved by a build that had a case this one
    /// doesn't) must fall back to the default rather than crash or silently pick an arbitrary case.
    func test_lastUsed_withUnrecognizedRawValue_fallsBackToAtkinson() {
        let defaults = Self.scratchDefaults()
        defaults.set("someRemovedCase", forKey: "Snap2Ink.lastUsedDitherAlgorithm")

        XCTAssertEqual(DitherAlgorithm.lastUsed(defaults: defaults), .atkinson)
    }

    // MARK: - Helpers

    /// A throwaway `UserDefaults` suite, so these tests neither read nor clobber a real install's
    /// saved choice.
    private static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "snap2ink.tests.\(UUID().uuidString)")!
    }
}
