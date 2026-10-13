import AVFoundation
import CoreImage
import XCTest
@testable import Eddie

/// Captions: SRT, manual captions, styles, word timing, the new text looks, and tightening the edit.
final class CaptionTests: XCTestCase {
    func caption(_ text: String, _ start: Double, _ duration: Double) -> TitleItem {
        var c = TitleItem(text: text, start: start, duration: duration, style: .caption)
        c.isCaption = true
        return c
    }

    func testSRTRoundTrip() {
        let caps = [caption("Hello there.", 0.5, 1.25), caption("Line one\nLine two", 62.004, 2)]
        let srt = SRT.export(caps)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,500 --> 00:00:01,750\nHello there.\n"))
        XCTAssertTrue(srt.contains("2\n00:01:02,004 --> 00:01:04,004\nLine one\nLine two"))
        let back = CaptionMaker.fromSRT(srt)
        XCTAssertEqual(back.map(\.text), ["Hello there.", "Line one\nLine two"])
        XCTAssertEqual(back[1].start, 62.004, accuracy: 0.001)
        XCTAssertTrue(back.allSatisfy(\.isCaption))
    }

    func testSRTFromOtherApps() {
        // Windows line endings, dots instead of commas, formatting tags, no trailing blank line.
        let text = "1\r\n00:00:01.000 --> 00:00:02.500\r\n<i>Hi</i> <b>you</b>\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nBye"
        let parsed = SRT.parse(text)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].text, "Hi you")
        XCTAssertEqual(parsed[0].end, 2.5, accuracy: 1e-9)
        XCTAssertEqual(parsed[1].text, "Bye")
    }

    func testManualCaptionsSpreadOverTheVideo() {
        let script = "First line\n\nA much longer second line that will need to be split into two pieces for reading\nEnd"
        let caps = CaptionMaker.manual(script, from: 2, to: 12)
        XCTAssertGreaterThanOrEqual(caps.count, 4, "the long line is split")
        XCTAssertTrue(caps.allSatisfy { $0.text.count <= 42 })
        XCTAssertEqual(caps.first!.start, 2, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(caps.last!.end, 12.0001)
        for (a, b) in zip(caps, caps.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 1e-9) }
        XCTAssertGreaterThan(caps[1].duration, caps[0].duration, "longer lines stay up longer")
    }

    func testPresetsAndWordTiming() {
        var c = caption("one two three", 10, 3)
        CaptionPreset.all.first { $0.name == "Highlight" }!.apply(&c)
        XCTAssertTrue(c.wordHighlight)
        XCTAssertGreaterThan(c.outline, 0)
        // No speech timings: words are spread over the caption.
        let even = c.timedWords
        XCTAssertEqual(even.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(even.first!.start, 10, accuracy: 1e-9)
        XCTAssertEqual(even.last!.end, 13, accuracy: 1e-9)
        // Speech timings are used while they still match the text.
        c.words = [.init(text: "one", start: 10, end: 10.2), .init(text: "two", start: 11, end: 11.3), .init(text: "three", start: 12, end: 12.9)]
        XCTAssertEqual(c.timedWords[1].start, 11)
        c.text = "one two three four"
        XCTAssertEqual(c.timedWords.count, 4, "edited text falls back to even spacing")
    }

    func testOldTitlesStillOpen() throws {
        let json = #"{"id":"\#(UUID())","text":"Hi","start":1,"duration":2,"style":"caption","isCaption":true}"#
        let t = try JSONDecoder().decode(TitleItem.self, from: Data(json.utf8))
        XCTAssertEqual(t.animation, .fade)
        XCTAssertEqual(t.outline, 0)
        XCTAssertFalse(t.wordHighlight)
    }

    // MARK: Rendering

    let frame = CGSize(width: 1280, height: 720)

    func opaquePixels(_ image: CIImage?) -> Int {
        guard let image else { return 0 }
        let px = GradeRenderer.shared.rgba8(image.cropped(to: CGRect(origin: .zero, size: frame)).composited(over: CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: frame))), maxWidth: 320)
        return stride(from: 3, to: px.pixels.count, by: 4).filter { px.pixels[$0] > 128 }.count
    }

    func testOutlineAndGlowGrowTheText() {
        var plain = caption("Big words", 0, 3)
        plain.plate = false
        var outlined = plain; outlined.outline = 0.15
        var glowing = plain; glowing.glow = 1
        let a = opaquePixels(TitleRenderer.overlay(plain, renderSize: frame, at: 1))
        let b = opaquePixels(TitleRenderer.overlay(outlined, renderSize: frame, at: 1))
        let c = opaquePixels(TitleRenderer.overlay(glowing, renderSize: frame, at: 1))
        XCTAssertGreaterThan(b, a, "the outline adds to the letters")
        XCTAssertGreaterThan(c, a, "the glow spreads around them")
    }

    func testTypewriterRevealsLetters() {
        var t = caption("Typing this out slowly", 0, 4)
        t.plate = false
        t.animation = .typewriter
        let early = opaquePixels(TitleRenderer.overlay(t, renderSize: frame, at: 0.2))
        let late = opaquePixels(TitleRenderer.overlay(t, renderSize: frame, at: 2.5))
        XCTAssertGreaterThan(late, early * 2)
    }

    func testPopStartsSmall() {
        var t = caption("Pop", 0, 3)
        t.animation = .pop
        XCTAssertLessThan(TitleRenderer.motion(t, at: 0.05).scale, 0.9)
        XCTAssertEqual(TitleRenderer.motion(t, at: 1).scale, 1, accuracy: 0.01)
        t.animation = .slideUp
        XCTAssertLessThan(TitleRenderer.motion(t, at: 0.02).lift, 0)
        XCTAssertEqual(TitleRenderer.motion(t, at: 1).lift, 0, accuracy: 1e-6)
    }

    func testWordHighlightColorsTheCurrentWord() {
        var t = caption("one two", 0, 2)
        t.plate = false
        t.wordHighlight = true
        t.color = "#FFFFFF"
        t.highlightColor = "#FF0000"
        t.animation = .none
        t.words = [.init(text: "one", start: 0, end: 1), .init(text: "two", start: 1, end: 2)]
        func redPixelsOnLeft(_ time: Double) -> Int {
            let img = TitleRenderer.overlay(t, renderSize: frame, at: time)!
            let left = img.cropped(to: CGRect(x: 0, y: 0, width: frame.width / 2, height: frame.height))
            let px = GradeRenderer.shared.rgba8(left.composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: frame.width / 2, height: frame.height))), maxWidth: 320)
            return stride(from: 0, to: px.pixels.count, by: 4).filter { px.pixels[$0] > 150 && px.pixels[$0 + 1] < 80 }.count
        }
        XCTAssertGreaterThan(redPixelsOnLeft(0.5), 20, "the first word is red while it's said")
        XCTAssertLessThan(redPixelsOnLeft(1.5), 5, "then the second word (on the right) is")
    }

    // MARK: Tightening

    func testRemoveRangesClosesGapsAndMovesThingsBack() {
        let url = URL(fileURLWithPath: "/tmp/x.mov")
        var p = Project(clips: [ClipItem(url: url, sourceStart: 0, sourceEnd: 4), ClipItem(url: url, sourceStart: 10, sourceEnd: 14)])
        p.clips[1].id = UUID()
        p.titles = [caption("before", 0.2, 0.5), caption("inside", 1.1, 0.3), caption("after", 5, 1)]
        p.music = [MusicItem(url: url, start: 6, sourceEnd: 2)]
        p.markers = [Marker(time: 7, name: "m")]
        p.removeRanges([(1.0, 1.5), (4.5, 5.0)])
        XCTAssertEqual(p.duration, 7, accuracy: 1e-6)
        XCTAssertEqual(p.titles.map(\.text), ["before", "after"])
        XCTAssertEqual(p.titles[1].start, 4, accuracy: 1e-6)
        XCTAssertEqual(p.music[0].start, 5, accuracy: 1e-6)
        XCTAssertEqual(p.markers[0].time, 6, accuracy: 1e-6)
    }

    func testFillerWordsAreFound() {
        let words: [Captioner.Word] = [.init(text: "So", start: 0, duration: 0.2), .init(text: "um,", start: 0.3, duration: 0.3),
                                       .init(text: "this", start: 0.7, duration: 0.2), .init(text: "Uh", start: 1, duration: 0.2)]
        let r = SpeechCleanup.fillerRanges(words)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].start, 0.27, accuracy: 1e-9)
    }

    func testPausesAreFound() async throws {
        let url = Bundle(for: Self.self).url(forResource: "pause", withExtension: "mov")!
        var c = ClipItem(url: url, sourceStart: 0, sourceEnd: 3.9)
        c.profile = .normal
        let ranges = await SpeechCleanup.silenceRanges(Project(clips: [c]), minimum: 0.7)
        XCTAssertEqual(ranges.count, 1)
        // Silence is 1.0–2.5 s; 0.15 s is kept at each edge.
        XCTAssertEqual(ranges[0].start, 1.15, accuracy: 0.1)
        XCTAssertEqual(ranges[0].end, 2.35, accuracy: 0.1)
    }
}

/// The outline sits outside the letters, so white text stays white.
final class OutlineTests: XCTestCase {
    func testOutlinedTextStaysBright() {
        var t = TitleItem(text: "Lapland at dawn", start: 0, duration: 3, style: .caption)
        CaptionPreset.all.first { $0.name == "Highlight" }!.apply(&t)
        t.wordHighlight = false
        t.animation = .none
        let frame = CGSize(width: 1280, height: 720)
        let image = TitleRenderer.overlay(t, renderSize: frame, at: 1)!
        let px = GradeRenderer.shared.rgba8(image.composited(over: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: frame))), maxWidth: 640)
        var white = 0, black = 0
        for i in stride(from: 0, to: px.pixels.count, by: 4) {
            let v = Int(px.pixels[i]) + Int(px.pixels[i + 1]) + Int(px.pixels[i + 2])
            if v > 700 { white += 1 } else if v < 60 { black += 1 }
        }
        if let out = ProcessInfo.processInfo.environment["EDDIE_SNAPSHOT_OUT"] {
            let cg = GradeRenderer.shared.context.createCGImage(image.composited(over: CIImage(color: CIColor(red: 0.45, green: 0.55, blue: 0.65)).cropped(to: CGRect(origin: .zero, size: frame))).cropped(to: CGRect(x: 200, y: 0, width: 880, height: 160)), from: CGRect(x: 200, y: 0, width: 880, height: 160))!
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("outline.png"))
        }
        XCTAssertGreaterThan(white, 400, "plenty of white letter pixels")
        XCTAssertGreaterThan(black, 200, "and a dark outline around them")
    }
}
