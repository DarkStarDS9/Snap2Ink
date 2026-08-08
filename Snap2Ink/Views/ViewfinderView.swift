import SwiftUI

/// Viewfinder, shutter, flip. That is the entire capture surface, on purpose.
struct ViewfinderView: View {
    @ObservedObject var model: PrintStudioModel
    /// Where the focus reticle is currently shown, in `CameraPreview`'s local coordinates. `nil`
    /// hides it — it only appears briefly after a tap, not as a permanent crosshair.
    @State private var focusReticle: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.camera.isAvailable {
                    CameraPreview(
                        session: model.camera.session,
                        onFocusTap: { devicePoint, viewPoint in
                            model.camera.focus(at: devicePoint)
                            showFocusReticle(at: viewPoint)
                        },
                        onZoomBegan: { model.camera.beginZoomGesture() },
                        onZoomChanged: { scale in model.camera.updateZoomGesture(scale: scale) }
                    )
                } else {
                    NoCameraPlaceholder()
                }

                // The panel is 480×800; a landscape shot is rotated to print sideways across it
                // rather than cropped down to a portrait sliver, so this guide — drawn for the
                // portrait case — is an approximation for a landscape frame. It still shows exactly
                // what a portrait shot will keep, which is the common case.
                PrintFrameGuide(style: model.style)

                if let focusReticle {
                    FocusReticle()
                        .position(focusReticle)
                        .transition(.opacity)
                }

                if let countdown = model.countdown {
                    Text("\(countdown)")
                        .font(.system(size: 120, weight: .thin, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 12)
                        .transition(.scale.combined(with: .opacity))
                        .id(countdown)
                }
            }
            .clipped()

            controls
        }
        .animation(.easeOut(duration: 0.2), value: model.countdown)
        .animation(.easeOut(duration: 0.15), value: focusReticle)
    }

    private func showFocusReticle(at point: CGPoint) {
        focusReticle = point
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            focusReticle = nil
        }
    }

    private var controls: some View {
        VStack(spacing: 18) {
            if model.camera.isAvailable, !model.camera.lensSwitchZoomFactors.isEmpty {
                LensSwitchRow(camera: model.camera)
            }

            Picker("Frame", selection: $model.style) {
                ForEach(PrintStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 40)

            HStack {
                Button {
                    model.selfTimerSeconds = model.selfTimerSeconds > 0 ? 0 : 3
                } label: {
                    Label(
                        model.selfTimerSeconds > 0 ? "\(model.selfTimerSeconds)s" : "Off",
                        systemImage: "timer"
                    )
                    .font(.callout)
                }
                .tint(model.selfTimerSeconds > 0 ? .yellow : .white)
                .frame(maxWidth: .infinity)

                ShutterButton { model.shutter() }
                    #if DEBUG
                    // Long-press loads the calibration target instead of taking a photo. Hidden and
                    // DEBUG-only because it is a bring-up instrument rather than a feature — see
                    // MANUAL-DEVICE-TESTS.md § "The dither fidelity check".
                    .onLongPressGesture(minimumDuration: 1.0) { model.loadCalibrationTarget() }
                    #endif

                Button {
                    model.camera.flipCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title3)
                }
                .tint(.white)
                .frame(maxWidth: .infinity)
                .disabled(!model.camera.isAvailable)
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 24)
        .background(Color.black)
    }
}

/// Quick-tap buttons for each lens the current virtual camera device offers, e.g. 0.5×/1×/3× on a
/// triple-camera iPhone. This *is* lens switching on a multi-lens device — the OS hands off between
/// physical lenses as `videoZoomFactor` crosses these thresholds, there is no separate lens to pick.
private struct LensSwitchRow: View {
    @ObservedObject var camera: CameraController

    private var factors: [CGFloat] {
        ([camera.minZoomFactor] + camera.lensSwitchZoomFactors + [camera.displayZoomReferenceFactor])
            .sorted()
            .reduce(into: [CGFloat]()) { result, factor in
                // De-duplicate factors that round to the same button, e.g. the main lens's raw
                // factor already present via `lensSwitchZoomFactors`.
                if result.last.map({ abs($0 - factor) > 0.05 }) ?? true { result.append(factor) }
            }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(factors, id: \.self) { factor in
                Button {
                    camera.setZoom(factor)
                } label: {
                    Text(label(for: factor))
                        .font(.caption.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(isSelected(factor) ? Color.yellow : Color.white.opacity(0.2))
                        .foregroundStyle(isSelected(factor) ? .black : .white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func isSelected(_ factor: CGFloat) -> Bool {
        abs(camera.zoomFactor - factor) < 0.15
    }

    /// `factor` is a raw `videoZoomFactor`; what the button should say is that number relative to
    /// the main wide lens, which is what "0.5×"/"1×"/"3×" actually mean to a user.
    private func label(for factor: CGFloat) -> String {
        let display = factor / camera.displayZoomReferenceFactor
        return display.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(display))×"
            : String(format: "%.1f×", display)
    }
}

/// Briefly shown where the user tapped to focus — the same yellow square the stock Camera app draws,
/// so tap-to-focus reads as familiar rather than as a custom gesture nobody knew was there.
private struct FocusReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(.yellow, lineWidth: 1.5)
            .frame(width: 70, height: 70)
    }
}

private struct ShutterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 3).frame(width: 76, height: 76)
                Circle().fill(.white).frame(width: 62, height: 62)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Outlines the part of the viewfinder that will actually reach the panel.
private struct PrintFrameGuide: View {
    let style: PrintStyle

    var body: some View {
        GeometryReader { geometry in
            let layout = PrintLayout.layout(style: style, canvas: DisplayGeometry.assumedX3.pixels)
            let scale = min(
                geometry.size.width / Double(layout.canvas.width),
                geometry.size.height / Double(layout.canvas.height)
            )
            let width = Double(layout.photo.width) * scale
            let height = Double(layout.photo.height) * scale

            Rectangle()
                .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                .frame(width: width, height: height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .allowsHitTesting(false)
    }
}

private struct NoCameraPlaceholder: View {
    var body: some View {
        ZStack {
            Color(white: 0.12)
            VStack(spacing: 12) {
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 44, weight: .thin))
                Text("No camera here")
                    .font(.headline)
                Text("The shutter will use a test card instead, so the dither is still worth looking at.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
            }
            .foregroundStyle(.white.opacity(0.8))
        }
    }
}
