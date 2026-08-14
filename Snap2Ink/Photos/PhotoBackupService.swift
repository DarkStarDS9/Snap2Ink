import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Saves the original photo behind a print to the user's Photos library, tagged with the dither
/// algorithm it was printed with, and reads that tag back — see `PhotoRestoreCoordinator`.
///
/// The tag lives in the EXIF `UserComment` field rather than a side file or a local database: the
/// backup's whole point is to survive Snap2Ink being deleted and reinstalled, or the user moving
/// the photo out of its album, so it has to travel inside the image itself.
enum PhotoBackupService {
    enum BackupError: Error {
        case authorizationDenied
        case encodingFailed
    }

    /// The marker prefixed to every EXIF comment Snap2Ink writes, so a restore can tell "this photo
    /// has our metadata" from "this EXIF comment happens to contain the word algorithm" — and so a
    /// photo from any other app is safely treated as untagged rather than misread.
    private static let metadataMarker = "Snap2Ink/1"

    // MARK: - Authorization

    /// Requests add-only access: permission to create new assets/albums, without being able to see
    /// anything already in the library. That is deliberately all this feature ever asks for — see
    /// `findAlbum(named:)` below for what it costs.
    static func requestAddOnlyAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    private static func hasAddOnlyAuthorization() -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Requests full read/write access — what `AlbumPhotoPicker` needs to browse the configured
    /// backup album directly, rather than the whole-library chrome `PHPickerViewController` used
    /// to require. A separate, later ask from `requestAddOnlyAuthorization` above: a user who
    /// never restores a backup never has to grant it.
    static func requestReadAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static func readAuthorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: - Save

    /// Encodes `image` as a JPEG carrying `algorithm` in its EXIF, and adds it to the library —
    /// into the configured album (creating it if needed) unless the user turned that off in
    /// `PhotoBackupSettings`.
    static func save(image: CGImage, algorithm: DitherAlgorithm) async throws {
        guard hasAddOnlyAuthorization() else { throw BackupError.authorizationDenied }
        let data = try encode(image, algorithm: algorithm)

        let albumName = PhotoBackupSettings.usesAlbum() ? PhotoBackupSettings.albumName() : nil
        // Fetched before the transaction: `PHAssetCollectionChangeRequest` needs the collection
        // object itself, and fetching cannot happen inside `performChanges`.
        let existingAlbum = albumName.flatMap(findAlbum(named:))

        try await PHPhotoLibrary.shared().performChanges {
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: data, options: nil)
            guard let albumName, let placeholder = creationRequest.placeholderForCreatedAsset else { return }

            if let existingAlbum, let addRequest = PHAssetCollectionChangeRequest(for: existingAlbum) {
                addRequest.addAssets([placeholder] as NSArray)
            } else {
                let albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                albumRequest.addAssets([placeholder] as NSArray)
            }
        }
    }

    /// Under add-only access (the `save(image:algorithm:)` path above) this only ever surfaces
    /// asset collections *this app created* — that's the whole trade for not asking for full
    /// library access there. It means an album a user made by hand with the same name is invisible
    /// to that path and gets shadowed by one Snap2Ink creates itself. Under full read access (the
    /// `AlbumPhotoPicker` browsing path) the same fetch can see any album with a matching title.
    private static func findAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject
    }

    // MARK: - Browsing

    /// The assets in the configured backup album, for `AlbumPhotoPicker` to display — `nil` if the
    /// album doesn't exist yet (e.g. before the first backup-into-an-album has happened). Requires
    /// full read authorization; callers should check `readAuthorizationStatus()` first.
    static func fetchBackupAlbumAssets(albumName: String) -> PHFetchResult<PHAsset>? {
        guard let album = findAlbum(named: albumName) else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(in: album, options: options)
    }

    /// Not `private`: `PhotoBackupServiceTests` exercises the encode/decode round trip directly,
    /// without going through `PHPhotoLibrary` — the point being tested is "does our own EXIF tag
    /// survive being written and read back", not Photos framework behaviour, and driving it through
    /// the real library would need authorization no test environment reliably has.
    static func encode(_ image: CGImage, algorithm: DitherAlgorithm) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw BackupError.encodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "\(metadataMarker) algorithm=\(algorithm.rawValue)",
            ],
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BackupError.encodingFailed }
        return data as Data
    }

    // MARK: - Restore

    /// The dither algorithm recorded in `data`'s EXIF, or `nil` if it was never printed by
    /// Snap2Ink (no marker), or was printed by a build old enough — or new enough — that its
    /// algorithm no longer matches a known case.
    static func algorithm(fromImageData data: Data) -> DitherAlgorithm? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let comment = exif[kCGImagePropertyExifUserComment] as? String,
              comment.hasPrefix(metadataMarker),
              let range = comment.range(of: "algorithm=")
        else {
            return nil
        }
        let rawValue = comment[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return DitherAlgorithm(rawValue: String(rawValue))
    }

    /// Decodes `data` back into the `CGImage` a restore hands to `PrintStudioModel.restoreAndSend`.
    static func image(fromImageData data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
