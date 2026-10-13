import AVFoundation

/// How a video is written out.
struct ExportSettings: Equatable, Codable {
    enum Codec: String, CaseIterable, Identifiable, Codable {
        case h264, hevc, prores, audio, gif
        var id: String { rawValue }
        var label: String {
            switch self {
            case .h264: return "H.264 — plays everywhere"
            case .hevc: return "HEVC — smaller, 10-bit"
            case .prores: return "ProRes 422 — for more editing"
            case .audio: return "Audio only (.m4a)"
            case .gif: return "Animated GIF (small, no sound)"
            }
        }
    }
    enum Resolution: String, CaseIterable, Identifiable, Codable {
        case project, p720, p1080, p2160
        var id: String { rawValue }
        var label: String {
            switch self {
            case .project: return "Project size"
            case .p720: return "720p"
            case .p1080: return "1080p"
            case .p2160: return "4K"
            }
        }
        /// Short side in pixels.
        var shortSide: CGFloat? {
            switch self {
            case .project: return nil
            case .p720: return 720
            case .p1080: return 1080
            case .p2160: return 2160
            }
        }
    }
    enum FrameRate: String, CaseIterable, Identifiable, Codable {
        case project, fps24, fps25, fps30, fps50, fps60
        var id: String { rawValue }
        var label: String { self == .project ? "Project rate" : rawValue.replacingOccurrences(of: "fps", with: "") + " fps" }
        var value: Float? {
            switch self {
            case .project: return nil
            case .fps24: return 24
            case .fps25: return 25
            case .fps30: return 30
            case .fps50: return 50
            case .fps60: return 60
            }
        }
    }

    var codec = Codec.hevc
    var resolution = Resolution.project
    var frameRate = FrameRate.project

    /// Ready-made settings for common destinations.
    static let presets: [(name: String, settings: ExportSettings)] = [
        ("Best quality (HEVC)", ExportSettings(codec: .hevc, resolution: .project, frameRate: .project)),
        ("Social — 1080p H.264", ExportSettings(codec: .h264, resolution: .p1080, frameRate: .fps30)),
        ("YouTube 4K (HEVC)", ExportSettings(codec: .hevc, resolution: .p2160, frameRate: .project)),
        ("Small file — 720p", ExportSettings(codec: .h264, resolution: .p720, frameRate: .fps30)),
        ("Master for editing (ProRes)", ExportSettings(codec: .prores, resolution: .project, frameRate: .project)),
        ("Animated GIF", ExportSettings(codec: .gif, resolution: .project, frameRate: .project)),
        ("Audio only", ExportSettings(codec: .audio, resolution: .project, frameRate: .project)),
    ]

    /// Output frame size for a project frame size (keeps the shape, even numbers).
    func size(for project: CGSize) -> CGSize {
        guard let short = resolution.shortSide else { return project }
        let s = short / max(1, min(project.width, project.height))
        guard s < 1 || resolution != .project else { return project }
        return CGSize(width: (project.width * s / 2).rounded() * 2, height: (project.height * s / 2).rounded() * 2)
    }

    var preset: String {
        switch codec {
        case .h264: return AVAssetExportPresetHighestQuality
        case .hevc: return AVAssetExportPresetHEVCHighestQuality
        case .prores: return AVAssetExportPresetAppleProRes422LPCM
        case .audio: return AVAssetExportPresetAppleM4A
        case .gif: return AVAssetExportPresetHighestQuality   // not used: GIFs are drawn frame by frame
        }
    }

    var fileType: AVFileType { codec == .audio ? .m4a : (codec == .h264 ? .mp4 : .mov) }
    var fileExtension: String {
        switch codec {
        case .audio: return "m4a"
        case .gif: return "gif"
        case .h264: return "mp4"
        default: return "mov"
        }
    }

    /// Rough file size in MB per minute at this frame size (for the export sheet).
    func megabytesPerMinute(for size: CGSize, fps: Double) -> Double {
        let pixels = Double(size.width * size.height) * fps
        let bitsPerPixel: Double
        switch codec {
        case .h264: bitsPerPixel = 0.12
        case .hevc: bitsPerPixel = 0.08
        case .prores: bitsPerPixel = 2.4
        case .audio: return 1.9   // 256 kbps AAC
        case .gif: bitsPerPixel = 0.9 * 640 * 360 / max(1, Double(size.width * size.height))   // ~640 px wide, 12 fps
        }
        return pixels * bitsPerPixel * 60 / 8 / 1_000_000
    }
}
