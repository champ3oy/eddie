import AVFoundation
import CoreImage
import XCTest
@testable import Eddie

/// Speed ramps, GIF export, stabilization, auto reframe, motion tracking, people cut-out.
final class MotionPackTests: XCTestCase {
    func fixture(_ name: String) -> URL { Bundle(for: Self.self).url(forResource: name, withExtension: "mov")! }

    func clip(_ name: String, _ duration: Double) -> ClipItem {
        var c = ClipItem(url: fixture(name), sourceStart: 0, sourceEnd: duration)
        c.profile = .normal
        return c
    }

    func testSpeedRampSplitsIntoSpeeds() {
        var p = Project(clips: [clip("ramp_10bit", 2)])
        let ids = p.speedRamp(p.clips[0].id, .hero)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(p.clips.map(\.speed), [1, 0.35, 1])
        XCTAssertEqual(p.clips.first!.sourceStart, 0)
        XCTAssertEqual(p.clips.last!.sourceEnd, 2, accuracy: 1e-9)
        for (a, b) in zip(p.clips, p.clips.dropFirst()) { XCTAssertEqual(a.sourceEnd, b.sourceStart, accuracy: 1e-9, "no gaps in the source") }
        XCTAssertEqual(p.duration, 0.7 + 0.6 / 0.35 + 0.7, accuracy: 1e-6, "the slow middle makes it longer")
    }

    func testGIFExport() async throws {
        let p = Project(clips: [clip("moving", 1)])
        let url = fixture("moving")
        let pool = MediaPool(videos: [url: try await VideoClip.load(url)], audio: [:], photos: [:])
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("eddie-\(UUID().uuidString.prefix(6)).gif")
        try await Exporter.export(project: p, pool: pool, lut: .djiAction4, settings: ExportSettings(codec: .gif), to: out) { _ in }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, "com.compuserve.gif")
        XCTAssertEqual(CGImageSourceGetCount(src), 12, "1 s at 12 fps")
    }

    func testStabilizeCountersTheShake() async throws {
        let c = clip("shake", 2.9)
        let size = CGSize(width: 320, height: 180)
        let keys = try await VisionTools.stabilize(c, source: size, frame: size, strength: 0.8)
        XCTAssertGreaterThan(keys.count, 20)
        XCTAssertGreaterThan(keys[0].transform.scale, 1.04, "zoomed in to hide the edges")
        // The fixture's window jitters by 18·sin(1.3n) px across; the correction should follow that jitter.
        let jitter = keys.map { 18 * sin(1.3 * ($0.time * 30).rounded()) }
        let xs = keys.map(\.transform.x)
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
            let num = zip(a, b).reduce(0) { $0 + ($1.0 - ma) * ($1.1 - mb) }
            let den = sqrt(a.reduce(0) { $0 + pow($1 - ma, 2) } * b.reduce(0) { $0 + pow($1 - mb, 2) })
            return den > 0 ? num / den : 0
        }
        XCTAssertGreaterThan(corr(xs, jitter), 0.6, "x moves with the jitter to cancel it")
    }

    func testReframeFollowsTheSubject() async throws {
        let c = clip("subject", 2)
        let keys = try await VisionTools.reframe(c, source: CGSize(width: 640, height: 360), frame: CGSize(width: 360, height: 640))
        XCTAssertFalse(keys.isEmpty)
        // The subject is on the left, so the picture moves right to center it.
        XCTAssertGreaterThan(keys.map(\.transform.x).reduce(0, +) / Double(keys.count), 0.3)
        do {
            _ = try await VisionTools.reframe(c, source: CGSize(width: 640, height: 360), frame: CGSize(width: 640, height: 360))
            XCTFail("same shape: nothing to reframe")
        } catch {}
    }

    func testTrackingFollowsTheMovingSquare() async throws {
        let c = clip("moving", 2)
        let url = fixture("moving")
        let p = Project(clips: [c])
        let pool = MediaPool(videos: [url: try await VideoClip.load(url)], audio: [:], photos: [:])
        let compiled = try ProjectCompiler.compile(p, pool: pool, state: GradeState(ProjectCompiler.snapshot(for: p, lut: .djiAction4)))
        let box = CGRect(x: 60.0 / 640, y: 150.0 / 360, width: 60.0 / 640, height: 60.0 / 360)
        let base = Transform2D(scale: 0.1, x: box.midX - 0.5, y: box.midY - 0.5)
        let keys = try await VisionTools.track(composition: compiled.composition, videoComposition: compiled.videoComposition,
                                               box: box, from: 0, to: 1.9, overlayStart: 0, base: base)
        let last = try XCTUnwrap(keys.last)
        // The square moves 180 px/s to the right: about 0.53 of the frame width by 1.9 s.
        XCTAssertEqual(last.transform.x - base.x, (Double(last.time) * 180) / 640, accuracy: 0.08)
        XCTAssertEqual(last.transform.y, base.y, accuracy: 0.05, "it doesn't move vertically")
    }

    func testCutOutWithNoPeopleIsTransparent() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        let out = VisionTools.removeBackground(image)
        let px = GradeRenderer.shared.rgba8(out, maxWidth: 32)
        let maxAlpha = stride(from: 3, to: px.pixels.count, by: 4).map { px.pixels[$0] }.max() ?? 0
        XCTAssertLessThan(maxAlpha, 30, "no one in the picture: nothing kept")
    }
}
