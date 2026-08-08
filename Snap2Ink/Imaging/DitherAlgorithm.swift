import Foundation

/// The look of the print. This is the one genuinely creative decision the app makes, so it is a
/// user-facing choice rather than a constant — each algorithm has a distinct character on a
/// four-level e-ink panel.
enum DitherAlgorithm: String, CaseIterable, Identifiable, Sendable {
    /// Atkinson: diffuses only 6/8 of the error, deliberately throwing the rest away. The lost
    /// error damps the feedback loop, so near-flat areas break up far less than under
    /// Floyd–Steinberg — the sparse, clean look of early Mac bitmaps. The cost is tonal accuracy:
    /// on a flat field the output drifts measurably toward mid-grey rather than holding the input's
    /// brightness (see `DithererTests`). The default, because on an actual photograph that trade
    /// reads as crispness.
    ///
    /// Note this is *not* the highlight blow-out Atkinson is usually described as producing. That
    /// is its behaviour with a 1-bit palette, where the discarded error has nowhere to go but the
    /// two extremes; with four levels it manifests as reduced contrast in flat regions instead.
    case atkinson
    /// Floyd–Steinberg: diffuses all of the error across four neighbours. Preserves average
    /// brightness closely — a flat field comes back within a couple of units of what went in —
    /// at the cost of visibly more scattered noise than Atkinson in areas with little detail.
    case floydSteinberg
    /// Ordered 4×4 Bayer: a fixed threshold matrix, no error propagation at all. Visibly
    /// cross-hatched, and — because the pattern is periodic rather than noisy — it compresses far
    /// better than either error-diffusion kernel. That makes it the pipeline's fallback when a
    /// print will not fit under the device's size cap (see `PrintPipeline`).
    case orderedBayer
    /// No dithering: every pixel snapped to its nearest level. Posterised and mostly useless as a
    /// photo, but it is the honest baseline the other three are judged against, and it is the
    /// cheapest way to show what dithering is actually buying.
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .atkinson: return "Atkinson"
        case .floydSteinberg: return "Floyd–Steinberg"
        case .orderedBayer: return "Ordered"
        case .none: return "Flat"
        }
    }

    var summary: String {
        switch self {
        case .atkinson: return "Sparse and clean"
        case .floydSteinberg: return "Faithful and noisy"
        case .orderedBayer: return "Cross-hatched, compact"
        case .none: return "No dithering at all"
        }
    }

    private static let lastUsedDefaultsKey = "Snap2Ink.lastUsedDitherAlgorithm"

    /// The algorithm the user picked last time, so a restart reopens on the same look rather than
    /// silently reverting to `.atkinson`. Falls back to `.atkinson` if nothing was ever saved, or if
    /// the saved raw value no longer matches a case (e.g. after a case is renamed or removed).
    static func lastUsed(defaults: UserDefaults = .standard) -> DitherAlgorithm {
        guard let raw = defaults.string(forKey: lastUsedDefaultsKey) else { return .atkinson }
        return DitherAlgorithm(rawValue: raw) ?? .atkinson
    }

    /// Persists the current choice. Called on every change rather than just at app exit, since
    /// nothing in this app runs code on termination (see `Snap2InkApp`).
    static func setLastUsed(_ algorithm: DitherAlgorithm, defaults: UserDefaults = .standard) {
        defaults.set(algorithm.rawValue, forKey: lastUsedDefaultsKey)
    }
}

/// An error-diffusion kernel: where a pixel's quantization error goes, and what it is divided by.
///
/// Offsets are relative to the pixel being quantized, in raster order — every offset is either on a
/// later column of the same row or on a later row, so a single forward pass never needs to revisit
/// a pixel it has already emitted.
struct DiffusionKernel {
    struct Tap {
        let dx: Int
        let dy: Int
        let weight: Int
    }

    let taps: [Tap]
    let divisor: Int

    /// ```
    ///        X  7
    ///     3  5  1        / 16
    /// ```
    static let floydSteinberg = DiffusionKernel(
        taps: [
            Tap(dx: 1, dy: 0, weight: 7),
            Tap(dx: -1, dy: 1, weight: 3),
            Tap(dx: 0, dy: 1, weight: 5),
            Tap(dx: 1, dy: 1, weight: 1),
        ],
        divisor: 16
    )

    /// ```
    ///        X  1  1
    ///     1  1  1
    ///        1           / 8
    /// ```
    /// Note the weights sum to 6, not 8. That shortfall is not a bug to be corrected — it is
    /// exactly what makes Atkinson look like Atkinson.
    static let atkinson = DiffusionKernel(
        taps: [
            Tap(dx: 1, dy: 0, weight: 1),
            Tap(dx: 2, dy: 0, weight: 1),
            Tap(dx: -1, dy: 1, weight: 1),
            Tap(dx: 0, dy: 1, weight: 1),
            Tap(dx: 1, dy: 1, weight: 1),
            Tap(dx: 0, dy: 2, weight: 1),
        ],
        divisor: 8
    )
}
