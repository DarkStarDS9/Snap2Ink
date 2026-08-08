import AVFoundation
import SwiftUI

/// The live viewfinder. A thin wrapper over `AVCaptureVideoPreviewLayer` — SwiftUI has no native
/// equivalent, and rendering frames through `Image` would cost far more than it bought.
///
/// Also where pinch-to-zoom and tap-to-focus attach: both need the preview layer itself, either to
/// convert a tap into a device point or to receive a `UIPinchGestureRecognizer`, so it is simpler for
/// this view to own the gesture recognizers than to hand the layer out to a SwiftUI gesture.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Fired on a tap with both the device point — in `(0, 0)`–`(1, 1)`, ready to pass straight to
    /// `CameraController.focus(at:)` — and the raw point in the view's own coordinate space, for
    /// positioning a focus reticle in the SwiftUI overlay above this view.
    let onFocusTap: (_ devicePoint: CGPoint, _ viewPoint: CGPoint) -> Void
    let onZoomBegan: () -> Void
    let onZoomChanged: (CGFloat) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocusTap = onFocusTap
        view.onZoomBegan = onZoomBegan
        view.onZoomChanged = onZoomChanged
        view.installGestures()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.onFocusTap = onFocusTap
        uiView.onZoomBegan = onZoomBegan
        uiView.onZoomChanged = onZoomChanged
    }

    /// A UIView whose backing layer *is* the preview layer, so it resizes with the view for free
    /// rather than needing a frame update in `layoutSubviews`.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // swiftlint:disable:next force_cast
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var onFocusTap: ((_ devicePoint: CGPoint, _ viewPoint: CGPoint) -> Void)?
        var onZoomBegan: (() -> Void)?
        var onZoomChanged: ((CGFloat) -> Void)?

        private var gesturesInstalled = false

        /// Idempotent: `makeUIView` calls it once, but guarding here means a future caller that
        /// re-adds gestures on `updateUIView` cannot end up with two of each recognizer.
        func installGestures() {
            guard !gesturesInstalled else { return }
            gesturesInstalled = true
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
            addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch)))
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: self)
            onFocusTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: point), point)
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                onZoomBegan?()
                onZoomChanged?(gesture.scale)
            case .changed:
                onZoomChanged?(gesture.scale)
            default:
                break
            }
        }
    }
}
