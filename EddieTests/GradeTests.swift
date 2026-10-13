import CoreImage
import XCTest
@testable import Eddie

final class CubeLUTTests: XCTestCase {
    func testBundledDJILUTLoads() {
        let lut = CubeLUT.djiAction4
        XCTAssertEqual(lut.size, 33)
        XCTAssertEqual(lut.data.count, 33 * 33 * 33 * 4 * MemoryLayout<Float>.size)
    }

    func testParsesSmallCube() throws {
        let text = """
        # comment
        TITLE "tiny"
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try CubeLUT(parsing: text, title: "tiny")
        XCTAssertEqual(lut.size, 2)
        let floats = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(Array(floats[4..<8]), [1, 0, 0, 1]) // second entry: red varies fastest, alpha added
        XCTAssertEqual(lut.data, CubeLUT.identity(size: 2).data)
    }

    func testRejectsWrongEntryCount() {
        XCTAssertThrowsError(try CubeLUT(parsing: "LUT_3D_SIZE 2\n0 0 0\n1 1 1", title: "bad"))
        XCTAssertThrowsError(try CubeLUT(parsing: "0 0 0", title: "no size"))
    }
}

final class GradeRecipeTests: XCTestCase {
    func testScaleAndClamp() {
        var r = GradeRecipe()
        r.exposure = 1.5
        r.contrast = 80
        let half = r.scaled(by: 0.5)
        XCTAssertEqual(half.exposure, 0.75)
        XCTAssertEqual(half.contrast, 40)
        let big = r.scaled(by: 1.5)
        XCTAssertEqual(big.exposure, 2) // clamped
        XCTAssertEqual(big.contrast, 100)
        XCTAssertTrue(r.scaled(by: 0).isNeutral)
    }

    func testJSONRoundTripAndNaN() throws {
        var r = GradeRecipe()
        r.temperature = 12
        let decoded = try JSONDecoder().decode(GradeRecipe.self, from: Data(r.jsonString().utf8))
        XCTAssertEqual(decoded, r)
        r.tint = .nan
        XCTAssertEqual(r.clamped().tint, 0)
    }
}

final class RendererTests: XCTestCase {
    let renderer = GradeRenderer.shared
    let lut = CubeLUT.djiAction4

    /// A test image: horizontal gray ramp on top, a few colored patches below (mid-gray LOG-ish values).
    func testImage() -> CIImage {
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 256, y: 0),
            "inputColor0": CIColor(red: 0.1, green: 0.1, blue: 0.1, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!,
            "inputColor1": CIColor(red: 0.85, green: 0.85, blue: 0.85, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!,
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 64, width: 256, height: 64))
        var image = ramp
        let colors: [(Double, Double, Double)] = [(0.55, 0.40, 0.35), (0.35, 0.45, 0.55), (0.40, 0.50, 0.35), (0.45, 0.45, 0.45)]
        for (i, c) in colors.enumerated() {
            let patch = CIImage(color: CIColor(red: c.0, green: c.1, blue: c.2))
                .cropped(to: CGRect(x: i * 64, y: 0, width: 64, height: 64))
            image = patch.composited(over: image)
        }
        return renderer.materialize(image)
    }

    func stats(_ recipe: GradeRecipe, mode: ViewMode = .graded) -> FrameStats {
        let out = renderer.render(testImage(), recipe: recipe, lut: lut, mode: mode)
        let px = renderer.rgba8(out, maxWidth: 256)
        return FrameStats(rgba: px.pixels, width: px.width, height: px.height)
    }

    func testNeutralRecipeEqualsLUTOnly() {
        XCTAssertEqual(stats(.neutral), stats(.neutral, mode: .lutOnly))
    }

    func testLUTChangesTheImage() {
        XCTAssertNotEqual(stats(.neutral, mode: .original), stats(.neutral, mode: .lutOnly))
    }

    func testKernelWithZeroKnobsIsNearIdentity() {
        // Tiny non-zero value forces the kernel to run; result must match LUT-only.
        var r = GradeRecipe(); r.contrast = 0.0001
        let a = stats(r), b = stats(.neutral, mode: .lutOnly)
        XCTAssertEqual(a.lumaMedian, b.lumaMedian, accuracy: 0.005)
        XCTAssertEqual(a.meanRGB[0], b.meanRGB[0], accuracy: 0.005)
    }

    func testKnobDirections() {
        let base = stats(.neutral)
        func with(_ k: WritableKeyPath<GradeRecipe, Double>, _ v: Double) -> FrameStats {
            var r = GradeRecipe(); r[keyPath: k] = v; return stats(r)
        }
        XCTAssertGreaterThan(with(\.exposure, 1).lumaMean, base.lumaMean + 0.05)
        XCTAssertLessThan(with(\.exposure, -1).lumaMean, base.lumaMean - 0.05)

        let warm = with(\.temperature, 60), cool = with(\.temperature, -60)
        XCTAssertGreaterThan(warm.meanRGB[0] - warm.meanRGB[2], base.meanRGB[0] - base.meanRGB[2] + 0.02)
        XCTAssertLessThan(cool.meanRGB[0] - cool.meanRGB[2], base.meanRGB[0] - base.meanRGB[2] - 0.02)
        // Warming must not push the image toward magenta (green stays put relative to red+blue average).
        func greenMagenta(_ s: FrameStats) -> Double { s.meanRGB[1] - (s.meanRGB[0] + s.meanRGB[2]) / 2 }
        XCTAssertEqual(greenMagenta(warm), greenMagenta(base), accuracy: 0.015)

        func greenness(_ s: FrameStats) -> Double { s.meanRGB[1] - (s.meanRGB[0] + s.meanRGB[2]) / 2 }
        XCTAssertLessThan(greenness(with(\.tint, 60)), greenness(base) - 0.01)         // magenta = less green
        XCTAssertGreaterThan(greenness(with(\.tint, -60)), greenness(base) + 0.01)

        let punchy = with(\.contrast, 80), flat = with(\.contrast, -80)
        XCTAssertGreaterThan(punchy.lumaP95 - punchy.lumaP5, base.lumaP95 - base.lumaP5 + 0.02)
        XCTAssertLessThan(flat.lumaP95 - flat.lumaP5, base.lumaP95 - base.lumaP5 - 0.02)

        XCTAssertGreaterThan(with(\.shadows, 80).lumaP5, base.lumaP5 + 0.01)
        XCTAssertLessThan(with(\.highlights, -80).lumaP95, base.lumaP95 - 0.01)
        XCTAssertGreaterThan(with(\.whites, 80).lumaP99, base.lumaP99)
        XCTAssertLessThan(with(\.blacks, -80).lumaP1, base.lumaP1)

        XCTAssertLessThan(with(\.saturation, -100).meanSaturation, 0.01)
        XCTAssertGreaterThan(with(\.saturation, 50).meanSaturation, base.meanSaturation)
        XCTAssertGreaterThan(with(\.vibrance, 60).meanSaturation, base.meanSaturation)
    }

    func testBitmapIsTopRowFirst() {
        // White on top half, black on bottom half (Core Image's y axis points up).
        let img = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 8, width: 8, height: 8))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)))
        let px = renderer.rgba8(img, maxWidth: 8)
        XCTAssertEqual(px.pixels[0], 255, "first row in the bitmap should be the top of the image")
    }
}

final class FrameStatsTests: XCTestCase {
    func testUniformGray() {
        let px = [UInt8](repeating: 128, count: 10 * 10 * 4)
        let s = FrameStats(rgba: px, width: 10, height: 10)
        XCTAssertEqual(s.lumaMedian, 128.0 / 255, accuracy: 0.01)
        XCTAssertEqual(s.clippedHighlightsPercent, 0)
        XCTAssertEqual(s.meanSaturation, 0, accuracy: 0.0001)
    }

    func testCastAxes() {
        // Lavender whites: red and blue above green.
        var px: [UInt8] = []
        for _ in 0..<100 { px += [200, 185, 215, 255] }
        let c = FrameStats(rgba: px, width: 100, height: 1).cast!
        XCTAssertLessThan(c.greenMagenta, -0.05)
        XCTAssertLessThan(c.warmth, 0)
    }

    func testClippedAndCrushed() {
        var px = [UInt8](repeating: 255, count: 4 * 4)       // 4 white pixels
        px += [UInt8](repeating: 0, count: 4 * 4)            // 4 black pixels
        let s = FrameStats(rgba: px, width: 8, height: 1)
        XCTAssertEqual(s.clippedHighlightsPercent, 50)
        XCTAssertEqual(s.crushedShadowsPercent, 50)
    }
}

final class WipeTests: XCTestCase {
    func testWipeShowsOriginalLeftAndGradedRight() {
        let r = GradeRenderer.shared
        let src = r.materialize(CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 10)))
        var recipe = GradeRecipe(); recipe.exposure = 1.5
        let wipe = r.renderWipe(src, recipe: recipe, lut: .djiAction4, split: 0.5)
        let px = r.rgba8(wipe, maxWidth: 100)
        let left = px.pixels[(5 * 100 + 10) * 4], right = px.pixels[(5 * 100 + 90) * 4]
        XCTAssertEqual(Int(left), 102, accuracy: 2, "left side is the untouched source")
        XCTAssertGreaterThan(right, left + 40, "right side is graded (+1.5 EV)")
    }
}

final class HistogramTests: XCTestCase {
    func testHistogramBinsAndClipping() {
        // 4 pixels BGRA: pure white, black, mid red, mid gray.
        let px: [UInt8] = [255, 255, 255, 255,  0, 0, 0, 255,  0, 0, 128, 255,  128, 128, 128, 255]
        let h = px.withUnsafeBytes { Histogram(bgra: $0.baseAddress!, width: 4, height: 1, rowBytes: 16, step: 1) }
        XCTAssertEqual(h.red.count, Histogram.bins)
        XCTAssertTrue(h.clippedHighlights)
        XCTAssertTrue(h.clippedShadows)
        XCTAssertGreaterThan(h.red[Histogram.bins / 2], 0)
        XCTAssertEqual(h.blue[Histogram.bins / 2], h.red[Histogram.bins / 2] / 2, accuracy: 0.001)
    }
}

final class PresetTests: XCTestCase {
    func testPresetsAddOnTopAndClamp() {
        var base = GradeRecipe(); base.saturation = -50
        let mono = Preset.all.first { $0.name == "Mono" }!
        XCTAssertEqual(base.adding(mono.adjust).saturation, -100)
        let warm = Preset.all.first { $0.name == "Warm" }!
        XCTAssertEqual(GradeRecipe().adding(warm.adjust).temperature, 18)
        XCTAssertEqual(Set(Preset.all.map(\.name)).count, Preset.all.count, "names are unique")
    }
}
