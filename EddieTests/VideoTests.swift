import AVFoundation
import CoreImage
import XCTest
@testable import Eddie

/// End-to-end tests against a synthetic 10-bit HEVC clip: a test pattern on top, a smooth 10-bit ramp at the bottom.
final class VideoTests: XCTestCase {
    var fixture: URL {
        Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!
    }

    func testLoadClip() async throws {
        let clip = try await VideoClip.load(fixture)
        XCTAssertEqual(clip.displaySize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(clip.duration.seconds, 2, accuracy: 0.1)
        XCTAssertEqual(clip.orientation, .up)
    }

    func testOrientationMapping() {
        XCTAssertEqual(VideoClip.orientation(for: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0)), .right)
        XCTAssertEqual(VideoClip.orientation(for: .identity), .up)
    }

    func testSampledFramesKeep10BitPrecision() async throws {
        let clip = try await VideoClip.load(fixture)
        let frames = try await FrameSampler.frames(of: clip, at: FrameSampler.evenTimes(count: 6, duration: clip.duration))
        XCTAssertEqual(frames.count, 6)
        XCTAssertEqual(frames[0].image.extent.size, CGSize(width: 1280, height: 720))

        // Read one row through the ramp (bottom half of the frame = low y in Core Image) as half floats.
        let image = frames[0].image
        let row = CGRect(x: 0, y: 100, width: 1280, height: 1)
        var halfs = [UInt16](repeating: 0, count: 1280 * 4)
        halfs.withUnsafeMutableBytes { buf in
            GradeRenderer.shared.context.render(image, toBitmap: buf.baseAddress!, rowBytes: 1280 * 8, bounds: row, format: .RGBAh, colorSpace: nil)
        }
        let greens = Set(stride(from: 1, to: halfs.count, by: 4).map { halfs[$0] })
        XCTAssertGreaterThan(greens.count, 400, "a 10-bit ramp should have far more than 256 distinct levels; got \(greens.count)")
    }

    func testCompositorRendersAllModes() async throws {
        let clip = try await VideoClip.load(fixture)
        var means: [ViewMode: Double] = [:]
        for mode in ViewMode.allCases {
            var r = GradeRecipe(); r.exposure = 1
            let state = GradeState(.init(recipe: r, lut: .djiAction4, mode: mode))
            let generator = AVAssetImageGenerator(asset: clip.asset)
            generator.videoComposition = clip.makeComposition(state: state)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let (cg, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
            XCTAssertEqual(cg.width, 1280)
            let px = GradeRenderer.shared.rgba8(CIImage(cgImage: cg), maxWidth: 320)
            means[mode] = FrameStats(rgba: px.pixels, width: px.width, height: px.height).lumaMean
        }
        XCTAssertGreaterThan(means[.graded]!, means[.lutOnly]! + 0.05, "exposure +1 should brighten the graded view")
        XCTAssertNotEqual(means[.original]!, means[.lutOnly]!, accuracy: 0.01)
    }

    func testExportBakesInTheGrade() async throws {
        let clip = try await VideoClip.load(fixture)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("eddie_export_test.mov")
        var r = GradeRecipe(); r.saturation = -100
        try await Exporter.export(clip: clip, snapshot: .init(recipe: r, lut: .djiAction4, mode: .graded), to: out) { _ in }

        let exported = try await VideoClip.load(out)
        XCTAssertEqual(exported.duration.seconds, 2, accuracy: 0.1)
        let audio = try await exported.asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "audio should be kept")

        let generator = AVAssetImageGenerator(asset: exported.asset)
        let (cg, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        let px = GradeRenderer.shared.rgba8(CIImage(cgImage: cg), maxWidth: 320)
        XCTAssertLessThan(FrameStats(rgba: px.pixels, width: px.width, height: px.height).meanSaturation, 0.03,
                          "saturation -100 should produce a black-and-white file")
    }
}
