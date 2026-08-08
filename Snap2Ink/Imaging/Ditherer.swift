import Foundation

/// Turns a continuous-tone grayscale image into one using only the panel's four levels.
///
/// Pure functions over `GrayImage`, with no Core Graphics, no concurrency and no I/O — the output
/// for a given input is fully determined, which is what makes the "every output pixel is in
/// `{0, 85, 170, 255}`" invariant something tests can assert rather than something the app has to
/// hope for.
enum Ditherer {

    /// Dithers `image` and returns a new one whose every pixel is one of `Quantizer.levels`.
    static func dither(_ image: GrayImage, using algorithm: DitherAlgorithm) -> GrayImage {
        switch algorithm {
        case .atkinson:
            return diffuse(image, kernel: .atkinson)
        case .floydSteinberg:
            return diffuse(image, kernel: .floydSteinberg)
        case .orderedBayer:
            return ordered(image)
        case .none:
            return flat(image)
        }
    }

    // MARK: - Error diffusion

    /// One forward raster pass, carrying quantization error into not-yet-visited neighbours.
    ///
    /// The accumulator is `[Int]`, not `[UInt8]`: on a hard edge the running error routinely pushes
    /// a pixel's working value below 0 or above 255, and clamping it into a byte at that point
    /// would silently discard error the kernel is supposed to keep propagating. Clamping happens
    /// once, at the moment a level is chosen (`Quantizer.levelIndex(for:)`).
    private static func diffuse(_ image: GrayImage, kernel: DiffusionKernel) -> GrayImage {
        let width = image.width
        let height = image.height
        var working = image.pixels.map(Int.init)
        var output = [UInt8](repeating: 0, count: working.count)

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let old = working[index]
                let new = Quantizer.nearestLevel(old)
                output[index] = new

                let error = old - Int(new)
                if error == 0 { continue }

                for tap in kernel.taps {
                    let nx = x + tap.dx
                    let ny = y + tap.dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    // Integer division truncates toward zero, so error leaks by up to one unit per
                    // tap. At a level step of 85 that is far below anything the panel can show, and
                    // keeping this in integers avoids the float accumulation drift that would make
                    // the preview and a re-run disagree.
                    working[ny * width + nx] += error * tap.weight / kernel.divisor
                }
            }
        }

        return GrayImage(width: width, height: height, pixels: output)
    }

    // MARK: - Ordered

    /// Classic 4×4 Bayer matrix, values 0...15 in the order that maximises the distance between
    /// successive thresholds.
    static let bayerMatrix4x4: [[Int]] = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
    ]

    /// Nudges each pixel up or down by a position-dependent fraction of one level step before
    /// snapping it, so flat midtones break into a regular hatch instead of a solid block. No state
    /// travels between pixels, which is why this compresses so much better than diffusion: the
    /// output is periodic, and deflate is very good at periodic.
    private static func ordered(_ image: GrayImage) -> GrayImage {
        var output = image
        let half = Quantizer.levelStep / 2

        for y in 0..<image.height {
            for x in 0..<image.width {
                let threshold = bayerMatrix4x4[y % 4][x % 4]
                // Maps the matrix cell into roughly (-half, +half) of one level step.
                let bias = (threshold * Quantizer.levelStep) / 16 - half
                output[x, y] = Quantizer.nearestLevel(Int(image[x, y]) + bias)
            }
        }

        return output
    }

    // MARK: - Flat

    private static func flat(_ image: GrayImage) -> GrayImage {
        var output = image
        output.pixels = image.pixels.map { Quantizer.nearestLevel(Int($0)) }
        return output
    }
}
