import Foundation

/// Sparse 256×256×65536 cognitive grid. Only occupied voxels are stored.
public struct SparseWaveGrid: Sendable, Equatable {
    private var voxels: [WaveCoord: [WaveInt]]

    public init(voxels: [WaveCoord: [WaveInt]] = [:]) {
        self.voxels = voxels
    }

    public var waveCount: Int { voxels.values.reduce(0) { $0 + $1.count } }

    public mutating func insert(_ wave: WaveInt, at coord: WaveCoord? = nil) {
        let key = coord ?? wave.coordinate()
        voxels[key, default: []].append(wave)
    }

    public func waves(at coord: WaveCoord) -> [WaveInt] {
        voxels[coord] ?? []
    }

    public func query(bounds: WaveBounds) -> [(WaveCoord, WaveInt)] {
        var result: [(WaveCoord, WaveInt)] = []
        for (coord, waves) in voxels where bounds.contains(coord) {
            for wave in waves {
                result.append((coord, wave))
            }
        }
        return result
    }

    /// Resonance: neighbours of `query` whose frequency is close, ranked by
    /// |Δfreq| then recency. This is the associative lookup, not a vector scan.
    public func resonate(query probe: WaveInt, radius: UInt8 = 8) -> [(WaveCoord, WaveInt, Double)] {
        let origin = probe.coordinate()
        let bounds = WaveBounds.around(origin, radius: radius)
        let qf = probe.frequency.doubleValue
        return query(bounds: bounds).compactMap { coord, wave in
            let delta = abs(wave.frequency.doubleValue - qf)
            guard delta.isFinite else { return nil }
            let score = 1.0 / (1.0 + delta)
            return (coord, wave, score)
        }
        .sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            return lhs.1.createdAt > rhs.1.createdAt
        }
    }
}
