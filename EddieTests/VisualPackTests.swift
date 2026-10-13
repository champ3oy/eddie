import AVFoundation
import CoreImage
import XCTest
@testable import Eddie

/// Green screen, blend modes, masks, blurred background, effects, hidden lanes, overlay lanes, stickers.
final class VisualPackTests: XCTestCase {
    var blueURL: URL { Bundle(for: Self.self).url(forResource: "normal_blue", withExtension: "mov")! }

    /// A solid-color PNG (for overlays).
    func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("solid-\(Int(r * 255))-\(Int(g * 255))-\(Int(b * 255)).png")
        let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    func main() -> ClipItem {
        var c = ClipItem(url: blueURL, sourceStart: 0, sourceEnd: 2)
        c.profile = .normal
        return c
    }

    func overlay(_ url: URL, lane: Int = 0, _ change: (inout ClipItem) -> Void = { _ in }) -> OverlayItem {
        var c = ClipItem(url: url, sourceStart: 0, sourceEnd: 2)
        c.isPhoto = true
        c.profile = .normal
        change(&c)
        return OverlayItem(clip: c, start: 0, lane: lane)
    }

    /// Mean RGB of a region of the frame at 1 s (fractions, y from the top).
    func rgb(_ p: Project, photos: [URL], region: CGRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)) async throws -> [Double] {
        let pool = MediaPool(videos: [blueURL: try await VideoClip.load(blueURL)], audio: [:],
                             photos: Dictionary(uniqueKeysWithValues: photos.map { ($0, CGSize(width: 64, height: 36)) }))
        let compiled = try ProjectCompiler.compile(p, pool: pool, state: GradeState(ProjectCompiler.snapshot(for: p, lut: .djiAction4)))
        let g = AVAssetImageGenerator(asset: compiled.composition)
        g.videoComposition = compiled.videoComposition
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await g.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        let e = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let rect = CGRect(x: e.width * region.minX, y: e.height * (1 - region.maxY), width: e.width * region.width, height: e.height * region.height)
        let px = GradeRenderer.shared.rgba8(CIImage(cgImage: cg).cropped(to: rect), maxWidth: 64)
        return FrameStats(rgba: px.pixels, width: px.width, height: px.height).meanRGB
    }

    func testGreenScreenShowsWhatsUnderneath() async throws {
        let green = try solid(0, 1, 0)
        var p = Project(clips: [main()])
        p.overlays = [overlay(green)]
        let unkeyed = try await rgb(p, photos: [green])
        XCTAssertGreaterThan(unkeyed[1], 0.8, "the green overlay covers the clip")
        p.overlays[0].clip.chromaKey = ChromaKey()
        let keyed = try await rgb(p, photos: [green])
        let clipAlone = try await rgb(Project(clips: [main()]), photos: [])
        for c in 0..<3 { XCTAssertEqual(keyed[c], clipAlone[c], accuracy: 0.06, "green is keyed out; the clip shows through") }
    }

    func testBlendModes() async throws {
        let white = try solid(1, 1, 1)
        var p = Project(clips: [main()])
        p.overlays = [overlay(white)]
        let normal = try await rgb(p, photos: [white])
        XCTAssertGreaterThan(normal[0], 0.9)
        p.overlays[0].blend = .multiply
        let multiplied = try await rgb(p, photos: [white])
        XCTAssertLessThan(multiplied[0], 0.2, "white × blue = blue")
        XCTAssertGreaterThan(multiplied[2], 0.5)
    }

    func testCircleMask() async throws {
        let red = try solid(1, 0, 0)
        var p = Project(clips: [main()])
        p.overlays = [overlay(red) { $0.mask = ClipMask(shape: .circle, width: 0.5, height: 0.5, feather: 0.05) }]
        let center = try await rgb(p, photos: [red])
        let corner = try await rgb(p, photos: [red], region: CGRect(x: 0.02, y: 0.02, width: 0.1, height: 0.1))
        XCTAssertGreaterThan(center[0], 0.8, "inside the circle: the overlay")
        XCTAssertLessThan(corner[0], 0.2, "outside: the clip")
        p.overlays[0].clip.mask?.invert = true
        let inverted = try await rgb(p, photos: [red])
        XCTAssertLessThan(inverted[0], 0.2)
    }

    func testBlurredBackgroundFillsTheBars() async throws {
        var p = Project(clips: [main()])
        p.format = ProjectFormat(aspect: .portrait, fill: false)
        let top = CGRect(x: 0.3, y: 0.03, width: 0.4, height: 0.1)
        let bars = try await rgb(p, photos: [], region: top)
        XCTAssertLessThan(bars[2], 0.05, "black bars above a landscape clip in a vertical frame")
        p.format.blurBackground = true
        let filled = try await rgb(p, photos: [], region: top)
        XCTAssertGreaterThan(filled[2], 0.3, "the blurred clip fills them")
    }

    func testEffects() async throws {
        let white = try solid(1, 1, 1)
        var p = Project(clips: [main()])
        p.overlays = [overlay(white) { $0.transform = .identity }]
        let corner = CGRect(x: 0.0, y: 0.0, width: 0.08, height: 0.08)
        let plain = try await rgb(p, photos: [white], region: corner)
        p.overlays[0].clip.effects = [ClipEffect(kind: .vignette, amount: 1)]
        let vignetted = try await rgb(p, photos: [white], region: corner)
        XCTAssertLessThan(vignetted[0], plain[0] - 0.2, "the vignette darkens the corners")
        XCTAssertNotEqual(VisualEffects.shakeOffset([ClipEffect(kind: .shake, amount: 1)], time: 1.3, size: CGSize(width: 1920, height: 1080)), .zero)
        // Every effect renders without breaking the picture.
        let image = CIImage(color: CIColor(red: 0.5, green: 0.4, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        for kind in ClipEffect.Kind.allCases {
            let out = VisualEffects.apply([ClipEffect(kind: kind, amount: 0.7)], to: image, time: 1.7)
            XCTAssertEqual(out.extent.size, image.extent.size, "\(kind)")
            let px = GradeRenderer.shared.rgba8(out, maxWidth: 32)
            XCTAssertFalse(px.pixels.isEmpty, "\(kind)")
        }
    }

    /// Effects on the effects lane only act during their stretch of time, on everything under them.
    func testEffectsLaneAppliesOnlyInItsRange() async throws {
        let white = try solid(1, 1, 1)
        var p = Project(clips: [main()])
        p.overlays = [overlay(white) { $0.transform = .identity }]
        let corner = CGRect(x: 0.0, y: 0.0, width: 0.08, height: 0.08)
        let plain = try await rgb(p, photos: [white], region: corner)
        let plainCenter = try await rgb(p, photos: [white])
        p.effects = [EffectItem(kind: .vignette, amount: 1, start: 1.5, duration: 0.5)]
        let before = try await rgb(p, photos: [white], region: corner)
        XCTAssertEqual(before[0], plain[0], accuracy: 0.02, "at 1 s the effect hasn't started")
        p.effects[0].start = 0.5; p.effects[0].duration = 1
        let during = try await rgb(p, photos: [white], region: corner)
        XCTAssertLessThan(during[0], plain[0] - 0.2, "inside its range the corners darken")
        let center = try await rgb(p, photos: [white])
        XCTAssertEqual(center[0], plainCenter[0], accuracy: 0.08, "a vignette leaves the middle alone")
        p.hiddenLanes = ["effects"]
        let hidden = try await rgb(p, photos: [white], region: corner)
        XCTAssertEqual(hidden[0], plain[0], accuracy: 0.02, "hiding the effects lane turns them off")
    }

    func testHiddenLanesAndOverlayOrder() async throws {
        let red = try solid(1, 0, 0), green = try solid(0, 1, 0)
        var p = Project(clips: [main()])
        // Listed red-then-green, but red is on the higher lane, so red is on top.
        p.overlays = [overlay(red, lane: 1), overlay(green, lane: 0)]
        p.overlays[1].clip.id = UUID()
        let top = try await rgb(p, photos: [red, green])
        XCTAssertGreaterThan(top[0], 0.8)
        p.hiddenLanes = [Project.overlayLane(1)]
        let hiddenRed = try await rgb(p, photos: [red, green])
        XCTAssertGreaterThan(hiddenRed[1], 0.8, "with lane 2 hidden, green shows")
        p.hiddenLanes = [Project.overlayLane(0), Project.overlayLane(1), "video"]
        let nothing = try await rgb(p, photos: [red, green])
        XCTAssertLessThan(nothing.max()!, 0.05, "everything hidden: black")
    }

    @MainActor
    func testStickerImage() throws {
        let url = try EditorModel.stickerImage("🔥")
        let image = try XCTUnwrap(CIImage(contentsOf: url))
        XCTAssertEqual(image.extent.width, 512)
        let px = GradeRenderer.shared.rgba8(image, maxWidth: 64)
        let opaque = stride(from: 3, to: px.pixels.count, by: 4).filter { px.pixels[$0] > 200 }.count
        XCTAssertGreaterThan(opaque, 200, "the emoji is drawn")
        XCTAssertLessThan(opaque, 64 * 64, "with a transparent background")
    }

    func testOldOverlaysAndFormatsStillOpen() throws {
        let o = #"{"clip":{"id":"\#(UUID())","url":"file:///a.png","sourceStart":0,"sourceEnd":3},"start":1,"opacity":0.5}"#
        let item = try JSONDecoder().decode(OverlayItem.self, from: Data(o.utf8))
        XCTAssertEqual(item.blend, .normal)
        XCTAssertEqual(item.lane, 0)
        XCTAssertEqual(item.clip.effects, [])
        let f = try JSONDecoder().decode(ProjectFormat.self, from: Data(#"{"aspect":"portrait","fill":false}"#.utf8))
        XCTAssertFalse(f.blurBackground)
    }
}
