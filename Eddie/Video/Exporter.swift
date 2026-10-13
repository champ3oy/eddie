import AVFoundation

/// Writes the clip with the grade baked in (HEVC, audio kept).
enum Exporter {
    enum ExportError: LocalizedError {
        case cannotCreateSession
        var errorDescription: String? { "Couldn't start the export." }
    }

    static func export(clip: VideoClip, snapshot: GradeState.Snapshot, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        // A separate state so changes in the UI during export don't affect the file.
        let state = GradeState(snapshot)
        guard let session = AVAssetExportSession(asset: clip.asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw ExportError.cannotCreateSession
        }
        session.videoComposition = clip.makeComposition(state: state)
        try? FileManager.default.removeItem(at: url)

        nonisolated(unsafe) let watched = session
        let monitor = Task {
            while !Task.isCancelled {
                progress(Double(watched.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: .mov)
        progress(1)
    }

    /// Exports a whole project (clips, speeds, per-clip grades, music).
    static func export(project: Project, media: [URL: VideoClip], music: [URL: MusicSource], lut: CubeLUT,
                       to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        // A separate grade state so UI changes during export don't affect the file.
        try await export(project: project, pool: MediaPool(videos: media, audio: music), lut: lut, to: url, progress: progress)
    }

    static func export(project: Project, pool: MediaPool, lut: CubeLUT, settings: ExportSettings = .init(),
                       to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let state = GradeState(ProjectCompiler.snapshot(for: project, lut: lut))
        // Compile once to learn the project frame size, then again at the export size/rate if they differ.
        var compiled = try ProjectCompiler.compile(project, pool: pool, state: state)
        let outSize = settings.size(for: compiled.renderSize)
        if outSize != compiled.renderSize || settings.frameRate.value != nil {
            compiled = try ProjectCompiler.compile(project, pool: pool, state: state, frameRate: settings.frameRate.value, renderSize: outSize)
        }
        if settings.codec == .gif {
            try await exportGIF(compiled, duration: project.duration, fps: Double(settings.frameRate.value ?? 12), to: url, progress: progress)
            return
        }
        guard let session = AVAssetExportSession(asset: compiled.composition, presetName: settings.preset) else {
            throw ExportError.cannotCreateSession
        }
        if settings.codec != .audio { session.videoComposition = compiled.videoComposition }
        session.audioMix = compiled.audioMix
        session.audioTimePitchAlgorithm = .spectral
        // The video defines the length; don't let audio padding run past it.
        session.timeRange = CMTimeRange(start: .zero, duration: ProjectCompiler.time(project.duration))
        try? FileManager.default.removeItem(at: url)

        // Progress by polling: `session.states` traps (crashing the app) when an export fails.
        nonisolated(unsafe) let watched = session
        let monitor = Task {
            while !Task.isCancelled {
                progress(Double(watched.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: settings.fileType)
        progress(1)
    }

    /// An animated GIF: frames of the finished edit (up to 640 px wide), looping.
    static func exportGIF(_ compiled: CompiledProject, duration: Double, fps: Double, to url: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let rate = min(max(fps, 5), 15)
        let g = AVAssetImageGenerator(asset: compiled.composition)
        g.videoComposition = compiled.videoComposition
        g.maximumSize = CGSize(width: 640, height: 640)
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        let count = max(1, Int(duration * rate))
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw ExportError.cannotCreateSession
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / rate]] as CFDictionary
        for i in 0..<count {
            try Task.checkCancellation()
            let t = min(duration - 0.01, Double(i) / rate)
            let (cg, _) = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600))
            CGImageDestinationAddImage(dest, cg, frameProps)
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.cannotCreateSession }
    }
}
