import AVFoundation
import CoreImage

/// Decodes raw 10-bit frames (no color management, no grade) at chosen times.
enum FrameSampler {
    struct Frame {
        let time: CMTime
        /// Untouched LOG frame, downscaled and stored in half float.
        let image: CIImage
    }

    /// `count` frames spread evenly across the clip, skipping the first and last 5 %.
    static func evenTimes(count: Int, duration: CMTime) -> [CMTime] {
        let d = duration.seconds
        guard d.isFinite, d > 0, count > 0 else { return [.zero] }
        if count == 1 { return [CMTime(seconds: d / 2, preferredTimescale: 600)] }
        let start = d * 0.05, end = d * 0.95
        return (0..<count).map { i in
            CMTime(seconds: start + (end - start) * Double(i) / Double(count - 1), preferredTimescale: 600)
        }
    }

    static func frames(of clip: VideoClip, at times: [CMTime], maxWidth: CGFloat = 1280) async throws -> [Frame] {
        var result: [Frame] = []
        for time in times {
            if let image = try decodeFrame(of: clip, at: time, maxWidth: maxWidth) {
                result.append(Frame(time: time, image: image))
            }
        }
        return result
    }

    private static func decodeFrame(of clip: VideoClip, at time: CMTime, maxWidth: CGFloat) throws -> CIImage? {
        let reader = try AVAssetReader(asset: clip.asset)
        let output = AVAssetReaderTrackOutput(track: clip.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: time, duration: CMTime(seconds: 1, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }

        var image = GradeRenderer.sourceImage(from: buffer).oriented(clip.orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if image.extent.width > maxWidth {
            let s = maxWidth / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
        }
        return GradeRenderer.shared.materialize(image)
    }
}
