import SwiftUI

/// The proof: exactly the pixels the panel is about to show, at whatever size the phone can give
/// them, plus the one decision worth making before committing — which dither.
///
/// A print takes the better part of ten seconds and there is no undo, so it is worth a screen.
struct ProofView: View {
    @ObservedObject var model: PrintStudioModel

    var body: some View {
        VStack(spacing: 0) {
            proofImage
                .frame(maxHeight: .infinity)
                .padding(.vertical, 16)

            controls
        }
    }

    @ViewBuilder
    private var proofImage: some View {
        if let proof = model.proof, let cgImage = proof.image.makeCGImage() {
            Image(decorative: cgImage, scale: 1.0)
                // Nearest-neighbour, not smoothing: the whole point of the proof is that the user
                // sees the actual dither pattern. Interpolating it would blur exactly the thing
                // they are choosing between.
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .background(.white)
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                .opacity(model.isRendering ? 0.45 : 1.0)
                .animation(.easeOut(duration: 0.15), value: model.isRendering)
        } else {
            ProgressView().tint(.white)
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Picker("Dither", selection: $model.algorithm) {
                    ForEach(DitherAlgorithm.allCases) { algorithm in
                        Text(algorithm.displayName).tag(algorithm)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.algorithm.summary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }

            if let proof = model.proof {
                // Size is not decoration here: it is the number that decides whether the print fits
                // under the device's cap, and it varies by several-fold across the algorithms.
                Text("\(proof.byteCount / 1024) KB · \(proof.image.width)×\(proof.image.height)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }

            captureDebugStrip

            HStack(spacing: 14) {
                Button("Retake") { model.retake() }
                    .buttonStyle(.bordered)
                    .tint(.white)

                Button("Rotate") { model.cycleManualRotation() }
                    .buttonStyle(.bordered)
                    .tint(.white)

                Button("Send to reader") { model.send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.proof == nil || !isReady)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    /// A stand-in for a faster confirmation loop than another TestFlight build, kept around for
    /// whatever the next orientation surprise turns out to be. Shows both quarter-turn values
    /// `CameraController` supplied for this shot (raw-buffer correction and photo-aperture rotation —
    /// see their doc comments for why these are two separate numbers), and whether the "Rotate"
    /// button below is currently overriding the aperture value.
    @ViewBuilder
    private var captureDebugStrip: some View {
        if let info = model.camera.lastCaptureDebugInfo {
            Text(
                "capture \(info.rawWidth)×\(info.rawHeight) · \(info.deviceOrientation.debugName)"
                    + " · raw \(info.appliedQuarterTurns)⟲"
                    + " · photo \(info.photoApertureQuarterTurns)⟲"
                    + (model.manualRotationOverride.map { " (override \($0)⟲)" } ?? "")
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.yellow.opacity(0.8))
        }
    }

    private var isReady: Bool {
        if case .ready = model.transportState { return true }
        return false
    }
}
