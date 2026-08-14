import CoreGraphics
import Foundation
import PhotosUI
import UniformTypeIdentifiers

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

    func handlePickerResults(_ results: [PHPickerResult]) {
        guard !results.isEmpty else { return }
        Task { await restore(results) }
    }

    private func restore(_ results: [PHPickerResult]) async {
        isRestoring = true
        defer { isRestoring = false }

        let startingAlgorithm = model.algorithm
        var sent = 0
        var skipped = 0
        var stoppedEarly = false

        for result in results {
            guard let data = await Self.loadImageData(from: result.itemProvider),
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

    /// Reads the file `provider` refers to and returns its raw bytes, which is what
    /// `PhotoBackupService.algorithm(fromImageData:)` needs — a re-encoded/downsampled
    /// representation (what `loadObject(ofClass: UIImage.self)` would hand back) can lose the EXIF
    /// comment entirely.
    private static func loadImageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
                continuation.resume(returning: nil)
                return
            }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                guard let url, error == nil, let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
