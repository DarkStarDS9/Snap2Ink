import Foundation

/// The panel's four grey levels and the conversions between an 8-bit value and a level index.
///
/// These four values are a **wire contract**, not an aesthetic choice. The firmware's non-dithered
/// PNG path (`PngToFramebufferConverter.cpp`, `useDithering == false`) buckets an incoming 8-bit
/// sample with integer `gray / 85`, so only `{0, 85, 170, 255}` land exactly on a bucket centre.
/// Ship any other value and the panel silently rounds it somewhere the dither did not intend.
///
/// See `docs/device-contract.md` for the full round-trip argument, including why the 2-bit PNG
/// encoding reproduces these four values exactly rather than approximately.
enum Quantizer {

    /// The only pixel values that may appear in a finished print.
    static let levels: [UInt8] = [0, 85, 170, 255]

    /// Spacing between adjacent levels. Used by the ordered-dither threshold and by error diffusion
    /// to reason about how much quantization error one step represents.
    static let levelStep = 85

    /// Nearest level index (0...3) for an arbitrary, possibly out-of-range value. Error diffusion
    /// pushes accumulated error well past 0/255 on high-contrast edges, so this takes an `Int` and
    /// clamps rather than requiring the caller to pre-clamp — clamping *before* choosing the level
    /// would throw away the sign information the diffusion step needs.
    static func levelIndex(for value: Int) -> Int {
        let clamped = min(max(value, 0), 255)
        // +42 rounds to nearest rather than flooring: 42 is levelStep/2, so a value exactly halfway
        // between two levels rounds up, matching how the preview and the panel agree on midtones.
        return min((clamped + levelStep / 2) / levelStep, 3)
    }

    /// Nearest legal output value for an arbitrary, possibly out-of-range input.
    static func nearestLevel(_ value: Int) -> UInt8 {
        levels[levelIndex(for: value)]
    }

    /// Whether every pixel is one of the four legal values. The pipeline's own invariant check —
    /// used by tests, and by `PrintPipeline` in debug builds, because a pipeline that quietly emits
    /// a 128 produces a print that looks right on the phone and wrong on the panel.
    static func isQuantized(_ image: GrayImage) -> Bool {
        let legal = Set(levels)
        return image.pixels.allSatisfy(legal.contains)
    }
}
