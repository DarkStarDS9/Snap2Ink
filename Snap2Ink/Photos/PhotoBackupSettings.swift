import Foundation

/// Whether/where Snap2Ink backs up the original photo behind every print to the user's Photos
/// library — see `PhotoBackupService`. A user setting, not a build flag: someone pairing a shared
/// reader may not want every print cluttering their camera roll, and someone who does may not want
/// it filed under a strange album name.
///
/// Follows the same `UserDefaults`-injectable-for-testing shape as `DitherAlgorithm.lastUsed` and
/// `Snap2InkPeer.userLabel`.
enum PhotoBackupSettings {
    static let defaultAlbumName = "Snap2Ink"

    private static let enabledDefaultsKey = "Snap2Ink.photoBackupEnabled"
    private static let usesAlbumDefaultsKey = "Snap2Ink.photoBackupUsesAlbum"
    private static let albumNameDefaultsKey = "Snap2Ink.photoBackupAlbumName"
    private static let hasPromptedDefaultsKey = "Snap2Ink.photoBackupHasPrompted"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledDefaultsKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledDefaultsKey)
    }

    /// `true` unless the user explicitly opted out of an album in favour of saving straight to the
    /// camera roll. Defaults to on, since "an album" is what the first-launch prompt offers.
    static func usesAlbum(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: usesAlbumDefaultsKey) as? Bool ?? true
    }

    static func setUsesAlbum(_ usesAlbum: Bool, defaults: UserDefaults = .standard) {
        defaults.set(usesAlbum, forKey: usesAlbumDefaultsKey)
    }

    static func albumName(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: albumNameDefaultsKey) ?? ""
        return stored.isEmpty ? defaultAlbumName : stored
    }

    static func setAlbumName(_ name: String, defaults: UserDefaults = .standard) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed, forKey: albumNameDefaultsKey)
    }

    /// Whether the one-time "back up your photos?" prompt has already been shown — see
    /// `StudioView`. Once true it never appears again, regardless of the answer given.
    static func hasPrompted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hasPromptedDefaultsKey)
    }

    static func setHasPrompted(_ prompted: Bool = true, defaults: UserDefaults = .standard) {
        defaults.set(prompted, forKey: hasPromptedDefaultsKey)
    }
}
