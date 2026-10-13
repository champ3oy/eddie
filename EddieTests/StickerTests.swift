import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Eddie

/// The emoji library, GIPHY results, and animated GIF overlays.
final class StickerTests: XCTestCase {
    func testWholeEmojiLibrary() {
        XCTAssertGreaterThan(EmojiCatalog.all.count, 3000, "skin tones, families and flags included")
        let browse = EmojiCatalog.byGroup
        XCTAssertEqual(browse.first?.group, "Smileys & Emotion")
        XCTAssertTrue(browse.contains { $0.group == "Flags" && $0.emoji.contains("🇬🇭") })
        XCTAssertFalse(browse.flatMap(\.emoji).contains("👍🏾"), "skin-tone copies stay out of browsing")
    }

    func testEmojiSearch() {
        XCTAssertEqual(EmojiCatalog.search("").count, EditorModel.stickerEmoji.count, "empty search shows the favorites")
        XCTAssertEqual(EmojiCatalog.search("map").first, "🗺️", "a whole-word match comes before maple leaf")
        XCTAssertTrue(EmojiCatalog.search("fire").contains("🔥"))
        XCTAssertTrue(EmojiCatalog.search("dog").contains("🐶"))
        XCTAssertTrue(EmojiCatalog.search("love").contains("😍"))
        XCTAssertTrue(EmojiCatalog.search("ghana").contains("🇬🇭"))
        XCTAssertTrue(EmojiCatalog.search("thumbs dark").contains("👍🏿"), "tones show when asked for")
        XCTAssertFalse(EmojiCatalog.search("thumbs").contains("👍🏿"))
        XCTAssertEqual(EmojiCatalog.search("🦄"), ["🦄"], "pasting an emoji uses it")
        XCTAssertEqual(EmojiCatalog.search("zzzqqq"), [])
    }

    func testGiphyResponse() throws {
        let json = """
        {"data":[
          {"type":"gif","id":"abc123","title":"Happy Dance","images":{
            "fixed_width_small":{"url":"https://media.giphy.com/media/abc123/100w.gif","width":"100","height":"50"},
            "downsized":{"url":"https://media.giphy.com/media/abc123/giphy-downsized.gif","width":"400","height":"200"},
            "original":{"url":"https://media.giphy.com/media/abc123/giphy.gif"}},
           "analytics":{"onsent":{"url":"https://giphy-analytics.giphy.com/v2/pingback_simple?x=1"}}},
          {"type":"gif","id":"nofull","title":"Broken","images":{"fixed_width_small":{"url":"https://x/y.gif"}}}
        ],"meta":{"status":200}}
        """
        let items = try Giphy.parse(Data(json.utf8))
        XCTAssertEqual(items.count, 1, "results without a usable file are skipped")
        XCTAssertEqual(items[0].id, "abc123")
        XCTAssertEqual(items[0].aspect, 2)
        XCTAssertEqual(items[0].full.lastPathComponent, "giphy-downsized.gif")
        XCTAssertNotNil(items[0].sentPing)
    }

    /// A 3-frame GIF (red, green, blue; 0.2 s each).
    func makeGIF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anim-\(UUID().uuidString.prefix(6)).gif")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil))
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (r, g, b) in [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)] {
            let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testAnimatedFramesLoop() throws {
        let anim = try XCTUnwrap(AnimatedImage.load(try makeGIF()))
        XCTAssertEqual(anim.frames.count, 3)
        XCTAssertEqual(anim.duration, 0.6, accuracy: 0.001)
        func red(_ t: Double) -> Double { mean(anim.frame(at: t))[0] }
        func green(_ t: Double) -> Double { mean(anim.frame(at: t))[1] }
        XCTAssertGreaterThan(red(0.05), 0.8)
        XCTAssertGreaterThan(green(0.3), 0.8)
        XCTAssertGreaterThan(red(0.65), 0.8, "it loops")
        XCTAssertNil(AnimatedImage.load(Bundle(for: Self.self).url(forResource: "photo_test", withExtension: "jpg")!), "a photo isn't animated")
    }

    /// The GIF plays on the video (and so in exports): different frames at different times.
    func testGIFOverlayPlaysInTheRender() async throws {
        let gif = try makeGIF()
        let blue = Bundle(for: Self.self).url(forResource: "normal_blue", withExtension: "mov")!
        var main = ClipItem(url: blue, sourceStart: 0, sourceEnd: 2)
        main.profile = .normal
        var c = ClipItem(url: gif, sourceStart: 0, sourceEnd: 2)
        c.isPhoto = true
        c.profile = .normal
        var p = Project(clips: [main])
        p.overlays = [OverlayItem(clip: c, start: 0, lane: 0)]
        let pool = MediaPool(videos: [blue: try await VideoClip.load(blue)], audio: [:], photos: [gif: CGSize(width: 64, height: 36)])
        let compiled = try ProjectCompiler.compile(p, pool: pool, state: GradeState(ProjectCompiler.snapshot(for: p, lut: .djiAction4)))
        let g = AVAssetImageGenerator(asset: compiled.composition)
        g.videoComposition = compiled.videoComposition
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        func center(_ t: Double) async throws -> [Double] {
            let (cg, _) = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let r = CGRect(x: cg.width / 2 - 8, y: cg.height / 2 - 8, width: 16, height: 16)
            return mean(CIImage(cgImage: cg).cropped(to: r))
        }
        let a = try await center(0.1), b = try await center(0.3)
        XCTAssertGreaterThan(a[0], 0.7, "red frame first")
        XCTAssertGreaterThan(b[1], 0.7, "then green")
    }

    private func mean(_ image: CIImage) -> [Double] {
        let px = GradeRenderer.shared.rgba8(image, maxWidth: 32)
        return FrameStats(rgba: px.pixels, width: px.width, height: px.height).meanRGB
    }
}

final class GiphyKeyTests: XCTestCase {
    func testBuiltInKeyUnscrambles() {
        // Same scrambling as scripts/release.sh: XOR with "eddie-giphy", then hex.
        let key = "abc123XYZ"
        let mask = Array("eddie-giphy".utf8)
        let hex = key.utf8.enumerated().map { String(format: "%02x", $0.element ^ mask[$0.offset % mask.count]) }.joined()
        XCTAssertEqual(Giphy.unscramble(hex), key)
        XCTAssertEqual(Giphy.unscramble("$(EDDIE_GIPHY_KEY)"), "", "an unfilled placeholder means no key")
        XCTAssertEqual(Giphy.unscramble(""), "")
        XCTAssertFalse(Giphy.hasBuiltInKey, "source builds carry no key")
    }
}
