import CompanionKit
import Foundation

/// Who Snap2Ink is to a companion display, and what it tells the device about itself.
///
/// The types here — `CompanionIdentity`, `ButtonMap`, `CompanionAssetProvider` — come from
/// CompanionKit, which ships inside the firmware repo alongside the wire format it implements. This
/// file is only Snap2Ink's *configuration* of them; the encoding, tagging and handshake are the
/// library's, and deliberately not reimplemented here.
enum Snap2InkPeer {

    /// **Snap2Ink's permanent application id. Never change this value.**
    ///
    /// It is identical across every install and every version of the app, forever: it is what makes
    /// two phones running Snap2Ink group into one tile on the device's sleep screen, and changing it
    /// would orphan every existing pairing on every device in the world, with no way to clean them
    /// up — unpairing is on-device only, there is no protocol opcode for "forget me".
    ///
    /// Derived reproducibly rather than picked at random, matching how SpokenFeeds derives its own:
    ///
    /// ```
    /// uuid5(NAMESPACE_DNS, "app.snap2ink.camera") == d742c301-e39c-5af0-81d1-2517a49048ad
    /// ```
    ///
    /// Anyone can regenerate it from the app's reverse-DNS name and confirm it, which a magic
    /// constant does not allow. The firmware compares sixteen opaque bytes and never parses them —
    /// the UUIDv5 structure is purely for humans.
    static let appId = UUID(uuidString: "D742C301-E39C-5AF0-81D1-2517A49048AD")!

    /// Shown in the device's pairing prompt ("Pair with Snap2Ink?"). Deliberately short — it is
    /// drawn on a 480px-wide e-ink panel.
    static let displayName = "Snap2Ink"

    /// Snap2Ink's button scheme, and the reasoning behind it.
    ///
    /// **Mandatory, not polish**: the device refuses `ACQUIRE` from a peer with no stored map, so an
    /// app with undefined buttons cannot reach the screen at all.
    ///
    /// The device is across the room, propped up, showing a photo. That is what makes a
    /// **remote shutter** the most valuable binding in the app — the phone can be set down as the
    /// camera and the reader becomes the trigger, which is the one thing this pair of devices can do
    /// that neither can alone. It lives on `back` rather than `confirm`.
    ///
    /// - `confirm` is `.none`. A remote toggle for the self-timer doesn't make sense — you're
    ///   holding the phone to set that, not standing across the room — so it stays a phone-only
    ///   control (see `ViewfinderView`) and isn't bound to a device button at all.
    /// - `left`/`right` are `.none`. Their local paging routings act on buffered *body text*, and a
    ///   print has none; binding them would draw a page-turn hint over a photograph.
    /// - `up`/`down` are `.localGalleryPrevious`/`.localGalleryNext`, unflagged. Gallery navigation is
    ///   app-declared, like the list screen's — leaving these `.none` would make the on-device gallery
    ///   picker inert for Snap2Ink installs. They only run while the device is actually showing the
    ///   local gallery (offline browse is its own boot mode, radio off), so there is no connected-state
    ///   behavior to preserve and no flags are needed.
    /// - `back` stays `.remote` while connected — that's the Shutter — but also carries `.localBack`
    ///   with `[.alsoNotify, .localOnlyOffline]`: connected, it only notifies (Shutter, unchanged);
    ///   offline and browsing, `.localOnlyOffline` runs the local action instead (leave the gallery
    ///   back to the picker), and `.alsoNotify`'s notify side is moot with no peer connected to receive
    ///   it. One binding, two lives, no button traded away.
    ///
    /// The side buttons' labels are stored but not currently drawn by the firmware (they have no
    /// hint position). They are set anyway: the labels are what a future firmware would draw, and a
    /// button whose label exists only in this comment is a button nobody can discover.
    ///
    /// `capabilities: .imageGallery` declares that Snap2Ink pushes a photo gallery the device can
    /// browse locally (protocol v8's on-device gallery picker) — without it, paired Snap2Ink installs
    /// don't show up as selectable tiles on the device's sleep-screen grid.
    static let uiDeclaration = UiDeclaration(shape: .image, buttons: [
        ButtonMapEntry(.back, .localBack, label: "Shutter", flags: [.alsoNotify, .localOnlyOffline]),
        ButtonMapEntry(.confirm, .none),
        ButtonMapEntry(.left, .none),
        ButtonMapEntry(.right, .none),
        ButtonMapEntry(.up, .localGalleryPrevious, label: ButtonLabels.up),
        ButtonMapEntry(.down, .localGalleryNext, label: ButtonLabels.down),
    ], capabilities: .imageGallery)

    static func binding(for button: CompanionButton) -> ButtonMapEntry? {
        uiDeclaration.buttons.first { $0.button == button }
    }

    private static let userLabelDefaultsKey = "Snap2Ink.userLabel"

    /// What this install calls itself on the device's gallery picker — distinct from `displayName`,
    /// which is identical across every install. Two people pairing the same reader both show up as
    /// "iPhone" under CompanionKit's own default (`UIDevice.current.name` returns a generic
    /// placeholder on iOS 16+ unless an app holds a restricted entitlement Snap2Ink has no case for),
    /// so without this they're indistinguishable in the picker. Empty means "not set yet."
    static func userLabel(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: userLabelDefaultsKey) ?? ""
    }

    /// Persists the label. Purely presentational — see `CompanionIdentity.userName` — so this is
    /// safe to change at any time, unlike `appId`/`installId`. Takes effect the next time Snap2Ink
    /// launches: `identity()` is read once at app start (see `Snap2InkApp.makeTransport()`), and
    /// `CompanionClient` holds it for its whole lifetime.
    static func setUserLabel(_ label: String, defaults: UserDefaults = .standard) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: userLabelDefaultsKey)
        } else {
            defaults.set(trimmed, forKey: userLabelDefaultsKey)
        }
    }

    /// This install's identity, with the `installId` minted into `UserDefaults` by CompanionKit.
    ///
    /// `UserDefaults` rather than the Keychain is a platform-wide decision, shared with SpokenFeeds:
    /// a Keychain item outlives app deletion, so a fresh install would silently re-attach to the
    /// peer directory the previous one left on the device.
    ///
    /// The cost, worth knowing: every delete-and-reinstall becomes a new peer, which means a new
    /// on-device pairing confirmation and a peer directory on the SD card that nothing will ever
    /// reclaim — unpairing is on-device only. That is the accepted trade, not an oversight.
    static func identity(defaults: UserDefaults = .standard) -> CompanionIdentity {
        let label = userLabel(defaults: defaults)
        return CompanionIdentity(
            appId: appId,
            displayName: displayName,
            userName: label.isEmpty ? CompanionIdentity.defaultUserName : label,
            defaults: defaults
        )
    }
}

/// Supplies the two per-peer assets the device stores and versions by tag.
///
/// Not `StaticAssetProvider`, because the icon is *rendered* to whatever dimensions the device
/// advertises rather than shipped at a fixed size — see `DeviceIcon`. 64×64 (512 bytes) is what the
/// protocol document records as today's size, but it is advertised per device precisely so it can
/// change, and a wrong length is rejected outright with `ASSET_ACK(REJECTED_SIZE)`.
final class Snap2InkAssetProvider: CompanionAssetProvider, @unchecked Sendable {
    var uiDeclaration: UiDeclaration { Snap2InkPeer.uiDeclaration }

    func icon(for capabilities: CompanionCapabilities) -> Data? {
        DeviceIcon.encoded(
            width: capabilities.iconPixelWidth,
            height: capabilities.iconPixelHeight,
            expectedByteCount: capabilities.iconByteCount
        )
    }
}
