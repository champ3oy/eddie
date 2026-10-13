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

        let monitor = Task {
            for await s in session.states(updateInterval: 0.25) {
                if case let .exporting(p) = s { progress(p.fractionCompleted) }
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
        guard let session = AVAssetExportSession(asset: compiled.composition, presetName: settings.preset) else {
            throw ExportError.cannotCreateSession
        }
        session.videoComposition = compiled.videoComposition
        session.audioMix = compiled.audioMix
        session.audioTimePitchAlgorithm = .spectral
        // The video defines the length; don't let audio padding run past it.
        session.timeRange = CMTimeRange(start: .zero, duration: ProjectCompiler.time(project.duration))
        try? FileManager.default.removeItem(at: url)

        let monitor = Task {
            for await s in session.states(updateInterval: 0.25) {
                if case let .exporting(p) = s { progress(p.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: settings.fileType)
        progress(1)
    }
}
