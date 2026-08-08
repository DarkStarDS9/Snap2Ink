import Foundation

struct PixelSize: Equatable {
    let width: Int
    let height: Int
}

struct PixelRect: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var size: PixelSize { PixelSize(width: width, height: height) }
}

/// How the photo sits on the panel.
enum PrintStyle: String, CaseIterable, Identifiable, Sendable {
    /// The photo fills the whole panel, edge to edge.
    case fullBleed
    /// A white border with a deep band along the bottom, carrying a caption — the classic
    /// instant-print look.
    case framed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullBleed: return "Full bleed"
        case .framed: return "Framed"
        }
    }
}

/// Where the photo and the caption go on the panel, in device pixels.
///
/// Pure arithmetic, kept apart from any rendering so the proportions can be asserted in tests and
/// so the layout does not have to be re-derived for the on-phone preview and the actual print.
///
/// A real instant-print frame is roughly 5:6; this panel is 3:5, far taller. Reproducing the
/// classic square image would leave an absurd expanse of white below it, so the photo aperture is
/// portrait (18:25) and the bottom band is sized to read as a caption strip rather than to match
/// the classic frame's exact ratio.
struct PrintLayout: Equatable {
    let canvas: PixelSize
    let photo: PixelRect
    /// The caption strip, or `nil` for `.fullBleed`, which has nowhere to put one.
    let caption: PixelRect?

    /// Border on the left, right and top of a `.framed` frame, at the panel's native 480px width.
    private static let referenceBorder = 24
    private static let referenceWidth = 480

    static func layout(style: PrintStyle, canvas: PixelSize) -> PrintLayout {
        switch style {
        case .fullBleed:
            return PrintLayout(
                canvas: canvas,
                photo: PixelRect(x: 0, y: 0, width: canvas.width, height: canvas.height),
                caption: nil
            )

        case .framed:
            // Scale the border with the panel so the frame keeps its proportions on a device whose
            // capability characteristic reports something other than 480×800.
            let border = max(4, referenceBorder * canvas.width / referenceWidth)
            let photoWidth = canvas.width - 2 * border
            // 18:25 — portrait, and tall enough that the caption band stays a band rather than
            // becoming half the print.
            let photoHeight = min(photoWidth * 25 / 18, canvas.height - 2 * border)
            let captionTop = border + photoHeight
            let captionHeight = canvas.height - captionTop

            return PrintLayout(
                canvas: canvas,
                photo: PixelRect(x: border, y: border, width: photoWidth, height: photoHeight),
                caption: captionHeight > border
                    ? PixelRect(x: border, y: captionTop, width: photoWidth, height: captionHeight)
                    : nil
            )
        }
    }
}
