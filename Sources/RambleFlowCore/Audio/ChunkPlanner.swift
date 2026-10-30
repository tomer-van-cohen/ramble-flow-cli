import Foundation

/// Loudness of a recording over time, one value per frame (dBFS, -120 for digital silence).
public struct EnergyProfile: Sendable, Equatable {
    public var frameDuration: TimeInterval
    public var levels: [Float]

    public init(frameDuration: TimeInterval, levels: [Float]) {
        self.frameDuration = frameDuration
        self.levels = levels
    }

    public static let silenceThreshold: Float = -50

    func frameIndex(_ time: TimeInterval) -> Int {
        max(0, min(levels.count, Int((time / frameDuration).rounded(.down))))
    }

    /// Mean level of frames within `radius` seconds of `time`.
    func smoothedLevel(at time: TimeInterval, radius: TimeInterval = 0.3) -> Float {
        let lo = frameIndex(time - radius)
        let hi = min(levels.count, frameIndex(time + radius) + 1)
        guard hi > lo else { return 0 }
        var sum: Float = 0
        for i in lo..<hi { sum += levels[i] }
        return sum / Float(hi - lo)
    }

    /// True when every frame in the span is below the silence threshold.
    public func isSilent(_ span: ChunkSpan) -> Bool {
        let lo = frameIndex(span.start)
        let hi = min(levels.count, max(lo + 1, frameIndex(span.end)))
        guard hi > lo else { return true }
        for i in lo..<hi where levels[i] >= Self.silenceThreshold { return false }
        return true
    }
}

/// Splits a recording into provider-sized requests, preferring quiet moments as boundaries so no
/// word is cut in half. No overlap is used, so no text has to be de-duplicated afterwards.
public enum ChunkPlanner {
    public struct Limits: Sendable, Equatable {
        /// Longest audio per request.
        public var maxDuration: TimeInterval
        /// Bytes per request to aim for.
        public var targetBytes: Int
        /// Encoded bytes per second of the prepared audio (container overhead included).
        public var bytesPerSecond: Double
        /// How far before the ideal cut to look for a quiet moment.
        public var searchWindow: TimeInterval = 45
        public var minChunk: TimeInterval = 10

        public init(maxDuration: TimeInterval, targetBytes: Int, bytesPerSecond: Double, searchWindow: TimeInterval = 45, minChunk: TimeInterval = 10) {
            self.maxDuration = maxDuration
            self.targetBytes = targetBytes
            self.bytesPerSecond = bytesPerSecond
            self.searchWindow = searchWindow
            self.minChunk = minChunk
        }

        /// Duration that fits both the time and the byte budget (10% headroom on bytes).
        public var effectiveMaxDuration: TimeInterval {
            let byBytes = Double(targetBytes) * 0.9 / max(bytesPerSecond, 1)
            return max(minChunk, min(maxDuration, byBytes))
        }
    }

    public static func plan(duration: TimeInterval, energy: EnergyProfile?, limits: Limits) -> [ChunkSpan] {
        guard duration > 0 else { return [] }
        let maxDuration = limits.effectiveMaxDuration
        if duration <= maxDuration { return [ChunkSpan(start: 0, end: duration)] }

        var spans: [ChunkSpan] = []
        var start: TimeInterval = 0
        while duration - start > maxDuration {
            let ideal = start + maxDuration
            var cut = ideal
            if let energy {
                let lower = max(start + limits.minChunk, ideal - min(limits.searchWindow, maxDuration / 2))
                var best = ideal
                var bestLevel = Float.greatestFiniteMagnitude
                // Walk backwards from the ideal cut so ties keep chunks as long as possible.
                var t = ideal
                while t >= lower {
                    let level = energy.smoothedLevel(at: t)
                    if level < bestLevel - 0.5 {
                        bestLevel = level
                        best = t
                    }
                    t -= energy.frameDuration
                }
                cut = best
            }
            cut = min(max(cut, start + limits.minChunk), ideal)
            spans.append(ChunkSpan(start: start, end: cut))
            start = cut
        }
        spans.append(ChunkSpan(start: start, end: duration))
        return spans
    }

    /// Splits one span in two at its quietest point near the middle (used when an encoded chunk is
    /// still over the byte cap, or the provider answered 413).
    public static func split(_ span: ChunkSpan, energy: EnergyProfile?) -> [ChunkSpan] {
        let middle = span.start + span.duration / 2
        var cut = middle
        if let energy {
            let radius = span.duration / 4
            var bestLevel = Float.greatestFiniteMagnitude
            var t = middle - radius
            while t <= middle + radius {
                let level = energy.smoothedLevel(at: t)
                if level < bestLevel - 0.5 {
                    bestLevel = level
                    cut = t
                }
                t += energy.frameDuration
            }
        }
        return [ChunkSpan(start: span.start, end: cut), ChunkSpan(start: cut, end: span.end)]
    }
}
