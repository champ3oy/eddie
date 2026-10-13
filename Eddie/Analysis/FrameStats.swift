import Foundation

/// Objective measurements of a rendered frame, sent to the AI alongside the image so it
/// doesn't have to guess exposure and white balance by eye alone. Values are 0...1 display (Rec.709) values.
struct FrameStats: Codable, Equatable {
    var lumaP1: Double
    var lumaP5: Double
    var lumaMedian: Double
    var lumaP95: Double
    var lumaP99: Double
    var lumaMean: Double
    var clippedHighlightsPercent: Double
    var crushedShadowsPercent: Double
    var meanRGB: [Double]
    /// Average color of the brightest, least-saturated pixels — roughly what "white" looks like.
    var brightNeutralRGB: [Double]
    var meanSaturation: Double

    init(rgba pixels: [UInt8], width: Int, height: Int) {
        let n = max(1, width * height)
        var histogram = [Int](repeating: 0, count: 256)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumY = 0.0, sumSat = 0.0
        var clipped = 0, crushed = 0
        var lumas = [UInt8](repeating: 0, count: n)

        for i in 0..<n {
            let r = Double(pixels[i * 4]) / 255, g = Double(pixels[i * 4 + 1]) / 255, b = Double(pixels[i * 4 + 2]) / 255
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let yi = UInt8(min(255, max(0, (y * 255).rounded())))
            lumas[i] = yi
            histogram[Int(yi)] += 1
            sumR += r; sumG += g; sumB += b; sumY += y
            sumSat += max(r, g, b) - min(r, g, b)
            if max(r, g, b) >= 0.985 { clipped += 1 }
            if y <= 0.02 { crushed += 1 }
        }

        func percentile(_ p: Double) -> Double {
            let target = Int((Double(n) * p).rounded(.down))
            var acc = 0
            for (v, count) in histogram.enumerated() {
                acc += count
                if acc > target { return Double(v) / 255 }
            }
            return 1
        }

        // Bright, near-neutral pixels: top 10 % of luma, below 98 % (not clipped), low saturation.
        let brightCut = percentile(0.90)
        var nr = 0.0, ng = 0.0, nb = 0.0, nc = 0
        for i in 0..<n {
            let y = Double(lumas[i]) / 255
            guard y >= brightCut, y < 0.98 else { continue }
            let r = Double(pixels[i * 4]) / 255, g = Double(pixels[i * 4 + 1]) / 255, b = Double(pixels[i * 4 + 2]) / 255
            guard max(r, g, b) - min(r, g, b) < 0.15 else { continue }
            nr += r; ng += g; nb += b; nc += 1
        }

        let dn = Double(n)
        lumaP1 = percentile(0.01)
        lumaP5 = percentile(0.05)
        lumaMedian = percentile(0.50)
        lumaP95 = percentile(0.95)
        lumaP99 = percentile(0.99)
        lumaMean = sumY / dn
        clippedHighlightsPercent = Double(clipped) / dn * 100
        crushedShadowsPercent = Double(crushed) / dn * 100
        meanRGB = [sumR / dn, sumG / dn, sumB / dn]
        brightNeutralRGB = nc > 0 ? [nr / Double(nc), ng / Double(nc), nb / Double(nc)] : []
        meanSaturation = sumSat / dn
    }

    /// Color cast of the bright near-neutral pixels on the two white-balance axes:
    /// warmth = R − B (positive = warm/yellow, negative = cool/blue),
    /// greenMagenta = G − (R+B)/2 (positive = green, negative = magenta/pink/lavender).
    var cast: (warmth: Double, greenMagenta: Double)? {
        guard brightNeutralRGB.count == 3 else { return nil }
        let (r, g, b) = (brightNeutralRGB[0], brightNeutralRGB[1], brightNeutralRGB[2])
        return (r - b, g - (r + b) / 2)
    }

    private var castDescription: String {
        guard let c = cast else { return "" }
        return String(format: " → whites cast: warmth (R−B) %+.3f, green–magenta (G−avg(R,B)) %+.3f", c.warmth, c.greenMagenta)
    }

    /// Short human/AI-readable form.
    var description: String {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        func rgb(_ v: [Double]) -> String { v.isEmpty ? "n/a" : "(" + v.map(f).joined(separator: ", ") + ")" }
        return """
        luma p1 \(f(lumaP1)), p5 \(f(lumaP5)), median \(f(lumaMedian)), p95 \(f(lumaP95)), p99 \(f(lumaP99)), mean \(f(lumaMean)); \
        clipped highlights \(String(format: "%.1f", clippedHighlightsPercent))%, crushed shadows \(String(format: "%.1f", crushedShadowsPercent))%; \
        mean RGB \(rgb(meanRGB)); bright-neutral RGB \(rgb(brightNeutralRGB))\(castDescription); mean saturation \(f(meanSaturation))
        """
    }
}
