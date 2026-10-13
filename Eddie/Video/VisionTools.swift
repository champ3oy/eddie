import AVFoundation
import CoreImage
import Vision

/// Analysis with Apple's Vision framework, on this Mac: following the subject (auto reframe), steadying
/// shaky footage, tracking an object for an overlay, and cutting people out of their background.
enum VisionTools {
    enum VisionError: LocalizedError {
        case noRoom, nothingFound, noFrames
        var errorDescription: String? {
            switch self {
            case .noRoom: return "This clip already fits the frame, so there's no room to reframe it. Try a different shape (like Vertical 9:16) first."
            case .nothingFound: return "Couldn't find anything to follow in this clip."
            case .noFrames: return "Couldn't read frames from this clip."
            }
        }
    }

    /// Frames of a clip at local times (seconds into the clip), small, upright.
    static func frames(_ clip: ClipItem, times: [Double], maxSide: CGFloat = 512) async throws -> [(Double, CGImage)] {
        let asset = AVURLAsset(url: clip.url)
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: maxSide, height: maxSide)
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        var out: [(Double, CGImage)] = []
        for t in times {
            let source = clip.sourceStart + t * clip.speed
            if let (cg, _) = try? await g.image(at: CMTime(seconds: source, preferredTimescale: 600)) { out.append((t, cg)) }
        }
        guard !out.isEmpty else { throw VisionError.noFrames }
        return out
    }

    /// How much wider/taller the clip is than the frame once it fills it (1 = exactly fits).
    static func overflow(source: CGSize, frame: CGSize) -> (x: Double, y: Double) {
        let base = max(frame.width / source.width, frame.height / source.height)
        return (Double(source.width * base / frame.width), Double(source.height * base / frame.height))
    }

    static func smooth(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > 2 else { return values }
        return values.indices.map { i in
            let a = max(0, i - window / 2), b = min(values.count - 1, i + window / 2)
            return values[a...b].reduce(0, +) / Double(b - a + 1)
        }
    }

    // MARK: Auto reframe

    /// Keyframes that keep the subject (people, faces, or whatever stands out) centered when the clip is cropped
    /// to fill a frame of another shape.
    static func reframe(_ clip: ClipItem, source: CGSize, frame: CGSize) async throws -> [Keyframe] {
        let room = overflow(source: source, frame: frame)
        guard room.x > 1.01 || room.y > 1.01 else { throw VisionError.noRoom }
        let step = 0.5
        let times = stride(from: 0.0, through: clip.duration, by: step).map { $0 } + (clip.duration.truncatingRemainder(dividingBy: step) > 0.1 ? [clip.duration] : [])
        let frames = try await frames(clip, times: times)
        var centers: [(Double, CGPoint)] = []
        for (t, image) in frames {
            if let c = subjectCenter(image) { centers.append((t, c)) }
        }
        guard !centers.isEmpty else { throw VisionError.nothingFound }
        let xs = smooth(centers.map { Double($0.1.x) }, window: 3)
        let ys = smooth(centers.map { 1 - Double($0.1.y) }, window: 3)   // Vision's y points up
        return centers.indices.map { i in
            var t = clip.transform
            if room.x > 1.01 { t.x = min(max(-(xs[i] - 0.5) * room.x, -(room.x - 1) / 2), (room.x - 1) / 2) }
            if room.y > 1.01 { t.y = min(max(-(ys[i] - 0.5) * room.y, -(room.y - 1) / 2), (room.y - 1) / 2) }
            return Keyframe(time: centers[i].0, transform: t)
        }
    }

    /// Where the subject is (normalized, Vision coordinates): people first, then faces, then what stands out.
    static func subjectCenter(_ image: CGImage) -> CGPoint? {
        let handler = VNImageRequestHandler(cgImage: image)
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([humans, faces, saliency])
        func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
        if let biggest = (humans.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            return center(biggest.boundingBox)
        }
        if let biggest = (faces.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }) { return center(biggest.boundingBox) }
        if let map = saliency.results?.first?.pixelBuffer, let c = centroid(map) { return c }
        if let salient = saliency.results?.first?.salientObjects?.max(by: { $0.confidence < $1.confidence }) { return center(salient.boundingBox) }
        return nil
    }

    /// The weighted center of a saliency heat map (normalized, y up), favoring the hottest spots.
    static func centroid(_ buffer: CVPixelBuffer) -> CGPoint? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        var peak: Float = 0
        for y in 0..<h { let r = (base + y * row).assumingMemoryBound(to: Float.self); for x in 0..<w { peak = max(peak, r[x]) } }
        guard peak > 0 else { return nil }
        var sx = 0.0, sy = 0.0, total = 0.0
        for y in 0..<h {
            let r = (base + y * row).assumingMemoryBound(to: Float.self)
            for x in 0..<w {
                let v = Double(r[x] / peak)
                guard v > 0.5 else { continue }   // only the hot spots
                let wgt = v * v
                sx += (Double(x) + 0.5) * wgt; sy += (Double(y) + 0.5) * wgt; total += wgt
            }
        }
        guard total > 0 else { return nil }
        // Rows run top to bottom in the buffer; Vision's y points up.
        return CGPoint(x: sx / total / Double(w), y: 1 - sy / total / Double(h))
    }

    // MARK: Stabilize

    /// Keyframes that cancel camera shake: the camera's path is measured frame to frame, smoothed, and the
    /// difference is countered with a small zoom to hide the edges. `strength` 0…1.
    static func stabilize(_ clip: ClipItem, source: CGSize, frame: CGSize, strength: Double = 0.7) async throws -> [Keyframe] {
        let rate = 10.0
        let times = stride(from: 0.0, through: clip.duration, by: 1 / rate).map { $0 }
        let frames = try await frames(clip, times: times, maxSide: 480)
        guard frames.count > 3 else { throw VisionError.noFrames }
        // Camera path in fractions of the picture (x right, y down).
        var path: [(Double, Double)] = [(0, 0)]
        for i in 1..<frames.count {
            let prev = frames[i - 1].1, next = frames[i].1
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: next)
            try? VNImageRequestHandler(cgImage: prev).perform([request])
            let shift = request.results?.first?.alignmentTransform ?? .identity
            let last = path[path.count - 1]
            path.append((last.0 + Double(shift.tx) / Double(prev.width), last.1 - Double(shift.ty) / Double(prev.height)))
        }
        let window = max(3, Int(rate * (0.6 + 1.4 * strength)))
        let sx = smooth(path.map(\.0), window: window), sy = smooth(path.map(\.1), window: window)
        let zoom = 1.0 + 0.04 + 0.08 * strength
        let room = overflow(source: source, frame: frame)
        return frames.indices.map { i in
            var t = clip.transform
            t.scale = max(t.scale, 1) * zoom
            // Move the picture against the shake (the part of the path the smoothing took out).
            let dx = (path[i].0 - sx[i]) * room.x * zoom, dy = (path[i].1 - sy[i]) * room.y * zoom
            let limit = (zoom - 1) / 2
            t.x += min(max(dx, -limit), limit)
            t.y += min(max(dy, -limit), limit)
            return Keyframe(time: frames[i].0, transform: t)
        }
    }

    // MARK: Motion tracking

    /// Follows what's under an overlay through the edit (in finished-frame coordinates) and returns keyframes
    /// that move the overlay with it. `box` is the overlay's area at `startTime`, normalized with y from the top.
    static func track(composition: AVAsset, videoComposition: AVVideoComposition?, box: CGRect, from startTime: Double,
                      to endTime: Double, overlayStart: Double, base: Transform2D) async throws -> [Keyframe] {
        let g = AVAssetImageGenerator(asset: composition)
        g.videoComposition = videoComposition
        g.maximumSize = CGSize(width: 640, height: 640)
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        let rate = 12.0
        var observation = VNDetectedObjectObservation(boundingBox: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        let sequence = VNSequenceRequestHandler()
        var keys: [Keyframe] = [Keyframe(time: startTime - overlayStart, transform: base)]
        let startCenter = CGPoint(x: box.midX, y: box.midY)
        var t = startTime
        while t + 1 / rate <= endTime {
            t += 1 / rate
            guard let (cg, _) = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            try? sequence.perform([request], on: cg)
            guard let result = request.results?.first as? VNDetectedObjectObservation, result.confidence > 0.25 else { break }
            observation = result
            let c = CGPoint(x: result.boundingBox.midX, y: 1 - result.boundingBox.midY)
            var k = base
            k.x = base.x + Double(c.x - startCenter.x)
            k.y = base.y + Double(c.y - startCenter.y)
            keys.append(Keyframe(time: t - overlayStart, transform: k))
        }
        guard keys.count > 1 else { throw VisionError.nothingFound }
        return keys
    }

    // MARK: People cut-out

    /// A mask of the people in the picture (white = person), at the picture's size. nil if there's no one.
    static func personMask(_ image: CIImage, accurate: Bool) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = accurate ? .accurate : .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        let e = image.extent
        return mask.transformed(by: CGAffineTransform(scaleX: e.width / mask.extent.width, y: e.height / mask.extent.height)
            .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
    }

    /// The picture with everything but people made transparent.
    static func removeBackground(_ image: CIImage, accurate: Bool = false) -> CIImage {
        guard let mask = personMask(image, accurate: accurate) else { return CIImage(color: .clear).cropped(to: image.extent) }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: image.extent)
    }
}
