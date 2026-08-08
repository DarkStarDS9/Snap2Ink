import Foundation

/// An 8-bit grayscale raster, row-major, one byte per pixel, no padding. The working currency of
/// the whole print pipeline: `ImagePreparer` produces one from a camera frame, `Ditherer` consumes
/// one and returns another, `PrintPipeline` blits them together, and `ImagePacker` serialises the
/// final one. Deliberately a plain value type with no Core Graphics dependency so every stage
/// between capture and encode is testable without a rendering context.
struct GrayImage: Equatable {
    let width: Int
    let height: Int
    /// `height * width` bytes, row-major. Index `y * width + x`.
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "GrayImage must have positive dimensions")
        precondition(pixels.count == width * height, "pixel buffer must be exactly width * height bytes")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int, filledWith value: UInt8) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: value, count: width * height))
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Copies `source` into this image with its top-left corner at (`originX`, `originY`). Pixels
    /// falling outside the destination are dropped rather than trapping — the caller's layout maths
    /// is checked by `PrintLayout`, and a rounding error here should produce a slightly clipped
    /// print, not a crash in the user's hands mid-shoot.
    mutating func blit(_ source: GrayImage, atX originX: Int, y originY: Int) {
        for sy in 0..<source.height {
            let dy = originY + sy
            guard dy >= 0, dy < height else { continue }
            for sx in 0..<source.width {
                let dx = originX + sx
                guard dx >= 0, dx < width else { continue }
                self[dx, dy] = source[sx, sy]
            }
        }
    }

    /// Rotates 90° counter-clockwise, swapping width and height. How a landscape photo reaches its
    /// portrait aperture in the panel's frame — this direction, specifically, because the phone's
    /// physical orientation and the panel's fixed orientation are related by a counter-clockwise
    /// turn, not a clockwise one; the other direction prints the photo upside down.
    func rotated90CounterClockwise() -> GrayImage {
        let newWidth = height
        let newHeight = width
        var rotated = [UInt8](repeating: 0, count: newWidth * newHeight)
        for y in 0..<height {
            for x in 0..<width {
                let newX = y
                let newY = width - 1 - x
                rotated[newY * newWidth + newX] = self[x, y]
            }
        }
        return GrayImage(width: newWidth, height: newHeight, pixels: rotated)
    }
}
