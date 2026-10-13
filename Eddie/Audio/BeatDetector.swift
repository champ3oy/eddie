import AVFoundation
import Accelerate

/// Finds the beat of a song: an onset envelope, its tempo by autocorrelation, then a beat grid
/// lined up with the strongest onsets.
enum BeatDetector {
    static func beats(in url: URL) async throws -> [Double] {
        let buffer = try await AudioProcessor.decode(url)
        return beats(buffer)
    }

    static func beats(_ buffer: AVAudioPCMBuffer) -> [Double] {
        let n = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let hop = 512
        guard n > hop * 64 else { return [] }
        // Mono energy per hop.
        let l = buffer.floatChannelData![0]
        let r = buffer.floatChannelData![Int(buffer.format.channelCount) > 1 ? 1 : 0]
        let frames = n / hop
        var energy = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var s: Float = 0
            let base = f * hop
            for j in 0..<hop {
                let v = (l[base + j] + r[base + j]) * 0.5
                s += v * v
            }
            energy[f] = log(1 + 1000 * s / Float(hop))
        }
        // Onsets: positive change in energy (the very first frame counts against silence), local average removed.
        var onset = [Float](repeating: 0, count: frames)
        onset[0] = energy[0]
        for f in 1..<frames { onset[f] = max(0, energy[f] - energy[f - 1]) }
        var prefix = [Float](repeating: 0, count: frames + 1)
        for f in 0..<frames { prefix[f + 1] = prefix[f] + onset[f] }
        let w = 16
        var smoothed = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            let a = max(0, f - w), b = min(frames, f + w)
            smoothed[f] = max(0, onset[f] - (prefix[b] - prefix[a]) / Float(b - a))
        }
        // Tempo: autocorrelation peak between 70 and 180 BPM.
        let fps = rate / Double(hop)
        let minLag = Int(fps * 60 / 180), maxLag = Int(fps * 60 / 70)
        guard maxLag + 1 < frames / 2 else { return [] }
        var scores = [Float](repeating: 0, count: maxLag + 2)
        smoothed.withUnsafeBufferPointer { p in
            for lag in max(1, minLag - 1)...(maxLag + 1) {
                var s: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(frames - lag))
                scores[lag] = s
            }
        }
        var best = minLag, bestScore: Float = -1
        for lag in minLag...maxLag {
            // Mild preference for tempos near 120 BPM.
            let bpm = 60 * fps / Double(lag)
            let weight = Float(exp(-pow(log2(bpm / 120), 2) / 2))
            if scores[lag] * weight > bestScore { bestScore = scores[lag] * weight; best = lag }
        }
        // Sub-frame tempo from the shape of the peak.
        var lag = Double(best)
        let before = Double(scores[best - 1]), here = Double(scores[best]), after = Double(scores[best + 1])
        let denom: Double = before - 2 * here + after
        if denom < 0 {
            let shift: Double = 0.5 * (before - after) / denom
            lag += min(0.5, max(-0.5, shift))
        }

        /// Strongest onset within ±2 frames of a grid position.
        func peak(near x: Double) -> (frame: Int, value: Float) {
            let center = Int(x.rounded())
            var bestF = center, bestV: Float = -1
            for f in max(0, center - 2)...min(frames - 1, center + 2) where smoothed[f] > bestV { bestV = smoothed[f]; bestF = f }
            return (bestF, bestV)
        }
        // Phase: the offset whose grid collects the most onset strength.
        var bestPhase = 0.0, phaseScore: Float = -1
        for phase in 0..<Int(lag.rounded(.up)) {
            var s: Float = 0
            var x = Double(phase)
            while x < Double(frames) - 2 { s += peak(near: x).value; x += lag }
            if s > phaseScore { phaseScore = s; bestPhase = Double(phase) }
        }
        // Beats on the grid, each nudged onto its actual onset.
        var out: [Double] = []
        var x = bestPhase
        while x < Double(frames) - 2 {
            let p = peak(near: x)
            out.append(Double(p.value > 0 ? p.frame : Int(x.rounded())) / fps)
            x += lag
        }
        return out
    }

    static func tempo(of beats: [Double]) -> Double? {
        guard beats.count > 2 else { return nil }
        return 60 / ((beats.last! - beats.first!) / Double(beats.count - 1))
    }
}
