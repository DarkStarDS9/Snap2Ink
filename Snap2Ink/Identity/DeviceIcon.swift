import Foundation

/// Snap2Ink's tile on the device's sleep screen: a 1-bit-per-pixel bitmap the firmware stores per
/// peer as `icon.bin`.
///
/// Drawn in code rather than shipped as an image asset: the device advertises its icon dimensions in
/// the capability characteristic, so the app has to be able to produce whatever size it is asked for
/// and a fixed-size bundled PNG could not. It also makes the icon a pure function, and therefore
/// testable, which a bundled asset is not.
///
/// Row-major, MSB-first within each byte, rows padded to whole bytes, **a set bit is ink** — all
/// four stated in `docs/companion-display-protocol.md` § "Icon field".
///
/// The subject is a camera rather than a photograph, because at this size on a monochrome panel a
/// silhouette with one strong circular feature survives and a framed-print border does not.
///
/// Tagging and pushing are CompanionKit's job; this type only produces the bytes.
enum DeviceIcon {

    /// Today's size per the protocol document (512 bytes packed); what to draw before a device has
    /// said otherwise.
    static let assumedSize = 64

    /// Renders the icon as a grid of "is this pixel ink", row-major, top-down.
    ///
    /// All geometry is expressed as fractions of the canvas so the same drawing works at whatever
    /// dimensions the firmware turns out to ask for.
    static func bitmap(width: Int = assumedSize, height: Int = assumedSize) -> [Bool] {
        precondition(width > 0 && height > 0)
        let w = Double(width)
        let h = Double(height)
        var pixels = [Bool](repeating: false, count: width * height)

        let body = (left: 0.06 * w, top: 0.31 * h, right: 0.94 * w, bottom: 0.88 * h)
        let corner = 0.08 * min(w, h)
        let bump = (left: 0.28 * w, top: 0.22 * h, right: 0.53 * w, bottom: 0.31 * h)
        let lens = (cx: 0.50 * w, cy: 0.62 * h, well: 0.20 * min(w, h), glass: 0.14 * min(w, h), aperture: 0.06 * min(w, h))
        let shutter = (cx: 0.80 * w, cy: 0.40 * h, r: 0.04 * min(w, h))

        for y in 0..<height {
            for x in 0..<width {
                // Pixel centres, so the shapes stay symmetric about the icon's midline at any size.
                let px = Double(x) + 0.5
                let py = Double(y) + 0.5

                var ink = false
                if inRoundedRect(px, py, body.left, body.top, body.right, body.bottom, corner) { ink = true }
                if inRect(px, py, bump.left, bump.top, bump.right, bump.bottom) { ink = true }

                // The lens is drawn as alternating discs rather than as a ring: paper well, ink
                // glass, paper aperture. Three hard edges read far better at this size than one
                // thin outline once the panel's own contrast is involved.
                let lensDistance = hypot(px - lens.cx, py - lens.cy)
                if lensDistance <= lens.well { ink = false }
                if lensDistance <= lens.glass { ink = true }
                if lensDistance <= lens.aperture { ink = false }

                if hypot(px - shutter.cx, py - shutter.cy) <= shutter.r { ink = false }

                pixels[y * width + x] = ink
            }
        }

        return pixels
    }

    /// Packs a bitmap into the documented wire form: row-major, 8 pixels per byte, most significant
    /// bit first, rows padded to whole bytes, a set bit meaning ink (black).
    static func packed(_ pixels: [Bool], width: Int, height: Int) -> Data {
        precondition(pixels.count == width * height, "bitmap must match the given dimensions")
        let bytesPerRow = (width + 7) / 8
        var out = Data(repeating: 0, count: bytesPerRow * height)

        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] {
                out[y * bytesPerRow + x / 8] |= UInt8(0x80) >> UInt8(x % 8)
            }
        }

        return out
    }

    /// The icon bytes for a device's advertised dimensions.
    ///
    /// The protocol guarantees the advertised icon width is **always a multiple of 8** — explicitly
    /// a guarantee rather than an accident of today's 64×64 — so the packed size is exactly
    /// `width * height / 8` with no padding convention to invent, and this returns bytes for every
    /// size a conforming device can ask for.
    ///
    /// The length check remains as a backstop only. A wrong length is rejected outright with
    /// `ASSET_ACK(REJECTED_SIZE)`, so if a device ever did violate the guarantee, sending nothing
    /// costs a sleep-screen tile while sending the wrong thing costs a failed enrolment asset and a
    /// confusing error.
    static func encoded(width: Int, height: Int, expectedByteCount: Int) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let bitmap = packed(bitmap(width: width, height: height), width: width, height: height)
        return bitmap.count == expectedByteCount ? bitmap : nil
    }

    // MARK: - Geometry

    private static func inRect(_ x: Double, _ y: Double, _ left: Double, _ top: Double, _ right: Double, _ bottom: Double) -> Bool {
        x >= left && x <= right && y >= top && y <= bottom
    }

    private static func inRoundedRect(
        _ x: Double, _ y: Double,
        _ left: Double, _ top: Double, _ right: Double, _ bottom: Double,
        _ radius: Double
    ) -> Bool {
        guard inRect(x, y, left, top, right, bottom) else { return false }
        let cx = min(max(x, left + radius), right - radius)
        let cy = min(max(y, top + radius), bottom - radius)
        // Inside the inset cross the clamped point is the point itself, so the distance is zero.
        return hypot(x - cx, y - cy) <= radius
    }
}
