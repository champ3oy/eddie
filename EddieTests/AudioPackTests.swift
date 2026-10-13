import AVFoundation
import XCTest
@testable import Eddie

/// Volume lines, voice effects, text to speech, extracting audio, audio-only export.
final class AudioPackTests: XCTestCase {
    var musicURL: URL { Bundle(for: Self.self).url(forResource: "music_test", withExtension: "m4a")! }
    var blueURL: URL { Bundle(for: Self.self).url(forResource: "normal_blue", withExtension: "mov")! }

    func testVolumeLineInterpolates() {
        let pts = [VolumePoint(time: 1, level: 0.2), VolumePoint(time: 3, level: 1)]
        XCTAssertEqual(pts.level(at: 0), 0.2, "flat before the first point")
        XCTAssertEqual(pts.level(at: 2), 0.6, accuracy: 1e-9)
        XCTAssertEqual(pts.level(at: 9), 1)
        XCTAssertEqual([VolumePoint]().level(at: 5), 1, "no points: steady")
    }

    func testMixFollowsTheVolumeLine() async throws {
        var clip = ClipItem(url: blueURL, sourceStart: 0, sourceEnd: 2)
        clip.audioMuted = true
        var song = MusicItem(url: musicURL, start: 0, sourceEnd: 2)
        song.fadeIn = 0; song.fadeOut = 0; song.volume = 1
        song.volumePoints = [VolumePoint(time: 0, level: 0), VolumePoint(time: 2, level: 1)]
        let p = Project(clips: [clip], music: [song])
        let pool = MediaPool(videos: [blueURL: try await VideoClip.load(blueURL)], audio: [musicURL: try await MusicSource.load(musicURL)], photos: [:])
        let compiled = try ProjectCompiler.compile(p, pool: pool, state: GradeState(ProjectCompiler.snapshot(for: p, lut: .djiAction4)))
        let w = try MusicPlaybackTests.loudness(compiled)
        XCTAssertGreaterThan(w.count, 6)
        XCTAssertLessThan(w[0], w[w.count - 2] * 0.4, "quiet at the start, louder towards the end")
    }

    func testVoiceEffectsRender() async throws {
        let input = try await AudioProcessor.decode(musicURL)
        for effect in AudioProcessor.VoiceEffect.allCases {
            let out = try AudioProcessor.render(input, through: effect.nodes())
            XCTAssertEqual(Int(out.frameLength), Int(input.frameLength), accuracy: 4096, "\(effect)")
            var diff: Float = 0
            let a = input.floatChannelData![0], b = out.floatChannelData![0]
            for i in stride(from: 48_000, to: min(Int(out.frameLength), 96_000), by: 7) { diff += abs(a[i] - b[i]) }
            XCTAssertGreaterThan(diff, 1, "\(effect) changes the sound")
        }
    }

    func testTextToSpeech() async throws {
        let url: URL
        do { url = try await SpeechMaker.speak("Hello from Eddie.", voice: nil) }
        catch { throw XCTSkip("No speech voice available: \(error)") }
        let d = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertGreaterThan(d, 0.4)
        let src = try await MusicSource.load(url)
        XCTAssertGreaterThan(src.duration, 0.4)
    }

    @MainActor
    func testExtractAudio() async throws {
        let model = EditorModel()
        model.addClips([blueURL])
        for _ in 0..<100 where model.project.clips.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let id = model.project.clips[0].id
        model.extractAudio(id)
        for _ in 0..<100 where model.project.music.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(model.project.clips[0].audioMuted, "the clip goes quiet")
        let m = try XCTUnwrap(model.project.music.first)
        XCTAssertEqual(m.url, blueURL)
        XCTAssertEqual(m.start, 0)
        XCTAssertEqual(m.duration, model.project.clips[0].duration, accuracy: 1e-6)
        model.undo()
        XCTAssertTrue(model.project.music.isEmpty)
        XCTAssertFalse(model.project.clips[0].audioMuted, "one undo puts it back")
    }

    func testAudioOnlyExport() async throws {
        let p = Project(clips: [ClipItem(url: blueURL, sourceStart: 0, sourceEnd: 2)])
        let pool = MediaPool(videos: [blueURL: try await VideoClip.load(blueURL)], audio: [:], photos: [:])
        let s = ExportSettings(codec: .audio)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString.prefix(6)).\(s.fileExtension)")
        try await Exporter.export(project: p, pool: pool, lut: .djiAction4, settings: s, to: out) { _ in }
        XCTAssertEqual(out.pathExtension, "m4a")
        let asset = AVURLAsset(url: out)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(video.isEmpty)
        XCTAssertEqual(audio.count, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
    }
}
