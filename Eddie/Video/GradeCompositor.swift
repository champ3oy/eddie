import AVFoundation
import CoreImage

/// Everything the compositor needs to draw a frame. Read on AVFoundation's threads, written by the UI,
/// so grade, framing and transition changes show up without rebuilding the player.
final class GradeState: @unchecked Sendable {
    struct Snapshot {
        var recipe: GradeRecipe
        var lut: CubeLUT
        var mode: ViewMode
        /// When set, a before/after wipe: original left of this fraction of the width, graded right of it.
        var split: Double? = nil
        /// Per-clip grades in a multi-clip project (already scaled by each clip's strength).
        var recipes: [UUID: GradeRecipe] = [:]
        /// Text drawn over the video.
        var titles: [TitleItem] = []
        /// Clips by id — framing, keyframes, source profile.
        var clips: [UUID: ClipItem] = [:]
        var overlayOpacity: [UUID: Double] = [:]
        /// Clips of another shape fill the frame (true) or fit inside it (false).
        var fill = false
        /// Fade to black at the very end (seconds) and where the end is.
        var fadeOut = 0.0
        var duration = 0.0

        func recipe(for clipID: UUID?) -> GradeRecipe {
            clipID.flatMap { recipes[$0] } ?? recipe
        }
    }

    private let lock = NSLock()
    private var value: Snapshot

    init(_ snapshot: Snapshot) { value = snapshot }

    var snapshot: Snapshot {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// One picture to draw in a frame: a video track (or a photo), placed and graded as a given clip.
final class LayerSpec: @unchecked Sendable {
    enum Role { case main, overlay }
    let clipID: UUID?
    let trackID: CMPersistentTrackID?
    let photoURL: URL?
    let orientation: CGImagePropertyOrientation
    let role: Role
    /// Where the clip starts on the timeline (for keyframes and fades).
    let start: Double
    /// Transition with the previous clip (this layer coming in) or the next one (this layer going out).
    let incoming: (kind: Transition.Kind, start: Double, duration: Double)?
    let outgoing: (kind: Transition.Kind, start: Double, duration: Double)?
    /// The first clip's fade from black.
    let fadeFromBlack: Double

    init(clipID: UUID?, trackID: CMPersistentTrackID?, photoURL: URL? = nil, orientation: CGImagePropertyOrientation,
         role: Role = .main, start: Double = 0, incoming: (Transition.Kind, Double, Double)? = nil,
         outgoing: (Transition.Kind, Double, Double)? = nil, fadeFromBlack: Double = 0) {
        self.clipID = clipID
        self.trackID = trackID
        self.photoURL = photoURL
        self.orientation = orientation
        self.role = role
        self.start = start
        self.incoming = incoming.map { (kind: $0.0, start: $0.1, duration: $0.2) }
        self.outgoing = outgoing.map { (kind: $0.0, start: $0.1, duration: $0.2) }
        self.fadeFromBlack = fadeFromBlack
    }
}

final class GradeInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    /// Bottom to top.
    let layers: [LayerSpec]
    let state: GradeState

    init(timeRange: CMTimeRange, layers: [LayerSpec], state: GradeState) {
        self.timeRange = timeRange
        self.layers = layers
        self.state = state
        let ids = Set(layers.compactMap(\.trackID))
        requiredSourceTrackIDs = ids.isEmpty ? nil : ids.sorted().map { NSNumber(value: $0) }
    }

    /// A single clip filling the whole frame (one-clip compositions, thumbnails, tests).
    convenience init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation,
                     state: GradeState, clipID: UUID? = nil) {
        self.init(timeRange: timeRange, layers: [LayerSpec(clipID: clipID, trackID: trackID, orientation: orientation)], state: state)
    }
}

/// Photos decoded once and kept (thread-safe).
enum StillCache {
    private static let cache = NSCache<NSURL, CIImage>()

    static func image(_ url: URL) -> CIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard var img = CIImage(contentsOf: url, options: [.colorSpace: NSNull(), .applyOrientationProperty: true]) else { return nil }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        // Big photos are scaled to at most 4K on the long side.
        let long = max(img.extent.width, img.extent.height)
        if long > 4096 { img = img.transformed(by: CGAffineTransform(scaleX: 4096 / long, y: 4096 / long), highQualityDownsample: true) }
        img = GradeRenderer.shared.materialize(img)
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// Draws every frame: each layer is cropped, graded (LUT only for D-Log M), framed with its keyframes,
/// blended for transitions, and titles go on top. Video arrives as 10-bit YCbCr and is processed in half float.
final class GradeCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_64RGBAHalf],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    let supportsWideColorSourceFrames = true

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? GradeInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "Eddie", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing frame"]))
            return
        }
        let snap = instruction.state.snapshot
        let size = request.renderContext.size
        let frame = CGRect(origin: .zero, size: size)
        let now = request.compositionTime.seconds

        var image: CIImage
        if let split = snap.split {
            // Before/after: the same frame without grades on the left, graded on the right.
            let before = Self.compose(instruction, request: request, snap: snap, mode: .original, size: size, now: now)
            let after = Self.compose(instruction, request: request, snap: snap, mode: .graded, size: size, now: now)
            image = before.cropped(to: CGRect(x: 0, y: 0, width: size.width * min(max(split, 0), 1), height: size.height))
                .composited(over: after)
        } else {
            image = Self.compose(instruction, request: request, snap: snap, mode: snap.mode, size: size, now: now)
        }
        for title in snap.titles where now >= title.start && now < title.end {
            if let overlay = TitleRenderer.overlay(title, renderSize: size, opacity: TitleRenderer.opacity(of: title, at: now)) {
                image = overlay.composited(over: image)
            }
        }
        if snap.fadeOut > 0, snap.duration > 0, now > snap.duration - snap.fadeOut {
            image = Self.dim(image, by: max(0, (snap.duration - now) / snap.fadeOut))
        }
        image = image.composited(over: CIImage(color: .black).cropped(to: frame)).cropped(to: frame)
        GradeRenderer.shared.context.render(image, to: output, bounds: frame, colorSpace: nil)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        request.finish(withComposedVideoFrame: output)
    }

    func cancelAllPendingVideoCompositionRequests() {}

    // MARK: Layers

    private static func compose(_ instruction: GradeInstruction, request: AVAsynchronousVideoCompositionRequest,
                                snap: GradeState.Snapshot, mode: ViewMode, size: CGSize, now: Double) -> CIImage {
        var canvas = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        for layer in instruction.layers {
            var source: CIImage
            if let url = layer.photoURL {
                guard let still = StillCache.image(url) else { continue }
                source = still
            } else if let track = layer.trackID, let buffer = request.sourceFrame(byTrackID: track) {
                source = GradeRenderer.sourceImage(from: buffer).oriented(layer.orientation)
                source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            } else {
                continue
            }
            let clip = layer.clipID.flatMap { snap.clips[$0] }
            let local = now - layer.start
            let framing = clip?.transform(at: local) ?? .identity
            let profile = clip?.profile ?? (layer.photoURL != nil ? .normal : .dlogM)

            source = crop(source, framing)
            var picture = GradeRenderer.shared.render(source, recipe: snap.recipe(for: layer.clipID), lut: snap.lut,
                                                      mode: mode, applyLUT: profile == .dlogM)
            picture = place(picture, framing, in: size, fill: layer.role == .overlay ? false : snap.fill)

            var opacity = layer.role == .overlay ? (layer.clipID.flatMap { snap.overlayOpacity[$0] } ?? 1) : 1
            var brightness = 1.0
            if layer.fadeFromBlack > 0 { brightness *= min(1, max(0, local / layer.fadeFromBlack)) }
            if let t = layer.incoming {
                let p = min(1, max(0, (now - t.start) / max(t.duration, 0.001)))
                switch t.kind {
                case .crossDissolve: opacity *= p
                case .dipToBlack: if p < 0.5 { opacity = 0 } else { brightness *= (p - 0.5) * 2 }
                case .wipe: picture = picture.cropped(to: CGRect(x: 0, y: 0, width: size.width * p, height: size.height))
                case .slide: picture = picture.transformed(by: CGAffineTransform(translationX: size.width * (1 - p), y: 0))
                }
            }
            if let t = layer.outgoing {
                let p = min(1, max(0, (now - t.start) / max(t.duration, 0.001)))
                switch t.kind {
                case .dipToBlack: brightness *= max(0, 1 - p * 2)
                case .slide: picture = picture.transformed(by: CGAffineTransform(translationX: -size.width * p, y: 0))
                case .crossDissolve, .wipe: break
                }
            }
            if brightness < 0.999 { picture = dim(picture, by: brightness) }
            if opacity < 0.999 { picture = fade(picture, to: opacity) }
            if opacity > 0.001 { canvas = picture.composited(over: canvas) }
        }
        return canvas
    }

    /// Cuts the crop margins off the source (fractions of its size; Core Image's y axis points up).
    static func crop(_ image: CIImage, _ t: Transform2D) -> CIImage {
        guard t.cropLeft > 0 || t.cropRight > 0 || t.cropTop > 0 || t.cropBottom > 0 else { return image }
        let e = image.extent
        let rect = CGRect(x: e.minX + e.width * t.cropLeft, y: e.minY + e.height * t.cropBottom,
                          width: e.width * max(0.05, 1 - t.cropLeft - t.cropRight),
                          height: e.height * max(0.05, 1 - t.cropTop - t.cropBottom))
        let cropped = image.cropped(to: rect)
        return cropped.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Scales the picture to fill (or fit) the frame, then applies the clip's zoom, offset and rotation.
    static func place(_ image: CIImage, _ t: Transform2D, in size: CGSize, fill: Bool) -> CIImage {
        let w = max(1, image.extent.width), h = max(1, image.extent.height)
        let base = fill ? max(size.width / w, size.height / h) : min(size.width / w, size.height / h)
        let s = base * CGFloat(t.scale)
        let m = CGAffineTransform(translationX: -w / 2 - image.extent.minX, y: -h / 2 - image.extent.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(rotationAngle: -CGFloat(t.rotation) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: size.width / 2 + CGFloat(t.x) * size.width,
                                             y: size.height / 2 - CGFloat(t.y) * size.height))
        return image.transformed(by: m, highQualityDownsample: s < 1)
    }

    /// Multiplies colour (not transparency): fades toward black.
    static func dim(_ image: CIImage, by f: Double) -> CIImage {
        let v = CGFloat(max(0, min(1, f)))
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: v, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: v, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: v, w: 0),
        ])
    }

    /// Makes the picture see-through.
    static func fade(_ image: CIImage, to opacity: Double) -> CIImage {
        let o = CGFloat(max(0, min(1, opacity)))
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: o, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: o, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: o, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: o),
        ])
    }
}

/// A loaded clip: its video track, display orientation and a video composition wired to a `GradeState`.
struct VideoClip {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let duration: CMTime
    let naturalSize: CGSize
    let displaySize: CGSize
    let frameRate: Float
    let orientation: CGImagePropertyOrientation
    /// 10-bit footage tagged Rec.709 (not HLG/PQ HDR) — how DJI cameras record D-Log M.
    var isLikelyLog = false

    enum LoadError: LocalizedError {
        case noVideo
        var errorDescription: String? { "This file has no video track." }
    }

    static func load(_ url: URL) async throws -> VideoClip {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LoadError.noVideo }
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let orientation = Self.orientation(for: transform)
        let display = size.applying(transform)
        var log = false
        if let format = try await track.load(.formatDescriptions).first {
            let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
            let bits = bitDepth(of: format)
            let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? ""
            let hdr = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            log = bits >= 10 && !hdr
        }
        return VideoClip(asset: asset, track: track, audioTrack: audio, duration: duration, naturalSize: size,
                         displaySize: CGSize(width: abs(display.width), height: abs(display.height)),
                         frameRate: fps > 0 ? fps : 30, orientation: orientation, isLikelyLog: log)
    }

    static func bitDepth(of format: CMFormatDescription) -> Int {
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        return ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int ?? 8
    }

    /// Maps a track's preferred transform (rotation) to a Core Image orientation.
    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): return .right   // rotated 90° clockwise
        case (0, -1, 1, 0): return .left    // rotated 90° counter-clockwise
        case (-1, 0, 0, -1): return .down   // 180°
        default: return .up
        }
    }

    func makeComposition(state: GradeState) -> AVVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = GradeCompositor.self
        composition.renderSize = displaySize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate.rounded())))
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        composition.instructions = [GradeInstruction(timeRange: CMTimeRange(start: .zero, duration: duration),
                                                     trackID: track.trackID, orientation: orientation, state: state)]
        return composition
    }
}
