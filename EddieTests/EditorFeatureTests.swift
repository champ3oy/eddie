import AVFoundation
import CoreImage
import XCTest
@testable import Eddie

/// Media bin/relink, insert/overwrite, reverse, freeze, audio clean-up, beats, captions, caches, AI tools.
final class EditorFeatureTests: XCTestCase {
    var blueURL: URL { Bundle(for: Self.self).url(forResource: "normal_blue", withExtension: "mov")! }
    var rampURL: URL { Bundle(for: Self.self).url(forResource: "ramp_10bit", withExtension: "mov")! }
    var musicURL: URL { Bundle(for: Self.self).url(forResource: "music_test", withExtension: "m4a")! }
    var speechURL: URL { Bundle(for: Self.self).url(forResource: "speech", withExtension: "mov")! }

    func clip(_ url: URL, _ a: Double = 0, _ b: Double = 2) -> ClipItem {
        var c = ClipItem(url: url, sourceStart: a, sourceEnd: b)
        c.profile = .normal
        return c
    }

    // MARK: Timeline edits

    func testInsertSplitsAndPushesAlong() {
        var p = Project(clips: [clip(blueURL), clip(blueURL)])
        let new = clip(rampURL, 0, 1)
        p.insert([new], atTime: 1)
        XCTAssertEqual(p.clips.count, 4)
        XCTAssertEqual(p.clips[1].id, new.id)
        XCTAssertEqual(p.duration, 5, accuracy: 1e-6)
    }

    func testOverwriteReplacesRange() {
        var p = Project(clips: [clip(blueURL), clip(blueURL)])
        let new = clip(rampURL, 0, 1)
        p.overwrite([new], atTime: 1.5)
        XCTAssertEqual(p.duration, 4, accuracy: 1e-6, "overwrite keeps the length")
        XCTAssertEqual(p.starts[p.index(of: new.id)!], 1.5, accuracy: 1e-6)
    }

    func testReversedClipSplitsAtTheRightSourceTime() {
        var c = clip(rampURL, 0, 2)
        c.reversed = true
        var p = Project(clips: [c])
        XCTAssertEqual(p.locate(0.5)!.sourceTime, 1.5, accuracy: 1e-6)
        p.split(at: 0.5)
        XCTAssertEqual(p.clips[0].sourceStart, 1.5, accuracy: 1e-6, "first half plays 2 → 1.5")
        XCTAssertEqual(p.clips[0].sourceEnd, 2, accuracy: 1e-6)
        XCTAssertEqual(p.clips[1].sourceStart, 0, accuracy: 1e-6)
        XCTAssertEqual(p.clips[1].sourceEnd, 1.5, accuracy: 1e-6)
    }

    func testRemovedMediaStaysInBinAndRelinks() {
        var p = Project(clips: [clip(blueURL)])
        p.remove(p.clips[0].id)
        XCTAssertEqual(p.bin, [blueURL])
        let moved = URL(fileURLWithPath: "/tmp/elsewhere/normal_blue.mov")
        p.clips = [clip(blueURL)]
        p.relink(blueURL, to: moved)
        XCTAssertEqual(p.clips[0].url, moved)
        XCTAssertEqual(p.bin, [moved])
        XCTAssertEqual(p.mediaURLs, [moved])
    }

    func testOldProjectsDecodeWithoutNewFields() throws {
        let json = #"{"clips":[],"music":[{"id":"\#(UUID())","url":"file:///a.m4a","start":0,"sourceEnd":3}]}"#
        let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(p.bin, [])
        XCTAssertNil(p.music[0].processed)
        XCTAssertEqual(p.music[0].beats, [])
    }

    func testBeatsAreSnapTargets() {
        var m = MusicItem(url: musicURL, start: 10, sourceStart: 1, sourceEnd: 4)
        m.beats = [0.5, 1.5, 2.5, 4.5]
        var p = Project(clips: [clip(blueURL)])
        p.music = [m]
        XCTAssertEqual(p.beatTimes(), [10.5, 11.5])
        XCTAssertTrue(p.edges().contains(11.5))
    }

    // MARK: Media processing

    func testReverserPlaysBackwards() async throws {
        let r = try await Reverser.reverse(rampURL)
        let original = try await VideoClip.load(rampURL)
        let reversed = try await VideoClip.load(r.video)
        XCTAssertEqual(reversed.duration.seconds, original.duration.seconds, accuracy: 0.1)
        XCTAssertNotNil(r.audio)
        func luma(_ url: URL, _ t: Double) async throws -> Double {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            let (cg, _) = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let px = GradeRenderer.shared.rgba8(CIImage(cgImage: cg), maxWidth: 32)
            return FrameStats(rgba: px.pixels, width: px.width, height: px.height).meanRGB[0]
        }
        let startOfReversed = try await luma(r.video, 0.1)
        let endOfOriginal = try await luma(rampURL, 1.85)
        let startOfOriginal = try await luma(rampURL, 0.1)
        XCTAssertGreaterThan(startOfReversed, startOfOriginal + 0.3, "the ramp runs bright → dark when reversed")
        XCTAssertEqual(startOfReversed, endOfOriginal, accuracy: 0.08)
    }

    func testNormalizeReachesTargetLoudness() async throws {
        let quiet = try await AudioProcessor.decode(musicURL)
        for c in 0..<2 { for i in 0..<Int(quiet.frameLength) { quiet.floatChannelData![c][i] *= 0.05 } }
        XCTAssertLessThan(AudioProcessor.loudness(quiet).rms, AudioProcessor.targetRMS - 10)
        AudioProcessor.normalize(quiet)
        let (rms, peak) = AudioProcessor.loudness(quiet)
        XCTAssertEqual(rms, AudioProcessor.targetRMS, accuracy: 2.5)
        XCTAssertLessThanOrEqual(peak, 0.9)
    }

    func testProcessWritesANewFileAndLeavesTheOriginal() async throws {
        let before = try Data(contentsOf: musicURL)
        let out = try await AudioProcessor.process(musicURL, options: .init(normalize: true))
        XCTAssertEqual(try Data(contentsOf: musicURL), before)
        let src = try await MusicSource.load(out)
        XCTAssertEqual(src.duration, 6, accuracy: 0.1)
    }

    func testNoiseReductionRunsWhenAvailable() async throws {
        let buffer = try await AudioProcessor.decode(speechURL)
        do {
            let clean = try AudioProcessor.isolateVoice(buffer)
            XCTAssertEqual(Int(clean.frameLength), Int(buffer.frameLength), accuracy: 4096)
            XCTAssertGreaterThan(AudioProcessor.loudness(clean).rms, -80, "speech survives")
        } catch let e as CocoaError where e.code == .featureUnsupported {
            throw XCTSkip("AUSoundIsolation not on this Mac")
        }
    }

    func testBeatDetectorFindsTempo() {
        // 120 BPM clicks for 8 seconds.
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let n = Int(rate * 8)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = AVAudioFrameCount(n)
        for beat in 0..<16 {
            let s = Int(Double(beat) * 0.5 * rate)
            for j in 0..<800 where s + j < n {
                let v = Float(sin(Double(j) * 0.3) * exp(-Double(j) / 200))
                b.floatChannelData![0][s + j] = v
                b.floatChannelData![1][s + j] = v
            }
        }
        let beats = BeatDetector.beats(b)
        XCTAssertEqual(BeatDetector.tempo(of: beats) ?? 0, 120, accuracy: 4)
        XCTAssertEqual(beats.first ?? 1, 0, accuracy: 0.05)
    }

    func testCaptionLinesBreakAtSentencesAndPauses() {
        let w: [Captioner.Word] = [
            .init(text: "Hello", start: 0, duration: 0.3), .init(text: "there.", start: 0.35, duration: 0.3),
            .init(text: "This", start: 1.0, duration: 0.2), .init(text: "is", start: 1.25, duration: 0.1),
            .init(text: "a", start: 1.4, duration: 0.1), .init(text: "test", start: 3.0, duration: 0.3),
        ]
        let lines = Captioner.lines(from: w)
        XCTAssertEqual(lines.map(\.text), ["Hello there.", "This is a", "test"])
        XCTAssertTrue(lines.allSatisfy { $0.isCaption && $0.style == .caption })
        for (a, b) in zip(lines, lines.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 1e-9) }
    }

    func testWaveformCacheRoundTrip() {
        let peaks: [Float] = [0.1, 0.5, 0.9]
        MediaCache.storeWaveform(peaks, for: musicURL, buckets: 3)
        XCTAssertEqual(MediaCache.waveform(for: musicURL, buckets: 3), peaks)
        XCTAssertNil(MediaCache.waveform(for: musicURL, buckets: 4))
    }

    func testThumbnailIsCachedOnDisk() async throws {
        let first = await MediaCache.thumbnail(for: blueURL, maxSide: 120)
        XCTAssertNotNil(first)
        let files = try FileManager.default.contentsOfDirectory(atPath: MediaCache.folder("Thumbnails").path)
        XCTAssertFalse(files.isEmpty)
    }

    func testExportH264IsMP4() async throws {
        let p = Project(clips: [clip(blueURL, 0, 1)])
        let pool = MediaPool(videos: [blueURL: try await VideoClip.load(blueURL)], audio: [:], photos: [:])
        let s = ExportSettings(codec: .h264, resolution: .p720, frameRate: .fps30)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("eddie-h264-\(UUID()).\(s.fileExtension)")
        try await Exporter.export(project: p, pool: pool, lut: .djiAction4, settings: s, to: out) { _ in }
        XCTAssertEqual(out.pathExtension, "mp4")
        // A real MP4, not a QuickTime file with an .mp4 name: the major brand isn't "qt  ".
        let head = try FileHandle(forReadingFrom: out).read(upToCount: 12) ?? Data()
        XCTAssertEqual(String(decoding: head[4..<8], as: UTF8.self), "ftyp")
        XCTAssertNotEqual(String(decoding: head[8..<12], as: UTF8.self), "qt  ")
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(d, 1, accuracy: 0.1)
    }

    // MARK: AI tools

    func testAgentToolsForNewFeatures() {
        var p = Project(clips: [clip(blueURL), clip(blueURL), clip(blueURL)])
        p.overlays = [OverlayItem(clip: clip(rampURL, 0, 1), start: 0.5)]
        p.music = [MusicItem(url: musicURL, start: 0, sourceEnd: 6)]
        let labels = TimelineLabels(p)
        let actions = [
            EditAction(type: "transition", clip: "all", duration: 0.5, kind: "wipe"),
            EditAction(type: "fade", fade_in: 1, fade_out: 2),
            EditAction(type: "format", aspect: "9:16"),
            EditAction(type: "framing", clip: "c2", x: 0.2, size: 1.5),
            EditAction(type: "ken_burns", clip: "c3"),
            EditAction(type: "overlay", target: "o1", opacity: 0.5, layout: "pip"),
            EditAction(type: "marker", at: 3, text: "Drop"),
            EditAction(type: "profile", clip: "c1", profile: "dlogM"),
            EditAction(type: "reverse", clip: "c2"),
            EditAction(type: "clean_audio", target: "m1", kind: "noise"),
            EditAction(type: "captions"),
            EditAction(type: "beats", music: "m1"),
        ]
        let r = EditExecutor.apply(actions, to: p, labels: labels, playhead: 0, sourceDuration: { _ in 2 })
        XCTAssertEqual(r.errors, [])
        let q = r.project
        XCTAssertEqual(q.clips[0].transitionIn?.kind, .dipToBlack, "fade_in is a fade from black on the first clip")
        XCTAssertEqual(q.clips[1].transitionIn?.kind, .wipe)
        XCTAssertEqual(q.clips[2].transitionIn?.duration ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(q.fadeOut, 2)
        XCTAssertEqual(q.format.aspect, .portrait)
        XCTAssertEqual(q.clips[1].transform.scale, 1.5)
        XCTAssertEqual(q.clips[1].transform.x, 0.2)
        XCTAssertEqual(q.clips[2].keyframes.count, 2)
        XCTAssertEqual(q.overlays[0].opacity, 0.5)
        XCTAssertLessThan(q.overlays[0].clip.transform.scale, 0.5)
        XCTAssertEqual(q.markers.map(\.name), ["Drop"])
        XCTAssertEqual(q.clips[0].profile, .dlogM)
        XCTAssertEqual(r.jobs, [.reverse(p.clips[1].id), .reduceNoise(p.music[0].id), .captions, .beats(p.music[0].id)])
        let text = TimelineDescriber.describe(q, playhead: 0)
        XCTAssertTrue(text.contains("o1:"))
        XCTAssertTrue(text.contains("wipe transition"))
        XCTAssertTrue(text.contains("Markers: k1"))
    }

    // MARK: Model wiring

    @MainActor
    func testCopyPasteAndMarkers() async throws {
        let model = EditorModel()
        model.addClips([blueURL])
        try await waitUntil { model.project.clips.count == 1 }
        let id = model.project.clips[0].id
        model.select(id, adding: false)
        model.copySelection()
        model.seek(to: 2)
        model.paste()
        XCTAssertEqual(model.project.clips.count, 2)
        XCTAssertNotEqual(model.project.clips[1].id, id)
        model.addMarker()
        XCTAssertEqual(model.project.markers.count, 1)
        model.seek(to: 0)
        model.jump(forward: true)
        XCTAssertEqual(model.clock.time, 2, accuracy: 0.05)
        model.selectAll()
        XCTAssertEqual(model.selectedIDs.count, 2)
        model.deleteSelection()
        XCTAssertTrue(model.project.clips.isEmpty)
        XCTAssertEqual(model.project.bin, [blueURL])
    }

    @MainActor
    func waitUntil(timeout: Double = 10, _ cond: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Each lane's speaker button mutes only that lane — in playback and export.
final class LaneMuteTests: XCTestCase {
    var rampURL: URL { Bundle(for: Self.self).url(forResource: "ramp_10bit", withExtension: "mov")! }
    var speechURL: URL { Bundle(for: Self.self).url(forResource: "speech", withExtension: "mov")! }

    func mix(_ p: Project) async throws -> [Float] {
        var c1 = p
        c1.duckUnderMusic = false
        let pool = MediaPool(videos: [rampURL: try await VideoClip.load(rampURL)],
                             audio: [speechURL: try await MusicSource.load(speechURL)], photos: [:])
        let compiled = try ProjectCompiler.compile(c1, pool: pool, state: GradeState(ProjectCompiler.snapshot(for: c1, lut: .djiAction4)))
        return try MusicPlaybackTests.loudness(compiled)
    }

    func project() -> Project {
        var clip = ClipItem(url: rampURL, sourceStart: 0, sourceEnd: 2)
        clip.profile = .normal
        var p = Project(clips: [clip, clip])
        p.clips[1].id = UUID()
        var vo = MusicItem(url: speechURL, start: 0, sourceEnd: 3.4)
        vo.kind = .voiceover; vo.volume = 1; vo.fadeIn = 0; vo.fadeOut = 0
        p.music = [vo]
        return p
    }

    func testMutingTheVideoSoundKeepsTheVoiceover() async throws {
        var p = project()
        p.music = []
        let videoOnly = try await mix(p)
        XCTAssertGreaterThan(videoOnly.max() ?? 0, 0.05, "the clips have sound (a tone)")

        p = project()
        p.mutedLanes = [Project.clipSoundLane]
        let voiceOnly = try await mix(p)
        XCTAssertGreaterThan(voiceOnly.max() ?? 0, 0.02, "the voiceover is still heard with the video sound muted")

        p.mutedLanes = [Project.clipSoundLane, Project.audioLane(0)]
        let silent = try await mix(p)
        XCTAssertLessThan(silent.max() ?? 1, 0.002, "muting the voiceover's lane too leaves silence")

        p.mutedLanes = [Project.audioLane(0)]
        let tone = try await mix(p)
        XCTAssertEqual(tone.max() ?? 0, videoOnly.max() ?? 0, accuracy: 0.02, "muting the voice lane leaves the video sound alone")
    }

    func testMutedLanesSaveWithTheProject() throws {
        var p = project()
        p.mutedLanes = [Project.clipSoundLane]
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.mutedLanes, [Project.clipSoundLane])
    }
}

/// The on-video overlay handles sit exactly on the rendered picture.
final class OverlayCanvasTests: XCTestCase {
    func testHandlesMatchTheRenderedOverlay() async throws {
        let blue = Bundle(for: Self.self).url(forResource: "normal_blue", withExtension: "mov")!
        let photo = Bundle(for: Self.self).url(forResource: "photo_test", withExtension: "jpg")!
        var main = ClipItem(url: blue, sourceStart: 0, sourceEnd: 2)
        main.profile = .normal
        var o = ClipItem(url: photo, sourceStart: 0, sourceEnd: 2)
        o.isPhoto = true
        o.profile = .normal
        o.transform = Transform2D(scale: 0.4, x: 0.2, y: -0.15)
        var p = Project(clips: [main])
        p.overlays = [OverlayItem(clip: o, start: 0)]
        let pool = MediaPool(videos: [blue: try await VideoClip.load(blue)], audio: [:], photos: [photo: CGSize(width: 800, height: 600)])
        let compiled = try ProjectCompiler.compile(p, pool: pool, state: GradeState(ProjectCompiler.snapshot(for: p, lut: .djiAction4)))
        let g = AVAssetImageGenerator(asset: compiled.composition)
        g.videoComposition = compiled.videoComposition
        let (cg, _) = try await g.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        // Find the orange photo's bounding box (red high, blue low) in the frame, y from the top.
        let px = GradeRenderer.shared.rgba8(CIImage(cgImage: cg), maxWidth: CGFloat(cg.width))
        var minX = Int.max, maxX = 0, minY = Int.max, maxY = 0
        for y in 0..<px.height { for x in 0..<px.width {
            let i = (y * px.width + x) * 4
            if px.pixels[i] > 180 && px.pixels[i + 2] < 120 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        } }
        let render = CGSize(width: px.width, height: px.height)
        let geo = OverlayCanvas.geometry(source: CGSize(width: 800, height: 600), transform: o.transform, render: compiled.renderSize, view: render)
        XCTAssertEqual(CGFloat(minX + maxX) / 2, geo.center.x, accuracy: 3)
        XCTAssertEqual(CGFloat(minY + maxY) / 2, geo.center.y, accuracy: 3)
        XCTAssertEqual(CGFloat(maxX - minX + 1), geo.size.width, accuracy: 4)
        XCTAssertEqual(CGFloat(maxY - minY + 1), geo.size.height, accuracy: 4)
    }
}

/// Dragging an overlay keeps it selected (it used to snap the selection back to the first clip every step).
final class OverlayDragTests: XCTestCase {
    @MainActor
    func testOverlayStaysSelectedWhileDragging() async throws {
        let blue = Bundle(for: Self.self).url(forResource: "normal_blue", withExtension: "mov")!
        let photo = Bundle(for: Self.self).url(forResource: "photo_test", withExtension: "jpg")!
        let model = EditorModel()
        model.addClips([blue])
        for _ in 0..<100 where model.project.clips.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        model.addOverlay(photo)
        for _ in 0..<100 where model.project.overlays.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let id = try XCTUnwrap(model.project.overlays.first?.id)
        model.selection = id

        model.beginInteraction()
        for i in 1...20 {
            model.setFraming(undo: .none) { $0.x = Double(i) * 0.01; $0.scale = 1 - Double(i) * 0.02; $0.rotation = Double(i) }
            XCTAssertEqual(model.selection, id, "still the overlay after step \(i)")
        }
        model.endInteraction()

        let t = model.project.overlays[0].clip.transform
        XCTAssertEqual(t.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(t.scale, 0.6, accuracy: 1e-9)
        XCTAssertEqual(t.rotation, 20)
        XCTAssertEqual(model.selection, id)
        // The whole drag is one undo step.
        model.undo()
        XCTAssertEqual(model.project.overlays[0].clip.transform, .identity)
        XCTAssertEqual(model.selection, id, "undo keeps the overlay selected too")
    }
}

/// A slideshow made only of photos (no video clips) exports.
final class PhotoOnlyExportTests: XCTestCase {
    func testPhotoSlideshowExports() async throws {
        let photo = Bundle(for: Self.self).url(forResource: "photo_test", withExtension: "jpg")!
        func slide(_ i: Int) -> ClipItem {
            var c = ClipItem(url: photo, sourceStart: 0, sourceEnd: 4)
            c.isPhoto = true
            c.profile = .normal
            if i > 0 { c.transitionIn = Transition(kind: .crossDissolve, duration: 0.6) }
            return c
        }
        var p = Project(clips: [slide(0), slide(1), slide(2)])
        p.clips[0].transitionIn = Transition(kind: .dipToBlack, duration: 0.6)
        p.fadeOut = 0.6
        p.titles = [TitleItem(text: "Welcome", start: 0.3, duration: 3, style: .title)]
        let pool = MediaPool(videos: [:], audio: [:], photos: [photo: CGSize(width: 800, height: 600)])
        for codec in [ExportSettings.Codec.h264, .hevc] {
            let s = ExportSettings(codec: codec, resolution: .project, frameRate: .project)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("slideshow-\(UUID().uuidString.prefix(6)).\(s.fileExtension)")
            try await Exporter.export(project: p, pool: pool, lut: .djiAction4, settings: s, to: out) { _ in }
            let d = try await AVURLAsset(url: out).load(.duration).seconds
            XCTAssertEqual(d, p.duration, accuracy: 0.1, "\(codec)")
            // The picture is the photo (orange), not the black filler under it.
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: out))
            let (cg, _) = try await g.image(at: CMTime(seconds: 5, preferredTimescale: 600))
            let px = GradeRenderer.shared.rgba8(CIImage(cgImage: cg), maxWidth: 32)
            let rgb = FrameStats(rgba: px.pixels, width: px.width, height: px.height).meanRGB
            XCTAssertGreaterThan(rgb[0], rgb[2] + 0.2, "\(codec): orange photo, got \(rgb)")
        }
    }
}
