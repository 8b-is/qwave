import Foundation

/// O(1) Marine salience (8b-Mem8/MARINE_ALGORITHM.md).
///
/// S = 0.3·Energy + 0.4·Stability + 0.3·Harmonic, clamped to [0, 1].
/// Stability (low jitter) outweighs raw energy — a quiet periodic signal
/// outranks a one-off spike. Used to rank page extracts, never to auto-store.
public struct MarineDetector: Sendable {
    public var clipThreshold: Double
    public var emaAlpha: Double
    public var harmonicEpsilon: Double
    public var weightEnergy: Double
    public var weightJitter: Double
    public var weightHarmonic: Double
    public var decay: Double

    private var last: Double = 0
    private var secondLast: Double = 0
    private var lastPeakIndex: Int?
    private var sampleIndex: Int = 0
    private var periodEMA: Double = 0
    private var amplitudeEMA: Double = 0
    public private(set) var salience: Double = 0

    public init(
        clipThreshold: Double = 0.01,
        emaAlpha: Double = 0.3,
        harmonicEpsilon: Double = 0.05,
        weightEnergy: Double = 0.3,
        weightJitter: Double = 0.4,
        weightHarmonic: Double = 0.3,
        decay: Double = 0.9
    ) {
        self.clipThreshold = clipThreshold
        self.emaAlpha = emaAlpha
        self.harmonicEpsilon = harmonicEpsilon
        self.weightEnergy = weightEnergy
        self.weightJitter = weightJitter
        self.weightHarmonic = weightHarmonic
        self.decay = decay
    }

    public mutating func process(sample: Double) -> Double {
        sampleIndex += 1
        let absSample = abs(sample)
        defer {
            secondLast = last
            last = sample
        }
        guard absSample >= clipThreshold else {
            salience *= decay
            return salience
        }

        let isPeak = (secondLast < last && last > sample) || (secondLast > last && last < sample)
        guard isPeak else { return salience }

        let amplitude = abs(last)
        let period: Double
        if let previous = lastPeakIndex {
            period = Double(sampleIndex - previous)
        } else {
            period = 0
        }
        lastPeakIndex = sampleIndex

        if periodEMA == 0 {
            periodEMA = max(period, 1)
            amplitudeEMA = amplitude
        } else {
            periodEMA = emaAlpha * max(period, 1) + (1 - emaAlpha) * periodEMA
            amplitudeEMA = emaAlpha * amplitude + (1 - emaAlpha) * amplitudeEMA
        }

        let energy = min(1.0, amplitude)
        let jitter = abs(period - periodEMA) + abs(amplitude - amplitudeEMA)
        let stability = 1.0 / (1.0 + jitter)
        let harmonic = harmonicAlignment(period: max(period, 1), fundamental: periodEMA)
        salience = min(1.0, max(0.0, weightEnergy * energy + weightJitter * stability + weightHarmonic * harmonic))
        return salience
    }

    /// Treat UTF-8 bytes as a centred PCM stream and return peak salience.
    public mutating func score(text: String) -> Double {
        var peak = 0.0
        for byte in text.utf8 {
            let sample = (Double(byte) - 128.0) / 128.0
            peak = max(peak, process(sample: sample))
        }
        return peak
    }

    public static func score(text: String) -> Double {
        var detector = MarineDetector()
        return detector.score(text: text)
    }

    private func harmonicAlignment(period: Double, fundamental: Double) -> Double {
        guard fundamental > 0 else { return 0 }
        var best = 0.0
        for k in 2...8 {
            let forward = Double(k) * fundamental
            let sub = fundamental / Double(k)
            for expected in [forward, sub] {
                let rel = abs(period - expected) / max(expected, 1)
                if rel <= harmonicEpsilon {
                    best = max(best, 1.0 - rel / harmonicEpsilon)
                }
            }
        }
        return best
    }
}
