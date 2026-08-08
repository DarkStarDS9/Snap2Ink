import Foundation

/// Serialises a four-level `GrayImage` into the companion protocol's raw image wire format: packed
/// 2-bit-per-pixel samples, no header, no compression.
///
/// There is no width/height/bit-depth to declare — the device already has the panel's dimensions
/// from the capability characteristic it advertised before any push, and it rejects
/// (`DECODE_FAILED`) any payload whose byte count is not exactly `bytesPerRow(width) * height` for
/// those advertised dimensions. It does not scale or crop, so getting the pixel count in `image`
/// wrong is not a cosmetic bug, it is a rejected push.
///
/// Each sample is 0...3 and *is* the final display level already (0=black, 3=white) — the device
/// does no further gray math on decode, so an unquantized pixel would show up wrong on the panel
/// with nothing downstream to catch it.
enum ImagePacker {

    enum PackError: Error, Equatable {
        /// A pixel was not one of `Quantizer.levels`. Packing an unquantized image would produce a
        /// payload that looks correct on the phone and wrong on the panel, so it is refused outright.
        case notQuantized
    }

    /// Packs `image` into `bytesPerRow(image.width) * image.height` bytes: four samples per byte,
    /// most-significant-bits first (bits 7-6 = the leftmost of the four, bits 1-0 = the rightmost),
    /// each row padded to a whole byte and stored top-to-bottom.
    static func pack(_ image: GrayImage) throws -> Data {
        guard Quantizer.isQuantized(image) else { throw PackError.notQuantized }

        let rowStride = bytesPerRow(image.width)
        var row = [UInt8](repeating: 0, count: rowStride)
        var out = Data(capacity: rowStride * image.height)

        for y in 0..<image.height {
            for index in row.indices { row[index] = 0 }
            for x in 0..<image.width {
                let sample = UInt8(Quantizer.levelIndex(for: Int(image[x, y])))
                let shift = 6 - 2 * (x % 4)
                row[x / 4] |= sample << UInt8(shift)
            }
            out.append(contentsOf: row)
        }

        return out
    }

    /// Bytes needed for one row of `width` 2-bit samples, four per byte, padded to a whole byte.
    static func bytesPerRow(_ width: Int) -> Int {
        (width + 3) / 4
    }
}
