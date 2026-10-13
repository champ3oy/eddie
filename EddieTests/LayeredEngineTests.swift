import AVFoundation
import CoreImage
import XCTest
@testable import Eddie

/// The layered engine: transitions, overlays, photos, framing, formats, source profiles, fades, export settings.
final class LayeredEngineTests: XCTestCase {
    var logURL: URL { Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")! }
    var blueURL: URL { Bundle(for: Self.self).url(forResource: "normal_blue", withExtension: "mov")! }
    var photoURL: URL { Bundle(for: Self.self).url(forResource: "photo_test", withExtension: "jpg")! }

    func pool() async throws -> MediaPool {
        MediaPool(videos: [logURL: try await VideoClip.load(logURL), blueURL: try await VideoClip.load(blueURL)],
                  audio: [:], photos: [photoURL: CGSize(width: 800, height: 600)])
    }

    /// Mean RGB of a frame (or of a region given as fractions of the frame, y from the top).
    func color(_ project: Project, at t: Double, region: CGRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)) async throws -> (r: Double, g: Double, b: Double, size: CGSize) {
        let compiled = try ProjectCompiler.compile(project, pool: try await pool(), state: GradeState(ProjectCompiler.snapshot(for: project, lut: .djiAction4)))
        let g = AVAssetImageGenerator(asset: compiled.composition)
        g.videoComposition = compiled.videoComposition
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600))
        let ci = CIImage(cgImage: cg)
        let e = ci.extent
        let rect = CGRect(x: e.width * region.minX, y: e.height * (1 - region.maxY), width: e.width * region.width, height: e.height * region.height)
        let px = GradeRenderer.shared.rgba8(ci.cropped(to: rect), maxWidth: 64)
        let s = FrameStats(rgba: px.pixels, width: px.width, height: px.height)
        return (s.meanRGB[0], s.meanRGB[1], s.meanRGB[2], CGSize(width: cg.width, height: cg.height))
    }

    func blue(_ start: Double = 0, _ end: Double = 2) -> ClipItem {
        var c = ClipItem(url: blueURL, sourceStart: start, sourceEnd: end)
        c.profile = .normal
        return c
    }

    func photo(_ seconds: Double = 2) -> ClipItem {
        var c = ClipItem(url: photoURL, sourceStart: 0, sourceEnd: seconds)
        c.isPhoto = true
        c.profile = .normal
        return c
    }

    func testNormalFootageSkipsTheLUT() async throws {
        let c = try await color(Project(clips: [blue()]), at: 1)
        XCTAssertGreaterThan(c.b, 0.7, "a plain blue clip stays blue without the D-Log M LUT")
        XCTAssertLessThan(c.r, 0.25)
    }

    func testPhotoClipAndCrossDissolve() async throws {
        var b = blue()
        b.transitionIn = Transition(kind: .crossDissolve, duration: 1)
        let p = Project(clips: [photo(2), b])   // photo 0–2, blue from 1 (overlap 1 s)
        XCTAssertEqual(p.duration, 3, accuracy: 1e-9)
        let start = try await color(p, at: 0.3), mid = try await color(p, at: 1.5), end = try await color(p, at: 2.6)
        XCTAssertGreaterThan(start.r, 0.7, "orange photo")
        XCTAssertGreaterThan(end.b, 0.7, "blue clip")
        XCTAssertTrue(mid.r > 0.3 && mid.b > 0.3, "half way through the dissolve both show: \(mid)")
    }

    func testDipToBlackAndFades() async throws {
        var first = blue()
        first.transitionIn = Transition(kind: .dipToBlack, duration: 1)   // first clip: fade from black
        var second = blue()
        second.transitionIn = Transition(kind: .dipToBlack, duration: 1)
        var p = Project(clips: [first, second])
        p.fadeOut = 0.5
        let opening = try await color(p, at: 0.05), dip = try await color(p, at: 1.5), ending = try await color(p, at: 2.98)
        XCTAssertLessThan(opening.b, 0.15, "fades in from black")
        XCTAssertLessThan(dip.b, 0.15, "black in the middle of a dip")
        XCTAssertLessThan(ending.b, 0.15, "fades out at the end")
    }

    func testOverlayPictureInPicture() async throws {
        var p = Project(clips: [blue()])
        var o = photo(1)
        o.transform = Transform2D(scale: 0.4, x: 0.25, y: -0.25)   // small, top right
        p.overlays = [OverlayItem(clip: o, start: 0.5)]
        let topRight = try await color(p, at: 1, region: CGRect(x: 0.7, y: 0.2, width: 0.1, height: 0.1))
        let bottomLeft = try await color(p, at: 1, region: CGRect(x: 0.1, y: 0.7, width: 0.1, height: 0.1))
        let after = try await color(p, at: 1.8, region: CGRect(x: 0.7, y: 0.2, width: 0.1, height: 0.1))
        XCTAssertGreaterThan(topRight.r, 0.7, "the overlay shows in the top right")
        XCTAssertGreaterThan(bottomLeft.b, 0.7, "the main clip shows elsewhere")
        XCTAssertGreaterThan(after.b, 0.7, "and the overlay is gone after it ends")
    }

    func testVerticalFormatAndZoom() async throws {
        var p = Project(clips: [photo()])
        p.format.aspect = .portrait
        let c = try await color(p, at: 1)
        XCTAssertEqual(c.size.width / c.size.height, 9.0 / 16, accuracy: 0.01)
        XCTAssertGreaterThan(c.r, 0.7)

        // Keyframes: a slow zoom-out from 3× to 1× on a fitted photo leaves bars only at the end.
        var z = photo(2)
        z.keyframes = [Keyframe(time: 0, transform: Transform2D(scale: 3)), Keyframe(time: 2, transform: Transform2D(scale: 1))]
        var q = Project(clips: [z])
        q.format = ProjectFormat(aspect: .portrait, fill: false)
        let edgeStart = try await color(q, at: 0.05, region: CGRect(x: 0.45, y: 0.02, width: 0.1, height: 0.05))
        let edgeEnd = try await color(q, at: 1.95, region: CGRect(x: 0.45, y: 0.02, width: 0.1, height: 0.05))
        XCTAssertGreaterThan(edgeStart.r, 0.7, "zoomed in, the photo covers the top")
        XCTAssertLessThan(edgeEnd.r, 0.1, "zoomed out to fit, black bars at the top")
    }

    func testKeyframeInterpolationAndSplit() {
        var c = photo(4)
        c.keyframes = [Keyframe(time: 0, transform: Transform2D(scale: 1)), Keyframe(time: 4, transform: Transform2D(scale: 2))]
        XCTAssertEqual(c.transform(at: 2).scale, 1.5, accuracy: 1e-6)
        var p = Project(clips: [c])
        p.split(at: 1)
        XCTAssertEqual(p.clips[1].transform(at: 0).scale, c.transform(at: 1).scale, accuracy: 1e-6, "framing stays continuous across a cut")
    }

    func testExportSettingsSizes() {
        let s = ExportSettings(codec: .h264, resolution: .p1080, frameRate: .fps30)
        XCTAssertEqual(s.size(for: CGSize(width: 3840, height: 2160)), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(s.size(for: CGSize(width: 2160, height: 3840)), CGSize(width: 1080, height: 1920), "vertical keeps its shape")
        XCTAssertEqual(ExportSettings().size(for: CGSize(width: 3840, height: 2160)), CGSize(width: 3840, height: 2160))
    }

    func testExportWithSettings() async throws {
        var b = blue()
        b.transitionIn = Transition(kind: .crossDissolve, duration: 0.5)
        let p = Project(clips: [photo(1), b])
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("eddie_settings_test.mov")
        try await Exporter.export(project: p, pool: try await pool(), lut: .djiAction4,
                                  settings: ExportSettings(codec: .h264, resolution: .p720, frameRate: .fps25), to: out) { _ in }
        let asset = AVURLAsset(url: out)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let (size, fps) = try await track.load(.naturalSize, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(size, CGSize(width: 960, height: 720), "the 4:3 photo sets the frame; 720p keeps the shape")
        XCTAssertEqual(fps, 25, accuracy: 0.5)
        XCTAssertEqual(duration, 2.5, accuracy: 0.1)
    }
}
