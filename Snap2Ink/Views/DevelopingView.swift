import SwiftUI

/// The wait, made the point rather than hidden behind it.
///
/// Sending a 40 KB print over this link takes several seconds, and the panel's two-pass grayscale
/// settle takes several more. A spinner would be an apology for that. Instead the print emerges out
/// of white at exactly the rate the bytes are actually arriving, so the progress bar and the picture
/// are the same indicator — and the brief inversion at the start is what the real panel does when it
/// begins a full refresh, not an invention.
struct DevelopingView: View {
    @ObservedObject var model: PrintStudioModel

    /// 0 = blank paper, 1 = fully developed.
    @State private var reveal: Double = 0
    /// The panel's refresh flash, mimicked for the moment the device starts drawing.
    @State private var isFlashing = false

    /// Bytes arriving only get the print a quarter of the way there. The rest is the panel settling,
    /// which is where the actual "developing" happens and where most of the wait is.
    private let revealDuringTransfer = 0.25

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            print
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)

            statusLine

            Spacer(minLength: 0)

            if model.stage == .printed {
                HStack(spacing: 14) {
                    Button("Take another") { model.retake() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    Button("Send again") { model.send() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 24)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onAppear { syncReveal(to: model.transportState) }
        .onChange(of: model.transportState) { _, state in syncReveal(to: state) }
        .animation(.easeOut(duration: 0.3), value: model.stage)
    }

    @ViewBuilder
    private var print: some View {
        if let proof = model.proof, let cgImage = proof.image.makeCGImage() {
            ZStack {
                Color.white
                Image(decorative: cgImage, scale: 1.0)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(reveal)
                    // Lifting brightness towards white early on makes the midtones arrive last,
                    // which is the order a real print resolves in — highlights first, shadows last.
                    .brightness((1.0 - reveal) * 0.4)
                    // The panel's refresh flash. Done as a difference-blended overlay rather than a
                    // conditional `.colorInvert()` because branching a modifier inside a ViewBuilder
                    // gives the two branches different view identities, and SwiftUI would tear the
                    // image down and rebuild it mid-animation instead of flashing it.
                    .overlay(Color.white.blendMode(.difference).opacity(isFlashing ? 1 : 0))
            }
            .aspectRatio(
                Double(proof.image.width) / Double(proof.image.height),
                contentMode: .fit
            )
            .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
        }
    }

    private var statusLine: some View {
        VStack(spacing: 10) {
            Text(caption)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))

            if case .sending(let progress) = model.transportState {
                ProgressView(value: progress)
                    .tint(.white)
                    .frame(width: 200)
            }
        }
    }

    private var caption: String {
        switch model.transportState {
        case .sending: return "Sending to your reader…"
        case .developing: return "Developing…"
        default: return model.stage == .printed ? "It's on your reader." : "Waiting for your reader…"
        }
    }

    private func syncReveal(to state: TransportState) {
        switch state {
        case .sending(let progress):
            withAnimation(.linear(duration: 0.2)) {
                reveal = progress * revealDuringTransfer
            }

        case .developing:
            // The panel inverts briefly as it starts a full refresh.
            isFlashing = true
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                isFlashing = false
                // easeIn, not easeOut: an e-ink grayscale settle stays faint for most of its
                // duration and then resolves quickly at the end.
                withAnimation(.easeIn(duration: 4.0)) { reveal = 1.0 }
            }

        default:
            if model.stage == .printed {
                withAnimation(.easeOut(duration: 0.3)) { reveal = 1.0 }
            }
        }
    }
}
