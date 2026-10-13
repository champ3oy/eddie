import AVFoundation
import CoreImage

/// A loaded audio file (songs, voiceovers, cleaned-up clip sound).
struct MusicSource {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let duration: Double

    static func load(_ url: URL) async throws -> MusicSource {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) has no audio."])
        }
        return MusicSource(asset: asset, track: track, duration: try await asset.load(.duration).seconds)
    }
}

/// Everything loaded that a project refers to.
struct MediaPool {
    var videos: [URL: VideoClip] = [:]
    var audio: [URL: MusicSource] = [:]
    /// Pixel size of photos.
    var photos: [URL: CGSize] = [:]
}

/// What the player and exporter need for a project.
struct CompiledProject {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix
    let renderSize: CGSize
    let frameRate: Float
}

/// Turns a `Project` into one AVComposition:
/// - main clips alternate between two video/audio tracks so neighbours can overlap for transitions;
/// - each overlay and each song gets its own track;
/// - one instruction per stretch of time lists the layers to draw there (bottom to top);
/// - each audio track gets a volume curve (clip volume, fades, transitions, ducking).
enum ProjectCompiler {
    enum CompileError: LocalizedError {
        case empty, missingMedia(String)
        var errorDescription: String? {
            switch self {
            case .empty: return "The project has no clips."
            case let .missingMedia(name): return "Couldn't find \(name)."
            }
        }
    }

    static let timescale: CMTimeScale = 6000

    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }

    /// Kept for callers that only have videos and songs.
    static func compile(_ project: Project, media: [URL: VideoClip], music: [URL: MusicSource],
                        state: GradeState, frameRate: Float? = nil, renderSize: CGSize? = nil) throws -> CompiledProject {
        try compile(project, pool: MediaPool(videos: media, audio: music), state: state, frameRate: frameRate, renderSize: renderSize)
    }

    /// One second of 64×64 black (bundled), used under photo-only edits so they can be exported.
    /// The asset is kept alive alongside its track (a track whose asset is gone can't be inserted).
    nonisolated(unsafe) static let carrier: (asset: AVURLAsset, track: AVAssetTrack)? = {
        let url = Bundle(for: GradeState.self).url(forResource: "carrier", withExtension: "mov")
            ?? Bundle.main.url(forResource: "carrier", withExtension: "mov")
        guard let url else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        Task.detached {
            track = try? await asset.loadTracks(withMediaType: .video).first
            done.signal()
        }
        done.wait()
        return track.map { (asset, $0) }
    }()
    static var carrierTrack: AVAssetTrack? { carrier?.track }

    /// The project's frame size: the first clip's, shaped by the project format.
    static func frameSize(_ project: Project, pool: MediaPool) -> CGSize {
        guard let first = project.clips.first else { return CGSize(width: 1920, height: 1080) }
        let firstVideo = project.clips.first { !$0.isPhoto }.flatMap { pool.videos[$0.url] }
        let sourceSize = (first.isPhoto ? pool.photos[first.url] : pool.videos[first.url]?.displaySize)
            ?? firstVideo?.displaySize ?? CGSize(width: 1920, height: 1080)
        return project.format.renderSize(source: sourceSize)
    }

    static func compile(_ project: Project, pool: MediaPool, state: GradeState,
                        frameRate: Float? = nil, renderSize: CGSize? = nil) throws -> CompiledProject {
        guard !project.clips.isEmpty else { throw CompileError.empty }

        // Frame size and rate come from the first video (or photo), shaped by the project format.
        let firstVideo = project.clips.first { !$0.isPhoto }.flatMap { pool.videos[$0.url] }
        let size = renderSize ?? frameSize(project, pool: pool)
        let fps = frameRate ?? firstVideo?.frameRate ?? 30

        let composition = AVMutableComposition()
        func newTrack(_ type: AVMediaType) -> AVMutableCompositionTrack? {
            composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        guard let videoA = newTrack(.video), let videoB = newTrack(.video),
              let soundA = newTrack(.audio), let soundB = newTrack(.audio) else { throw CompileError.empty }
        let video = [videoA, videoB], sound = [soundA, soundB]
        var trackEnds: [CMPersistentTrackID: CMTime] = [:]

        /// Puts a clip's picture and sound on the given tracks at `at` (photos leave the tracks empty there).
        func place(_ clip: ClipItem, at: Double, video vt: AVMutableCompositionTrack, sound st: AVMutableCompositionTrack) throws {
            let start = time(at)
            for t in [vt, st] {
                let end = trackEnds[t.trackID] ?? .zero
                if start > end { t.insertEmptyTimeRange(CMTimeRange(start: end, end: start)) }
            }
            let length = time(clip.duration)
            if clip.isPhoto {
                vt.insertEmptyTimeRange(CMTimeRange(start: start, duration: length))
                st.insertEmptyTimeRange(CMTimeRange(start: start, duration: length))
            } else {
                let sourceURL = clip.reversed ? (clip.reversedURL ?? clip.url) : clip.url
                guard let info = pool.videos[sourceURL] else { throw CompileError.missingMedia(clip.name) }
                // A reversed copy runs backwards: source time s is at (length - s) in it.
                var range = CMTimeRange(start: time(clip.sourceStart), end: time(clip.sourceEnd))
                if clip.reversed, clip.reversedURL != nil {
                    let total = info.duration.seconds
                    range = CMTimeRange(start: time(max(0, total - clip.sourceEnd)), end: time(max(0, total - clip.sourceStart)))
                }
                try vt.insertTimeRange(range, of: info.track, at: start)
                if let override = clip.audioOverride.flatMap({ pool.audio[$0] }) {
                    try st.insertTimeRange(range, of: override.track, at: start)
                } else if let audio = info.audioTrack {
                    try st.insertTimeRange(range, of: audio, at: start)
                } else {
                    st.insertEmptyTimeRange(CMTimeRange(start: start, duration: range.duration))
                }
                if clip.speed != 1 {
                    let inserted = CMTimeRange(start: start, duration: range.duration)
                    vt.scaleTimeRange(inserted, toDuration: length)
                    st.scaleTimeRange(inserted, toDuration: length)
                }
            }
            trackEnds[vt.trackID] = start + length
            trackEnds[st.trackID] = start + length
        }

        let starts = project.starts
        let total = project.duration
        for (i, clip) in project.clips.enumerated() {
            try place(clip, at: starts[i], video: video[i % 2], sound: sound[i % 2])
        }

        // Overlays, cut at the end of the video.
        var overlayTracks: [(OverlayItem, AVMutableCompositionTrack, AVMutableCompositionTrack)] = []
        for o in project.overlays where o.start < total - 0.05 {
            var item = o
            if item.end > total { item.clip.sourceEnd = item.clip.sourceStart + (total - item.start) * item.clip.speed }
            guard let vt = newTrack(.video), let st = newTrack(.audio) else { continue }
            try place(item.clip, at: item.start, video: vt, sound: st)
            overlayTracks.append((item, vt, st))
        }

        // Songs, voiceovers, sound effects: each on its own track, cut at the end of the video.
        var musicTracks: [(MusicItem, AVMutableCompositionTrack)] = []
        for item in project.music {
            guard let src = pool.audio[item.playURL], item.start < total, let track = newTrack(.audio) else { continue }
            let length = min(item.duration, total - item.start, src.duration - item.sourceStart)
            guard length > 0.05 else { continue }
            try track.insertTimeRange(CMTimeRange(start: time(item.sourceStart), duration: time(length)), of: src.track, at: time(item.start))
            var trimmed = item
            trimmed.sourceEnd = item.sourceStart + length
            musicTracks.append((trimmed, track))
        }

        // MARK: Instructions: one per stretch where the set of visible layers stays the same.
        var cuts = Set([0.0, total])
        for (i, c) in project.clips.enumerated() { cuts.insert(starts[i]); cuts.insert(min(total, starts[i] + c.duration)) }
        for (o, _, _) in overlayTracks { cuts.insert(o.start); cuts.insert(min(total, o.end)) }
        let times = cuts.filter { $0 >= 0 && $0 <= total }.sorted()

        var instructions: [GradeInstruction] = []
        for (a, b) in zip(times, times.dropFirst()) where b - a > 1e-6 {
            let mid = (a + b) / 2
            var layers: [LayerSpec] = []
            for (i, clip) in project.clips.enumerated() where starts[i] <= mid && starts[i] + clip.duration > mid {
                let overlapIn = project.overlap(at: i)
                let overlapOut = i + 1 < project.clips.count ? project.overlap(at: i + 1) : 0
                let info = clip.isPhoto ? nil : pool.videos[clip.reversed ? (clip.reversedURL ?? clip.url) : clip.url]
                layers.append(LayerSpec(
                    clipID: clip.id,
                    trackID: clip.isPhoto ? nil : video[i % 2].trackID,
                    photoURL: clip.isPhoto ? clip.url : nil,
                    orientation: info?.orientation ?? .up,
                    role: .main,
                    start: starts[i],
                    incoming: overlapIn > 0 ? (clip.transitionIn!.kind, starts[i], overlapIn) : nil,
                    outgoing: overlapOut > 0 ? (project.clips[i + 1].transitionIn!.kind, starts[i + 1], overlapOut) : nil,
                    fadeFromBlack: i == 0 ? (clip.transitionIn?.duration ?? 0) : 0))
            }
            for (o, vt, _) in overlayTracks where o.start <= mid && o.end > mid {
                let info = o.clip.isPhoto ? nil : pool.videos[o.clip.url]
                layers.append(LayerSpec(clipID: o.id, trackID: o.clip.isPhoto ? nil : vt.trackID,
                                        photoURL: o.clip.isPhoto ? o.clip.url : nil,
                                        orientation: info?.orientation ?? .up, role: .overlay, start: o.start,
                                        fadeFromBlack: o.clip.transitionIn?.duration ?? 0))
            }
            instructions.append(GradeInstruction(timeRange: CMTimeRange(start: time(a), end: time(b)), layers: layers, state: state))
        }

        // An edit made only of photos has no real video, and AVFoundation won't export a composition without
        // any ("Operation Stopped"). A tiny black clip stretched under the whole edit gives it one; the
        // compositor never draws it.
        let hasFootage = composition.tracks(withMediaType: .video).contains { $0.segments.contains { !$0.isEmpty } }
        if !hasFootage, total > 0, let carrier = Self.carrierTrack, let ct = newTrack(.video) {
            let one = CMTimeRange(start: .zero, duration: carrier.timeRange.duration)
            try ct.insertTimeRange(one, of: carrier, at: .zero)
            ct.scaleTimeRange(CMTimeRange(start: .zero, duration: one.duration), toDuration: time(total))
        }

        // Drop tracks that ended up with nothing on them (e.g. the second main track of a one-clip edit).
        var removed = Set<CMPersistentTrackID>()
        for t in composition.tracks where t.trackID != videoA.trackID && t.segments.allSatisfy({ $0.isEmpty }) {
            // Photos need no source frames, so an all-empty video track is fine to remove.
            removed.insert(t.trackID)
            composition.removeTrack(t)
        }

        // MARK: Sound: one volume curve per track.
        var mixParams: [AVMutableAudioMixInputParameters] = []
        let audible = project.music.filter { !project.mutedLanes.contains(Project.audioLane($0.lane)) }
        let duck = project.duckUnderMusic ? audible.filter { $0.kind != .effect } : []
        let voice = audible.filter { $0.kind == .voiceover }

        func presence(_ items: [MusicItem], at t: Double) -> Double {
            items.map { m -> Double in
                let ramp = 0.3
                return min(1, max(0, min((t - m.start) / ramp + 0.5, (m.end - t) / ramp + 0.5)))
            }.max() ?? 0
        }
        func endFade(_ t: Double) -> Double {
            project.fadeOut > 0 ? min(1, max(0, (total - t) / project.fadeOut)) : 1
        }
        /// Turns a gain function over [start, end] into volume ramps at the given key times.
        func curve(_ params: AVMutableAudioMixInputParameters, from start: Double, to end: Double,
                   keys: [Double], gain: (Double) -> Double) {
            let ts = Set(keys + [start, end]).filter { $0 >= start && $0 <= end }.sorted()
            for (a, b) in zip(ts, ts.dropFirst()) where b - a > 1e-4 {
                params.setVolumeRamp(fromStartVolume: Float(gain(a)), toEndVolume: Float(gain(b)),
                                     timeRange: CMTimeRange(start: time(a), end: time(b)))
            }
        }
        var duckKeys: [Double] = []
        for m in duck { duckKeys += [m.start - 0.15, m.start + 0.15, m.end - 0.15, m.end + 0.15] }
        let fadeKeys = project.fadeOut > 0 ? [total - project.fadeOut] : []

        let mainParams = [AVMutableAudioMixInputParameters(track: soundA), AVMutableAudioMixInputParameters(track: soundB)]
        for p in mainParams { p.setVolume(0, at: .zero) }
        for (i, clip) in project.clips.enumerated() {
            let s = starts[i], e = s + clip.duration
            let inO = project.overlap(at: i), outO = i + 1 < project.clips.count ? project.overlap(at: i + 1) : 0
            let level = clip.audioMuted || project.mutedLanes.contains(Project.clipSoundLane) ? 0 : clip.volume
            func gain(_ t: Double) -> Double {
                var g = level
                if clip.audioFadeIn > 0 { g *= min(1, max(0, (t - s) / clip.audioFadeIn)) }
                if clip.audioFadeOut > 0 { g *= min(1, max(0, (e - t) / clip.audioFadeOut)) }
                if inO > 0 { g *= min(1, max(0, (t - s) / inO)) }
                if outO > 0 { g *= min(1, max(0, (e - t) / outO)) }
                g *= 1 - (1 - Project.duckLevel) * presence(duck, at: t)
                return g * endFade(t)
            }
            let keys = [s + clip.audioFadeIn, e - clip.audioFadeOut, s + inO, e - outO] + duckKeys + fadeKeys
            curve(mainParams[i % 2], from: s, to: e, keys: keys, gain: gain)
        }
        mixParams += mainParams.filter { !removed.contains($0.trackID) }

        for (o, _, st) in overlayTracks where !removed.contains(st.trackID) {
            let p = AVMutableAudioMixInputParameters(track: st)
            let level = o.clip.audioMuted || project.mutedLanes.contains(Project.overlaySoundLane) ? 0 : o.clip.volume
            p.setVolume(Float(level), at: .zero)
            mixParams.append(p)
        }

        for (item, track) in musicTracks {
            let p = AVMutableAudioMixInputParameters(track: track)
            let s = item.start, e = item.start + item.duration
            let fi = min(item.fadeIn, item.duration / 2), fo = min(item.fadeOut, item.duration / 2)
            // Music dips under voiceover.
            let underVoice = item.kind == .voiceover ? [] : voice
            let laneOn = !project.mutedLanes.contains(Project.audioLane(item.lane))
            func gain(_ t: Double) -> Double {
                var g = laneOn ? item.volume : 0
                if fi > 0.01 { g *= min(1, max(0, (t - s) / fi)) }
                if fo > 0.01 { g *= min(1, max(0, (e - t) / fo)) }
                g *= 1 - 0.65 * presence(underVoice, at: t)
                return g * endFade(t)
            }
            var keys = [s + fi, e - fo] + fadeKeys
            for v in underVoice { keys += [v.start - 0.15, v.start + 0.15, v.end - 0.15, v.end + 0.15] }
            p.setVolume(Float(gain(s)), at: .zero)
            curve(p, from: s, to: e, keys: keys, gain: gain)
            mixParams.append(p)
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParams

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = GradeCompositor.self
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = instructions

        return CompiledProject(composition: composition, videoComposition: videoComposition, audioMix: audioMix,
                               renderSize: size, frameRate: fps)
    }

    /// The grade state for a project (per-clip grades, framing, overlays, end fade).
    static func snapshot(for project: Project, lut: CubeLUT, mode: ViewMode = .graded, split: Double? = nil) -> GradeState.Snapshot {
        var recipes: [UUID: GradeRecipe] = [:], clips: [UUID: ClipItem] = [:], opacity: [UUID: Double] = [:]
        for c in project.clips { recipes[c.id] = c.effectiveRecipe; clips[c.id] = c }
        for o in project.overlays { recipes[o.id] = o.clip.effectiveRecipe; clips[o.id] = o.clip; opacity[o.id] = o.opacity }
        return GradeState.Snapshot(recipe: .neutral, lut: lut, mode: mode, split: split, recipes: recipes, titles: project.titles,
                                   clips: clips, overlayOpacity: opacity, fill: project.format.fill,
                                   fadeOut: project.fadeOut, duration: project.duration)
    }
}
