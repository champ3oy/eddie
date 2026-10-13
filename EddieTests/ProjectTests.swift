import AVFoundation
import CoreImage
import XCTest
@testable import Eddie

final class ProjectModelTests: XCTestCase {
    let url = URL(fileURLWithPath: "/tmp/a.mov")

    func project() -> Project {
        Project(clips: [
            ClipItem(url: url, sourceStart: 0, sourceEnd: 4),
            ClipItem(url: url, sourceStart: 1, sourceEnd: 3, speed: 2),   // 1 s on the timeline
        ])
    }

    func testDurationsAndLocate() {
        let p = project()
        XCTAssertEqual(p.duration, 5, accuracy: 1e-9)
        XCTAssertEqual(p.starts, [0, 4])
        let hit = p.locate(4.5)!
        XCTAssertEqual(hit.index, 1)
        XCTAssertEqual(hit.sourceTime, 2, accuracy: 1e-9)   // 0.5 s in at 2× → 1 s into the 1…3 range
    }

    func testSplitMoveRemoveDuplicate() {
        var p = project()
        let right = p.split(at: 1.5)
        XCTAssertNotNil(right)
        XCTAssertEqual(p.clips.count, 3)
        XCTAssertEqual(p.clips[0].sourceEnd, 1.5, accuracy: 1e-9)
        XCTAssertEqual(p.clips[1].sourceStart, 1.5, accuracy: 1e-9)
        XCTAssertEqual(p.duration, 5, accuracy: 1e-9, "splitting doesn't change length")
        XCTAssertNil(p.split(at: 0.05), "too close to an edge")

        let last = p.clips[2].id
        p.move(last, to: 0)
        XCTAssertEqual(p.clips[0].id, last)

        let dup = p.duplicate(last)!
        XCTAssertEqual(p.clips[1].id, dup)
        p.remove(dup)
        XCTAssertEqual(p.clips.count, 3)
    }

    func testTrimAndSpeedClamp() {
        var p = project()
        let id = p.clips[0].id
        p.trim(id, start: 3.95, sourceDuration: 10)
        XCTAssertEqual(p.clips[0].sourceStart, 4 - ClipItem.minLength, accuracy: 1e-9)
        p.trim(id, end: 99, sourceDuration: 10)
        XCTAssertEqual(p.clips[0].sourceEnd, 10)
        p.setSpeed(id, 10)
        XCTAssertEqual(p.clips[0].speed, 4)
    }

    func testCodableRoundTrip() throws {
        var p = project()
        p.music = [MusicItem(url: url, start: 1, sourceEnd: 3)]
        p.clips[0].recipe.exposure = 0.5
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }
}

final class ProjectCompilerTests: XCTestCase {
    var videoURL: URL { Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")! }
    var musicURL: URL { Bundle(for: Self.self).url(forResource: "music_test", withExtension: "m4a")! }

    /// Two pieces of the 2 s test clip: 0–1 s graded black & white, then 1–2 s at 2× speed ungraded; plus a song.
    func makeProject() -> Project {
        var a = ClipItem(url: videoURL, sourceStart: 0, sourceEnd: 1)
        a.recipe.saturation = -100
        let b = ClipItem(url: videoURL, sourceStart: 1, sourceEnd: 2, speed: 2)
        return Project(clips: [a, b], music: [MusicItem(url: musicURL, start: 0.5, sourceEnd: 6)])
    }

    func testCompileAndExport() async throws {
        let project = makeProject()
        let media = [videoURL: try await VideoClip.load(videoURL)]
        let music = [musicURL: try await MusicSource.load(musicURL)]
        var recipes: [UUID: GradeRecipe] = [:]
        for c in project.clips { recipes[c.id] = c.effectiveRecipe }
        let state = GradeState(.init(recipe: .neutral, lut: .djiAction4, mode: .graded, recipes: recipes))

        let compiled = try ProjectCompiler.compile(project, media: media, music: music, state: state)
        XCTAssertEqual(compiled.composition.duration.seconds, 1.5, accuracy: 0.02)
        XCTAssertEqual(compiled.videoComposition.instructions.count, 2)
        XCTAssertEqual(compiled.composition.tracks(withMediaType: .audio).count, 3, "two alternating clip-sound tracks (for transitions) + one song")

        // Per-clip grades: the first part is black & white, the second isn't.
        func saturation(at seconds: Double, in asset: AVAsset, composition: AVVideoComposition?) async throws -> Double {
            let g = AVAssetImageGenerator(asset: asset)
            g.videoComposition = composition
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            let (cg, _) = try await g.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            let px = GradeRenderer.shared.rgba8(CIImage(cgImage: cg), maxWidth: 200)
            return FrameStats(rgba: px.pixels, width: px.width, height: px.height).meanSaturation
        }
        let bw = try await saturation(at: 0.5, in: compiled.composition, composition: compiled.videoComposition)
        let color = try await saturation(at: 1.25, in: compiled.composition, composition: compiled.videoComposition)
        XCTAssertLessThan(bw, 0.03)
        XCTAssertGreaterThan(color, bw + 0.05)

        // Export the whole thing.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("eddie_project_test.mov")
        try await Exporter.export(project: project, media: media, music: music, lut: .djiAction4, to: out) { _ in }
        let exported = AVURLAsset(url: out)
        let exportedDuration = try await exported.load(.duration).seconds
        let exportedAudio = try await exported.loadTracks(withMediaType: .audio)
        XCTAssertEqual(exportedDuration, 1.5, accuracy: 0.05)
        XCTAssertEqual(exportedAudio.count, 1, "audio is mixed down")
    }
}

final class TitlesAndSnappingTests: XCTestCase {
    func testSnapPicksNearestTargetWithinTolerance() {
        XCTAssertEqual(Snap.apply(4.96, to: [0, 5, 9], tolerance: 0.1).time, 5)
        XCTAssertEqual(Snap.apply(4.96, to: [0, 5, 9], tolerance: 0.1).target, 5)
        XCTAssertNil(Snap.apply(4.5, to: [0, 5, 9], tolerance: 0.1).target)
        XCTAssertEqual(Snap.apply(4.5, to: [], tolerance: 1).time, 4.5)
    }

    func testEdgesIncludeClipsTitlesAndMusic() {
        let url = URL(fileURLWithPath: "/tmp/a.mov")
        var p = Project(clips: [ClipItem(url: url, sourceStart: 0, sourceEnd: 2), ClipItem(url: url, sourceStart: 0, sourceEnd: 3)])
        let title = TitleItem(start: 1, duration: 2)
        p.titles = [title]
        XCTAssertEqual(Set(p.edges()), Set([0, 2, 5, 1, 3]))
        XCTAssertEqual(Set(p.edges(excluding: title.id)), Set([0, 2, 5]))
    }

    func testOldProjectFilesWithoutTitlesStillOpen() throws {
        let json = #"{"clips":[],"music":[]}"#
        let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertTrue(p.titles.isEmpty)
    }

    func testTitleFades() {
        let t = TitleItem(start: 2, duration: 3)
        XCTAssertEqual(TitleRenderer.opacity(of: t, at: 2), 0)
        XCTAssertEqual(TitleRenderer.opacity(of: t, at: 3.5), 1)
        XCTAssertEqual(TitleRenderer.opacity(of: t, at: 4.9), 0.4, accuracy: 0.01)
    }

    func testTitleIsDrawnIntoTheFrame() async throws {
        let url = Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!
        var project = Project(clips: [ClipItem(url: url, sourceStart: 0, sourceEnd: 2)])
        var recipe = GradeRecipe(); recipe.exposure = -2   // dark frame so white text stands out
        project.clips[0].recipe = recipe
        let media = [url: try await VideoClip.load(url)]

        func centerBrightness(titles: [TitleItem]) async throws -> Double {
            let state = GradeState(.init(recipe: .neutral, lut: .djiAction4, mode: .graded,
                                         recipes: [project.clips[0].id: recipe], titles: titles))
            let compiled = try ProjectCompiler.compile(project, media: media, music: [:], state: state)
            let g = AVAssetImageGenerator(asset: compiled.composition)
            g.videoComposition = compiled.videoComposition
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            let (cg, _) = try await g.image(at: CMTime(seconds: 1, preferredTimescale: 600))
            // Middle band of the frame, where a centered title sits.
            let ci = CIImage(cgImage: cg)
            let band = ci.cropped(to: CGRect(x: ci.extent.width * 0.3, y: ci.extent.height * 0.4,
                                             width: ci.extent.width * 0.4, height: ci.extent.height * 0.2))
            let px = GradeRenderer.shared.rgba8(band, maxWidth: 200)
            return FrameStats(rgba: px.pixels, width: px.width, height: px.height).lumaP99
        }

        let without = try await centerBrightness(titles: [])
        let with = try await centerBrightness(titles: [TitleItem(text: "HELLO", start: 0.2, duration: 1.6)])
        XCTAssertGreaterThan(with, without + 0.3, "white title text should appear in the middle of the frame")
    }
}

final class ArrangementTests: XCTestCase {
    func testPreviewOpensGapAndLandingIndex() {
        let url = URL(fileURLWithPath: "/tmp/a.mov")
        let a = ClipItem(url: url, sourceStart: 0, sourceEnd: 2)   // 0–2
        let b = ClipItem(url: url, sourceStart: 0, sourceEnd: 3)   // 2–5
        let c = ClipItem(url: url, sourceStart: 0, sourceEnd: 1)   // 5–6
        let p = Project(clips: [a, b, c])

        // Dragging A toward the end: the others close up and A's slot opens after C.
        let preview = p.previewStarts(moving: a.id, to: 2)
        XCTAssertEqual(preview[b.id], 0)
        XCTAssertEqual(preview[c.id], 3)
        XCTAssertEqual(preview[a.id], 4)

        // A's middle (1 s) dragged to 4.0 s: past B's middle (1.5 in the closed-up row) and C's (3.5).
        XCTAssertEqual(p.landingIndex(moving: a.id, center: 4.0), 2)
        XCTAssertEqual(p.landingIndex(moving: a.id, center: 1.0), 0)
        XCTAssertEqual(p.landingIndex(moving: c.id, center: 0.5), 0)
    }
}

final class TitleTransformTests: XCTestCase {
    let frame = CGSize(width: 1920, height: 1080)

    func testOlderTitleFilesStillDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","text":"Hi","start":1,"duration":2,"style":"caption","size":1}"#
        let t = try JSONDecoder().decode(TitleItem.self, from: Data(json.utf8))
        XCTAssertEqual(t.font, "System")
        XCTAssertNil(t.x)
        XCTAssertEqual(t.rotation, 0)
        XCTAssertTrue(t.resolvedPlate, "captions default to a plate")
    }

    func testPositionMovesTheOverlay() {
        var t = TitleItem(text: "HELLO", start: 0)
        let centered = TitleRenderer.overlay(t, renderSize: frame)!.extent
        XCTAssertEqual(centered.midX, frame.width / 2, accuracy: 2)
        t.x = 0.2; t.y = 0.25   // y from the top
        let moved = TitleRenderer.overlay(t, renderSize: frame)!.extent
        XCTAssertEqual(moved.midX, frame.width * 0.2, accuracy: 2)
        XCTAssertEqual(moved.midY, frame.height * 0.75, accuracy: 2, "Core Image y points up")
    }

    func testRotationTurnsTheBox() {
        var t = TitleItem(text: "A WIDE TITLE", start: 0)
        let flat = TitleRenderer.overlay(t, renderSize: frame)!.extent
        XCTAssertGreaterThan(flat.width, flat.height)
        t.rotation = 90
        let turned = TitleRenderer.overlay(t, renderSize: frame)!.extent
        XCTAssertGreaterThan(turned.height, turned.width)
    }

    func testFontsAndStyles() {
        var t = TitleItem(text: "x", start: 0)
        t.font = "Serif"
        XCTAssertNotNil(TitleRenderer.font(t, pointSize: 40).fontDescriptor.symbolicTraits)
        t.font = "Georgia"; t.italic = true
        let f = TitleRenderer.font(t, pointSize: 40)
        XCTAssertTrue(f.familyName?.contains("Georgia") ?? false)
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.italic))
        t.font = "No Such Font"
        XCTAssertEqual(TitleRenderer.font(t, pointSize: 40).pointSize, 40, "falls back to the system font")
        XCTAssertEqual(TitleRenderer.color("#FF0000").redComponent, 1, accuracy: 0.01)
    }
}

final class MusicPlaybackTests: XCTestCase {
    /// Mixes the compiled composition's audio exactly as the player would (with the audio mix) and
    /// returns the loudness of each 0.25 s window.
    static func loudness(_ compiled: CompiledProject) throws -> [Float] {
        let reader = try AVAssetReader(asset: compiled.composition)
        let tracks = compiled.composition.tracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000,
        ])
        output.audioMix = compiled.audioMix
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "\(String(describing: reader.error))")
        var windows: [Float] = [], sum: Float = 0, n = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { s in
                for i in 0..<(length / 4) {
                    sum += s[i] * s[i]; n += 1
                    if n == 2000 { windows.append((sum / Float(n)).squareRoot()); sum = 0; n = 0 }
                }
            }
        }
        return windows
    }

    func testSongIsAudibleInTheMix() async throws {
        let videoURL = Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!
        let musicURL = ProcessInfo.processInfo.environment["EDDIE_SONG"].map(URL.init(fileURLWithPath:))
            ?? Bundle(for: Self.self).url(forResource: "music_test", withExtension: "m4a")!
        var clip = ClipItem(url: videoURL, sourceStart: 0, sourceEnd: 2)
        clip.audioMuted = true   // so anything we hear is the song
        let offset = Double(ProcessInfo.processInfo.environment["EDDIE_SONG_OFFSET"] ?? "") ?? 0
        let project = Project(clips: [clip], music: [MusicItem(url: musicURL, start: 0.5, sourceStart: offset, sourceEnd: offset + 6, fadeIn: 0, fadeOut: 0)])
        let state = GradeState(.init(recipe: .neutral, lut: .djiAction4, mode: .graded))
        let compiled = try ProjectCompiler.compile(project, media: [videoURL: try await VideoClip.load(videoURL)],
                                                   music: [musicURL: try await MusicSource.load(musicURL)], state: state)
        let w = try Self.loudness(compiled)
        print("[loudness]", w.map { String(format: "%.3f", $0) })
        XCTAssertLessThan(w.first ?? 1, 0.02, "before the song starts it's silent (clip muted)")
        XCTAssertGreaterThan(w[w.count / 2 + 1], 0.04, "the song is audible after it starts")
    }
}

final class MusicInPlayerTests: XCTestCase {
    @MainActor
    func testAddedSongReachesThePlayer() async throws {
        let model = EditorModel()
        let env = ProcessInfo.processInfo.environment
        let videoURL = env["EDDIE_CLIP"].map(URL.init(fileURLWithPath:)) ?? Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!
        let musicURL = env["EDDIE_SONG"].map(URL.init(fileURLWithPath:)) ?? Bundle(for: Self.self).url(forResource: "music_test", withExtension: "m4a")!
        model.open(videoURL)
        for _ in 0..<100 where model.player.currentItem == nil { try await Task.sleep(for: .milliseconds(50)) }
        model.addMusic(musicURL)
        for _ in 0..<200 where model.project.music.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        print("[song] starts at", model.project.music.first?.sourceStart ?? -1, "duck:", model.project.duckUnderMusic)
        let item = try XCTUnwrap(model.player.currentItem)
        let tracks = item.asset.tracks(withMediaType: .audio)
        print("[player] audio tracks:", tracks.count, "mix params:", item.audioMix?.inputParameters.count ?? -1,
              "music start:", model.project.music.first?.start ?? -1, "duration:", model.project.music.first?.duration ?? -1,
              "muted:", model.player.isMuted, "volume:", model.player.volume)
        XCTAssertEqual(tracks.count, 2, "clip sound + song")
        XCTAssertEqual(item.audioMix?.inputParameters.count, 2)
    }
}

final class SongOffsetTests: XCTestCase {
    @MainActor
    func testSongOffsetKeepsPlaceAndLength() async throws {
        let model = EditorModel()
        let videoURL = Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!
        let musicURL = Bundle(for: Self.self).url(forResource: "music_test", withExtension: "m4a")!
        model.open(videoURL)
        for _ in 0..<100 where model.player.currentItem == nil { try await Task.sleep(for: .milliseconds(50)) }
        model.addMusic(musicURL)
        for _ in 0..<100 where model.project.music.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let before = model.project.music[0]
        model.setSongOffset(before.id, to: 3)
        let after = model.project.music[0]
        XCTAssertEqual(after.sourceStart, 3)
        XCTAssertEqual(after.start, before.start, "stays in place on the timeline")
        XCTAssertEqual(after.duration, before.duration, accuracy: 0.001)
    }
}

final class DuckingTests: XCTestCase {
    func testClipSoundLevelsDuckUnderMusic() {
        let url = URL(fileURLWithPath: "/tmp/a.mov")
        var p = Project(clips: [ClipItem(url: url, sourceStart: 0, sourceEnd: 4),
                                ClipItem(url: url, sourceStart: 0, sourceEnd: 4, volume: 0.5)])
        p.music = [MusicItem(url: url, start: 2, sourceEnd: 4)]   // plays 2–6
        let levels = p.clipSoundLevels()
        func level(at t: Double) -> Double { levels.first { $0.start <= t && t < $0.end }!.level }
        XCTAssertEqual(level(at: 1), 1)
        XCTAssertEqual(level(at: 3), Project.duckLevel)
        XCTAssertEqual(level(at: 5), 0.5 * Project.duckLevel)
        XCTAssertEqual(level(at: 7), 0.5)
        p.duckUnderMusic = false
        XCTAssertEqual(p.clipSoundLevels().first { $0.start <= 3 && 3 < $0.end }!.level, 1)
    }

    func testOlderClipsWithoutVolumeStillDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","url":"file:///tmp/a.mov","sourceStart":0,"sourceEnd":2}"#
        let c = try JSONDecoder().decode(ClipItem.self, from: Data(json.utf8))
        XCTAssertEqual(c.volume, 1)
        XCTAssertEqual(c.speed, 1)
    }

    func testDuckingLowersClipSoundInTheMix() async throws {
        let videoURL = Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!
        let musicURL = Bundle(for: Self.self).url(forResource: "music_test", withExtension: "m4a")!
        let media = [videoURL: try await VideoClip.load(videoURL)]
        let music = [musicURL: try await MusicSource.load(musicURL)]
        func clipLoudnessDuringSong(duck: Bool) throws -> Float {
            // Song at volume 0 so we only hear the clip's own sound.
            var p = Project(clips: [ClipItem(url: videoURL, sourceStart: 0, sourceEnd: 2)],
                            music: [MusicItem(url: musicURL, start: 0.5, sourceEnd: 6, volume: 0, fadeIn: 0, fadeOut: 0)])
            p.duckUnderMusic = duck
            let compiled = try ProjectCompiler.compile(p, media: media, music: music, state: GradeState(.init(recipe: .neutral, lut: .djiAction4, mode: .graded)))
            let w = try MusicPlaybackTests.loudness(compiled)
            return w[w.count - 2]
        }
        let normal = try clipLoudnessDuringSong(duck: false)
        let ducked = try clipLoudnessDuringSong(duck: true)
        print("[duck]", normal, ducked)
        XCTAssertGreaterThan(normal, 0.02)
        XCTAssertEqual(ducked / normal, Float(Project.duckLevel), accuracy: 0.05)
    }
}
