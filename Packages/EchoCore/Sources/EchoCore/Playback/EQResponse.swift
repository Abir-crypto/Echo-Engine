import CEchoDSP

/// The equalizer's frequency response (SPEC § 8), from the same filter math the audio uses, for drawing the curve.
public enum EQResponse {
    public static let frequencyRange: ClosedRange<Double> = 20...20_000

    /// Combined gain in dB of `bands` at each frequency.
    public static func magnitudeDB(of bands: [EQBand], at frequencies: [Double], sampleRate: Double = 48_000) -> [Double] {
        let filters = bands.compactMap { band -> echo.dsp.BiquadCoefficients? in
            guard band.gainDB != 0, let shape = band.kind.filterShape else { return nil }
            return echo.dsp.makeBiquad(shape, sampleRate, Double(band.frequencyHz), Double(band.gainDB), Double(band.q))
        }
        return frequencies.map { frequency in
            filters.reduce(0) { $0 + echo.dsp.biquadMagnitudeDB($1, sampleRate, frequency) }
        }
    }

    /// `count` frequencies spread evenly on a log scale across `frequencyRange`.
    public static func logFrequencies(count: Int) -> [Double] {
        guard count > 1 else { return [frequencyRange.lowerBound] }
        let low = log10(frequencyRange.lowerBound), high = log10(frequencyRange.upperBound)
        return (0..<count).map { pow(10, low + (high - low) * Double($0) / Double(count - 1)) }
    }

    /// Whether every band is at 0 dB.
    public static func isFlat(_ bands: [EQBand]) -> Bool {
        bands.allSatisfy { $0.gainDB == 0 || $0.kind == .unknown }
    }
}

extension EQBand.Kind {
    var filterShape: echo.dsp.FilterShape? {
        switch self {
        case .lowShelf: .lowShelf
        case .peaking: .peaking
        case .highShelf: .highShelf
        case .unknown: nil
        }
    }
}
