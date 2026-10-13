import AVFoundation
import MediaToolbox
import XCTest
@testable import Eddie

/// Measures the audio that actually flows through a playing AVPlayer for one composition track,
/// using an audio processing tap (the player is muted, the tap still sees the samples).
final class PlaybackProbe {
    nonisolated(unsafe) static var energy: Float = 0
    nonisolated(unsafe) static var frames = 0

    static func tap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: nil,
            init: nil, finalize: nil, prepare: nil, unprepare: nil,
            process: { tap, frameCount, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frameCount, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let list = UnsafeMutableAudioBufferListPointer(buffers)
                for b in list {
                    guard let data = b.mData else { continue }
                    let n = Int(b.mDataByteSize) / 4
                    let s = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<n { PlaybackProbe.energy += s[i] * s[i] }
                    PlaybackProbe.frames += n
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else { return nil }
        return tap
    }
}

final class LivePlaybackTests: XCTestCase {
    @MainActor
    func testSongPlaysDuringLivePlayback() async throws {
        let env = ProcessInfo.processInfo.environment
        let videoURL = Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!
        let musicURL = env["EDDIE_SONG"].map(URL.init(fileURLWithPath:))
            ?? Bundle(for: Self.self).url(forResource: "music_test", withExtension: "m4a")!
        let offset = Double(env["EDDIE_SONG_OFFSET"] ?? "") ?? 0
        let project = Project(clips: [ClipItem(url: videoURL, sourceStart: 0, sourceEnd: 2)],
                              music: [MusicItem(url: musicURL, start: 0, sourceStart: offset, sourceEnd: offset + 2, fadeIn: 0, fadeOut: 0)])
        let compiled = try ProjectCompiler.compile(project, media: [videoURL: try await VideoClip.load(videoURL)],
                                                   music: [musicURL: try await MusicSource.load(musicURL)],
                                                   state: GradeState(.init(recipe: .neutral, lut: .djiAction4, mode: .graded)))

        // Tap the song's track (the last audio track) in the player's own audio mix.
        let mix = compiled.audioMix.mutableCopy() as! AVMutableAudioMix
        let params = mix.inputParameters.map { $0.mutableCopy() as! AVMutableAudioMixInputParameters }
        params.last!.audioTapProcessor = PlaybackProbe.tap()
        mix.inputParameters = params

        let item = AVPlayerItem(asset: compiled.composition)
        item.videoComposition = compiled.videoComposition
        item.audioMix = mix
        item.audioTimePitchAlgorithm = .spectral
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        PlaybackProbe.energy = 0; PlaybackProbe.frames = 0
        for _ in 0..<100 where item.status != .readyToPlay { try await Task.sleep(for: .milliseconds(50)) }
        player.play()
        try await Task.sleep(for: .seconds(1.6))
        player.pause()
        let rms = PlaybackProbe.frames > 0 ? (PlaybackProbe.energy / Float(PlaybackProbe.frames)).squareRoot() : 0
        print("[live] song frames:", PlaybackProbe.frames, "rms:", rms, "status:", item.status.rawValue, item.error.map { "\($0)" } ?? "")
        XCTAssertGreaterThan(PlaybackProbe.frames, 10_000, "the song's samples should flow while playing")
        XCTAssertGreaterThan(rms, 0.01, "and they should not be silent")
    }
}

final class EditorPlaybackTests: XCTestCase {
    @MainActor
    func testSongPlaysThroughTheEditor() async throws {
        let env = ProcessInfo.processInfo.environment
        let videoURL = env["EDDIE_CLIP"].map(URL.init(fileURLWithPath:)) ?? Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!
        let musicURL = env["EDDIE_SONG"].map(URL.init(fileURLWithPath:)) ?? Bundle(for: Self.self).url(forResource: "music_test", withExtension: "m4a")!
        let model = EditorModel()
        model.open(videoURL)
        for _ in 0..<200 where model.player.currentItem == nil { try await Task.sleep(for: .milliseconds(50)) }
        model.seek(to: 0)
        model.addMusic(musicURL)
        for _ in 0..<200 where model.project.music.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))

        let item = try XCTUnwrap(model.player.currentItem)
        let mix = item.audioMix!.mutableCopy() as! AVMutableAudioMix
        let params = mix.inputParameters.map { $0.mutableCopy() as! AVMutableAudioMixInputParameters }
        params.last!.audioTapProcessor = PlaybackProbe.tap()
        mix.inputParameters = params
        item.audioMix = mix
        model.player.isMuted = true
        PlaybackProbe.energy = 0; PlaybackProbe.frames = 0

        model.seek(to: 0)
        model.togglePlay()
        var statuses: [Int] = []
        for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(100))
            statuses.append(model.player.timeControlStatus.rawValue)
        }
        model.togglePlay()
        let rms = PlaybackProbe.frames > 0 ? (PlaybackProbe.energy / Float(PlaybackProbe.frames)).squareRoot() : 0
        print("[editor] song frames:", PlaybackProbe.frames, "rms:", rms, "clock:", model.clock.time,
              "statuses(0 paused,1 waiting,2 playing):", statuses, "reason:", model.player.reasonForWaitingToPlay?.rawValue ?? "-")
        XCTAssertGreaterThan(PlaybackProbe.frames, 10_000)
    }
}

final class StuckDragTests: XCTestCase {
    /// A drag that macOS cancels without an "ended" event must not leave the player out of date.
    @MainActor
    func testCancelledDragDoesNotFreezeThePlayer() async throws {
        let videoURL = Bundle(for: Self.self).url(forResource: "log_test_10bit", withExtension: "mov")!
        let musicURL = Bundle(for: Self.self).url(forResource: "music_test", withExtension: "m4a")!
        let model = EditorModel()
        model.open(videoURL)
        for _ in 0..<200 where model.player.currentItem == nil { try await Task.sleep(for: .milliseconds(50)) }

        model.beginInteraction()          // a drag starts… and its end is never reported
        model.addMusic(musicURL)          // then the user adds a song
        for _ in 0..<200 where model.project.music.isEmpty { try await Task.sleep(for: .milliseconds(50)) }

        let audioTracks = model.player.currentItem?.asset.tracks(withMediaType: .audio).count ?? 0
        XCTAssertEqual(audioTracks, 2, "the player should include the new song (clip sound + song)")
    }
}
