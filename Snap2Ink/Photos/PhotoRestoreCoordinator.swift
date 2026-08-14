import CoreGraphics
import Foundation
import Photos

/// Drives "restore from Photos": the user picks photos previously backed up by
/// `PhotoBackupService`, and each one that still carries its dither metadata is resent to the
/// reader through the same capture → proof → send stages a live photo takes — see
/// `PrintStudioModel.restoreAndSend` — so watching a batch arrive looks like a sequence of
/// ordinary prints, not a hidden background job.
@MainActor
final class PhotoRestoreCoordinator: ObservableObject {
    @Published var isPickerPresented = false
    @Published private(set) var isRestoring = false
    @Published var summaryMessage: String?

    private let model: PrintStudioModel

    init(model: PrintStudioModel) {
        self.model = model
    }

    func present() {
        isPickerPresented = true
    }

    func handleSelection(_ assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        Task { await restore(assets) }
    }

    private func restore(_ assets: [PHAsset]) async {
        isRestoring = true
        defer { isRestoring = false }

        let startingAlgorithm = model.algorithm
        var sent = 0
        var skipped = 0
        var stoppedEarly = false

        for asset in assets {
            guard let data = await Self.loadImageData(from: asset),
                  let algorithm = PhotoBackupService.algorithm(fromImageData: data),
                  let image = PhotoBackupService.image(fromImageData: data)
            else {
                skipped += 1
                continue
            }

            let succeeded = await model.restoreAndSend(image: image, algorithm: algorithm)
            guard succeeded else {
                // The reader dropped out from under a real send, not a metadata problem — leave the
                // model on that failed proof (its own error alert already explains why) rather than
                // firing the rest of the batch at a link that just failed.
                stoppedEarly = true
                break
            }
            sent += 1
            // A beat so a batch of resends still reads as a sequence of prints arriving one at a
            // time, matching the pace of watching any single print develop.
            try? await Task.sleep(for: .seconds(1))
        }

        if !stoppedEarly {
            model.retake()
            model.resetAlgorithm(to: startingAlgorithm)
        }

        var parts: [String] = []
        if sent > 0 { parts.append("Sent \(sent).") }
        if skipped > 0 { parts.append("\(skipped) skipped — no Snap2Ink backup data.") }
        if stoppedEarly { parts.append("Stopped after your reader had a problem.") }
        summaryMessage = parts.isEmpty ? "Nothing to send." : parts.joined(separator: " ")
    }

    /// Reads `asset`'s original, unedited bytes — what `PhotoBackupService.algorithm(fromImageData:)`
    /// needs, since a re-encoded/downsampled representation (what `requestImage` would hand back)
    /// can lose the EXIF comment entirely. Snap2Ink's own backups are never edited, so "original"
    /// here just means "the file as Photos stored it".
    private static func loadImageData(from asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .original
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
